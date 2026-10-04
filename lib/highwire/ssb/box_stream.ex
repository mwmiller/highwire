defmodule HighWire.SSB.BoxStream do
  @moduledoc """
  SSB box-stream framing: the encrypted transport beneath muxrpc.

  One frame = 34-byte encrypted header (2-byte big-endian body length +
  16-byte body MAC) followed by the body ciphertext. The 24-byte nonce
  is a big-endian counter: +1 per header box, +1 more per body box
  (data frames consume 2, end frames consume 1).
  """

  @max_body 4096
  @box_end <<0::144>>

  @type nonce :: binary()

  @spec box_end() :: binary()
  def box_end, do: @box_end

  @spec box(binary(), nonce(), binary()) :: {binary(), nonce()}
  def box(data, nonce, key) when byte_size(data) > @max_body do
    <<chunk::binary-size(@max_body), rest::binary>> = data
    {b1, n1} = box(chunk, nonce, key)
    {b2, n2} = box(rest, n1, key)
    {b1 <> b2, n2}
  end

  def box(@box_end, nonce, key) do
    {:enacl.secretbox(@box_end, nonce, key), incr(nonce)}
  end

  def box(data, nonce, key) do
    len = byte_size(data)
    <<tag::binary-size(16), body::binary>> = :enacl.secretbox(data, incr(nonce), key)
    enc_header = :enacl.secretbox(<<len::16-big, tag::binary>>, nonce, key)
    {enc_header <> body, incr(incr(nonce))}
  end

  @spec unbox(binary(), nonce(), binary()) ::
          {:frame, binary(), nonce(), binary()} | {:end, nonce()} | :partial
  def unbox(buf, _nonce, _key) when byte_size(buf) < 34, do: :partial

  def unbox(buf, nonce, key) do
    <<hdr::binary-size(34), rest::binary>> = buf
    plain_hdr = open!(hdr, nonce, key)

    if plain_hdr == @box_end do
      {:end, nonce}
    else
      <<len::16-big, tag::binary-size(16)>> = plain_hdr

      if byte_size(rest) >= len do
        <<body::binary-size(^len), rem::binary>> = rest
        payload = open!(tag <> body, incr(nonce), key)
        {:frame, payload, incr(incr(nonce)), rem}
      else
        :partial
      end
    end
  end

  @spec incr(nonce()) :: nonce()
  def incr(nonce) do
    <<n::big-integer-size(192)>> = nonce
    <<Integer.mod(n + 1, Bitwise.bsl(1, 192))::big-integer-size(192)>>
  end

  defp open!(box, nonce, key) do
    case :enacl.secretbox_open(box, nonce, key) do
      {:ok, plain} -> plain
      {:error, reason} -> raise "box-stream authentication failed: #{inspect(reason)}"
    end
  end
end
