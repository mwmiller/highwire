defmodule HighWire.SSB.ErpcTest do
  @moduledoc """
  The erpc transport's own contract: EJSON decoding, and the degrade.

  The everyday suite runs with the engine disabled, so there is no node
  and every call must answer `{:error, :no_engine}` — no raises, no
  hangs, no distribution started by a test. The live-engine half of the
  contract (a real node, a real plugin answer, a builtin refusal) is
  in `HighWire.SSB.EngineTest`, which is the only suite that boots one.
  """

  use ExUnit.Case, async: true

  alias HighWire.SSB.Erpc

  describe "with the engine disabled" do
    test "every call answers no_engine" do
      assert {:error, :no_engine} = Erpc.call(["admin", "status"], [], 50)
      assert {:error, :no_engine} = Erpc.call(["whoami"], [], 50)
      assert {:error, :no_engine} = Erpc.call(["no", "such", "method"], [], 50)
    end

    test "a short timeout still answers, never hangs" do
      assert {:error, :no_engine} = Erpc.call(["admin", "status"], [], 10)
    end
  end

  describe "from_ejson/1" do
    test "objects become maps keyed by the same binaries Jason leaves" do
      props = [{<<"enabled">>, true}, {<<"attempts">>, 3}]
      assert Erpc.from_ejson({props}) == %{"enabled" => true, "attempts" => 3}
    end

    test "null becomes nil, at any depth" do
      props = [{<<"a">>, :null}, {<<"b">>, {[{<<"c">>, :null}]}}]

      assert Erpc.from_ejson({props}) == %{
               "a" => nil,
               "b" => %{"c" => nil}
             }
    end

    test "lists decode elementwise" do
      ejson = [{[{<<"host">>, :null}]}, {[{<<"port">>, 8008}]}]

      assert Erpc.from_ejson(ejson) == [%{"host" => nil}, %{"port" => 8008}]
    end

    test "duplicate keys resolve to the last, as Jason.decode does" do
      assert Erpc.from_ejson({[{<<"k">>, 1}, {<<"k">>, 2}]}) == %{"k" => 2}
    end

    test "atoms, numbers and binaries pass through untouched" do
      assert Erpc.from_ejson(:ok) == :ok
      assert Erpc.from_ejson(42) == 42
      assert Erpc.from_ejson(1.5) == 1.5
      assert Erpc.from_ejson(true) == true
      assert Erpc.from_ejson(<<"sg">>) == "sg"
    end
  end
end
