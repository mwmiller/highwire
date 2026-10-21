defmodule HighWire.TimelineIndexTest do
  @moduledoc false

  # These exercise the render path against the shared, supervised
  # MessageIndex, recording into it directly — so they clear it around
  # themselves and never run async.
  use ExUnit.Case, async: false

  alias HighWire.SSB.MessageIndex
  alias HighWire.Timeline

  setup do
    MessageIndex.clear()
    on_exit(&MessageIndex.clear/0)
    :ok
  end

  defp msg(author, key, timestamp, content) do
    %{
      "key" => key,
      "value" => %{"author" => author, "timestamp" => timestamp, "content" => content}
    }
  end

  defp post(author, key, ts, root \\ nil) do
    content = %{"type" => "post", "text" => "hi"}
    content = if root, do: Map.put(content, "root", root), else: content
    msg(author, key, ts, content)
  end

  describe "honoured tombstones" do
    test "the author's own tombstone removes the message" do
      hidden = post("@alice", "%gone.sha256", 1_000)
      kept = post("@alice", "%kept.sha256", 2_000)

      MessageIndex.record_deletes([{"%gone.sha256", "@alice"}])

      keys = Timeline.build_feed([hidden, kept], "@me", %{}) |> Enum.map(& &1.msg["key"])
      refute "%gone.sha256" in keys
      assert "%kept.sha256" in keys
    end

    test "a tombstone from anyone but the author is ignored" do
      msg = post("@alice", "%post.sha256", 1_000)

      # @mallory did not write it, so her delete does not count.
      MessageIndex.record_deletes([{"%post.sha256", "@mallory"}])

      keys = Timeline.build_feed([msg], "@me", %{}) |> Enum.map(& &1.msg["key"])
      assert "%post.sha256" in keys
    end

    test "the tombstone stays until it is replaced, not consumed by one read" do
      hidden = post("@alice", "%gone.sha256", 1_000)

      MessageIndex.record_deletes([{"%gone.sha256", "@alice"}])

      assert Timeline.build_feed([hidden], "@me", %{}) == []
      # a second render still honours it
      assert Timeline.build_feed([hidden], "@me", %{}) == []
    end
  end

  describe "edits of a target outside the window" do
    test "thread under the root the index recorded for the target" do
      # The reply this edit revises has aged out of the window; only the
      # index remembers which conversation it belonged to.
      MessageIndex.record_edits([{"%edit.sha256", "%reply.sha256", "%root.sha256"}])

      edit =
        msg("@bob", "%edit.sha256", 3_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%reply.sha256",
          "text" => "revised"
        })

      assert [row] = Timeline.build_feed([edit], "@me", %{})
      assert row.root_key == "%root.sha256"
      assert row.kind != :other
    end

    test "an in-window target still resolves through the window, not the index" do
      root = post("@alice", "%root.sha256", 1_000)
      reply = post("@bob", "%reply.sha256", 2_000, "%root.sha256")

      # A stale index answer must not override the window's own chain.
      MessageIndex.record_edits([{"%edit.sha256", "%reply.sha256", "%stale.sha256"}])

      edit =
        msg("@bob", "%edit.sha256", 3_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%reply.sha256",
          "text" => "revised"
        })

      assert [row] = Timeline.build_feed([root, reply, edit], "@me", %{})
      assert row.root_key == "%root.sha256"
    end

    test "an edit with no index entry and no window target stands alone" do
      edit =
        msg("@alice", "%edit.sha256", 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%gone.sha256",
          "text" => "orphan"
        })

      assert [row] = Timeline.build_feed([edit], "@me", %{})
      assert row.kind == :other
    end
  end

  # The drains fold the live streams into the index. These drive the
  # Timeline's item/sentinel handlers directly with a minimal state, so
  # the observable is the index and the buffered cursor — no client, no
  # window.
  describe "live drain folds" do
    defp drain(overrides \\ %{}) do
      Map.merge(
        %{
          tombstone_ref: :tref,
          tombstone_buf: [],
          tombstone_snapshot?: true,
          edit_ref: :eref,
          edit_buf: [],
          edit_snapshot?: true,
          status: :loading,
          pending: %{},
          acc: [],
          messages: %{},
          self_id: "@me.ed25519"
        },
        overrides
      )
    end

    defp item(ref, msg), do: {HighWire.SSB.Client, ref, {:item, msg}}

    test "the snapshot buffers, and the sentinel folds it into the index" do
      delete =
        msg("@alice", "%del.sha256", 1_000, %{"type" => "delete", "dest" => "%gone.sha256"})

      delete = Map.put(delete, "timestamp", 1_700_000_000_000)
      {:noreply, st} = Timeline.handle_info(item(:tref, delete), drain())

      # buffered, not yet recorded
      assert st.tombstone_buf == [delete]
      assert MessageIndex.deleted_by("%gone.sha256") == nil

      {:noreply, st} = Timeline.handle_info(item(:tref, %{"sync" => true}), st)

      assert st.tombstone_buf == []
      refute st.tombstone_snapshot?
      assert MessageIndex.deleted_by("%gone.sha256") == "@alice"
      # the cursor advanced to the item's received time
      assert MessageIndex.cursor("delete") == 1_700_000_000_000
    end

    test "an item after the sentinel folds on its own" do
      {:noreply, st} = Timeline.handle_info(item(:tref, %{"sync" => true}), drain())
      refute st.tombstone_snapshot?

      delete =
        msg("@bob", "%del.sha256", 1_000, %{"type" => "delete", "dest" => "%gone.sha256"})
        |> Map.put("timestamp", 1_800_000_000_000)

      {:noreply, st} = Timeline.handle_info(item(:tref, delete), st)

      assert st.tombstone_buf == []
      assert MessageIndex.deleted_by("%gone.sha256") == "@bob"
      assert MessageIndex.cursor("delete") == 1_800_000_000_000
    end

    test "edit items fold the same way, keyed by their target" do
      edit =
        msg("@bob", "%edit.sha256", 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%reply.sha256"
        })
        |> Map.put("timestamp", 1_900_000_000_000)

      {:noreply, st} = Timeline.handle_info(item(:eref, edit), drain())
      assert st.edit_buf == [edit]

      {:noreply, st} = Timeline.handle_info(item(:eref, %{"sync" => true}), st)

      assert st.edit_buf == []
      refute st.edit_snapshot?
      # the reply's thread root comes from the window, which is empty, so
      # the index records the target with no root rather than dropping it
      assert MessageIndex.cursor("post-edit") == 1_900_000_000_000
    end

    test "an error drops the ref, keeps the buffer, and re-arms the snapshot" do
      state = drain(%{tombstone_snapshot?: false, tombstone_buf: ["partial"]})

      {:noreply, st} =
        Timeline.handle_info({HighWire.SSB.Client, :tref, {:error, :closed}}, state)

      assert st.tombstone_ref == nil
      assert st.tombstone_buf == ["partial"]
      assert st.tombstone_snapshot?
    end
  end

  # The 13s heartbeat reruns the same window through finalize. When the
  # rebuilt payload matches the last one, nothing is broadcast — that is
  # what a quiet feed looks like.
  describe "unchanged heartbeats stay quiet" do
    defp finalize_state(messages) do
      %{
        client: nil,
        self_id: "@me.ed25519",
        follows: [],
        contact_msgs: [],
        acc: [post("@alice", "%post.sha256", 1_000)],
        messages: messages,
        blob_rev: 0,
        status: :ok,
        gen: 0,
        reload_timer: nil,
        pending: %{make_ref() => :feed},
        done_count: 0,
        profile_fetching?: false
      }
    end

    test "the first finalize broadcasts; a rerun with the same window is silent" do
      Phoenix.PubSub.subscribe(HighWire.PubSub, HighWire.Timeline.topic())

      # The prior payload is empty, so the first build is news.
      st = finalize_state(%{})
      [ref | _] = Map.keys(st.pending)
      {:noreply, st} = Timeline.handle_info({HighWire.SSB.Client, ref, :done}, st)
      assert_received {HighWire.Timeline, :updated, _payload}

      # Same window, same facts: rebuild and stay silent.
      st = %{st | acc: [post("@alice", "%post.sha256", 1_000)], pending: %{make_ref() => :feed}}
      [ref2 | _] = Map.keys(st.pending)
      {:noreply, _st} = Timeline.handle_info({HighWire.SSB.Client, ref2, :done}, st)
      refute_received {HighWire.Timeline, :updated, _}
    end
  end
end
