defmodule HighWire.Backgammon.Notation do
  @moduledoc """
  Standard Magriel notation for backgammon messages.

  Points are numbered 1..24 from the **acting player's** perspective: point 1
  is the point nearest to where you bear off (your home board), point 24 is
  your opponent's 1-point, the farthest point from your home. `:bar` is the
  bar, `:off` is bear-off (a checker removed from the board).

  A single move is written `from/to` using these numbers, e.g. `13/8`,
  `bar/20`, `6/off`. A turn with multiple moves is written space-separated,
  e.g. `13/8 13/8`.

  Because points are relative to the actor, the same table reads identically
  to both players from their own side — the standard backgammon convention.
  """

  @typedoc "A position on the board: an integer point 1..24, :bar, or :off"
  @type pos :: 1..24 | :bar | :off

  @doc """
  Render a single move in Magriel notation: `from/to`.

  ## Examples

      iex> HighWire.Backgammon.Notation.move(13, 8)
      "13/8"

      iex> HighWire.Backgammon.Notation.move(:bar, 20)
      "bar/20"

      iex> HighWire.Backgammon.Notation.move(6, :off)
      "6/off"

      iex> HighWire.Backgammon.Notation.move(:bar, :off)
      "bar/off"

  """
  @spec move(pos, pos) :: String.t()
  def move(from, to) when from in 1..24 and to in 1..24 do
    "#{from}/#{to}"
  end

  def move(:bar, to) when to in 1..24, do: "bar/#{to}"
  def move(:bar, :off), do: "bar/off"
  def move(from, :off) when from in 1..24, do: "#{from}/off"
  def move(:bar, to), do: "bar/#{to}"
  def move(from, to), do: "#{from}/#{to}"

  @doc """
  Render a full turn (zero or more moves) in Magriel notation.

  Moves may be given as `{from, to}` tuples or as already-rendered strings.

  ## Examples

      iex> HighWire.Backgammon.Notation.turn([{13, 8}, {13, 8}])
      "13/8 13/8"

      iex> HighWire.Backgammon.Notation.turn([{6, :off}])
      "6/off"

      iex> HighWire.Backgammon.Notation.turn([])
      ""

  """
  @spec turn([{pos, pos} | String.t()]) :: String.t()
  def turn(moves) when is_list(moves) do
    Enum.map_join(moves, " ", fn
      {from, to} -> move(from, to)
      str when is_binary(str) -> str
    end)
  end

  @doc """
  Parse a Magriel turn back into `{from, to}` moves, the inverse of
  `turn/1` for folding and verification. `:bar` and `:off` come back as the
  atoms; point pairs as integers.

  ## Examples

      iex> HighWire.Backgammon.Notation.parse("13/8 13/8")
      [{13, 8}, {13, 8}]

      iex> HighWire.Backgammon.Notation.parse("bar/20 6/off")
      [{:bar, 20}, {6, :off}]

      iex> HighWire.Backgammon.Notation.parse("")
      []

  """
  @spec parse(String.t()) :: [{pos, pos}]
  def parse(""), do: []

  def parse(string) when is_binary(string) do
    string
    |> String.split(" ", trim: true)
    |> Enum.map(fn token ->
      case token |> String.split("/", parts: 2) do
        ["bar", to] -> {:bar, num(to)}
        [from, "off"] -> {num(from), :off}
        [from, to] -> {num(from), num(to)}
      end
    end)
  end

  defp num(string) when string in ["bar", "off"], do: String.to_atom(string)

  defp num(string) do
    case Integer.parse(string) do
      {n, ""} when n in 1..24 -> n
      _ -> raise ArgumentError, "invalid point: #{inspect(string)}"
    end
  end

  @doc """
  The human-readable name of a point from the acting player's perspective.

  Returns `"bar"` or `"off"` for the special positions, otherwise
  `"24-point"`-style wording.

  ## Examples

      iex> HighWire.Backgammon.Notation.point_name(13)
      "13-point"

      iex> HighWire.Backgammon.Notation.point_name(:bar)
      "bar"

  """
  @spec point_name(pos) :: String.t()
  def point_name(:bar), do: "bar"
  def point_name(:off), do: "off the board"
  def point_name(n) when n in 1..24, do: "#{n}-point"
end
