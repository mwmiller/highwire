defmodule HighWire.Backgammon.Engine do
  @moduledoc """
  Position model and move rules for HighWire backgammon.

  ## Position model

  A position is **actor-relative**: points are numbered `1..24` from the
  acting player's perspective (`1` is their home/1-point, `24` their
  opponent's 1-point), and a point holds a **signed count** — positive =
  the actor's checkers, negative = the opponent's. The bar and bear-off
  counts are kept separately for each side (`bar`/`opp_bar`, `off`/`opp_off`).

  After a turn the position is `mirror/1`ed so the next mover reads an
  identical board from their own side (the standard backgammon convention,
  also how Magriel notation works).

  ## Rules

  * A die moves a checker from point `p` to `p - die` (down toward home);
    a landing point must be vacant, the actor's own point, or hold exactly
    one opponent checker (a hit sends that checker to the opponent's bar).
  * While any of the actor's checkers is on the bar, every die must re-enter
    at point `25 - die` and no other move is legal.
  * Bearing off is legal only when every actor checker is in the home board
    (points `1..6`) and the bar is clear. A die `d` may bear off a checker
    from the **highest** occupied point `p <= d` (standard precedence: you
    can't bear a lower checker while a higher one is reachable by the die).
  * `legal_plays/2` enumerates every **maximal** play for a roll; a play is
    maximal when no remaining die can be used.
  * `legal_play?/3` validates a specific move sequence against a position and
    roll (each move implies its own die by geometry) and insists the play is
    maximal — shared by the per-turn verifier and the interactive UI.
  """

  alias __MODULE__

  defstruct points: %{}, bar: 0, opp_bar: 0, off: 0, opp_off: 0

  @type t :: %__MODULE__{
          points: %{optional(1..24) => integer()},
          bar: non_neg_integer(),
          opp_bar: non_neg_integer(),
          off: non_neg_integer(),
          opp_off: non_neg_integer()
        }

  @type move :: {:bar, 1..24} | {1..24, :off} | {1..24, 1..24}

  @doc """
  The starting position, actor-relative:

      self  2@24, 5@13, 3@8, 5@6
      opp   2@1, 5@12, 3@17, 5@19

  The board is symmetric, so `mirror(initial()) == initial()`. Each side's
  opening pip count is the canonical 167.
  """
  @spec initial() :: Engine.t()
  def initial do
    %Engine{
      points: %{24 => 2, 13 => 5, 8 => 3, 6 => 5, 1 => -2, 12 => -5, 17 => -3, 19 => -5},
      bar: 0,
      opp_bar: 0,
      off: 0,
      opp_off: 0
    }
  end

  @doc """
  The actor-relative flip: re-read the same board from the opponent's side
  after the actor's turn. Point `p` becomes `25 - p`, signs flip, and the bar
  and bear-off counts swap sides.

  ## Examples

      iex> b = HighWire.Backgammon.Engine.initial()
      iex> b == HighWire.Backgammon.Engine.mirror(b)
      true

      iex> b = %HighWire.Backgammon.Engine{points: %{4 => 2, 20 => -1}, bar: 1, off: 2}
      iex> mirror = HighWire.Backgammon.Engine.mirror(b)
      iex> mirror.points
      %{5 => 1, 21 => -2}
      iex> mirror.bar
      0
      iex> mirror.off
      0
      iex> mirror.opp_bar
      1
      iex> mirror.opp_off
      2

  """
  @spec mirror(t()) :: t()
  def mirror(%Engine{} = board) do
    %Engine{
      points: Map.new(board.points, fn {p, n} -> {25 - p, -n} end),
      bar: board.opp_bar,
      opp_bar: board.bar,
      off: board.opp_off,
      opp_off: board.off
    }
  end

  @doc """
  The die list for a roll. Doubles expand to four identical dice.

  ## Examples

      iex> HighWire.Backgammon.Engine.roll_dies({3, 5})
      [3, 5]

      iex> HighWire.Backgammon.Engine.roll_dies({4, 4})
      [4, 4, 4, 4]

  """
  def roll_dies({a, a}) when a in 1..6, do: [a, a, a, a]
  def roll_dies({a, b}) when a in 1..6 and b in 1..6, do: [a, b]

  @doc """
  The signed count on a point: positive = actor's checkers, negative = the
  opponent's.

  ## Examples

      iex> HighWire.Backgammon.Engine.count(HighWire.Backgammon.Engine.initial(), 1)
      -2
      iex> HighWire.Backgammon.Engine.count(HighWire.Backgammon.Engine.initial(), 13)
      5
      iex> HighWire.Backgammon.Engine.count(HighWire.Backgammon.Engine.initial(), 6)
      5

  """
  @spec count(t(), 1..24) :: integer()
  def count(%Engine{} = board, p) when p in 1..24, do: Map.get(board.points, p, 0)

  @doc """
  The total number of the actor's checkers still on the board or bar
  (15 minus any already borne off).
  """
  @spec checkers(t()) :: non_neg_integer()
  def checkers(%Engine{} = board) do
    board.bar +
      Enum.reduce(board.points, 0, fn {_p, n}, acc -> acc + max(n, 0) end)
  end

  @doc """
  The game stake multiplier based on the opponent's position after a win.

  - 1 (single): opponent has borne off at least one checker
  - 2 (gammon): opponent has borne off no checkers
  - 3 (backgammon): opponent has borne off no checkers and has checkers
    on the bar or in the winner's home board (points 1..6)

  Called with the position from the winner's perspective (after their final
  turn, before mirroring).
  """
  @spec stake(t()) :: pos_integer()
  def stake(%Engine{opp_off: opp_off}) when opp_off > 0, do: 1

  def stake(%Engine{opp_bar: opp_bar}) when opp_bar > 0, do: 3

  def stake(%Engine{} = board) do
    if Enum.any?(1..6, fn p -> Map.get(board.points, p, 0) < 0 end),
      do: 3,
      else: 2
  end

  @doc """
  Whether the actor can bear off: every actor checker is in the home board
  (points `1..6`) and the bar is clear.
  """
  @spec bearable?(t()) :: boolean()
  def bearable?(%Engine{} = board) do
    board.bar == 0 and
      board.points |> Enum.all?(fn {p, n} -> n < 0 or p <= 6 end)
  end

  @doc """
  Apply a single move to a position: `{:bar, to}` re-enters a bar checker,
  `{from, :off}` bears one off, otherwise a plain `{from, to}` move. Landing
  on a singleton opponent checker hits it to the opponent's bar.

  The caller is responsible for the move being legal (see `moves_for/2`).
  """
  @spec apply_move(t(), move()) :: t()
  def apply_move(%Engine{} = board, {:bar, to}) when to in 1..24 do
    board |> Map.put(:bar, board.bar - 1) |> land(to)
  end

  def apply_move(%Engine{} = board, {from, :off}) when from in 1..24 do
    %Engine{board | points: bump(board.points, from, -1), off: board.off + 1}
  end

  def apply_move(%Engine{} = board, {from, to}) when from in 1..24 and to in 1..24 do
    board |> Map.put(:points, bump(board.points, from, -1)) |> land(to)
  end

  defp land(board, to) do
    case count(board, to) do
      # A singleton opponent checker is hit to the opponent's bar; the
      # landing checker then owns the point on its own.
      -1 -> %Engine{board | points: Map.put(board.points, to, 1), opp_bar: board.opp_bar + 1}
      _ -> %Engine{board | points: bump(board.points, to, 1)}
    end
  end

  @doc """
  Every single-die legal move available on a position.

  When the actor has checkers on the bar, the only moves are re-entries at
  `25 - die`; otherwise the regular moves (a checker on a point `p > die`
  stepped to `p - die`) plus — when bearing off is legal — the bear from the
  highest occupied point `<= die`.
  """
  @spec moves_for(t(), 1..6) :: [move()]
  def moves_for(%Engine{bar: bar} = board, die) when die in 1..6 do
    if bar > 0 do
      entry_moves(board, die)
    else
      regular_moves(board, die) ++ bear_moves(board, die)
    end
  end

  defp entry_moves(board, die) do
    to = 25 - die
    if landable?(board, to), do: [{:bar, to}], else: []
  end

  defp regular_moves(board, die) do
    for from <- self_points(board),
        from > die,
        to = from - die,
        landable?(board, to),
        do: {from, to}
  end

  defp bear_moves(board, die) do
    if bearable?(board) do
      highest = self_points(board) |> Enum.filter(&(&1 <= die)) |> Enum.max(fn -> nil end)
      if highest, do: [{highest, :off}], else: []
    else
      []
    end
  end

  @doc """
  Every **maximal** play for a roll: all move sequences that consume the dice
  as far as possible (never leaving a die playable). Doubles expand to four
  dice. Each play is returned as a list of `{from, to}` moves with the moves
  ordered for Magriel rendering (`HighWire.Backgammon.Notation.turn/1`).
  Duplicate plays (same moves in different generation order) are removed.

  ## Examples

      iex> b = %HighWire.Backgammon.Engine{points: %{6 => 2, 3 => 1}}
      iex> HighWire.Backgammon.Engine.legal_plays(b, {2, 5})
      [[{3, 1}, {1, :off}], [{6, 1}, {1, :off}], [{6, 1}, {3, 1}], [{6, 1}, {6, 4}], [{6, 4}, {3, :off}], [{6, 4}, {4, :off}]]

  """
  def legal_plays(board, roll) do
    board
    |> search(roll_dies(roll), [])
    |> Enum.map(&canonicalize/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Canonical move order: bar exits first, then highest source point first
  (tie-broken by destination), bear-offs last. This ensures each logical
  play has exactly one representation so Enum.uniq/1 deduplicates correctly.
  """
  @spec canonicalize([move()]) :: [move()]
  def canonicalize(moves) do
    Enum.sort_by(moves, fn
      {:bar, to} -> {0, 0, -to}
      {from, :off} -> {2, from, 0}
      {from, to} -> {1, -from, to}
    end)
  end

  defp search(board, dice, acc) do
    case next_branches(board, dice) do
      [] ->
        [acc]

      branches ->
        Enum.flat_map(branches, fn {die, move} ->
          search(apply_move(board, move), remove_one(dice, die), acc ++ [move])
        end)
    end
  end

  defp next_branches(board, dice) do
    for die <- dice |> Enum.uniq(),
        move <- moves_for(board, die) do
      {die, move}
    end
  end

  @doc """
  Whether a specific move sequence is a legal, **maximal** play for the roll
  on the position. Each move is matched against any available die that makes
  it legal (bear-offs can use any die >= the point number when it's the
  highest occupied point); at the end no remaining die may still be usable
  — this is what makes a stand (an empty move list) legal only when nothing
  can move.

  ## Examples

      iex> b = %HighWire.Backgammon.Engine{points: %{6 => 2, 3 => 1}}
      iex> HighWire.Backgammon.Engine.legal_play?(b, {2, 5}, [{6, 4}, {6, 1}])
      true
      iex> HighWire.Backgammon.Engine.legal_play?(b, {2, 5}, [{6, 4}])
      false
      iex> HighWire.Backgammon.Engine.legal_play?(b, {2, 5}, [])
      false

  """
  @spec legal_play?(t(), {1..6, 1..6}, [move()]) :: boolean()
  def legal_play?(%Engine{} = position, roll, moves) do
    case consume(position, roll_dies(roll), moves) do
      {:ok, final, remaining} ->
        next_branches(final, remaining) == []

      :error ->
        false
    end
  end

  defp consume(board, dice, []) do
    {:ok, board, dice}
  end

  defp consume(board, dice, [move | rest]) do
    dice
    |> Enum.filter(fn die -> move_possible?(board, die, move) end)
    |> Enum.reduce_while(:error, fn die, _acc ->
      case consume(apply_move(board, move), remove_one(dice, die), rest) do
        {:ok, _, _} = result -> {:halt, result}
        :error -> {:cont, :error}
      end
    end)
  end

  # Geometric validity check for a single move against a single die value.
  # Unlike `moves_for/2` this is order-independent: it does NOT enforce the
  # "bear from the highest occupied point" restriction, because the search
  # that produces `legal_plays/2` already builds that ordering into every
  # play it returns.  This function only needs to confirm that the move
  # consumes exactly one die and is physically possible on the board.
  defp move_possible?(%Engine{} = board, die, {:bar, to}) when is_integer(to) do
    board.bar > 0 and 25 - to == die and landable?(board, to)
  end

  defp move_possible?(%Engine{} = board, die, {from, :off}) when is_integer(from) do
    board.bar == 0 and bearable?(board) and from <= die and count(board, from) > 0
  end

  defp move_possible?(%Engine{} = board, die, {from, to})
       when is_integer(from) and is_integer(to) do
    board.bar == 0 and from > die and from - to == die and count(board, from) > 0 and
      landable?(board, to)
  end

  defp move_possible?(_board, _die, _move), do: false

  defp landable?(board, to), do: to in 1..24 and count(board, to) >= -1

  defp self_points(board), do: for({p, n} <- board.points, n > 0, do: p)

  @doc """
  Pip count for a side: the total distance the side's checkers still have to
  travel to bear off. The actor travels point-number pips from point `p`
  (their moves run `24 -> 1`); the opponent travels `25 - p` from point `p`
  (their moves run the other way). Every checker on the bar costs 25 pips,
  and borne-off checkers cost nothing.

  ## Examples

      iex> b = HighWire.Backgammon.Engine.initial()
      iex> HighWire.Backgammon.Engine.pips(b, :actor)
      167
      iex> HighWire.Backgammon.Engine.pips(b, :opponent)
      167

      iex> HighWire.Backgammon.Engine.pips(%HighWire.Backgammon.Engine{}, :actor)
      0
  """
  @spec pips(Engine.t(), :actor | :opponent) :: non_neg_integer()
  def pips(%Engine{} = position, :actor) do
    Enum.reduce(position.points, position.bar * 25, fn
      {p, n}, acc when n > 0 -> acc + p * n
      _, acc -> acc
    end)
  end

  def pips(%Engine{} = position, :opponent) do
    Enum.reduce(position.points, position.opp_bar * 25, fn
      {p, n}, acc when n < 0 -> acc + (25 - p) * -n
      _, acc -> acc
    end)
  end

  @doc """
  Apply a full play (a list of moves, as returned by `legal_plays/2`) to a
  position and return the resulting position. The caller is responsible for
  the play being legal; folding turns to re-run the game just reduces the
  moves over `apply_move/2`. The result is still in the acting player's
  frame — mirror it to prepare the board for the next mover.

  ## Examples

      iex> b = %HighWire.Backgammon.Engine{points: %{6 => 2, 3 => 1}}
      iex> HighWire.Backgammon.Engine.apply(b, [{3, 1}, {6, 1}])
      %HighWire.Backgammon.Engine{points: %{6 => 1, 1 => 2}}

  """
  @spec apply(t(), [move()]) :: t()
  def apply(%Engine{} = board, moves) when is_list(moves) do
    Enum.reduce(moves, board, fn mv, b -> apply_move(b, mv) end)
  end

  defp remove_one(list, value) do
    {matching, rest} = Enum.split_with(list, &(&1 == value))

    case matching do
      [] -> rest
      [_ | more] -> more ++ rest
    end
  end

  defp bump(points, p, by) do
    nxt = Map.get(points, p, 0) + by

    if nxt == 0 do
      Map.delete(points, p)
    else
      Map.put(points, p, nxt)
    end
  end
end
