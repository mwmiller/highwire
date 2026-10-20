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

  test "a sink opens as sink, streams the body in chunks, and ends with true" do
    frames = Muxrpc.encode_sink(9, ["blobs", "add"], ["&x=.sha256"], :binary.copy(<<7>>, 10), 4)

    assert [open, first, second, third, last] = frames
    assert {:packet, %{stream: 1, end: 0, req: 9}, body, <<>>} = Muxrpc.decode(open)

    assert Jason.decode!(body) == %{
             "name" => ["blobs", "add"],
             "args" => ["&x=.sha256"],
             "type" => "sink"
           }

    # The bytes the engine appends come through in order and complete —
    # the frame split is invisible to it.
    data = Enum.map([first, second, third], &Muxrpc.decode/1)

    assert Enum.map(data, fn {:packet, %{stream: 1, end: 0, req: 9}, b, <<>>} -> b end)
           |> IO.iodata_to_binary() == :binary.copy(<<7>>, 10)

    assert Enum.map(data, fn {:packet, _, b, _} -> byte_size(b) end) == [4, 4, 2]
    assert {:packet, %{stream: 1, end: 1, req: 9}, "true", <<>>} = Muxrpc.decode(last)
  end

  test "a sink's small body is one frame, and an empty body is none" do
    assert [_open, data, _end] = Muxrpc.encode_sink(1, ["blobs", "add"], [nil], "abc", 4)
    assert {:packet, %{stream: 1, end: 0, req: 1}, "abc", <<>>} = Muxrpc.decode(data)

    # An empty blob opens and ends with nothing between: no zero-length
    # frame for the engine to append.
    assert [_open, _end] = Muxrpc.encode_sink(2, ["blobs", "add"], [nil], "", 4)
  end

  test "the frame cap is the 32-bit length field's ceiling" do
    # A body that overflowed the header's length field would be silently
    # shortened by the bitstring and reach the engine as a short frame.
    # encode/2 refuses sizes past this; the test pins the ceiling itself
    # (allocating a 4 GiB body to trip the guard is not worth doing).
    assert Muxrpc.max_body() == :erlang.bsl(1, 32) - 1

    # A body at the top of the safe range frames with the length field
    # holding its true size.
    body = :binary.copy(<<7>>, 1024)

    assert {:packet, _, ^body, <<>>} =
             Muxrpc.decode(Muxrpc.encode(%{stream: 0, end: 0, req: 1}, body))
  end
end
