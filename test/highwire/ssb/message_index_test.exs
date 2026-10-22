defmodule HighWire.SSB.MessageIndexTest do
  @moduledoc false

  # The index is one supervised, named process over one DETS file, so
  # these tests share it and clear between cases — never async.
  use ExUnit.Case, async: false

  alias HighWire.SSB.MessageIndex

  setup do
    MessageIndex.clear()
    # …and clear on the way out: whatever the last case advanced would
    # otherwise outlive this module and reach a later reader — the
    # timeline's drains read these cursors on reload.
    on_exit(&MessageIndex.clear/0)
    :ok
  end

  defp msg(author, key, content, received \\ 1_000) do
    %{
      "key" => key,
      "timestamp" => received,
      "value" => %{"author" => author, "timestamp" => received, "content" => content}
    }
  end

  describe "tombstone/1" do
    test "a delete naming a message carries its key and author" do
      tombstone = msg("@a", "%del.sha256", %{"type" => "delete", "dest" => "%gone.sha256"})

      assert MessageIndex.tombstone(tombstone) == {"%gone.sha256", "@a"}
    end

    test "a delete naming a feed id or a blank is not honoured" do
      feed = msg("@a", "%d1.sha256", %{"type" => "delete", "dest" => "@b.ed25519"})
      blank = msg("@a", "%d2.sha256", %{"type" => "delete", "dest" => ""})

      assert MessageIndex.tombstone(feed) == nil
      assert MessageIndex.tombstone(blank) == nil
    end

    test "a message that is not a delete carries no tombstone" do
      post = msg("@a", "%p.sha256", %{"type" => "post", "text" => "hi"})
      assert MessageIndex.tombstone(post) == nil
    end
  end

  describe "edit/1" do
    test "prefers revisionRoot, and falls back through the client variants" do
      root =
        msg("@a", "%e1.sha256", %{
          "type" => "post-edit",
          "revisionRoot" => "%root.sha256",
          "revisionBranch" => "%branch.sha256"
        })

      branch = msg("@a", "%e2.sha256", %{"type" => "post-edit", "revisionBranch" => "%r.sha256"})
      plain = msg("@a", "%e3.sha256", %{"type" => "post-edit", "root" => "%r2.sha256"})
      drop = msg("@a", "%e4.sha256", %{"type" => "post-edit", "branch" => "%r3.sha256"})

      assert MessageIndex.edit(root) == {"%e1.sha256", "%root.sha256"}
      assert MessageIndex.edit(branch) == {"%e2.sha256", "%r.sha256"}
      assert MessageIndex.edit(plain) == {"%e3.sha256", "%r2.sha256"}
      assert MessageIndex.edit(drop) == {"%e4.sha256", "%r3.sha256"}
    end

    test "an edit naming no message key is not an edit to record" do
      edit = msg("@a", "%e.sha256", %{"type" => "post-edit", "text" => "no pointer"})
      assert MessageIndex.edit(edit) == nil
    end
  end

  describe "record and consult" do
    test "the deleter is kept alongside the key" do
      MessageIndex.record_deletes([{"%gone.sha256", "@a.ed25519"}])

      assert MessageIndex.deleted_by("%gone.sha256") == "@a.ed25519"
      assert MessageIndex.deleted_by("%other.sha256") == nil
    end

    test "an edit's thread root is kept for a target outside the window" do
      MessageIndex.record_edits([{"%edit.sha256", "%reply.sha256", "%root.sha256"}])

      assert MessageIndex.edit_thread_root("%reply.sha256") == "%root.sha256"
      assert MessageIndex.edit_thread_root("%edit.sha256") == nil
    end

    test "clearing forgets every tombstone, edit, and cursor" do
      MessageIndex.record_deletes([{"%gone.sha256", "@a.ed25519"}])
      MessageIndex.record_edits([{"%edit.sha256", "%reply.sha256", "%root.sha256"}])
      MessageIndex.advance_cursor("delete", 5_000)

      MessageIndex.clear()

      assert MessageIndex.deleted_by("%gone.sha256") == nil
      assert MessageIndex.edit_thread_root("%reply.sha256") == nil
      assert MessageIndex.cursor("delete") == nil
    end
  end

  describe "cursor/1" do
    test "an empty index has no cursor" do
      assert MessageIndex.cursor("delete") == nil
    end

    test "advances to the highest time seen, and never backwards" do
      MessageIndex.advance_cursor("delete", 2_000)
      assert MessageIndex.cursor("delete") == 2_000

      MessageIndex.advance_cursor("delete", 1_000)
      assert MessageIndex.cursor("delete") == 2_000

      MessageIndex.advance_cursor("delete", 3_000)
      assert MessageIndex.cursor("delete") == 3_000
    end

    test "each type keeps its own cursor" do
      MessageIndex.advance_cursor("delete", 2_000)
      MessageIndex.advance_cursor("post-edit", 9_000)

      assert MessageIndex.cursor("delete") == 2_000
      assert MessageIndex.cursor("post-edit") == 9_000
    end
  end

  describe "sentinel?/1" do
    test "the sync sentinel is not a message; anything else is" do
      assert MessageIndex.sentinel?(%{"sync" => true})
      refute MessageIndex.sentinel?(%{"key" => "%x.sha256"})
      refute MessageIndex.sentinel?(nil)
    end
  end
end
