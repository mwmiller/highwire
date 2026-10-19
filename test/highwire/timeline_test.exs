defmodule HighWire.TimelineTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias HighWire.SSB.Client
  alias HighWire.Timeline

  # A feed message carrying `content` for the given author/key.
  defp msg(author, key, timestamp, content) do
    %{
      "key" => key,
      "value" => %{"author" => author, "timestamp" => timestamp, "content" => content}
    }
  end

  defp vote(author, key, timestamp, vote_props) do
    msg(author, key, timestamp, Map.put(vote_props, "type", "vote"))
  end

  # Answers Client.stream/4-shaped calls without a network and records
  # them, so tests can prove which connection a stream opened on; the
  # first contacts item boots the feed streams through this. Client
  # calls are recorded too (blobs.want, profile avatar) and reply with
  # a plain {:ok, nil} — the avatar fetch misses, which is what a want
  # test wants: no profiles fetched, only blob refs.
  defmodule FakeClient do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    def streams(client), do: GenServer.call(client, :streams)

    def calls(client), do: GenServer.call(client, :calls)

    @impl true
    def init(_), do: {:ok, {[], []}}

    @impl true
    def handle_call({:stream, name, args, _subscriber}, _from, {streams, calls}) do
      {:reply, {:ok, make_ref()}, {[{name, args} | streams], calls}}
    end

    def handle_call({:call, ["publish"], args}, _from, {streams, calls}) do
      {:reply, {:ok, %{"key" => "%published=.sha256"}}, {streams, [{["publish"], args} | calls]}}
    end

    def handle_call({:call, name, args}, _from, {streams, calls}) do
      {:reply, {:ok, nil}, {streams, [{name, args} | calls]}}
    end

    def handle_call(:streams, _from, {streams, _calls} = state) do
      {:reply, Enum.reverse(streams), state}
    end

    def handle_call(:calls, _from, {_streams, calls} = state) do
      {:reply, Enum.reverse(calls), state}
    end
  end

  describe "publish content builders" do
    test "post content is type + text" do
      assert Timeline.post_content("hi") == %{"type" => "post", "text" => "hi"}
    end

    test "reply content carries root and branch" do
      assert Timeline.reply_content("%root=.sha256", "%parent=.sha256", "yo") == %{
               "type" => "post",
               "text" => "yo",
               "root" => "%root=.sha256",
               "branch" => "%parent=.sha256"
             }
    end

    test "vote content matches this network's production shape" do
      assert Timeline.vote_content("%target=.sha256", 1) == %{
               "type" => "vote",
               "vote" => %{
                 "link" => "%target=.sha256",
                 "value" => 1,
                 "expression" => "like"
               }
             }
    end

    test "contact content toggles following" do
      assert Timeline.contact_content("@peer.ed25519", true) == %{
               "type" => "contact",
               "contact" => "@peer.ed25519",
               "following" => true
             }

      assert Timeline.contact_content("@peer.ed25519", false)["following"] == false
    end
  end

  describe "vote_link/1" do
    test "nested vote shape (what this network publishes)" do
      c = %{"type" => "vote", "vote" => %{"link" => "%a=.sha256", "value" => 1}}
      assert Timeline.vote_link(c) == "%a=.sha256"
    end

    test "classic js-client value shape" do
      c = %{"type" => "vote", "value" => %{"link" => "%b=.sha256", "value" => 1}}
      assert Timeline.vote_link(c) == "%b=.sha256"
    end

    test "flat link shape" do
      assert Timeline.vote_link(%{"type" => "vote", "link" => "%c=.sha256"}) == "%c=.sha256"
    end

    test "non-votes and malformed votes are nil" do
      assert Timeline.vote_link(%{"type" => "post"}) == nil
      assert Timeline.vote_link(%{"type" => "vote", "vote" => %{}}) == nil
    end
  end

  describe "likes_state/3 pipeline" do
    test "one like per author; the latest vote per author wins" do
      msgs = [
        vote("a1", "%v1", 1_000, %{"vote" => %{"link" => "%t", "value" => 1}}),
        vote("a2", "%v2", 2_000, %{"vote" => %{"link" => "%t", "value" => 1}}),
        # a1 retracts later — both messages are in the window.
        vote("a1", "%v3", 3_000, %{"vote" => %{"link" => "%t", "value" => 0}})
      ]

      likes = Timeline.likes_state(msgs)

      assert Timeline.like_counts(likes) == %{"%t" => 1}
      assert Timeline.my_likes(likes, "a1") == []
      assert Timeline.my_likes(likes, "a2") == ["%t"]
      assert Timeline.my_likes(likes, "nobody") == []
    end

    test "latest wins by timestamp even when the list order differs" do
      older = vote("a1", "%v1", 1_000, %{"vote" => %{"link" => "%t", "value" => 0}})
      newer = vote("a1", "%v2", 2_000, %{"vote" => %{"link" => "%t", "value" => 1}})

      likes = Timeline.likes_state([newer, older])

      assert Timeline.like_counts(likes) == %{"%t" => 1}
      assert Timeline.my_likes(likes, "a1") == ["%t"]
    end

    test "counts all three vote shapes together" do
      msgs = [
        vote("a1", "%v1", 1_000, %{"vote" => %{"link" => "%t", "value" => 1}}),
        vote("a2", "%v2", 2_000, %{"value" => %{"link" => "%t", "value" => 1}}),
        vote("a3", "%v3", 3_000, %{"link" => "%t"})
      ]

      assert Timeline.likes_state(msgs) |> Timeline.like_counts() == %{"%t" => 3}
    end

    test "non-vote messages never enter the state" do
      msgs = [msg("a1", "%v1", 1_000, %{"type" => "post", "text" => "hi"})]

      assert Timeline.likes_state(msgs) == %{}
    end

    test "like_authors lists positive voters newest-first, retractions out" do
      msgs = [
        vote("a1", "%v1", 1_000, %{"vote" => %{"link" => "%t", "value" => 1}}),
        vote("a2", "%v2", 2_000, %{"vote" => %{"link" => "%t", "value" => 1}}),
        # a1 takes it back — the voter disappears from the list.
        vote("a1", "%v3", 3_000, %{"vote" => %{"link" => "%t", "value" => 0}}),
        vote("a3", "%v4", 4_000, %{"vote" => %{"link" => "%u", "value" => 1}})
      ]

      assert Timeline.likes_state(msgs) |> Timeline.like_authors() == %{
               "%t" => ["a2"],
               "%u" => ["a3"]
             }
    end

    test "like_authors orders voters by vote recency" do
      older = vote("a1", "%v1", 1_000, %{"vote" => %{"link" => "%t", "value" => 1}})
      newer = vote("a2", "%v2", 2_000, %{"vote" => %{"link" => "%t", "value" => 1}})

      likes = Timeline.likes_state([older, newer])

      assert Timeline.like_authors(likes) == %{"%t" => ["a2", "a1"]}
    end
  end

  describe "build_feed/3" do
    # Thread factory: root nil → a rootless (own-key) post. Keys carry
    # the .sha256 suffix msg_id?/1 requires of thread root references.
    defp post(author, key, ts, root \\ nil) do
      content = %{"type" => "post", "text" => "hi"}
      content = if root, do: Map.put(content, "root", root), else: content
      msg(author, key, ts, content)
    end

    test "a post-edit collapses onto the post it revises, newest text wins" do
      root = post("@alice", "%root.sha256", 1_000)

      edit =
        msg("@alice", "%edit.sha256", 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%root.sha256",
          "text" => "revised"
        })

      assert [row] = Timeline.build_feed([root, edit], "@me", %{})
      assert row.root_key == "%root.sha256"
      assert row.msg["key"] == "%edit.sha256"
      assert row.msg["value"]["content"]["text"] == "revised"
      assert row.edited_by == ["@alice"]
      # the edit is activity on the post, so the row sits at the edit's time
      assert row.activity == 2_000
    end

    test "the newest revision wins when several edits land" do
      root = post("@alice", "%root.sha256", 1_000)

      first =
        msg("@alice", "%e1.sha256", 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%root.sha256",
          "text" => "one"
        })

      second =
        msg("@alice", "%e2.sha256", 3_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%root.sha256",
          "text" => "two"
        })

      assert [row] = Timeline.build_feed([root, first, second], "@me", %{})
      assert row.msg["value"]["content"]["text"] == "two"
      assert row.edited_by == ["@alice", "@alice"]
    end

    test "an edit of a reply joins the reply's thread, not its own row" do
      root = post("@alice", "%root.sha256", 1_000)
      reply = post("@bob", "%reply.sha256", 2_000, "%root.sha256")

      edit =
        msg("@bob", "%edit.sha256", 3_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%reply.sha256",
          "text" => "revised reply"
        })

      assert [row] = Timeline.build_feed([root, reply, edit], "@me", %{})
      assert row.root_key == "%root.sha256"
      assert row.edited_by == ["@bob"]
    end

    test "an edit whose target is outside the window stands alone" do
      edit =
        msg("@alice", "%edit.sha256", 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%gone.sha256",
          "text" => "orphan"
        })

      assert [row] = Timeline.build_feed([edit], "@me", %{})
      assert row.kind == :other
    end

    test "an edit never lets one message head two rows" do
      root = post("@alice", "%root.sha256", 1_000)

      edit =
        msg("@alice", "%edit.sha256", 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%root.sha256",
          "text" => "revised"
        })

      assert [row] = Timeline.build_feed([root, edit, edit], "@me", %{})
      assert row.root_key == "%root.sha256"
    end

    test "root likes count once when the root sits in the window" do
      root = post("@alice", "%root.sha256", 1_000)
      reply = post("@bob", "%reply.sha256", 2_000, "%root.sha256")

      assert [row] = Timeline.build_feed([root, reply], "@me", %{"%root.sha256" => 2})
      assert row.likes == 2
    end

    test "mid-chain roots merge under the thread root" do
      root = post("@alice", "%root.sha256", 1_000)
      mid = post("@bob", "%mid.sha256", 2_000, "%root.sha256")
      # a client that set root to its parent instead of the thread head
      deep = post("@carol", "%deep.sha256", 3_000, "%mid.sha256")

      assert [row] = Timeline.build_feed([root, mid, deep], "@me", %{})
      assert row.root_key == "%root.sha256"
      assert row.msg["key"] == "%root.sha256"
      assert row.rooted?

      # the raw root-key count only sees mid; the label counts both posts
      assert row.replies == 2
    end

    test "a missing root never lets one message head two rows" do
      mid = post("@alice", "%mid.sha256", 2_000, "%gone.sha256")
      older = post("@bob", "%older.sha256", 1_500, "%gone.sha256")
      deep = post("@carol", "%deep.sha256", 3_000, "%mid.sha256")

      assert [row] = Timeline.build_feed([mid, older, deep], "@me", %{})
      refute row.rooted?
      assert row.root_key == "%gone.sha256"

      # newest post heads the row, and never previews itself
      assert row.msg["key"] == "%deep.sha256"
      assert Enum.map(row.recent, & &1["key"]) == ["%mid.sha256", "%older.sha256"]
      assert row.replies == 2
    end

    test "an in-window head is excluded from its own recent previews" do
      root = post("@alice", "%root.sha256", 1_000)
      reply = post("@bob", "%reply.sha256", 2_000, "%root.sha256")

      assert [row] = Timeline.build_feed([root, reply], "@me", %{})
      assert row.msg["key"] == "%root.sha256"
      assert Enum.map(row.recent, & &1["key"]) == ["%reply.sha256"]
    end

    test "cyclic roots terminate instead of hanging" do
      a = post("@alice", "%a.sha256", 1_000, "%b.sha256")
      b = post("@bob", "%b.sha256", 2_000, "%a.sha256")

      assert is_list(Timeline.build_feed([a, b], "@me", %{}))
    end

    test "contact edits group by direction: a block is not a follow" do
      follow =
        msg("@alice", "%f1.sha256", 1_000, %{
          "type" => "contact",
          "contact" => "@dave.ed25519",
          "following" => true
        })

      block =
        msg("@alice", "%b1.sha256", 2_000, %{
          "type" => "contact",
          "contact" => "@eve.ed25519",
          "blocking" => true
        })

      unfollow =
        msg("@alice", "%u1.sha256", 3_000, %{
          "type" => "contact",
          "contact" => "@frank.ed25519",
          "following" => false
        })

      # a block that also carries following: false stays a block
      both =
        msg("@alice", "%b2.sha256", 4_000, %{
          "type" => "contact",
          "contact" => "@gina.ed25519",
          "blocking" => true,
          "following" => false
        })

      rows = Timeline.build_feed([follow, block, unfollow, both], "@me", %{})

      # one row per author per direction, newest edit first: both blocks
      # collapse into one row (which never claims those feeds were
      # followed), and the follow/unfollow stay distinct
      assert Enum.map(rows, &{&1.contact_action, Map.get(&1, &1.contact_action)}) == [
               {:blocked, ["@eve.ed25519", "@gina.ed25519"]},
               {:unfollowed, ["@frank.ed25519"]},
               {:followed, ["@dave.ed25519"]}
             ]
    end
  end

  describe "contacts stream items" do
    defp contacts_state(overrides \\ %{}) do
      Map.merge(
        %{
          client: start_supervised!(FakeClient),
          contacts_ref: :contacts_ref,
          contacts_primed?: false,
          contact_ref: nil,
          contact_buf: [],
          contact_msgs: [],
          about_ref: nil,
          about_ids: MapSet.new(),
          drain_client: nil,
          last_drain_at: nil,
          follows: [],
          self_id: "@me.ed25519",
          status: :connecting,
          acc: [],
          pending: %{},
          reload_timer: nil,
          gen: 0
        },
        overrides
      )
    end

    defp item(graph) do
      {Client, :contacts_ref, {:item, graph}}
    end

    test "first item after connect replaces; later items merge" do
      st = contacts_state()

      {:noreply, st} =
        Timeline.handle_info(item(%{"@a.ed25519" => true, "@b.ed25519" => true}), st)

      assert Enum.sort(st.follows) == ["@a.ed25519", "@b.ed25519", "@me.ed25519"]
      assert st.contacts_primed?

      # a live delta — must merge, not replace
      {:noreply, st} = Timeline.handle_info(item(%{"@c.ed25519" => true}), st)
      assert Enum.sort(st.follows) == ["@a.ed25519", "@b.ed25519", "@c.ed25519", "@me.ed25519"]

      # unfollow arrives as null — edge drops, self stays pinned
      {:noreply, st} = Timeline.handle_info(item(%{"@a.ed25519" => nil}), st)
      assert Enum.sort(st.follows) == ["@b.ed25519", "@c.ed25519", "@me.ed25519"]

      # false (block) drops the edge too
      {:noreply, st} = Timeline.handle_info(item(%{"@c.ed25519" => false}), st)
      assert Enum.sort(st.follows) == ["@b.ed25519", "@me.ed25519"]
    end

    test "self is always pinned, even when the graph mentions it" do
      st = contacts_state()

      {:noreply, st} = Timeline.handle_info(item(%{"@me.ed25519" => true}), st)
      assert st.follows == ["@me.ed25519"]
    end

    test "the first item boots the feed streams; later items schedule reloads" do
      st = contacts_state()

      # first item continues the boot sequence: feeds open, no reload
      {:noreply, st} = Timeline.handle_info(item(%{"@a.ed25519" => true}), st)
      assert st.status == :loading
      assert map_size(st.pending) == 2

      # a delta merges and schedules a prompt reload
      {:noreply, st2} = Timeline.handle_info(item(%{"@a.ed25519" => true}), st)
      assert_received {:reload, 0}
      assert st2.contacts_primed?
    end
  end

  describe "contact drain (messagesByType)" do
    # Follow events sit outside the per-feed window and never enter the
    # paged publicFeed — the store-wide drain is what keeps them on the
    # timeline at all.
    defp drain_state(overrides) do
      post = msg("@me.ed25519", "%p=.sha256", 5_000, %{"type" => "post", "text" => "hi"})

      follow =
        msg("@a.ed25519", "%c=.sha256", 1_000, %{"type" => "contact", "contact" => "@b=.ed25519"})

      Map.merge(
        %{
          client: start_supervised!(FakeClient),
          contact_ref: :contact_ref,
          contact_buf: [],
          contact_msgs: [],
          about_ref: nil,
          about_ids: MapSet.new(),
          drain_client: nil,
          last_drain_at: nil,
          contacts_ref: nil,
          contacts_primed?: true,
          profile_fetching?: false,
          # @a is a follow id too, so the contact author's profile is
          # never narrowed out of the payload between the two builds.
          follows: ["@me.ed25519", "@a.ed25519"],
          self_id: "@me.ed25519",
          status: :loading,
          acc: [post],
          pending: %{},
          messages: %{feed: [], profiles: %{"@me.ed25519" => %{}, "@a.ed25519" => %{}}},
          blob_rev: 0,
          gen: 0,
          done_count: 0,
          reload_timer: nil,
          active: %{self() => make_ref()}
        },
        Map.new(overrides)
      )
      |> Map.put(:_post, post)
      |> Map.put(:_follow, follow)
    end

    test "a drain landing after the feed payload rebuilds with follow rows, window intact" do
      st = drain_state(pending: %{123 => "@me.ed25519"})

      # the feed window finishes first: payload is final, no contacts yet
      {:noreply, st} = Timeline.handle_info({Client, 123, :done}, st)
      assert st.status == :ok
      assert Enum.any?(st.messages.feed, &(&1.msg["key"] == "%p=.sha256"))
      refute Enum.any?(st.messages.feed, &(&1.kind == :contact))

      # then the drain lands
      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, {:item, st._follow}}, st)
      assert st.contact_buf == [st._follow]
      assert st.contact_msgs == []

      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, :done}, st)
      assert st.contact_ref == nil
      assert st.contact_msgs == [st._follow]

      # the rebuild carries follow rows AND the window it already had
      assert Enum.any?(st.messages.feed, &(&1.kind == :contact))
      assert Enum.any?(st.messages.feed, &(&1.msg["key"] == "%p=.sha256"))
    end

    test "a drain finishing mid-stream merges quietly; the feed's own finalize carries it" do
      st = drain_state(status: :ok, pending: %{123 => "@me.ed25519"})

      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, {:item, st._follow}}, st)
      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, :done}, st)

      # merged, but no rebuild while the feed window is still streaming
      assert st.contact_msgs == [st._follow]
      assert st.messages.feed == []

      # the feed's finalize pass picks the drain up
      {:noreply, st} = Timeline.handle_info({Client, 123, :done}, st)
      assert Enum.any?(st.messages.feed, &(&1.kind == :contact))
      assert Enum.any?(st.messages.feed, &(&1.msg["key"] == "%p=.sha256"))
    end

    test "a repeat of an already-known contact neither accumulates nor rebroadcasts" do
      st =
        drain_state(
          status: :ok,
          pending: %{},
          contact_msgs: [
            st_follow =
              msg("@a.ed25519", "%c=.sha256", 1_000, %{
                "type" => "contact",
                "contact" => "@b=.ed25519"
              })
          ],
          messages: %{feed: [:untouched], profiles: %{}}
        )

      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, {:item, st_follow}}, st)
      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, :done}, st)

      assert st.contact_msgs == [st_follow]
      assert st.messages.feed == [:untouched]
    end

    test "a stream error drops the buffer and keeps what already merged" do
      st = drain_state(contact_msgs: ["kept"], contact_buf: ["partial"])

      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, {:error, :closed}}, st)
      assert st.contact_ref == nil
      assert st.contact_buf == []
      assert st.contact_msgs == ["kept"]
    end

    test "a reload opens the drain alongside the feed window" do
      st = drain_state(contact_ref: nil, status: :ok)

      {:noreply, st} = Timeline.handle_info({:reload, 0}, st)
      assert is_reference(st.contact_ref)
      # The about pass opens on the same reload, in its own slot.
      assert is_reference(st.about_ref)
      assert map_size(st.pending) >= 1
      assert st.acc == []
    end

    test "the drain opens on its dedicated connection, never the shared one" do
      main = start_supervised!(%{id: :fake_main, start: {FakeClient, :start_link, [nil]}})

      dedicated =
        start_supervised!(%{id: :fake_dedicated, start: {FakeClient, :start_link, [nil]}})

      st = drain_state(contact_ref: nil, status: :ok, client: main, drain_client: dedicated)

      {:noreply, st} = Timeline.handle_info({:reload, 0}, st)

      assert is_reference(st.contact_ref)
      assert st.drain_client == dedicated

      assert FakeClient.streams(dedicated) == [
               {["messagesByType"], [%{"type" => "contact"}]},
               {["messagesByType"], [%{"type" => "about"}]}
             ]

      # the shared connection carries only the per-feed windows
      assert FakeClient.streams(main) != []

      assert Enum.all?(FakeClient.streams(main), fn {name, _args} ->
               name != ["messagesByType"]
             end)
    end

    test "a completed drain is not re-opened on the next reload" do
      st =
        drain_state(
          contact_ref: nil,
          status: :ok,
          last_drain_at: System.monotonic_time(:millisecond)
        )

      {:noreply, st} = Timeline.handle_info({:reload, 0}, st)
      assert st.contact_ref == nil
      assert st.about_ref == nil
    end

    test "the drain re-opens once the refresh window has passed" do
      stale = System.monotonic_time(:millisecond) - 16 * 60_000
      st = drain_state(contact_ref: nil, status: :ok, last_drain_at: stale)

      {:noreply, st} = Timeline.handle_info({:reload, 0}, st)
      assert is_reference(st.contact_ref)
    end

    test "a completed pass stamps the refresh window" do
      st = drain_state(status: :ok, pending: %{})

      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, :done}, st)
      assert is_integer(st.last_drain_at)
    end

    test "a stream error drops the buffer, keeps what merged, and rotates the connection" do
      dedicated =
        start_supervised!(%{id: :fake_error_client, start: {FakeClient, :start_link, [nil]}})

      st = drain_state(contact_msgs: ["kept"], contact_buf: ["partial"], drain_client: dedicated)

      {:noreply, st} = Timeline.handle_info({Client, :contact_ref, {:error, :closed}}, st)
      assert st.contact_ref == nil
      assert st.contact_buf == []
      assert st.contact_msgs == ["kept"]
      assert st.drain_client == nil
    end

    test "drain connection death clears the dangling refs" do
      st =
        drain_state(
          contact_ref: :contact_ref,
          contact_buf: ["partial"],
          about_ref: :about_ref,
          drain_client: self()
        )

      {:noreply, st} = Timeline.handle_info({:EXIT, self(), :closed}, st)
      assert st.drain_client == nil
      assert st.contact_ref == nil
      assert st.contact_buf == []
      assert st.about_ref == nil
    end

    test "the about pass folds feed targets and completes into the filter" do
      st = drain_state(about_ref: :about_ref, status: :ok)

      about =
        msg("@b=.ed25519", "%a=.sha256", 9_000, %{"type" => "about", "about" => "@b=.ed25519"})

      # Abouts that target a message, or of another type, name no feed.
      other =
        msg("@c=.ed25519", "%d=.sha256", 9_000, %{"type" => "about", "about" => "%m=.sha256"})

      {:noreply, st} = Timeline.handle_info({Client, :about_ref, {:item, about}}, st)
      {:noreply, st} = Timeline.handle_info({Client, :about_ref, {:item, other}}, st)

      assert st.about_ids == MapSet.new(["@b=.ed25519"])

      # The contact pass is untouched while the about pass runs.
      assert st.contact_ref == :contact_ref

      {:noreply, st} = Timeline.handle_info({Client, :about_ref, :done}, st)

      assert st.about_ref == nil
      assert st.about_ids == MapSet.new(["@b=.ed25519"])
    end

    test "a completed about pass marks an empty store" do
      # An empty pass must read as "no abouts in the store" — nil means
      # "not read yet" and would keep the filter off forever.
      st = drain_state(about_ref: :about_ref, status: :ok)
      {:noreply, st} = Timeline.handle_info({Client, :about_ref, :done}, st)
      assert st.about_ids == MapSet.new()
    end

    test "a failed about pass keeps whatever arrived" do
      st = drain_state(about_ref: :about_ref, about_ids: MapSet.new(["@b=.ed25519"]))

      {:noreply, st} = Timeline.handle_info({Client, :about_ref, {:error, :closed}}, st)

      assert st.about_ref == nil
      assert st.about_ids == MapSet.new(["@b=.ed25519"])
    end
  end

  describe "blob wants" do
    # A body embedding an image the store has never seen, with every
    # profile already known — the finalize shape where the worker used
    # to be skipped on an empty missing list, taking every blob want
    # with it. Fresh posts by known authors are the common case.
    test "ride even when every profile is already known" do
      client = start_supervised!(%{id: :blob_client, start: {FakeClient, :start_link, [nil]}})
      img = "&" <> String.duplicate("A", 43) <> "=.sha256"

      post =
        msg("@me.ed25519", "%p=.sha256", 5_000, %{"type" => "post", "text" => "![x](#{img})"})

      st = drain_state(pending: %{123 => "@me.ed25519"}, acc: [post], client: client)

      {:noreply, st} = Timeline.handle_info({Client, 123, :done}, st)

      assert st.profile_fetching?
      assert_receive {:profiles_fetched, _}, 2_000
      assert Enum.any?(FakeClient.calls(client), &match?({["blobs", "want"], [^img]}, &1))
    end

    test "no worker when nothing is missing and nothing is unseen" do
      st = drain_state(pending: %{123 => "@me.ed25519"})

      {:noreply, st} = Timeline.handle_info({Client, 123, :done}, st)

      refute st.profile_fetching?
      refute_receive {:profiles_fetched, _}, 100
    end
  end

  # Answers Client.call/4-shaped get requests with the shape a missing
  # message actually comes back as: an :ok error map, not a message.
  defmodule GhostClient do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call({:call, _name, _args}, _from, state) do
      {:reply, {:ok, %{"message" => "message not found", "name" => "Error", "stack" => "_"}},
       state}
    end

    # The broken thread.sorted answers with an empty stream — no items,
    # no sentinel. The page must fall back to the window either way.
    def handle_call({:stream, _name, _args, _subscriber}, _from, state) do
      {:reply, {:ok, make_ref()}, state}
    end
  end

  # Answers patchwork.thread.sorted by replaying canned items to the
  # subscriber before the stream call even returns — the drain finds
  # them waiting in its mailbox — and serves everything else a
  # method-not-found, so get falls through to the window.
  defmodule ThreadClient do
    @moduledoc false
    use GenServer

    def start(items), do: GenServer.start_link(__MODULE__, items)

    @impl true
    def init(items), do: {:ok, items}

    @impl true
    def handle_call({:stream, name, _args, subscriber}, _from, items) do
      ref = make_ref()

      if name == ["patchwork", "thread", "sorted"] do
        Enum.each(items, &send(subscriber, {HighWire.SSB.Client, ref, {:item, &1}}))
        send(subscriber, {HighWire.SSB.Client, ref, {:item, %{"sync" => true}}})
      end

      {:reply, {:ok, ref}, items}
    end

    def handle_call({:call, _name, _args}, _from, items) do
      {:reply, {:error, :methodnotfound}, items}
    end
  end

  describe "fork replies (reply-to-a-reply)" do
    # The patchwork fork shape: the reply pins root to the message it
    # answers, with fork naming the thread (and one sibling leaving the
    # fork field off, reachable only by walking the root chain).
    defp fork_window do
      root = msg("@a=.ed25519", "%r=.sha256", 1_000, %{"type" => "post", "text" => "op"})

      reply =
        msg("@b=.ed25519", "%a=.sha256", 2_000, %{
          "type" => "post",
          "text" => "first",
          "root" => "%r=.sha256",
          "branch" => ["%r=.sha256"]
        })

      fork =
        msg("@c=.ed25519", "%f=.sha256", 3_000, %{
          "type" => "post",
          "text" => "second",
          "root" => "%a=.sha256",
          "branch" => ["%a=.sha256"],
          "fork" => "%r=.sha256"
        })

      sibling =
        msg("@d=.ed25519", "%s=.sha256", 3_500, %{
          "type" => "post",
          "text" => "third",
          "root" => "%a=.sha256",
          "branch" => ["%a=.sha256"]
        })

      stranger =
        msg("@e=.ed25519", "%x=.sha256", 4_000, %{
          "type" => "post",
          "text" => "elsewhere",
          "root" => "%zz=.sha256",
          "branch" => ["%zz=.sha256"],
          "fork" => "%zz=.sha256"
        })

      [root, reply, fork, sibling, stranger]
    end

    defp post_call(client, key) do
      st = %{client: client, messages: %{messages: fork_window()}}
      {:reply, post, _st} = Timeline.handle_call({:post, key}, {self(), make_ref()}, st)
      post
    end

    test "the window fallback seats forks after the message they answer" do
      post = post_call(nil, "%f=.sha256")

      assert post.root["key"] == "%r=.sha256"
      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end

    test "a get that answers with the engine's error map still resolves the thread" do
      # A missing message comes back {:ok, %{"message" => "message not
      # found", "name" => "Error", ...}} — an error map, not a message.
      # Treating it as a message stopped the root walk at that ghost, so
      # opening a midlevel link rendered it (empty) with no thread above
      # it even though every ancestor sat in the window. The window copy
      # must win over the ghost.
      client = start_supervised!({GhostClient, nil})
      post = post_call(client, "%f=.sha256")

      assert post.root["key"] == "%r=.sha256"
      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end

    test "engine replies merge with the window's forks, stranger threads stay out" do
      engine_reply =
        msg("@b=.ed25519", "%a=.sha256", 2_000, %{
          "type" => "post",
          "text" => "first",
          "root" => "%r=.sha256",
          "branch" => ["%r=.sha256"]
        })

      client = ThreadClient.start([engine_reply])
      post = post_call(client, "%f=.sha256")

      assert post.root["key"] == "%r=.sha256"
      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end

    test "opening on the thread root pulls the forks in too" do
      client = ThreadClient.start([])
      post = post_call(client, "%r=.sha256")

      assert post.root["key"] == "%r=.sha256"
      # empty stream falls back to the window's plain reply, and the
      # root view — the feed row's own click target — gains the forks;
      # the stranger's thread never leaks in
      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end

    test "the settled acc window feeds the page even when the payload copy is empty" do
      st = %{client: nil, acc: fork_window(), pending: %{}, messages: %{messages: []}}
      {:reply, post, _st} = Timeline.handle_call({:post, "%r=.sha256"}, {self(), make_ref()}, st)

      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end

    test "an empty acc mid-reload falls back to the last payload's window" do
      st = %{
        client: nil,
        acc: [],
        pending: %{make_ref() => :feed},
        messages: %{messages: fork_window()}
      }

      {:reply, post, _st} = Timeline.handle_call({:post, "%r=.sha256"}, {self(), make_ref()}, st)

      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end

    test "a half-streamed acc mid-reload also falls back to the last payload's window" do
      # open_windows resets acc and refills it across the stream; a page
      # opened mid-reload must not seat replies from that partial window
      # when the previous payload still holds a complete one
      partial = fork_window() |> Enum.reject(&(&1["key"] == "%s=.sha256"))

      st = %{
        client: nil,
        acc: partial,
        pending: %{make_ref() => :feed},
        messages: %{messages: fork_window()}
      }

      {:reply, post, _st} = Timeline.handle_call({:post, "%r=.sha256"}, {self(), make_ref()}, st)

      assert Enum.map(post.replies, & &1["key"]) == ["%a=.sha256", "%f=.sha256", "%s=.sha256"]
    end
  end

  describe "publish ack injects into the window" do
    test "a published vote lands in the payload before any reload" do
      {:ok, client} = FakeClient.start_link(nil)

      st = %{
        client: client,
        self_id: "@me=.ed25519",
        follows: [],
        contact_msgs: [],
        acc: [],
        messages: %{profiles: %{}},
        blob_rev: 0,
        status: :ok,
        gen: 0,
        reload_timer: nil,
        pending: %{},
        done_count: 0,
        profile_fetching?: false
      }

      vote = Timeline.vote_content("%t=.sha256", 1)

      {:reply, {:ok, key}, st2} =
        Timeline.handle_call({:publish_content, vote}, {self(), make_ref()}, st)

      assert is_binary(key)
      assert [%{"key" => ^key} | _] = st2.acc
      assert st2.messages.my_likes == ["%t=.sha256"]
      assert st2.messages.like_counts == %{"%t=.sha256" => 1}
      assert st2.messages.likes_by == %{"%t=.sha256" => ["@me=.ed25519"]}
    end
  end

  describe "reload retry" do
    test "a reload request while streams are in flight comes back shortly" do
      st = %{
        gen: 3,
        reload_timer: nil,
        active: %{self() => make_ref()},
        pending: %{make_ref() => :feed},
        status: :ok,
        follows: ["@a=.ed25519"],
        client: self()
      }

      {:noreply, st2} = Timeline.handle_info({:reload, 3}, st)

      assert st2.reload_timer != nil
      # not the 13s heartbeat — the short retry
      assert_receive {:reload, 3}, 1_500
    end
  end

  describe "boot recovery" do
    test "a stalled boot re-opens the window on the heartbeat" do
      {:ok, client} = FakeClient.start_link(nil)

      st = %{
        status: :loading,
        contacts_primed?: true,
        client: client,
        self_id: "@me=.ed25519",
        follows: ["@a=.ed25519"],
        pending: %{},
        acc: [],
        done_count: 0,
        gen: 2,
        reload_timer: nil,
        active: %{self() => make_ref()},
        contact_ref: nil,
        contact_msgs: [],
        contact_buf: [],
        about_ref: nil,
        about_ids: MapSet.new(),
        drain_client: nil,
        last_drain_at: nil,
        messages: %{messages: []}
      }

      {:noreply, st2} = Timeline.handle_info({:reload, 2}, st)

      assert map_size(st2.pending) > 0
      assert st2.acc == []
      assert st2.reload_timer != nil
    end

    test "a boot that never primed contacts re-dials instead" do
      st = %{
        status: :loading,
        contacts_primed?: false,
        client: self(),
        pending: %{},
        gen: 5,
        reload_timer: nil,
        active: %{self() => make_ref()},
        contacts_ref: nil,
        blob_ls_ref: nil
      }

      {:noreply, st2} = Timeline.handle_info({:reload, 5}, st)

      assert st2.status == :connecting
      assert st2.contacts_primed? == false
      assert_receive :connect, 4_000
    end
  end

  describe "ensure_profiles" do
    defp ensure_state(overrides) do
      Map.merge(
        %{
          client: nil,
          profile_fetching?: false,
          profile_wants: MapSet.new(),
          messages: %{profiles: %{"@known=.ed25519" => %{name: "Known"}}}
        },
        Map.new(overrides)
      )
    end

    test "parks unknown ids and leaves profiled and malformed ones alone" do
      {:noreply, st} =
        Timeline.handle_cast(
          {:ensure_profiles, ["@known=.ed25519", "@fresh=.ed25519", "not-a-feed"]},
          ensure_state([])
        )

      assert st.profile_wants == MapSet.new(["@fresh=.ed25519"])
    end

    test "unions with wants already parked; no client means no worker" do
      {:noreply, st} =
        Timeline.handle_cast({:ensure_profiles, ["@one=.ed25519"]}, ensure_state([]))

      {:noreply, st} = Timeline.handle_cast({:ensure_profiles, ["@two=.ed25519"]}, st)

      assert st.profile_wants == MapSet.new(["@one=.ed25519", "@two=.ed25519"])
      assert st.profile_fetching? == false
    end
  end

  describe "root_row" do
    test "stores recent replies newest-first so the template's reverse reads chronologically" do
      root = msg("@a=.ed25519", "%root=.sha256", 1_000, %{"type" => "post", "text" => "hi"})
      old = msg("@a=.ed25519", "%old=.sha256", 2_000, %{"type" => "post", "text" => "one"})
      mid = msg("@b=.ed25519", "%mid=.sha256", 3_000, %{"type" => "post", "text" => "two"})
      new = msg("@c=.ed25519", "%new=.sha256", 4_000, %{"type" => "post", "text" => "three"})

      # the engine returns the newest few OLDEST FIRST
      item = %{
        "key" => root["key"],
        "value" => root["value"],
        "timestamp" => 1_000,
        "totalReplies" => 3,
        "latestReplies" => [old, mid, new]
      }

      row = Timeline.root_row(item, nil, false)

      assert Enum.map(row.recent, & &1["key"]) == ["%new=.sha256", "%mid=.sha256", "%old=.sha256"]
      assert row.replies == 3
      # activity follows the newest reply, not the root's own time
      assert row.activity == 4_000
    end

    test "caps recent at the newest three" do
      root = msg("@a=.ed25519", "%root=.sha256", 1_000, %{"type" => "post", "text" => "hi"})

      replies =
        for {n, ts} <- [{1, 2_000}, {2, 3_000}, {3, 4_000}, {4, 5_000}],
            do: msg("@a=.ed25519", "%r#{n}=.sha256", ts, %{"type" => "post", "text" => "r"})

      item = %{
        "key" => root["key"],
        "value" => root["value"],
        "timestamp" => 1_000,
        "totalReplies" => 4,
        "latestReplies" => replies
      }

      row = Timeline.root_row(item, nil, false)

      assert Enum.map(row.recent, & &1["key"]) == ["%r4=.sha256", "%r3=.sha256", "%r2=.sha256"]
    end
  end

  # Answers Client.call/4 from a canned %{"gossip.peers" => reply}
  # table; anything absent replies with a method-not-found error, the
  # way an engine predating that RPC would.
  defmodule NetworkClient do
    @moduledoc false
    use GenServer

    def start(table) do
      {:ok, pid} = GenServer.start_link(__MODULE__, table)
      pid
    end

    @impl true
    def init(table), do: {:ok, table}

    @impl true
    def handle_call({:call, name, _args}, _from, table) do
      {:reply, Map.get(table, Enum.join(name, "."), {:error, :methodnotfound}), table}
    end
  end

  describe "network report" do
    test "a gossip.peers report rides in whole, with the address book merged" do
      known = [%{"address" => "net:host:1~shs:key", "source" => "pub"}]

      client =
        NetworkClient.start(%{
          "gossip.peers" =>
            {:ok,
             %{
               "enabled" => true,
               "cap" => 30,
               "connections" => ["@a=.ed25519"],
               "lanCandidates" => 2,
               "autoconnectCandidates" => 5,
               "dialTry" => [%{"addr" => "net:host:1~shs:key", "attempts" => 0}]
             }},
          "admin.peers.known" => {:ok, known}
        })

      assert report = Timeline.fetch_network(client)
      assert report["enabled"] == true
      assert report["cap"] == 30
      assert report["connections"] == ["@a=.ed25519"]
      assert report["lanCandidates"] == 2
      assert report["knownPeers"] == known
      refute Map.has_key?(report, "partial")
    end

    test "the address book sorts connected first, then recency, then address" do
      known = [
        %{"address" => "net:new.example:8008~shs:zeta", "stateChange" => 300},
        %{"address" => "net:live.example:8008~shs:alpha", "stateChange" => 100},
        %{"address" => "net:quiet.example:8008~shs:mid"},
        %{"address" => "net:old.example:8008~shs:beta", "stateChange" => 200}
      ]

      client =
        NetworkClient.start(%{
          "gossip.peers" => {:ok, %{"connections" => ["@alpha.ed25519"]}},
          "admin.peers.known" => {:ok, known}
        })

      assert report = Timeline.fetch_network(client)

      # A live session outranks any timestamp: the book itself only
      # carries `stateChange` (epoch ms), so liveness is the report's
      # own connections list, matched against the id behind the
      # address. Under that, most recent state change first — and the
      # alphabet breaks the tie so the order is stable.
      assert Enum.map(report["knownPeers"], & &1["address"]) == [
               "net:live.example:8008~shs:alpha",
               "net:new.example:8008~shs:zeta",
               "net:old.example:8008~shs:beta",
               "net:quiet.example:8008~shs:mid"
             ]
    end

    test "no gossip.peers: the report assembles from the admin namespace" do
      client =
        NetworkClient.start(%{
          "admin.dialer.status" => {:ok, %{"enabled" => false}},
          "admin.peers.connected" => {:ok, [%{"id" => "@x=.ed25519"}, %{"id" => 42}]},
          "admin.peers.known" => {:ok, [%{"address" => "net:host:2~shs:key"}]}
        })

      assert report = Timeline.fetch_network(client)
      assert report["enabled"] == false
      assert report["connections"] == ["@x=.ed25519"]
      assert report["knownPeers"] == [%{"address" => "net:host:2~shs:key"}]
      assert report["dialTry"] == []
      assert report["partial"] == true
      refute Map.has_key?(report, "cap")
      refute Map.has_key?(report, "lanCandidates")
    end

    test "the fallback tolerates a half-answer: dialer only" do
      client = NetworkClient.start(%{"admin.dialer.status" => {:ok, %{"enabled" => true}}})

      assert report = Timeline.fetch_network(client)
      assert report["enabled"] == true
      assert report["connections"] == []
      assert report["knownPeers"] == []
      assert report["partial"] == true
    end

    test "the fallback tolerates a half-answer: connected only" do
      client =
        NetworkClient.start(%{
          "admin.dialer.status" => {:ok, %{}},
          "admin.peers.connected" => {:ok, [%{"id" => "@y=.ed25519"}]}
        })

      assert report = Timeline.fetch_network(client)
      assert report["connections"] == ["@y=.ed25519"]
      refute Map.has_key?(report, "enabled")
      assert report["partial"] == true
    end

    test "an engine that answers nothing falls back to the peer cache" do
      report = Timeline.fetch_network(NetworkClient.start(%{}))

      assert report["seeded"]
      refute Map.has_key?(report, "enabled")
      assert report["connections"] == []
      assert report["dialTry"] == []
    end

    test "the seeded report carries the cached peers, newest first" do
      now = System.system_time(:millisecond)

      meta = %{
        "net:old.example:8008~shs:@old.ed25519" => %{"last_seen_at" => now - 10_000},
        "net:new.example:8008~shs:@new.ed25519" => %{"last_seen_at" => now},
        "@feed.ed25519" => %{"last_activity_at" => now}
      }

      report = Timeline.fetch_network(NetworkClient.start(%{}), meta)

      # Feed-id entries describe connection recency, not an address, so
      # they have no place in the book ring and are left out.
      assert [%{"address" => "net:new.example:8008~shs:@new.ed25519"}, oldest] =
               report["knownPeers"]

      assert oldest["address"] == "net:old.example:8008~shs:@old.ed25519"
    end

    test "gossip answers but the address book fails: knownPeers goes empty" do
      client = NetworkClient.start(%{"gossip.peers" => {:ok, %{"connections" => []}}})

      assert report = Timeline.fetch_network(client)
      assert report["knownPeers"] == []
    end

    test "no client (or a dead one) is the seeded report, not nothing" do
      assert %{"seeded" => true} = Timeline.fetch_network(nil)

      pid = NetworkClient.start(%{})
      :ok = GenServer.stop(pid)
      assert %{"seeded" => true} = Timeline.fetch_network(pid)
    end
  end

  describe "network dial outcomes accumulate into peer meta" do
    test "records failed dials without clearing a past success" do
      addr = "net:dead.example:8008~shs:@dead.ed25519"

      client =
        NetworkClient.start(%{
          "gossip.peers" =>
            {:ok,
             %{
               "enabled" => true,
               "connections" => [],
               "dialTry" => [
                 %{"addr" => addr, "attempts" => 5, "lastOk" => 0, "lastTry" => 1_000}
               ]
             }},
          "admin.peers.known" => {:ok, [%{"address" => addr}]}
        })

      report = Timeline.fetch_network(client, %{})

      assert [%{"address" => ^addr}] = report["knownPeers"]
      assert meta = report["peer_meta"]
      m = HighWire.PeersMeta.get(meta, addr)
      assert m["dial_attempts"] == 5
      # no success ever → dial_ok_at may be missing or 0; do not set a false max
      assert (m["dial_ok_at"] || 0) == 0
    end

    test "remembers a past success when failures accumulate later" do
      addr = "net:flap.example:8008~shs:@flap.ed25519"
      ok_at = 2_000

      client =
        NetworkClient.start(%{
          "gossip.peers" =>
            {:ok,
             %{
               "enabled" => true,
               "connections" => [],
               "dialTry" => [
                 %{"addr" => addr, "attempts" => 7, "lastOk" => ok_at, "lastTry" => 5_000}
               ]
             }},
          "admin.peers.known" => {:ok, [%{"address" => addr}]}
        })

      report = Timeline.fetch_network(client, %{})

      m = HighWire.PeersMeta.get(report["peer_meta"], addr)
      assert m["dial_attempts"] == 7
      assert m["dial_ok_at"] == ok_at
    end

    test "keeps the highest success timestamp seen" do
      addr = "net:recovered.example:8008~shs:@rec.ed25519"

      # First observation: a flapper that once succeeded a while ago.
      client1 =
        NetworkClient.start(%{
          "gossip.peers" =>
            {:ok,
             %{
               "enabled" => true,
               "connections" => [],
               "dialTry" => [
                 %{"addr" => addr, "attempts" => 3, "lastOk" => 1_000, "lastTry" => 1_500}
               ]
             }},
          "admin.peers.known" => {:ok, [%{"address" => addr}]}
        })

      report1 = Timeline.fetch_network(client1, %{})
      meta1 = report1["peer_meta"]

      # Later observation: a later success — max must be kept.
      client2 =
        NetworkClient.start(%{
          "gossip.peers" =>
            {:ok,
             %{
               "enabled" => true,
               "connections" => [],
               "dialTry" => [
                 %{"addr" => addr, "attempts" => 0, "lastOk" => 9_000, "lastTry" => 9_000}
               ]
             }},
          "admin.peers.known" => {:ok, [%{"address" => addr}]}
        })

      report2 = Timeline.fetch_network(client2, meta1)

      m = HighWire.PeersMeta.get(report2["peer_meta"], addr)
      assert m["dial_attempts"] == 0
      assert m["dial_ok_at"] == 9_000
    end
  end
end
