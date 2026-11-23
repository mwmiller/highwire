defmodule HighWire.Chess.Legacy.StoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias HighWire.Chess.Legacy
  alias HighWire.Chess.Legacy.Store

  @invite_key "%ADH7dzQ1qJDBrvDEcnC+++NxeGHQnL6nEhlhiz2Q8xM=.sha256"

  setup do
    # The store runs under the application supervisor and owns the DETS
    # table; a test that wants a table of its own has to take its place.
    :ok = Supervisor.terminate_child(HighWire.Supervisor, Store)

    on_exit(fn ->
      {:ok, _pid} = Supervisor.restart_child(HighWire.Supervisor, Store)
    end)

    :ok
  end

  describe "a table that cannot answer" do
    setup do
      # DETS does not create the directory, so this table never opens and
      # the store runs tableless, as it does on a boot where the file is
      # unreachable.
      start_supervised!({Store, path: Path.join(missing_dir(), "chess_legacy.dets")})
      :ok
    end

    test "get/1 answers nil rather than a game" do
      assert Store.get(Legacy.game_id(@invite_key)) == nil
    end

    test "games/0 answers an empty list" do
      assert Store.games() == []
    end

    test "file/1 files nothing and warns once for the run" do
      level = Logger.level()
      Logger.configure(level: :warning)
      on_exit(fn -> Logger.configure(level: level) end)

      log =
        capture_log(fn ->
          assert Store.ingest(invite(key(1))) == :ignored
          assert Store.ingest(invite(key(2))) == :ignored
        end)

      assert log =~ "cannot file a row"
      assert length(Regex.scan(~r/cannot file a row/, log)) == 1
    end
  end

  test "a re-delivered message is :seen" do
    path = Path.join(System.tmp_dir!(), "highwire-legacy-store-#{unique()}.dets")
    on_exit(fn -> File.rm(path) end)

    start_supervised!({Store, path: path})

    msg = invite(@invite_key)

    assert {:ok, _game_id} = Store.ingest(msg)
    assert Store.ingest(msg) == :seen
    assert length(Store.games()) == 1
  end

  defp invite(key) do
    %{
      "key" => key,
      "value" => %{
        "author" => "@white.ed25519",
        "timestamp" => 1,
        "content" => %{
          "type" => "chess_invite",
          "myColor" => "white",
          "inviting" => "@black.ed25519"
        }
      }
    }
  end

  # A key names a game only when it is a message key: 32 bytes, base64.
  defp key(n), do: "%" <> Base.encode64(<<n::256>>) <> ".sha256"

  defp missing_dir, do: Path.join(System.tmp_dir!(), "highwire-missing-#{unique()}")
  defp unique, do: System.unique_integer([:positive])
end
