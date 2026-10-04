defmodule HighWire.SSB.Muxrpc do
  @moduledoc """
  muxrpc packet framing: a 9-byte header — flags (1), body length (4
  big-endian unsigned), request number (4 big-endian signed) — followed
  by the body. Flags are `<<0::4, stream::1, end::1, type::2>>`.

  `type 0` is JSON (what this client sends; erlbutt decodes request
  bodies as JSON regardless of the type bits). All replies arrive on the
  negated request number.
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
