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
       identity), never by a blob.

  A served file is immutable — its key is the hash of its bytes — and is
  cached for a year. The placeholder is the exception, on a minute-long
  window so the real blob takes over its URL as soon as it lands.

  The content type comes from the bytes: a blob carries no name, so the
  signature is what tells the browser what it is holding.

  Also serves `GET /identicon/<feed-id-hex>`: the Excon `:framed`
  identicon for feeds without an avatar image (deterministic per id, so
  it is cached immutably).

  The keys are strictly validated as hex, so the paths can never escape
  those directories. Unparseable keys 404.
  """

  use HighWireWeb, :controller

  alias HighWire.Blob
  alias HighWire.Timeline

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

  # The engine's own cap on one blob (`?BLOB_MAX_SIZE` in erlbutt is
  # 5 MiB), and the length read_body stops at, so an oversized upload is
  # refused before its bytes are read rather than after they are buffered.
  @max_blob_size 5 * 1024 * 1024

  @doc """
  `POST /blob` — store an attached image and answer with its SSB
  reference.

  The browser sends the file itself as the request body, under the file's
  own content type, which the endpoint's parsers pass over
  (`pass: ["*/*"]`), so the bytes are read here. Only images are taken:
  this is the picture path a composer turns into `![alt](&…)`, and a
  non-image would come out the other end as a broken one.
  """
  def create(conn, _params) do
    if image_type?(upload_type(conn)) do
      store(conn)
    else
      refuse(conn, 415, "only images can be attached")
    end
  end

  defp store(conn) do
    case Plug.Conn.read_body(conn, length: @max_blob_size, read_timeout: 15_000) do
      {:ok, "", conn} ->
        refuse(conn, 422, "that file is empty")

      {:ok, bytes, conn} ->
        case Timeline.add_blob(bytes) do
          {:ok, ref} -> json(conn, %{ref: ref, url: Blob.url(ref)})
          {:error, :offline} -> refuse(conn, 503, "HighWire is not connected")
          {:error, reason} -> refuse(conn, 422, describe(reason))
        end

      {:more, _partial, conn} ->
        refuse(conn, 413, "image is larger than 5 MB")

      {:error, _reason} ->
        refuse(conn, 400, "could not read that upload")
    end
  end

  defp upload_type(conn) do
    case Plug.Conn.get_req_header(conn, "content-type") do
      [type | _] -> type |> String.split(";") |> hd() |> String.trim()
      [] -> nil
    end
  end

  defp image_type?(type), do: is_binary(type) and String.starts_with?(type, "image/")

  defp refuse(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # A blob's key is the hash of its bytes, so the file at this path can
  # never become different bytes: immutable, cached for a year. Avatars
  # ride this route and feeds share the same people, so a minute-long
  # window meant every repeated face was refetched for as long as a page
  # stayed open. The `?v=<blob_rev>` query an avatar URL carries is what
  # re-fetches a URL whose bytes upgraded from placeholder to real blob.
  defp serve(conn, {:file, path}) do
    case Blob.content_type(path) do
      {:ok, type} ->
        conn
        |> put_resp_content_type(type)
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> put_blob_headers(type)
        |> send_blob(path)

      {:error, _} ->
        send_resp(conn, 404, "not found")
    end
  end

  # The placeholder answers a blob whose bytes are not local yet, and the
  # short window is the point: the real blob takes over the URL as soon
  # as it lands.
  defp serve(conn, {:generated, data}) do
    conn
    |> put_resp_content_type("image/svg+xml")
    |> put_resp_header("cache-control", "public, max-age=60")
    |> send_resp(200, data)
  end

  # A player asks for the bytes it wants: the browser opens with
  # `Range: bytes=0-` and narrows the window as the listener seeks.
  # Answering with the whole file every time leaves the seek guessing,
  # so one range is honoured and answered 206.
  defp send_blob(conn, path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        conn = put_resp_header(conn, "accept-ranges", "bytes")

        case requested_range(conn, size) do
          {:ok, offset, length} ->
            conn
            |> put_resp_header(
              "content-range",
              "bytes #{offset}-#{offset + length - 1}/#{size}"
            )
            |> send_file(206, path, offset, length)

          :error ->
            send_file(conn, 200, path)
        end

      {:error, _} ->
        send_resp(conn, 404, "not found")
    end
  end

  defp requested_range(conn, size) do
    with [value] <- get_req_header(conn, "range"),
         "bytes=" <> spec <- value,
         [first, last] <- String.split(spec, "-", parts: 2) do
      bounds(first, last, size)
    else
      _ -> :error
    end
  end

  defp bounds(first, last, size) do
    case {Integer.parse(first), Integer.parse(last)} do
      {{start, ""}, {stop, ""}} when start <= stop and stop < size ->
        {:ok, start, stop - start + 1}

      {{start, ""}, :error} when start < size ->
        {:ok, start, size - start}

      {:error, {length, ""}} when length > 0 ->
        length = min(length, size)
        {:ok, size - length, length}

      _ ->
        :error
    end
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
end
