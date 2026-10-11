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

  # Answers Client.stream/4-shaped calls without a network; the
  # first contacts item boots the feed streams through this.
  defmodule FakeClient do
    @moduledoc false
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call({:stream, _name, _args, _subscriber}, _from, state),
      do: {:reply, {:ok, make_ref()}, state}
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

  describe "build_feed/4" do
    # Thread factory: root nil → a rootless (own-key) post. Keys carry
    # the .sha256 suffix msg_id?/1 requires of thread root references.
    defp post(author, key, ts, root \\ nil) do
      content = %{"type" => "post", "text" => "hi"}
      content = if root, do: Map.put(content, "root", root), else: content
      msg(author, key, ts, content)
    end

    test "root likes count once when the root sits in the window" do
      root = post("@alice", "%root.sha256", 1_000)
      reply = post("@bob", "%reply.sha256", 2_000, "%root.sha256")

      assert [row] = Timeline.build_feed([root, reply], "@me", %{"%root.sha256" => 2}, 10_000)
      assert row.likes == 2
    end

    test "mid-chain roots merge under the thread root" do
      root = post("@alice", "%root.sha256", 1_000)
      mid = post("@bob", "%mid.sha256", 2_000, "%root.sha256")
      # a client that set root to its parent instead of the thread head
      deep = post("@carol", "%deep.sha256", 3_000, "%mid.sha256")

      assert [row] = Timeline.build_feed([root, mid, deep], "@me", %{}, 10_000)
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

      assert [row] = Timeline.build_feed([mid, older, deep], "@me", %{}, 10_000)
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

      assert [row] = Timeline.build_feed([root, reply], "@me", %{}, 10_000)
      assert row.msg["key"] == "%root.sha256"
      assert Enum.map(row.recent, & &1["key"]) == ["%reply.sha256"]
    end

    test "cyclic roots terminate instead of hanging" do
      a = post("@alice", "%a.sha256", 1_000, "%b.sha256")
      b = post("@bob", "%b.sha256", 2_000, "%a.sha256")

      assert is_list(Timeline.build_feed([a, b], "@me", %{}, 10_000))
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
          contacts_ref: nil,
          contacts_primed?: true,
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
      assert map_size(st.pending) >= 1
      assert st.acc == []
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

      row = Timeline.root_row(item, nil, 10_000, false)

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

      row = Timeline.root_row(item, nil, 10_000, false)

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

    test "an engine that answers nothing yields no report at all" do
      assert Timeline.fetch_network(NetworkClient.start(%{})) == nil
    end

    test "gossip answers but the address book fails: knownPeers goes empty" do
      client = NetworkClient.start(%{"gossip.peers" => {:ok, %{"connections" => []}}})

      assert report = Timeline.fetch_network(client)
      assert report["knownPeers"] == []
    end

    test "no client (or a dead one) is no report" do
      assert Timeline.fetch_network(nil) == nil

      pid = NetworkClient.start(%{})
      :ok = GenServer.stop(pid)
      assert Timeline.fetch_network(pid) == nil
    end
  end
end
