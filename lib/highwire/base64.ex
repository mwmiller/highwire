defmodule HighWire.Base64 do
  @moduledoc """
  The base64 spellings SSB exchanges, decoded in one place.

  Blob refs, addresses and display ids travel unpadded as often as padded,
  and in the URL-safe alphabet as often as the standard one. Decoding
  therefore repairs the padding first and then tries standard base64 before
  the URL-safe alphabet, so callers get bytes rather than a spelling to
  match.
  """

  @doc """
  Decode padded or unpadded base64 in either alphabet.
  """
  @spec decode(String.t()) :: {:ok, binary()} | :error
  def decode(str) when is_binary(str) do
    padded = pad(String.trim(str))

    case Base.decode64(padded) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.url_decode64(padded)
    end
  end

  # Unpadded input is common (a display id, a published ref), and base64
  # decoders want the length to be a multiple of four.
  defp pad(str) do
    str <> String.duplicate("=", rem(4 - rem(byte_size(str), 4), 4))
  end
end
