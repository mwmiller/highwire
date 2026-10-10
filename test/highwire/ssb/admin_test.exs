defmodule HighWire.SSB.AdminTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Admin

  # Test config runs with the sidecar disabled and no engine listening,
  # so every call must degrade to an error tuple — no raises, no hangs,
  # no leaked processes. The LiveView binds these directly.
  describe "with the engine disabled" do
    test "dialer_status answers an error" do
      assert {:error, _} = Admin.dialer_status()
    end

    test "dialer_enable answers an error" do
      assert {:error, _} = Admin.dialer_enable()
    end

    test "dialer_disable answers an error" do
      assert {:error, _} = Admin.dialer_disable()
    end

    test "dialer_trigger answers an error" do
      assert {:error, _} = Admin.dialer_trigger()
    end

    test "peers_known answers an error" do
      assert {:error, _} = Admin.peers_known()
    end

    test "a short timeout still answers, never hangs" do
      assert {:error, _} = Admin.dialer_status(50)
    end
  end
end
