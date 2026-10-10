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
          follows: [],
          self_id: "@me.ed25519",
          status: :connecting,
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
end
