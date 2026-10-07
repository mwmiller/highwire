defmodule HighWire.SSB.NetworkTest do
  use ExUnit.Case, async: false

  alias HighWire.SSB.Network
  alias HighWire.Timeline

  @dev "1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYnaR/s="
  @mainnet "1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYRan/s="

  setup do
    # unique_integer restarts every VM boot, so the name must carry a
    # run-scoped prefix — otherwise a later run's shuffle can land on a
    # same-numbered leftover directory from an earlier run.
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hw-net-#{System.system_time(:microsecond)}-#{System.unique_integer([:positive])}"
      )

    _ = File.rm_rf(tmp)
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, tmp)

    on_exit(fn ->
      if previous do
        Application.put_env(:highwire, :application_dir, previous)
      else
        Application.delete_env(:highwire, :application_dir)
      end
    end)

    {:ok, tmp: tmp}
  end

  defp consult do
    assert {:ok, terms} = :file.consult(String.to_charlist(Network.path()))
    terms
  end

  defp get(terms, key) do
    Enum.find_value(terms, fn
      {^key, value} -> value
      _other -> nil
    end)
  end

  test "no overrides file falls back to the development profile" do
    assert Network.current() == :dev
    assert Network.current_id() == @dev
    assert Network.publishable?()
  end

  test "set/1 writes a consultable file and round-trips" do
    assert :ok = Network.set(:mainnet)

    terms = consult()
    assert get(terms, :network_id) == String.to_charlist(@mainnet)
    assert get(terms, :extra_network_ids) == [String.to_charlist(@dev)]

    assert Network.current() == :mainnet
    assert Network.current_id() == @mainnet
    refute Network.publishable?()

    assert :ok = Network.set(:dev)

    terms = consult()
    assert get(terms, :network_id) == String.to_charlist(@dev)
    assert get(terms, :extra_network_ids) == [String.to_charlist(@mainnet)]

    assert Network.current() == :dev
    assert Network.publishable?()
  end

  test "set/1 preserves unrelated terms already in the file", %{tmp: _tmp} do
    File.mkdir_p!(Path.dirname(Network.path()))
    File.write!(Network.path(), "{peer_dialer,true}.\n")

    assert :ok = Network.set(:mainnet)

    terms = consult()
    assert {:peer_dialer, true} in terms
    assert get(terms, :network_id) == String.to_charlist(@mainnet)
  end

  test "an unknown network id in the file selects no profile and blocks posting" do
    File.mkdir_p!(Path.dirname(Network.path()))
    File.write!(Network.path(), "{network_id,\"bm90LWEtcmVhbC1uZXR3b3Jr\"}.\n")

    assert Network.current() == :custom
    assert Network.current_id() == "bm90LWEtcmVhbC1uZXR3b3Jr"
    refute Network.publishable?()
  end

  test "a corrupt overrides file is ignored, then repaired by set/1" do
    File.mkdir_p!(Path.dirname(Network.path()))
    File.write!(Network.path(), "this is not erlang {{{\n")

    assert Network.current() == :dev
    assert Network.publishable?()

    assert :ok = Network.set(:mainnet)
    assert Network.current() == :mainnet
  end

  test "timeline publishes only on the development network" do
    assert {:error, :offline} = Timeline.publish("hello")

    assert :ok = Network.set(:mainnet)
    assert {:error, :mainnet_read_only} = Timeline.publish("hello")
    assert {:error, :mainnet_read_only} = Timeline.like("%some=.sha256")
    assert {:error, :mainnet_read_only} = Timeline.follow("@some=.ed25519")

    assert :ok = Network.set(:dev)
    assert {:error, :offline} = Timeline.publish("hello")
  end
end
