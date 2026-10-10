defmodule HighWire.Blob do
  @moduledoc """
  SSB blob references (`&<base64>.sha256`) → the hex key the blob
  stores are laid out by, and the local URL that serves them.

  `/blob/<hex>` is answered from HighWire's own data: the engine's
  blob store (`<home>/.ssberl/blobs/<HH>/<rest>` — erlbutt's layout),
  then the `images/` cache, then a generated placeholder. The old
  JS-client store (`~/.ssb`) is not consulted: everything on screen
  was imported or replicated into HighWire's directories.
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

  @doc "The engine's blob store root."
  def store_root do
    Application.get_env(
      :highwire,
      :blob_store,
      Path.join([HighWire.home_dir(), ".ssberl", "blobs"])
    )
  end

  @doc "HighWire's image cache: generated placeholders and legacy copies."
  def cache_root, do: Path.join(HighWire.home_dir(), "images")

  @doc """
  The engine-store path for a hex key.

  erlbutt addresses blobs by the minimal uppercase hex of the digest
  (`integer_to_binary(hash, 16)` — no leading zero nibbles, letters
  upper), split two characters for the directory. A key that shortens
  below that split cannot exist on disk and answers nil, matching the
  engine's own not_found.
  """
  def store_path(hex) do
    hex = hex |> String.upcase() |> String.replace_leading("0", "")

    case hex do
      <<dir::binary-size(2), rest::binary>> -> Path.join([store_root(), dir, rest])
      _too_short -> nil
    end
  end

  @doc "True when the blob behind `ref` is already on disk (cache or store)."
  def local?(ref) do
    case ref_to_hex(ref) do
      {:ok, hex} ->
        File.regular?(Path.join(cache_root(), hex)) or store_file?(hex)

      :error ->
        # not a servable ref at all — nothing to want
        true
    end
  end

  @doc false
  def store_file?(hex) do
    case store_path(hex) do
      nil -> false
      path -> File.regular?(path)
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
