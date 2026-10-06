defmodule HighWireWeb.BlobController do
  @moduledoc """
  Serves blobs by hex key: `GET /blob/<64-hex>`.

  Resolution order (copy-on-read):

    1. `~/.highwire/images/<hex>` — HighWire's own cache
    2. `~/.ssb/blobs/sha256/<h[:2]>/<h[2:]>` — Patchwork's store,
       read-only: on a hit the bytes are copied into the cache and from
       then on served from there
    3. a generated Excon `:framed` identicon (keyed by the hex, cached
       under `images/gen/`) — a placeholder in the same framed format as
       feed avatars while the real bytes are being wanted over the wire.
       The short cache window lets the real blob take over as soon as it
       lands.

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

      File.regular?(source = Blob.source_path(hex)) and File.stat!(source).size > 0 ->
        case cache_copy(source, cache) do
          :ok -> {:file, cache}
          :error -> {:file, source}
        end

      File.regular?(gen) ->
        {:file, gen}

      true ->
        data = Excon.ident(cool_id(hex), type: :framed)
        _ = File.mkdir_p(Path.dirname(gen))
        _ = File.write(gen, data)
        {:generated, data}
    end
  end

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

  # Cache the bytes of a Patchwork-store hit under ~/.highwire; the
  # source store is only ever read. Any failure just serves the source.
  defp cache_copy(source, cache) do
    tmp = cache <> ".tmp-#{System.unique_integer([:positive])}"

    copied =
      File.mkdir_p(Path.dirname(cache)) == :ok and File.cp(source, tmp) == :ok and
        File.rename(tmp, cache) == :ok

    if copied do
      :ok
    else
      File.rm(tmp)
      :error
    end
  end

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
