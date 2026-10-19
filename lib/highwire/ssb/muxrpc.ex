defmodule HighWire.SSB.Muxrpc do
  @moduledoc """
  muxrpc packet framing: a 9-byte header — flags (1), body length (4
  big-endian unsigned), request number (4 big-endian signed) — followed
  by the body. Flags are `<<0::4, stream::1, end::1, type::2>>`.

  `type 0` is JSON (what this client sends; erlbutt decodes request
  bodies as JSON regardless of the type bits). All replies arrive on the
  negated request number.

  A *sink* (`blobs.add`) is the one request whose body this client
  streams: `encode_sink/5` builds the opening, data and end frames, and
  the reply is a single end frame once the engine has the whole body.
  """

  @rpc_end <<0::72>>

  @type meta :: %{stream: 0 | 1, end: 0 | 1, req: integer()}

  @spec rpc_end() :: binary()
  def rpc_end, do: @rpc_end

  @spec encode(meta(), binary()) :: binary()
  def encode(%{stream: stream, end: endf, req: req}, body) when is_binary(body) do
    <<0::4, stream::1, endf::1, 0::2, byte_size(body)::32-big-unsigned, req::32-big-signed,
      body::binary>>
  end

  @spec encode_request(integer(), [String.t()], term(), String.t(), 0 | 1) :: binary()
  def encode_request(req, name, args, type, stream) do
    body = Jason.encode!(%{name: name, args: args, type: type})
    encode(%{stream: stream, end: 0, req: req}, body)
  end

  @doc """
  The frames of a muxrpc *sink* (`blobs.add`): the request frame with
  stream type `sink`, the body as binary frames of at most `chunk` bytes,
  and an end frame carrying JSON `true`.

  The engine ends the sink on the end flag, and reads that frame's body as
  the sink's own error channel — a body that is not `true` aborts the
  blob, so an error must never ride on it.
  """
  @spec encode_sink(integer(), [String.t()], term(), binary(), pos_integer()) :: [binary()]
  def encode_sink(req, name, args, body, chunk \\ 64 * 1024) do
    data = Enum.map(chunks(body, chunk), &encode(%{stream: 1, end: 0, req: req}, &1))

    [encode_request(req, name, args, "sink", 1)] ++
      data ++ [encode(%{stream: 1, end: 1, req: req}, "true")]
  end

  defp chunks(<<>>, _chunk), do: []
  defp chunks(body, chunk) when byte_size(body) <= chunk, do: [body]

  defp chunks(body, chunk) do
    size = byte_size(body)
    for pos <- 0..(size - 1)//chunk, do: binary_part(body, pos, min(chunk, size - pos))
  end

  @spec decode(binary()) ::
          {:packet, meta(), binary(), binary()}
          | {:rpc_end, binary()}
          | :partial
  def decode(buf) when byte_size(buf) < 9, do: :partial
  def decode(<<0::72, rem::binary>>), do: {:rpc_end, rem}

  def decode(buf) do
    <<flags::binary-size(1), size::32-big-unsigned, req::32-big-signed, rest::binary>> = buf
    <<0::4, stream::1, endf::1, _type::2>> = flags

    if byte_size(rest) >= size do
      <<body::binary-size(^size), rem::binary>> = rest
      {:packet, %{stream: stream, end: endf, req: req}, body, rem}
    else
      :partial
    end
  end
end
