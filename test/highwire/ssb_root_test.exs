defmodule HighWire.SSBRootTest do
  @moduledoc """
  The engine's repo follows `:ssb_home`, so HighWire runs against an
  erlbutt that keeps its own `.ssberl` somewhere else — the secret, the
  address book, the DETS indexes and the blobs all move with it.
  """
  use ExUnit.Case, async: false

  alias HighWire.{Blob, SSB}

  setup do
    previous_home = Application.get_env(:highwire, :ssb_home)
    previous_store = Application.get_env(:highwire, :blob_store)

    on_exit(fn ->
      restore(:ssb_home, previous_home)
      restore(:blob_store, previous_store)
    end)

    :ok
  end

  test "the repo, the address book and the blobs follow the SSB home" do
    home = Path.join(System.tmp_dir!(), "hw-ssb-#{System.unique_integer([:positive])}")
    Application.put_env(:highwire, :ssb_home, home)
    Application.delete_env(:highwire, :blob_store)

    assert HighWire.ssb_dir() == Path.join(home, ".ssberl")
    assert SSB.Import.repo() == Path.join(home, ".ssberl")
    assert SSB.ConnSuppress.path() == Path.join([home, ".ssberl", "conn.json"])
    assert Blob.store_root() == Path.join([home, ".ssberl", "blobs"])
  end

  test "a home written with ~ expands" do
    Application.put_env(:highwire, :ssb_home, "~/")

    assert HighWire.ssb_dir() == Path.expand("~/.ssberl")
  end

  test "with no SSB home set, the repo sits in the app home" do
    Application.delete_env(:highwire, :ssb_home)

    assert HighWire.ssb_dir() == Path.join(HighWire.home_dir(), ".ssberl")
  end

  defp restore(key, nil), do: Application.delete_env(:highwire, key)
  defp restore(key, value), do: Application.put_env(:highwire, key, value)
end
