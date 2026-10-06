defmodule HighWire.Avatar do
  @moduledoc """
  Patchwork/Poncho-style avatars: the `color-hash` v1.0.3 color of a feed id
  (BKDRHash → HSL buckets → hex), the id shortening Patchwork uses for
  display when a feed has no name, and the URL helpers that pick between a
  feed's blob image and the Excon framed identicon used when there is none.

  This is a faithful port of `color-hash`'s default pipeline so HighWire's
  avatar tiles are pixel-identical to Poncho Wonky's.
  """

  alias HighWire.Blob

  @max_safe_integer div(9_007_199_254_740_991, 137)
  @saturation [0.35, 0.5, 0.65]
  @lightness [0.35, 0.5, 0.65]

  @doc """
  The Patchwork avatar background color for `id`, as a `#rrggbb` hex string.

  Matches `new ColorHash().hex(id)` from color-hash v1.0.3.
  """
  @spec hex(binary()) :: binary()
  def hex(id) when is_binary(id) do
    hash = bkdr_hash(id)
    h = rem(hash, 359)
    hash = div(hash, 360)
    s = Enum.at(@saturation, rem(hash, 3))
    hash = div(hash, 3)
    l = Enum.at(@lightness, rem(hash, 3))

    {r, g, b} = hsl_to_rgb(h / 360, s, l)

    "#" <> Enum.map_join([r, g, b], "", &pad_hex/1)
  end

  @doc """
  Patchwork's `shortFeedId`: the first 9 characters of the id after `@`
  (`id.slice(1, 10)` in JavaScript).
  """
  @spec short_id(binary()) :: binary()
  def short_id("@" <> rest), do: String.slice(rest, 0, 9)
  def short_id(id) when is_binary(id), do: String.slice(id, 0, 9)

  @doc """
  The URL of the Excon `:framed` identicon for a feed id (hex-encoded id
  as the key — deterministic, so the response is immutable-cacheable).
  """
  @spec identicon_url(binary()) :: binary()
  def identicon_url(id) when is_binary(id) do
    "/identicon/" <> Base.encode16(id, case: :lower)
  end

  @doc """
  The image URL for an avatar tile: the feed's blob when it has a valid
  image reference, otherwise the framed identicon keyed by the feed id.
  """
  @spec avatar_src(binary(), binary() | nil) :: binary()
  def avatar_src(id, image), do: Blob.url(image) || identicon_url(id)

  @doc """
  Cache-busting query for image URLs: a positive `blob_rev` from the
  timeline payload becomes `?v=<n>` so the browser refetches a URL whose
  bytes have upgraded from generated placeholder to real blob.
  """
  @spec rev_query(integer() | nil) :: binary()
  def rev_query(rev) when is_integer(rev) and rev > 0, do: "?v=#{rev}"
  def rev_query(_rev), do: ""

  # BKDRHash (modified) from color-hash/lib/bkdr-hash.js, verbatim semantics:
  # append "x", then hash = hash * 131 + charCode, reducing via / 137 whenever
  # the accumulator exceeds MAX_SAFE_INTEGER. All intermediates stay below
  # 2^53 so IEEE-754 doubles agree with integer arithmetic, and JS
  # `parseInt(hash / 137)` equals integer division here (the true quotient is
  # an exact integer when divisible, otherwise both truncate toward zero).
  defp bkdr_hash(str) do
    (str <> "x")
    |> String.to_charlist()
    |> Enum.reduce(0, fn code, hash ->
      hash = if hash > @max_safe_integer, do: div(hash, 137), else: hash
      hash * 131 + code
    end)
  end

  # HSL2RGB from color-hash/lib/color-hash.js. `round_half_up/1` reproduces
  # JavaScript's Math.round (floor(x + 0.5)); Float.round/2 would not.
  defp hsl_to_rgb(h, s, l) do
    q = if l < 0.5, do: l * (1 + s), else: l + s - l * s
    p = 2 * l - q

    [h + 1 / 3, h, h - 1 / 3]
    |> Enum.map(fn color ->
      color = wrap(color)

      cond do
        color < 1 / 6 -> p + (q - p) * 6 * color
        color < 0.5 -> q
        color < 2 / 3 -> p + (q - p) * 6 * (2 / 3 - color)
        true -> p
      end
    end)
    |> then(fn [r, g, b] ->
      {round_half_up(r * 255), round_half_up(g * 255), round_half_up(b * 255)}
    end)
  end

  defp wrap(color) when color < 0, do: color + 1
  defp wrap(color) when color > 1, do: color - 1
  defp wrap(color), do: color

  defp round_half_up(x), do: floor(x + 0.5)

  defp pad_hex(v) do
    bin = v |> Integer.to_string(16) |> String.downcase()
    if v < 16, do: "0" <> bin, else: bin
  end
end
