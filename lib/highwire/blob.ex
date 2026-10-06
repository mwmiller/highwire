defmodule HighWire.Blob do
  @moduledoc """
  SSB blob references (`&<base64>.sha256`) → the hex key Patchwork's
  store is laid out by, and the local URL that serves them.

  Patchwork keeps blobs at `~/.ssb/blobs/sha256/<hex[:2]>/<hex[2:]>`;
  HighWire serves `/blob/<hex>` from a copy-on-read cache in
  `~/.highwire/images` and never writes into the source store.
  """

  @doc """
  The URL that serves the blob behind `ref`, or nil when the reference
  is not a valid sha256 blob id (callers fall back to the color tile).
  """
  @spec url(term()) :: binary() | nil
  def url(ref) when is_binary(ref) do
    case ref_to_hex(ref) do
      {:ok, hex} -> "/blob/" <> hex
      :error -> nil
    end
  end

  def url(_), do: nil

  @doc """
  `&<base64>.sha256` → lowercase hex of the 32 digest bytes.
  """
  @spec ref_to_hex(binary()) :: {:ok, binary()} | :error
  def ref_to_hex("&" <> rest) do
    case String.split(rest, ".sha256", parts: 2) do
      [b64, ""] -> decode(b64)
      _ -> :error
    end
  end

  def ref_to_hex(_), do: :error

  @doc "Patchwork's blob store root (read-only)."
  def source_root do
    Application.get_env(:highwire, :blob_source, Path.expand("~/.ssb/blobs/sha256"))
  end

  @doc "HighWire's copy-on-read avatar cache."
  def cache_root, do: Path.join(HighWire.home_dir(), "images")

  @doc "The Patchwork-store path for a hex key."
  def source_path(hex) do
    Path.join([source_root(), binary_part(hex, 0, 2), binary_part(hex, 2, 62)])
  end

  @doc "True when the blob behind `ref` is already on disk (cache or store)."
  def local?(ref) do
    case ref_to_hex(ref) do
      {:ok, hex} ->
        File.regular?(Path.join(cache_root(), hex)) or File.regular?(source_path(hex))

      :error ->
        # not a servable ref at all — nothing to want
        true
    end
  end

  # Standard base64 is what ssb refs use; the URL-safe alphabet is
  # accepted too, and padding is repaired for unpadded emitters.
  defp decode(b64) do
    padded = b64 <> String.duplicate("=", rem(4 - rem(byte_size(b64), 4), 4))

    found =
      Enum.find_value([Base.decode64(padded), Base.url_decode64(padded)], fn
        {:ok, bin} when byte_size(bin) == 32 -> Base.encode16(bin, case: :lower)
        _ -> nil
      end)

    case found do
      nil -> :error
      hex -> {:ok, hex}
    end
  end
end
