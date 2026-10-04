defmodule HighWire.SSB.BoxStreamTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.BoxStream

  @nonce <<0::192>>

  setup do
    {:ok, key: :crypto.strong_rand_bytes(32)}
  end

  test "box/unbox round-trips and advances the nonce by 2", %{key: key} do
    data = "hello boxstream"
    {boxed, n2} = BoxStream.box(data, @nonce, key)
    assert n2 == BoxStream.incr(BoxStream.incr(@nonce))
    assert {:frame, ^data, ^n2, <<>>} = BoxStream.unbox(boxed, @nonce, key)
  end

  test "end frame round-trips as 34 bytes and signals :end", %{key: key} do
    {boxed, n2} = BoxStream.box(BoxStream.box_end(), @nonce, key)
    assert byte_size(boxed) == 34
    assert n2 == BoxStream.incr(@nonce)
    assert {:end, @nonce} = BoxStream.unbox(boxed, @nonce, key)
  end

  test "partial buffers stay partial", %{key: key} do
    {boxed, _} = BoxStream.box("some payload", @nonce, key)
    assert BoxStream.unbox(binary_part(boxed, 0, 10), @nonce, key) == :partial
    <<hdr::binary-size(34), _::binary>> = boxed
    assert BoxStream.unbox(hdr, @nonce, key) == :partial
  end

  test "two frames concatenated decode in order", %{key: key} do
    {b1, n1} = BoxStream.box("first", @nonce, key)
    {b2, n2} = BoxStream.box("second", n1, key)
    assert {:frame, "first", n1, rest} = BoxStream.unbox(b1 <> b2, @nonce, key)
    assert {:frame, "second", ^n2, <<>>} = BoxStream.unbox(rest, n1, key)
  end

  test "payloads over 4096 bytes chunk and reassemble", %{key: key} do
    data = :crypto.strong_rand_bytes(10_000)
    {boxed, _} = BoxStream.box(data, @nonce, key)
    assert reassemble(boxed, @nonce, key, <<>>) == data
  end

  test "tampering is detected" do
    key = :crypto.strong_rand_bytes(32)
    {boxed, _} = BoxStream.box("payload", @nonce, key)
    <<a, rest::binary>> = boxed
    tampered = <<Bitwise.bxor(a, 1)>> <> rest
    assert_raise RuntimeError, ~r/authentication failed/, fn ->
      BoxStream.unbox(tampered, @nonce, key)
    end
  end

  defp reassemble(<<>>, _nonce, _key, acc), do: acc

  defp reassemble(buf, nonce, key, acc) do
    assert {:frame, chunk, n, rest} = BoxStream.unbox(buf, nonce, key)
    reassemble(rest, n, key, acc <> chunk)
  end
end
