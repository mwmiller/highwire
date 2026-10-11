defmodule HighWire.SSB.ImportTest do
  use ExUnit.Case, async: false

  import Bitwise, only: [band: 2]

  alias HighWire.SSB.Import

  setup do
    home = tmp!("hw-import-home")
    js = tmp!("hw-import-js")

    prev_dir = Application.get_env(:highwire, :application_dir)
    prev_ssb = Application.get_env(:highwire, :ssb, [])

    Application.put_env(:highwire, :application_dir, home)
    Application.put_env(:highwire, :ssb, Keyword.put(prev_ssb, :js_home, js))

    on_exit(fn ->
      restore(:application_dir, prev_dir)
      restore(:ssb, prev_ssb)
    end)

    {:ok, home: home, js: js}
  end

  describe "detect/0" do
    test "no JS store means no offer", %{js: js} do
      assert Import.detect() == :none
      refute File.exists?(Path.join(js, "secret"))
    end

    test "a JS secret with no local identity is an offer", %{js: js} do
      id = write_secret!(js)

      assert {:ok, info} = Import.detect()
      assert info.id == id
      assert info.log_path == nil
      assert info.log_size == nil
      assert info.blobs == false
    end

    test "the offer carries the log's size and blob presence", %{js: js} do
      _id = write_secret!(js)
      File.write!(Path.join(js, "log.offset"), :crypto.strong_rand_bytes(4096))
      File.mkdir_p!(Path.join(js, "blobs/sha256"))

      assert {:ok, info} = Import.detect()
      assert info.log_path == Path.join(js, "log.offset")
      assert info.log_size == 4096
      assert info.blobs == true
    end

    test "an identity of our own closes the offer", %{js: js, home: _home} do
      _id = write_secret!(js)
      write_local_secret!("mine")

      assert Import.detect() == :none
    end

    test "the marker re-opens the offer after an interrupted import", %{js: js} do
      _id = write_secret!(js)
      write_local_secret!("half-imported")
      File.write!(Import.marker_path(), "import accepted")

      assert {:ok, _info} = Import.detect()
    end

    test "a marker without a JS store is nothing to recover", %{js: js} do
      _id = write_secret!(js)
      File.rm!(Path.join(js, "secret"))
      File.write!(Import.marker_path(), "import accepted")

      assert Import.detect() == :none
    end

    test "an unreadable JS secret degrades to a fresh start", %{js: js} do
      File.mkdir_p!(js)
      File.write!(Path.join(js, "secret"), "not a key at all")

      assert Import.detect() == :none
    end
  end

  describe "prepare/0" do
    test "arms the marker first, wipes the derived tier, keeps the rest", %{js: js} do
      id = write_secret!(js)
      File.write!(Path.join(js, "log.offset"), "flume")
      File.mkdir_p!(Path.join(js, "blobs"))

      repo = Import.repo()
      File.mkdir_p!(repo)

      derived_dirs = ["feeds", "views"]

      derived_files = [
        "invites.tab",
        "room_members.tab",
        "store.db",
        "store.db-wal",
        "ingest.journal",
        "ingest.journal.bak"
      ]

      keepers = ["conn.json", "overrides.cfg", "data_version"]

      Enum.each(derived_dirs, &File.mkdir_p!(Path.join(repo, &1)))
      Enum.each(derived_files ++ keepers, &File.write!(Path.join(repo, &1), "old"))
      File.mkdir_p!(Path.join(repo, "blobs/sha256"))
      File.write!(Path.join(repo, "blobs/sha256/aa"), "blob")

      assert :ok = Import.prepare()
      assert Import.marker?()

      for name <- derived_dirs ++ derived_files do
        refute File.exists?(Path.join(repo, name)), "#{name} should be gone"
      end

      for name <- keepers do
        assert File.read!(Path.join(repo, name)) == "old"
      end

      assert File.read!(Path.join(repo, "blobs/sha256/aa")) == "blob"
      assert File.read!(Import.local_secret()) =~ id
    end

    test "the copied secret is as tight as the engine's own", %{js: js} do
      _id = write_secret!(js)

      assert :ok = Import.prepare()
      assert band(File.stat!(Import.local_secret()).mode, 0o777) == 0o600
    end

    test "an existing local secret is replaced by the JS one", %{js: js} do
      id = write_secret!(js)
      write_local_secret!("a different identity")

      assert :ok = Import.prepare()
      assert File.read!(Import.local_secret()) =~ id
    end

    test "refuses when the old store vanished, and arms nothing", %{js: js} do
      File.mkdir_p!(js)

      assert Import.prepare() == {:error, :no_js_secret}
      refute Import.marker?()
    end
  end

  describe "marker helpers" do
    test "clearing an absent marker is a success" do
      assert Import.marker?() == false
      assert :ok = Import.clear_marker()
      assert Import.marker?() == false
    end

    test "the marker round-trips" do
      File.mkdir_p!(HighWire.home_dir())
      File.write!(Import.marker_path(), "import accepted")

      assert Import.marker?()
      assert :ok = Import.clear_marker()
      refute Import.marker?()
    end
  end

  describe "paths" do
    test "store paths hang off the configured JS home", %{js: js} do
      assert Import.js_home() == js
      assert Import.js_secret() == Path.join(js, "secret")
      assert Import.log_path() == nil
      assert Import.blobs_src() == nil
    end
  end

  # -- helpers -----------------------------------------------------------

  defp tmp!(prefix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
      )

    _ = File.rm_rf(path)
    File.mkdir_p!(path)
    path
  end

  defp restore(key, nil), do: Application.delete_env(:highwire, key)
  defp restore(key, value), do: Application.put_env(:highwire, key, value)

  defp write_secret!(dir) do
    pub = Base.encode64(:crypto.strong_rand_bytes(32))
    priv = Base.encode64(:crypto.strong_rand_bytes(64))

    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "secret"),
      """
      # SSB-KEYS-JSON
      # comment line
      {
        "curve": "ed25519",
        "public": "#{pub}.ed25519",
        "private": "#{priv}.ed25519",
        "id": "@#{pub}.ed25519"
      }
      """
    )

    "@#{pub}.ed25519"
  end

  defp write_local_secret!(body) do
    File.mkdir_p!(Import.repo())
    File.write!(Import.local_secret(), body)
  end
end
