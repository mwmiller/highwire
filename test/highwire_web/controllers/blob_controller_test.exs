defmodule HighWireWeb.BlobControllerTest do
  @moduledoc """
  The avatar/image serving layer: `/blob/<hex>` resolves through
  HighWire's cache, then the engine's own blob store, then a
  generated framed placeholder — and `/identicon/<hex>` serves the
  deterministic Excon identicon for feeds without an avatar image.
  Everything lives under the test home (`~/.highwire-test`), so these
  tests never touch the real stores.
  """
  use HighWireWeb.ConnCase, async: true

  alias HighWire.Blob

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "cached-bytes">>
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, "from-store">>

  setup do
    hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    cache = Path.join(Blob.cache_root(), hex)
    gen = Path.join([Blob.cache_root(), "gen", hex])
    store = Blob.store_path(hex)

    on_exit(fn ->
      File.rm(cache)
      File.rm(gen)
      if store, do: File.rm(store)
    end)

    %{hex: hex, cache: cache, gen: gen, store: store}
  end

  test "serves bytes already in HighWire's cache", %{conn: conn, hex: hex, cache: cache} do
    File.mkdir_p!(Path.dirname(cache))
    File.write!(cache, @png)

    conn = get(conn, "/blob/#{hex}")

    assert response(conn, 200) == @png
    assert media_type(conn) == "image/png"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=60"]
  end

  test "a hit in the engine's own store is served directly, without copying", %{
    conn: conn,
    hex: hex,
    cache: cache,
    store: store
  } do
    File.mkdir_p!(Path.dirname(store))
    File.write!(store, @jpeg)
    refute File.exists?(cache)

    conn = get(conn, "/blob/#{hex}")
    assert response(conn, 200) == @jpeg
    assert media_type(conn) == "image/jpeg"
    # the store is the source of truth — nothing is duplicated into the cache
    refute File.exists?(cache)

    # once the store stops holding it, the placeholder takes over
    File.rm!(store)
    conn = get(build_conn(), "/blob/#{hex}")
    assert media_type(conn) == "image/svg+xml"
  end

  test "a zero-byte store file falls through to the placeholder", %{
    conn: conn,
    hex: hex,
    cache: cache,
    store: store
  } do
    File.mkdir_p!(Path.dirname(store))
    File.write!(store, "")

    conn = get(conn, "/blob/#{hex}")

    assert media_type(conn) == "image/svg+xml"
    assert response(conn, 200) =~ "<svg"
    refute File.exists?(cache)
  end

  test "a missing blob generates a framed placeholder and caches it under gen", %{
    conn: conn,
    hex: hex,
    cache: cache,
    gen: gen
  } do
    conn = get(conn, "/blob/#{hex}")

    assert media_type(conn) == "image/svg+xml"
    body = response(conn, 200)
    assert body =~ "<svg"
    refute File.exists?(cache)
    assert File.regular?(gen)

    # the cached placeholder answers the next request identically
    conn = get(build_conn(), "/blob/#{hex}")
    assert response(conn, 200) == body
  end

  test "content type follows the file's magic bytes", %{conn: conn} do
    gif = <<0x47, 0x49, 0x46, 0x38, 0x37, 0x61, "rest">>
    gif_hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    gif_cache = Path.join(Blob.cache_root(), gif_hex)
    File.mkdir_p!(Path.dirname(gif_cache))
    File.write!(gif_cache, gif)
    on_exit(fn -> File.rm(gif_cache) end)

    conn = get(conn, "/blob/#{gif_hex}")
    assert media_type(conn) == "image/gif"
    assert response(conn, 200) == gif
  end

  test "keys that are not 64 hex characters never reach the stores", %{conn: conn} do
    for bad <- ["not-hex", String.duplicate("a", 63), String.duplicate("a", 65)] do
      conn = get(conn, "/blob/#{bad}")
      assert response(conn, 404) == "not found"
    end
  end

  test "identicon: deterministic framed svg, cached immutably", %{conn: conn} do
    id = "@" <> String.duplicate("A", 43) <> "=.ed25519"
    key = Base.encode16(id, case: :lower)
    path = Path.join([Blob.cache_root(), "ident", key])
    on_exit(fn -> File.rm(path) end)

    conn = get(conn, "/identicon/#{key}")

    assert response(conn, 200) =~ "<svg"
    assert media_type(conn) == "image/svg+xml"
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert File.regular?(path)

    # same key, same bytes — the response is safe to cache forever
    conn = get(build_conn(), "/identicon/#{key}")
    assert response(conn, 200) =~ "<svg"
  end

  test "identicon keys that are not even-length hex 404", %{conn: conn} do
    for bad <- ["zz", "abc", String.duplicate("f", 514)] do
      assert get(conn, "/identicon/#{bad}") |> response(404) == "not found"
    end
  end

  # The content-type header carries a charset; compare the media type.
  defp media_type(conn),
    do: conn |> Plug.Conn.get_resp_header("content-type") |> hd() |> String.split(";") |> hd()
end
