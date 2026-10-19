defmodule HighWireWeb.BlobController do
  @moduledoc """
  Serves blobs by hex key: `GET /blob/<64-hex>`.

  Resolution order:

    1. `~/.highwire/images/<hex>` — HighWire's own cache (generated
       placeholders, plus copies made while the old store was still a
       source)
    2. `<home>/.ssberl/blobs/<HH>/<rest>` — the engine's own blob
       store: everything HighWire serves was imported or replicated
       into it, and the old JS-client store (`~/.ssb`) is never opened
    3. a neutral "missing blob" placeholder (dashed frame over a
       mountain glyph, no per-key derivation) — the bytes have never
       been seen. It deliberately does NOT look like an identicon:
       identicons only mean something keyed by a feed id (a long-lived
       identity), never by a blob. The short cache window lets the
       real blob take over as soon as it lands.

  Also serves `GET /identicon/<feed-id-hex>`: the Excon `:framed`
  identicon for feeds without an avatar image (deterministic per id, so
  it is cached immutably).

  The keys are strictly validated as hex, so the paths can never escape
  those directories. Unparseable keys 404.
  """

  use HighWireWeb, :controller

  alias HighWire.Blob

  # Excon picks its four-color palette from four bits of the id's hash;
  # these are its gold/olive/orange (brown-reading) palettes. Salt the
  # id until the hash lands on a cool palette — deterministic per id,
  # so the output and its cache stay stable.
  @warm_palettes MapSet.new([3, 4, 5, 12])

  def show(conn, %{"key" => key}) do
    case hex_key(key) do
      {:ok, hex} -> serve(conn, resolve(hex))
      {:error, _} -> send_resp(conn, 404, "not found")
    end
  end

  defp serve(conn, {:file, path}) do
    case content_type(path) do
      {:ok, type} ->
        conn
        |> put_resp_content_type(type)
        |> put_resp_header("cache-control", "public, max-age=60")
        |> put_blob_headers(type)
        |> send_file(200, path)

      {:error, _} ->
        send_resp(conn, 404, "not found")
    end
  end

  defp serve(conn, {:generated, data}) do
    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("cache-control", "public, max-age=60")
    |> send_resp(200, data)
  end

  # These bytes are a peer's, not ours. `nosniff` stops a browser from
  # re-typing them by content the way it re-reads a sniffed type; an SVG
  # is worse than that — it is a document, and served same-origin it
  # would run script in the app's own origin the moment a post links
  # `&<blob>.sha256`. The sandbox costs the ordinary case nothing (an
  # `<img>` load ignores CSP) and removes script execution from a
  # document context, which is the whole attack.
  defp put_blob_headers(conn, "image/svg+xml") do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header(
      "content-security-policy",
      "sandbox; default-src 'none'; style-src 'unsafe-inline'"
    )
  end

  defp put_blob_headers(conn, _type) do
    put_resp_header(conn, "x-content-type-options", "nosniff")
  end

  def ident(conn, %{"key" => key}) do
    with {:ok, id} <- id_key(key),
         {:ok, data} <- framed_identicon(id) do
      conn
      |> put_resp_content_type("image/svg+xml")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> send_resp(200, data)
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  defp hex_key(key) do
    if String.match?(key, ~r/\A[0-9a-fA-F]{64}\z/) do
      {:ok, String.downcase(key)}
    else
      {:error, :bad_key}
    end
  end

  # The identicon key is the feed id itself, hex-encoded (even-length
  # lowercase hex, bounded so the path stays a single segment).
  defp id_key(key) do
    with true <- String.match?(key, ~r/\A[0-9a-f]{4,512}\z/),
         {:ok, id} <- Base.decode16(key, case: :lower),
         true <- id != "" do
      {:ok, id}
    else
      _ -> {:error, :bad_key}
    end
  end

  defp resolve(hex) do
    cache = Path.join(Blob.cache_root(), hex)
    gen = Path.join([Blob.cache_root(), "gen", hex])

    cond do
      File.regular?(cache) ->
        {:file, cache}

      is_binary(store = Blob.store_path(hex)) and File.regular?(store) and
          File.stat!(store).size > 0 ->
        {:file, store}

      true ->
        # Earlier builds cached Excon identicons under gen/ keyed by
        # the blob hex — a pseudo-identicon that means nothing. Remove
        # on sight; the neutral placeholder answers until the real
        # bytes land in the store above.
        _ = File.rm(gen)
        {:generated, missing_blob_svg()}
    end
  end

  # Static, theme-aware via prefers-color-scheme (the SVG renders in an
  # <img>, which honors media queries but not page CSS). No key in it:
  # every missing blob looks the same, and only feed-id identicons get
  # to be interesting.
  @missing_blob_svg """
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
    <style>
      .bg { fill: #22252b; }
      .fg { fill: #8f93a0; }
      .dash { fill: none; stroke: #8f93a0; stroke-width: 2; stroke-dasharray: 7 5; opacity: 0.7; }
      @media (prefers-color-scheme: light) {
        .bg { fill: #e8eaef; }
        .fg { fill: #65656e; }
        .dash { stroke: #65656e; }
      }
    </style>
    <rect class="bg" width="64" height="64"/>
    <rect class="dash" x="5" y="5" width="54" height="54"/>
    <path class="fg" d="M12 47 L26 31 L34 39 L42 29 L52 47 Z"/>
    <circle class="fg" cx="45" cy="20" r="5"/>
  </svg>
  """

  defp missing_blob_svg, do: @missing_blob_svg

  # Deterministic per feed id; cached under images/ident/ so the Blake2
  # hash and SVG assembly happen once per id ever.
  defp framed_identicon(id) do
    key = Base.encode16(id, case: :lower)
    path = Path.join([Blob.cache_root(), "ident", key])

    if File.regular?(path) do
      {:ok, File.read!(path)}
    else
      data = Excon.ident(cool_id(id), type: :framed)
      _ = File.mkdir_p(Path.dirname(path))
      _ = File.write(path, data)
      {:ok, data}
    end
  end

  # Try the id as-is first, then append a salt until the palette nibble
  # (high4 bits of hash byte 4 — same position for :png and :framed)
  # lands outside the warm set. A cool palette exists for3/4 of all
  # hashes, so this almost never salts twice.
  defp cool_id(id) do
    Enum.find_value(0..15, id, fn salt ->
      salted = if salt == 0, do: id, else: id <> "$" <> Integer.to_string(salt)
      cool_salt(salted, Blake2.hash2b(salted, 5))
    end) || id
  end

  defp cool_salt(salted, <<_::binary-size(4), pal::integer-size(4), _::bitstring>>) do
    if MapSet.member?(@warm_palettes, pal), do: nil, else: salted
  end

  defp cool_salt(_salted, _hash), do: nil

  defp content_type(path) do
    case File.open(path, [:read], &IO.binread(&1, 16)) do
      {:ok, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>} -> {:ok, "image/png"}
      {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} -> {:ok, "image/jpeg"}
      {:ok, <<"GIF87a", _::binary>>} -> {:ok, "image/gif"}
      {:ok, <<"GIF89a", _::binary>>} -> {:ok, "image/gif"}
      {:ok, <<"RIFF", _::binary-size(4), "WEBP", _::binary>>} -> {:ok, "image/webp"}
      {:ok, <<"<svg", _::binary>>} -> {:ok, "image/svg+xml"}
      {:ok, _} -> {:ok, "application/octet-stream"}
      {:error, _} -> {:error, :unreadable}
    end
  end
end
