defmodule HighWire.SSB.MuxrpcTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Muxrpc

  test "request encode/decode round-trip" do
    pkt = Muxrpc.encode_request(1, ["whoami"], [], "sync", 0)
    assert {:packet, %{stream: 0, end: 0, req: 1}, body, <<>>} = Muxrpc.decode(pkt)
    assert Jason.decode!(body) == %{"name" => ["whoami"], "args" => [], "type" => "sync"}
  end

  test "source request sets the stream flag" do
    pkt = Muxrpc.encode_request(2, ["createHistoryStream"], [%{"id" => "@x"}], "source", 1)
    assert {:packet, %{stream: 1, req: 2}, _, <<>>} = Muxrpc.decode(pkt)
  end

  test "reply on negated req with end flag" do
    pkt = Muxrpc.encode(%{stream: 0, end: 1, req: -3}, ~s({"error":["Error","nope"]}))
    assert {:packet, %{stream: 0, end: 1, req: -3}, body, <<>>} = Muxrpc.decode(pkt)
    assert Jason.decode!(body)["error"] == ["Error", "nope"]
  end

  test "stream terminator carries true" do
    pkt = Muxrpc.encode(%{stream: 1, end: 1, req: -7}, "true")
    assert {:packet, %{stream: 1, end: 1, req: -7}, "true", <<>>} = Muxrpc.decode(pkt)
  end

  test "partial input yields :partial" do
    pkt = Muxrpc.encode_request(1, ["whoami"], [], "sync", 0)
    assert Muxrpc.decode(binary_part(pkt, 0, 5)) == :partial
    assert Muxrpc.decode(binary_part(pkt, 0, byte_size(pkt) - 1)) == :partial
  end

  test "rpc_end decodes and keeps the remainder" do
    assert {:rpc_end, "abc"} = Muxrpc.decode(Muxrpc.rpc_end() <> "abc")
  end

  test "extra frames after one packet are preserved" do
    p1 = Muxrpc.encode(%{stream: 0, end: 0, req: -1}, "1")
    p2 = Muxrpc.encode(%{stream: 0, end: 0, req: -2}, "2")
    assert {:packet, %{req: -1}, "1", rest} = Muxrpc.decode(p1 <> p2)
    assert {:packet, %{req: -2}, "2", <<>>} = Muxrpc.decode(rest)
  end
end
