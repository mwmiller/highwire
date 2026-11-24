defmodule HighWire.SSB.SidecarTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Sidecar

  # owner_pid/2 decides which attached engines a shutdown may stop:
  # ours (live pidfile naming this very port) — never a foreign engine,
  # a dead pid, or a reused pid that no longer looks like a VM.
  describe "owner_pid/2" do
    test "claims a live pidfile engine that names this port" do
      me = System.pid() |> String.to_integer()

      assert Sidecar.owner_pid(8899, %{"os_pid" => me, "port" => 8899}) == me
    end

    test "ignores a pidfile recorded for another port" do
      me = System.pid() |> String.to_integer()

      assert Sidecar.owner_pid(8899, %{"os_pid" => me, "port" => 9999}) == nil
    end

    test "ignores a dead pid even when the port matches" do
      assert Sidecar.owner_pid(8899, %{"os_pid" => 999_999_999, "port" => 8899}) == nil
    end

    test "ignores missing or malformed pidfiles" do
      assert Sidecar.owner_pid(8899, nil) == nil
      assert Sidecar.owner_pid(8899, %{"os_pid" => 1}) == nil
      assert Sidecar.owner_pid(8899, %{"port" => 8899}) == nil
    end

    # The pidfile is shared by every HighWire on this home, so a live
    # engine is only ours when this VM spawned it. Otherwise quitting
    # the app (or a second dev server) stops the engine the first
    # server is reading its feed from.
    test "claims an engine this VM spawned" do
      me = System.pid() |> String.to_integer()

      assert Sidecar.owner_pid(8899, %{"os_pid" => me, "port" => 8899, "by" => System.pid()}) ==
               me
    end

    test "ignores an engine another live HighWire spawned, and reaps it once that one is gone" do
      me = System.pid() |> String.to_integer()
      other = spawn_sleeper()
      leaked = %{"os_pid" => me, "port" => 8899, "by" => to_string(other)}

      assert Sidecar.owner_pid(8899, leaked) == nil

      stop_sleeper(other)
      assert Sidecar.owner_pid(8899, leaked) == me
    end
  end

  defp spawn_sleeper do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, {:args, ["30"]}])
    {:os_pid, pid} = :erlang.port_info(port, :os_pid)
    pid
  end

  defp stop_sleeper(pid) do
    System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
    wait_until_gone(pid, 50)
  end

  defp wait_until_gone(_pid, 0), do: :ok

  defp wait_until_gone(pid, tries) do
    if match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true)) do
      Process.sleep(20)
      wait_until_gone(pid, tries - 1)
    else
      :ok
    end
  end

  # The engine's logger renders with an explicit depth: without it a
  # single crash report dumps the whole mailbox — a queued
  # request_blob_wants list of ~56k ids came to 56k log lines — and a
  # couple of disconnects rewrote the log faster than it rotated.
  # depth 64 keeps a report to a screenful, list tails collapsing to
  # "...".  The configs must also stay parseable Erlang: the escaping
  # in the heredocs is exactly the sort of thing consult catches.
  describe "engine logger config" do
    test "sys_config caps the formatter depth and parses" do
      cfg = Sidecar.sys_config("/tmp/hw-test", 8899)

      assert cfg =~ ~S(formatter => {logger_formatter, #{)
      assert cfg =~ "depth => 64"
      assert cfg =~ "erlbutt.log"
      assert_erlang_config(cfg)
    end

    test "import_sys_config caps the formatter depth and parses" do
      cfg = Sidecar.import_sys_config("/tmp/hw-test")

      assert cfg =~ ~S(formatter => {logger_formatter, #{)
      assert cfg =~ "depth => 64"
      assert cfg =~ "erlbutt-import.log"
      assert_erlang_config(cfg)
    end
  end

  defp assert_erlang_config(cfg) do
    path = Path.join(System.tmp_dir!(), "hw-sys-#{System.unique_integer([:positive])}.config")
    File.write!(path, cfg)
    assert {:ok, [[{:kernel, _}, {:ssb, _}]]} = :file.consult(String.to_charlist(path))
    File.rm(path)
  end
end
