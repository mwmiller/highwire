defmodule HighWire.BlobIndexTest do
  @moduledoc """
  The parent map (blob ref → the post that carried it) is held in
  `:persistent_term` only, so a restart begins with none of it. The
  sweep used to rebuild it only when the store gained files — a restart
  against an already-populated index therefore left every blob without
  its post until a new blob arrived.
  """

  use ExUnit.Case, async: false

  alias HighWire.{Blob, BlobIndex}

  setup do
    # The app's indexer sweeps on its own timer; take it out so it cannot
    # race the store this test seeds, and put it back when the test ends.
    stop_index()
    File.rm_rf(Blob.store_root())

    on_exit(fn ->
      stop_index()
      File.rm_rf(Blob.store_root())
      File.rm(dets_path())
      forget()

      start_index()
    end)

    :ok
  end

  test "a restart rebuilds the parent map even when the store gained nothing" do
    bytes = <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "pixels">>
    ref = Blob.ref(bytes)
    {:ok, hex} = Blob.ref_to_hex(ref)

    path = Blob.store_path(hex)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    key = "%blob-index-test.#{System.unique_integer([:positive])}.sha256"

    :dets.insert(
      :highwire_search,
      {key, "@alice.example", "A picture in the field #{ref}", 1_700_000_000_000}
    )

    on_exit(fn -> :dets.delete(:highwire_search, key) end)

    Phoenix.PubSub.subscribe(HighWire.PubSub, BlobIndex.topic())

    # First run: the store file is new, so the map is built along with
    # its row.
    start_index()
    assert_receive :updated, 5_000

    assert BlobIndex.parents()[ref].key == key

    # Restart: `:persistent_term` is not durable, and the file was
    # indexed by the previous run, so the sweep has nothing new to
    # place. The post is still in the search index, and the map has to
    # come back from it.
    stop_index()
    forget()

    start_index()
    assert_receive :updated, 5_000

    assert %{key: ^key, author: "@alice.example", text: text} = BlobIndex.parents()[ref]
    assert text =~ "A picture in the field"
  end

  # A fresh VM starts with none of these; a restart inside one leaves
  # them behind, so the test clears them to reproduce a real boot.
  defp forget do
    for key <- [:rows, :counts, :status, :parents] do
      :persistent_term.erase({BlobIndex, key})
    end
  end

  defp stop_index do
    case Supervisor.terminate_child(HighWire.Supervisor, BlobIndex) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  defp start_index do
    {:ok, pid} = Supervisor.restart_child(HighWire.Supervisor, BlobIndex)
    pid
  end

  defp dets_path, do: Path.join(HighWire.home_dir(), "blob-index.dets")
end
