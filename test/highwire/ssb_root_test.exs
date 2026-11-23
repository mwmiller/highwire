defmodule HighWire.SSBRootTest do
  @moduledoc """
  The engine's repo follows `:ssb_home`, so HighWire runs against an
  erlbutt that keeps its own `.ssberl` somewhere else — the secret, the
  address book, the DETS indexes and the blobs all move with it.
  """
  use ExUnit.Case, async: false

  alias HighWire.{Blob, SSB}

  setup do
    previous =
      for key <- [:ssb_home, :blob_store, :engine], do: {key, Application.get_env(:highwire, key)}

    on_exit(fn ->
      for {key, value} <- previous, do: restore(key, value)
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

  describe "spawn_engine?/0" do
    test "the app home is HighWire's engine to run" do
      Application.delete_env(:highwire, :engine)

      assert HighWire.spawn_engine?()
    end

    test "a home named from outside is left to its own engine" do
      Application.delete_env(:highwire, :engine)
      Application.put_env(:highwire, :ssb_home, Path.join(System.tmp_dir!(), "hw-elsewhere"))

      refute HighWire.spawn_engine?()
    end

    test "spawn opts in on any home, attach opts out on the app home" do
      Application.put_env(:highwire, :ssb_home, Path.join(System.tmp_dir!(), "hw-elsewhere"))
      Application.put_env(:highwire, :engine, :spawn)
      assert HighWire.spawn_engine?()

      Application.put_env(:highwire, :engine, :attach)
      refute HighWire.spawn_engine?()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:highwire, key)
  defp restore(key, value), do: Application.put_env(:highwire, key, value)
end
