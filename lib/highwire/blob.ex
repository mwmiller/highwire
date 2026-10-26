defmodule HighWire.Blob do
  @moduledoc """
  SSB blob references (`&<base64>.sha256`) → the hex key the blob
  stores are laid out by, and the local URL that serves them.

  `/blob/<hex>` is answered from HighWire's own data: the engine's
  blob store (`<home>/.ssberl/blobs/<HH>/<rest>` — erlbutt's layout),
  then the `images/` cache, then a generated placeholder. The old
  JS-client store (`~/.ssb`) is not consulted: everything on screen
  was imported or replicated into HighWire's directories.

  A blob carries no name, so what it is comes from its bytes: the
  signature says whether it is a picture, a recording, a film or
  something else, and both the route and the renderer ask.
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

  @doc """
  The SSB reference (`&<base64>.sha256`) for these bytes — the string a
  post carries in `![alt](…)`.

  The same string is the id `blobs.add` is opened with, because erlbutt's
  own `hash_id/1` is `"&" ++ base64(sha256(Blob)) ++ ".sha256"` and the
  engine verifies the streamed bytes against the id it was given. So a
  blob the store accepted is exactly the blob the post points at, or the
  add fails loudly instead.
  """
  @spec ref(binary()) :: binary()
  def ref(bytes) when is_binary(bytes) do
    "&" <> Base.encode64(:crypto.hash(:sha256, bytes)) <> ".sha256"
  end

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

  @doc """
  What kind of media a blob holds, from its first bytes.

  A blob carries no name and no extension: the bytes are the only thing
  that says what it is. The renderer asks here, so a post carrying an
  audio file can be a player rather than a picture that cannot load.
  `:missing` when the bytes have not arrived yet.
  """
  @spec media_type(binary()) :: :image | :audio | :video | :file | :missing
  def media_type(ref) when is_binary(ref) do
    case ref_to_hex(ref) do
      {:ok, hex} -> kind_of(hex)
      :error -> :missing
    end
  end

  def media_type(_), do: :missing

  @doc """
  The MIME type of a blob file, from its first bytes.

  Blobs have no extension to go by, and a browser will not sniff for
  itself, so the type that goes out is the type the signature gives.
  """
  @spec content_type(Path.t()) :: {:ok, binary()} | {:error, :unreadable}
  def content_type(path) do
    # 48 bytes: the ISOBMFF head runs size(4) + "ftyp"(4) + brand(4) +
    # minor version(4), and the compatible brands that can carry `avif`
    # start at byte 16 — the first eight of them fit here.
    case File.open(path, [:read], &IO.binread(&1, 48)) do
      {:ok, head} -> {:ok, mime(head)}
      {:error, _} -> {:error, :unreadable}
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

  # The same order the blob route serves: HighWire's own cache first,
  # then the engine's blob store.
  defp local_path(hex) do
    cache = Path.join(cache_root(), hex)

    cond do
      File.regular?(cache) ->
        cache

      is_binary(store = store_path(hex)) and stored?(store) ->
        store

      true ->
        nil
    end
  end

  defp stored?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > 0
      _ -> false
    end
  end

  defp kind_of(hex) do
    case local_path(hex) do
      nil -> :missing
      path -> kind(content_type(path))
    end
  end

  defp kind({:ok, "image/" <> _}), do: :image
  defp kind({:ok, "audio/" <> _}), do: :audio
  defp kind({:ok, "video/" <> _}), do: :video
  defp kind(_), do: :file

  # Magic bytes. An MPEG audio frame starts with eleven set bits, which
  # is why the frame check takes the second byte whole: its top three
  # bits set is the sync.
  defp mime(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp mime(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp mime(<<"GIF87a", _::binary>>), do: "image/gif"
  defp mime(<<"GIF89a", _::binary>>), do: "image/gif"
  defp mime(<<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp mime(<<"<svg", _::binary>>), do: "image/svg+xml"
  defp mime(<<"ID3", _::binary>>), do: "audio/mpeg"
  defp mime(<<0xFF, second, _::binary>>) when second >= 0xE0, do: "audio/mpeg"
  defp mime(<<"OggS", _::binary>>), do: "audio/ogg"
  defp mime(<<"fLaC", _::binary>>), do: "audio/flac"
  defp mime(<<"RIFF", _::binary-size(4), "WAVE", _::binary>>), do: "audio/wav"

  # ISOBMFF — the box format AVIF, HEIC, MP4 and M4A all share. The
  # signature is never at byte 0: four bytes of box size come first,
  # then "ftyp", then the brand that says what the file is. `avif` is a
  # still image and `avis` an image sequence; encoders that file AVIF
  # under a structural brand (`mif1`, `msf1`, `miaf`) name `avif` only
  # among the compatible brands behind the minor version, so those are
  # looked for there too. The HEIC family names a picture no browser
  # here can draw, so it stays a file: an image that will not render is
  # pulled from the post outright, while a file link still opens.
  defp mime(<<_::32, "ftyp", brand::binary-size(4), _::binary>>) when brand in ["avif", "avis"],
    do: "image/avif"

  defp mime(<<_::32, "ftyp", brand::binary-size(4), _::binary-size(4), compatible::binary>>)
       when brand in ["mif1", "msf1", "miaf"] do
    if compatible_brand?(compatible), do: "image/avif", else: "application/octet-stream"
  end

  defp mime(<<_::32, "ftyp", brand::binary-size(4), _::binary>>)
       when brand in ["heic", "heix", "heim", "heis", "hevc", "hevx"],
       do: "application/octet-stream"

  defp mime(<<_::32, "ftyp", "M4A ", _::binary>>), do: "audio/mp4"
  defp mime(<<_::32, "ftyp", "qt", _::binary>>), do: "video/quicktime"
  defp mime(<<_::32, "ftyp", _brand::binary-size(4), _::binary>>), do: "video/mp4"
  defp mime(<<0x1A, 0x45, 0xDF, 0xA3, _::binary>>), do: "video/webm"
  defp mime(<<"%PDF-", _::binary>>), do: "application/pdf"
  defp mime(_), do: "application/octet-stream"

  # A compatible brand sits every four bytes from byte 16; the head
  # read carries the first eight of them.
  defp compatible_brand?(<<"avif", _::binary>>), do: true
  defp compatible_brand?(<<"avis", _::binary>>), do: true
  defp compatible_brand?(<<_::binary-size(4), rest::binary>>), do: compatible_brand?(rest)
  defp compatible_brand?(_head), do: false
end
