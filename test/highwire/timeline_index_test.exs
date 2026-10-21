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

  # A payload's `:index` (message key → author) exists so a vote/about/edit
  # row can name its target. It is bounded by the keys the rows going out
  # can ask about, never by the store: the full pass merges the store-wide
  # contact drain into `acc`, and an index over all of it shipped a
  # store-sized map — 200k+ entries, ~90% of the payload — to every view on
  # every mount and reload.
  describe "the payload index is bounded by the rows, not the store" do
    defp boundary_state(acc) do
      %{
        client: nil,
        self_id: "@me.ed25519",
        follows: [],
        contact_msgs: [],
        collapsed_contacts: %{by_group: %{}, rows: %{}},
        acc: acc,
        messages: %{},
        blob_rev: 0,
        status: :ok,
        gen: 0,
        reload_timer: nil,
        pending: %{make_ref() => :feed},
        done_count: 0,
        profile_fetching?: false
      }
    end

    defp payload_for(acc) do
      Phoenix.PubSub.subscribe(HighWire.PubSub, HighWire.Timeline.topic())

      st = boundary_state(acc)
      [ref | _] = Map.keys(st.pending)
      {:noreply, _st} = Timeline.handle_info({HighWire.SSB.Client, ref, :done}, st)

      receive do
        {HighWire.Timeline, :updated, payload} -> payload
      after
        1_000 -> flunk("finalize did not broadcast a payload")
      end
    end

    test "answers every key the rendered rows resolve, however deep the store" do
      # An `about` message points at the feed it describes, and an edit
      # reply points at the post it revises. Both name their target
      # through the index; both targets are off-window here, so the index
      # is the only place the sentence can find them.
      target = post("@silvia", "%target.sha256", 1_000)

      about =
        msg("@alice", "%about.sha256", 2_000, %{
          "type" => "about",
          "about" => "%target.sha256",
          "name" => "Silvia"
        })

      edited = post("@bob", "%reply.sha256", 1_500, "%target.sha256")

      edit =
        msg("@bob", "%edit.sha256", 2_500, %{
          "type" => "post-edit",
          "revisionRoot" => "%reply.sha256",
          "text" => "revised"
        })

      # The store-wide drain: thousands of messages no row references.
      # They are older than the rendered ones, so the `about` and the
      # edit reply keep their window seats and their targets stay in the
      # demand set.
      noise = for i <- 1..2_000, do: post("@noise", "%noise-#{i}.sha256", 100 + i)

      payload = payload_for([target, edited, about, edit | noise])

      assert payload.index["%target.sha256"] == "@silvia"
      assert payload.index["%reply.sha256"] == "@bob"
      # ...and the index is the rendered window plus the targets it names,
      # not the store. The flat list holds up to 2000 rows; the index
      # holds those keys and the handful of targets they reference, never
      # a map over every message the store has ever carried.
      assert map_size(payload.index) <= length(payload.messages) + 10
    end

    test "every key a sentence resolves answers the same as the full store" do
      # The invariant the whole design rests on: the demand set is one
      # definition (`MessageText.target_keys/1`), so a key the render
      # resolves is a key the index was built for. Compare the bounded
      # index against one built over the whole store, on exactly the keys
      # the sentences ask about.
      target = post("@silvia", "%target.sha256", 1_000)

      about =
        msg("@alice", "%about.sha256", 2_000, %{
          "type" => "about",
          "about" => "%target.sha256",
          "name" => "Silvia"
        })

      noise = for i <- 1..500, do: post("@noise", "%noise-#{i}.sha256", 100 + i)
      store = [target, about | noise]

      payload = payload_for(store)

      full =
        Map.new(store, fn m -> {m["key"], m["value"]["author"]} end)

      asked =
        store
        |> Enum.flat_map(&HighWireWeb.MessageText.target_keys/1)
        |> Enum.uniq()

      assert asked != []

      for key <- asked do
        assert payload.index[key] == full[key],
               "index disagreed on #{key}: #{inspect(payload.index[key])} vs #{inspect(full[key])}"
      end
    end

    test "does not grow the index with messages no row references" do
      small = post("@alice", "%post.sha256", 1_000)
      payload_small = payload_for([small])

      big = for i <- 1..5_000, do: post("@noise", "%n#{i}.sha256", 2_000 + i)
      payload_big = payload_for([small | big])

      assert map_size(payload_small) == map_size(payload_big)
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
        collapsed_contacts: %{by_group: %{}, rows: %{}},
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
