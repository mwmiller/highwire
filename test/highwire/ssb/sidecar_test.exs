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
  end
end
