defmodule HighWire.Chess.Engine do
  @moduledoc """
  The rules of chess, and nothing else.

  A position is a plain map — the occupied squares, whose turn it is, the
  castling rights still standing, an en-passant target, the halfmove clock
  and the positions already seen — so a fold can hold one, compare two, and
  keep one on disk without a struct version to migrate.

  Moves are coordinate strings (`"e2e4"`, `"e7e8q"`): unambiguous to write,
  trivial to check, and the same for every reader. `san/2` renders a move the
  way a player writes it, for the pages.

  Everything a fold needs to distrust a message lives here: a move that
  cannot be generated from the position is refused, so a game whose author
  invents a knight's hop is a game the fold stops on rather than one that
  quietly disagrees with every other node.
  """

  @type color :: :white | :black
  @type piece_type :: :pawn | :knight | :bishop | :rook | :queen | :king
  @type square :: binary()
  @type piece :: {piece_type(), color()}

  @type t :: %{
          board: %{optional(square()) => piece()},
          turn: color(),
          castling: MapSet.t(atom()),
          ep: square() | nil,
          halfmove: non_neg_integer(),
          fullmove: pos_integer(),
          seen: %{optional(binary()) => pos_integer()}
        }

  @type move :: %{
          from: square(),
          to: square(),
          promo: piece_type() | nil,
          castle: :king | :queen | nil
        }

  @files ~w(a b c d e f g h)

  @doc "The position a game opens from."
  @spec initial() :: t()
  def initial do
    board =
      Map.new([
        {"a1", {:rook, :white}},
        {"b1", {:knight, :white}},
        {"c1", {:bishop, :white}},
        {"d1", {:queen, :white}},
        {"e1", {:king, :white}},
        {"f1", {:bishop, :white}},
        {"g1", {:knight, :white}},
        {"h1", {:rook, :white}},
        {"a2", {:pawn, :white}},
        {"b2", {:pawn, :white}},
        {"c2", {:pawn, :white}},
        {"d2", {:pawn, :white}},
        {"e2", {:pawn, :white}},
        {"f2", {:pawn, :white}},
        {"g2", {:pawn, :white}},
        {"h2", {:pawn, :white}},
        {"a7", {:pawn, :black}},
        {"b7", {:pawn, :black}},
        {"c7", {:pawn, :black}},
        {"d7", {:pawn, :black}},
        {"e7", {:pawn, :black}},
        {"f7", {:pawn, :black}},
        {"g7", {:pawn, :black}},
        {"h7", {:pawn, :black}},
        {"a8", {:rook, :black}},
        {"b8", {:knight, :black}},
        {"c8", {:bishop, :black}},
        {"d8", {:queen, :black}},
        {"e8", {:king, :black}},
        {"f8", {:bishop, :black}},
        {"g8", {:knight, :black}},
        {"h8", {:rook, :black}}
      ])

    pos = %{
      board: board,
      turn: :white,
      castling: MapSet.new([:wk, :wq, :bk, :bq]),
      ep: nil,
      halfmove: 0,
      fullmove: 1
    }

    Map.put(pos, :seen, %{key(pos) => 1})
  end

  @doc "Whether a square name is on the board."
  @spec square?(term()) :: boolean()
  def square?(<<f, r>>) when f in ?a..?h and r in ?1..?8, do: true
  def square?(_), do: false

  @doc "The square one file and one rank on, or nil when off the board."
  @spec shift(square(), integer(), integer()) :: square() | nil
  def shift(square, df, dr) do
    {f, r} = coords(square)
    shift_sq(f + df, r + dr)
  end

  @doc "The piece on a square, or nil."
  @spec at(t(), square()) :: piece() | nil
  def at(pos, square), do: Map.get(pos.board, square)

  @doc "The colour whose king stands on `square`, if any."
  @spec king_square(t(), color()) :: square() | nil
  def king_square(pos, color) do
    Enum.find_value(pos.board, fn {square, piece} ->
      if piece == {:king, color}, do: square
    end)
  end

  @doc """
  Whether `color`'s king is attacked. A position missing that king is not in
  check: a fold that has lost one has already stopped for another reason,
  and this must never be the function that raises.
  """
  @spec in_check?(t(), color()) :: boolean()
  def in_check?(pos, color) do
    case king_square(pos, color) do
      nil -> false
      square -> attacked?(pos.board, square, other(color))
    end
  end

  @doc "Check against the side to move."
  @spec in_check?(t()) :: boolean()
  def in_check?(pos), do: in_check?(pos, pos.turn)

  @doc "Whether any piece of `by` attacks `square`."
  @spec attacked?(map(), square(), color()) :: boolean()
  def attacked?(board, square, by) do
    Enum.any?(board, fn {from, {type, color}} ->
      color == by and attacks?(board, from, square, type)
    end)
  end

  # An attacker's reach, measured from the attacker. Cheaper than generating
  # its moves and needing no legality pass of its own.
  defp attacks?(_board, from, to, :pawn) do
    {df, dr} = delta(from, to)
    abs(df) == 1 and abs(dr) == 1
  end

  defp attacks?(_board, from, to, :knight) do
    {df, dr} = delta(from, to)
    {abs(df), abs(dr)} in [{1, 2}, {2, 1}]
  end

  defp attacks?(_board, from, to, :king) do
    {df, dr} = delta(from, to)
    max(abs(df), abs(dr)) == 1
  end

  defp attacks?(board, from, to, type) when type in [:bishop, :rook, :queen] do
    {df, dr} = delta(from, to)
    straight? = df == 0 or dr == 0
    diagonal? = abs(df) == abs(dr)

    shape? =
      (type == :bishop and diagonal?) or
        (type == :rook and straight?) or
        (type == :queen and (straight? or diagonal?))

    shape? and clear_path?(board, from, to)
  end

  defp delta(from, to) do
    {ff, fr} = coords(from)
    {tf, tr} = coords(to)
    {tf - ff, tr - fr}
  end

  defp clear_path?(board, from, to) do
    {df, dr} = delta(from, to)
    step = {sign(df), sign(dr)}
    empty_between?(board, from, to, step)
  end

  defp empty_between?(board, from, to) do
    {df, dr} = delta(from, to)
    empty_between?(board, from, to, {sign(df), sign(dr)})
  end

  defp empty_between?(board, from, to, {df, dr}) do
    {f, r} = coords(from)

    case shift_sq(f + df, r + dr) do
      nil ->
        true

      ^to ->
        true

      next ->
        if Map.has_key?(board, next), do: false, else: empty_between?(board, next, to, {df, dr})
    end
  end

  defp shift_sq(f, r) when f in 0..7 and r in 0..7 do
    Enum.at(@files, f) <> Integer.to_string(r + 1)
  end

  defp shift_sq(_f, _r), do: nil

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  defp pawn_step(:white), do: 1
  defp pawn_step(:black), do: -1

  @doc "Every legal move in `pos`, as coordinate strings."
  @spec legal_moves(t()) :: [binary()]
  def legal_moves(pos), do: pos |> legal() |> Enum.map(&uci/1)

  @doc """
  Apply a coordinate move. Anything the position does not allow is refused
  with the reason, so a caller can say why rather than only that.
  """
  @spec move(t(), binary()) :: {:ok, t()} | {:error, atom()}
  def move(pos, uci) when is_binary(uci) do
    case Enum.find(legal(pos), &(uci(&1) == uci)) do
      nil -> {:error, :illegal}
      mv -> {:ok, apply_move(pos, mv)}
    end
  end

  def move(_pos, _uci), do: {:error, :malformed}

  @doc "The coordinate string for a move."
  @spec uci(move()) :: binary()
  def uci(%{from: from, to: to, promo: nil}), do: from <> to
  def uci(%{from: from, to: to, promo: promo}), do: from <> to <> letter(promo)

  @doc "The legal moves, as move maps."
  @spec legal(t()) :: [move()]
  def legal(pos) do
    color = pos.turn

    pos
    |> pseudo_legal(color)
    |> Enum.filter(fn mv ->
      next = apply_move(pos, mv)
      not in_check?(next, color)
    end)
  end

  # Shape and occupancy only. Castling is resolved here because its "nothing
  # in between" is a different question from a slider's ray, and the squares
  # it must not cross need the check test either way.
  defp pseudo_legal(pos, color) do
    board = pos.board

    Enum.flat_map(board, fn
      {square, {type, ^color}} -> moves_from(board, square, type, color, pos.ep)
      _ -> []
    end) ++ castling(pos, color)
  end

  defp moves_from(board, square, :pawn, color, ep) do
    {f, r} = coords(square)
    step = pawn_step(color)
    last = if color == :white, do: 7, else: 0
    start = if color == :white, do: 1, else: 6

    push =
      case shift_sq(f, r + step) do
        nil -> []
        ahead -> if Map.has_key?(board, ahead), do: [], else: [ahead]
      end

    double =
      if r == start and push != [] do
        case shift_sq(f, r + 2 * step) do
          nil -> []
          two -> if Map.has_key?(board, two), do: [], else: [two]
        end
      else
        []
      end

    captures =
      for df <- [-1, 1],
          to = shift_sq(f + df, r + step),
          to != nil,
          capturable?(board, to, color, ep),
          do: to

    targets = push ++ double ++ captures
    promoting = Enum.filter(targets, fn to -> elem(coords(to), 1) == last end)

    for to <- targets, promo <- promos(to, promoting) do
      %{from: square, to: to, promo: promo, castle: nil}
    end
  end

  defp moves_from(board, square, :knight, color, _ep) do
    hop(board, square, color, [
      {1, 2},
      {2, 1},
      {2, -1},
      {1, -2},
      {-1, -2},
      {-2, -1},
      {-2, 1},
      {-1, 2}
    ])
  end

  defp moves_from(board, square, :bishop, color, _ep) do
    ray(board, square, color, [{1, 1}, {1, -1}, {-1, 1}, {-1, -1}])
  end

  defp moves_from(board, square, :rook, color, _ep) do
    ray(board, square, color, [{1, 0}, {-1, 0}, {0, 1}, {0, -1}])
  end

  defp moves_from(board, square, :queen, color, _ep) do
    ray(board, square, color, [
      {1, 1},
      {1, -1},
      {-1, 1},
      {-1, -1},
      {1, 0},
      {-1, 0},
      {0, 1},
      {0, -1}
    ])
  end

  defp moves_from(board, square, :king, color, _ep) do
    hop(board, square, color, [
      {1, 0},
      {-1, 0},
      {0, 1},
      {0, -1},
      {1, 1},
      {1, -1},
      {-1, 1},
      {-1, -1}
    ])
  end

  defp promos(to, promoting) do
    if to in promoting, do: [:queen, :rook, :bishop, :knight], else: [nil]
  end

  defp capturable?(board, to, color, ep) do
    case Map.get(board, to) do
      {_type, ^color} -> false
      {_type, _other} -> true
      nil -> ep != nil and to == ep
    end
  end

  defp hop(board, square, color, offsets) do
    for {df, dr} <- offsets,
        to = shift(square, df, dr),
        to != nil,
        not own?(board, to, color),
        do: %{from: square, to: to, promo: nil, castle: nil}
  end

  defp ray(board, square, color, directions) do
    Enum.flat_map(directions, fn {df, dr} -> slide(board, square, square, color, df, dr) end)
  end

  # `from` stays the piece's square all the way down the ray; `square` is
  # only where the walk stands, which is empty by the time it moves on.
  defp slide(board, from, square, color, df, dr) do
    case shift(square, df, dr) do
      nil ->
        []

      to ->
        case Map.get(board, to) do
          nil ->
            [
              %{from: from, to: to, promo: nil, castle: nil}
              | slide(board, from, to, color, df, dr)
            ]

          {_type, ^color} ->
            []

          _ ->
            [%{from: from, to: to, promo: nil, castle: nil}]
        end
    end
  end

  defp own?(board, square, color) do
    case Map.get(board, square) do
      {_type, ^color} -> true
      _ -> false
    end
  end

  # Castling: rights still standing, the squares between empty, and the king
  # neither in check, crossing an attacked square, nor landing on one.
  defp castling(pos, color) do
    {home, rook_k, rook_q, right_k, right_q} =
      case color do
        :white -> {"e1", "h1", "a1", :wk, :wq}
        :black -> {"e8", "h8", "a8", :bk, :bq}
      end

    cond do
      Map.get(pos.board, home) != {:king, color} ->
        []

      in_check?(pos, color) ->
        []

      true ->
        king_side =
          if MapSet.member?(pos.castling, right_k) and
               empty_between?(pos.board, home, rook_k) and
               not attacked?(pos.board, shift(home, 1, 0), other(color)) and
               not attacked?(pos.board, shift(home, 2, 0), other(color)) do
            [%{from: home, to: shift(home, 2, 0), promo: nil, castle: :king}]
          else
            []
          end

        queen_side =
          if MapSet.member?(pos.castling, right_q) and
               empty_between?(pos.board, home, rook_q) and
               not attacked?(pos.board, shift(home, -1, 0), other(color)) and
               not attacked?(pos.board, shift(home, -2, 0), other(color)) do
            [%{from: home, to: shift(home, -2, 0), promo: nil, castle: :queen}]
          else
            []
          end

        king_side ++ queen_side
    end
  end

  @doc """
  Apply a move without asking whether it is legal. Callers pass moves
  `legal/1` produced.
  """
  @spec apply_move(t(), move()) :: t()
  def apply_move(pos, %{castle: :king} = mv) do
    castle(pos, mv, if(pos.turn == :white, do: {"h1", "f1"}, else: {"h8", "f8"}))
  end

  def apply_move(pos, %{castle: :queen} = mv) do
    castle(pos, mv, if(pos.turn == :white, do: {"a1", "d1"}, else: {"a8", "d8"}))
  end

  def apply_move(pos, mv) do
    color = pos.turn
    piece = Map.fetch!(pos.board, mv.from)

    captured_square = if en_passant_capture?(pos, mv), do: ep_victim(mv, piece), else: mv.to
    captured = Map.get(pos.board, captured_square)

    board =
      pos.board
      |> Map.delete(mv.from)
      |> Map.delete(captured_square)
      |> Map.put(mv.to, promoted(piece, mv))

    pos
    |> Map.put(:board, board)
    |> Map.put(:castling, drop_rights(pos.castling, [mv.from, mv.to, captured_square]))
    |> Map.put(:ep, en_passant_target(pos, mv, piece))
    |> Map.put(:halfmove, halfmove(pos.halfmove, piece, captured))
    |> Map.put(:turn, other(color))
    |> Map.update!(:fullmove, fn n -> if color == :black, do: n + 1, else: n end)
    |> count()
  end

  defp castle(pos, mv, {rook_from, rook_to}) do
    king = Map.fetch!(pos.board, mv.from)
    rook = Map.fetch!(pos.board, rook_from)

    board =
      pos.board
      |> Map.delete(mv.from)
      |> Map.delete(rook_from)
      |> Map.put(mv.to, king)
      |> Map.put(rook_to, rook)

    rights = if pos.turn == :white, do: [:wk, :wq], else: [:bk, :bq]

    pos
    |> Map.put(:board, board)
    |> Map.put(:castling, Enum.reduce(rights, pos.castling, &MapSet.delete(&2, &1)))
    |> Map.put(:ep, nil)
    |> Map.put(:halfmove, pos.halfmove + 1)
    |> Map.put(:turn, other(pos.turn))
    |> Map.update!(:fullmove, fn n -> if pos.turn == :black, do: n + 1, else: n end)
    |> count()
  end

  defp count(pos) do
    k = key(pos)
    seen = Map.get(pos, :seen, %{})
    Map.put(pos, :seen, Map.update(seen, k, 1, fn n -> n + 1 end))
  end

  defp promoted({:pawn, color}, %{promo: nil}), do: {:pawn, color}
  defp promoted({:pawn, color}, %{promo: type}), do: {type, color}
  defp promoted(piece, _mv), do: piece

  defp en_passant_capture?(pos, mv) do
    case Map.fetch!(pos.board, mv.from) do
      {:pawn, _color} -> pos.ep != nil and mv.to == pos.ep and Map.get(pos.board, mv.to) == nil
      _ -> false
    end
  end

  # The pawn taken in passing stands on the square the mover passed over:
  # same file as the target, one rank back toward the mover.
  defp ep_victim(mv, {:pawn, color}) do
    {f, r} = coords(mv.to)
    shift_sq(f, r - pawn_step(color))
  end

  defp en_passant_target(_pos, %{from: from, to: to}, {:pawn, _color}) do
    {_ff, fr} = coords(from)
    {tf, tr} = coords(to)

    if abs(tr - fr) == 2, do: shift_sq(tf, div(fr + tr, 2)), else: nil
  end

  defp en_passant_target(_pos, _mv, _piece), do: nil

  defp halfmove(_clock, {:pawn, _color}, _captured), do: 0
  defp halfmove(_clock, _piece, captured) when captured != nil, do: 0
  defp halfmove(clock, _piece, _captured), do: clock + 1

  defp drop_rights(rights, squares) do
    squares
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&rights_for/1)
    |> Enum.reduce(rights, &MapSet.delete(&2, &1))
  end

  defp rights_for("e1"), do: [:wk, :wq]
  defp rights_for("a1"), do: [:wq]
  defp rights_for("h1"), do: [:wk]
  defp rights_for("e8"), do: [:bk, :bq]
  defp rights_for("a8"), do: [:bq]
  defp rights_for("h8"), do: [:bk]
  defp rights_for(_), do: []

  @doc "A stable key for the repetition history: pieces, side to move, rights, en passant."
  @spec key(t()) :: binary()
  def key(pos) do
    board =
      pos.board
      |> Enum.sort()
      |> Enum.map_join("", fn {square, {type, color}} ->
        square <> letter(type) <> Atom.to_string(color)
      end)

    rights = pos.castling |> Enum.sort() |> Enum.map_join("-", &Atom.to_string/1)
    "#{board}|#{pos.turn}|#{rights}|#{pos.ep}"
  end

  @doc """
  What the position says about the game: `:playing`, `{:checkmate, winner}`,
  `:stalemate`, or `{:draw, reason}` for the ways it ends without one.
  """
  @spec status(t()) :: :playing | {:checkmate, color()} | :stalemate | {:draw, atom()}
  def status(pos) do
    cond do
      legal(pos) == [] and in_check?(pos) -> {:checkmate, other(pos.turn)}
      legal(pos) == [] -> :stalemate
      pos.halfmove >= 100 -> {:draw, :fifty_moves}
      insufficient?(pos) -> {:draw, :insufficient_material}
      Map.get(pos.seen, key(pos), 0) >= 3 -> {:draw, :repetition}
      true -> :playing
    end
  end

  # Bare kings, or one minor piece against a bare king. Anything more can
  # still be forced, and the fold is not a tablebase.
  defp insufficient?(pos) do
    case for {_square, {type, _color}} <- pos.board, type != :king, do: type do
      [] -> true
      [type] when type in [:bishop, :knight] -> true
      _ -> false
    end
  end

  def other(:white), do: :black
  def other(:black), do: :white

  defp coords(<<f, r>>), do: {Enum.find_index(@files, &(&1 == <<f>>)), r - ?1}

  @doc """
  A move written the way a player writes it — `Nf3`, `exd5`, `O-O`, `e8=Q+`.
  `pos` is the position before the move.
  """
  @spec san(t(), binary()) :: binary() | nil
  def san(pos, uci) when is_binary(uci) do
    case Enum.find(legal(pos), &(uci(&1) == uci)) do
      nil -> nil
      mv -> san(pos, mv)
    end
  end

  def san(pos, %{castle: side} = mv) when side != nil do
    if(side == :king, do: "O-O", else: "O-O-O") <> check_mark(pos, mv)
  end

  def san(pos, mv) do
    {type, _color} = Map.fetch!(pos.board, mv.from)
    capture? = Map.has_key?(pos.board, mv.to) or en_passant_capture?(pos, mv)

    body =
      case type do
        :pawn ->
          if capture?, do: file(mv.from) <> "x" <> mv.to, else: mv.to

        _ ->
          hint = disambiguation(pos, mv, type)
          capture = if capture?, do: "x", else: ""
          piece_letter(type) <> hint <> capture <> mv.to
      end

    promo = if mv.promo, do: "=" <> piece_letter(mv.promo), else: ""
    body <> promo <> check_mark(pos, mv)
  end

  # Two pieces of the same kind can reach one square: name the file, or the
  # rank when they share it too.
  defp disambiguation(pos, mv, type) do
    rivals =
      for candidate <- legal(pos),
          candidate.from != mv.from,
          candidate.to == mv.to,
          match?({^type, _color}, Map.get(pos.board, candidate.from)),
          do: candidate.from

    cond do
      rivals == [] -> ""
      Enum.all?(rivals, &(file(&1) != file(mv.from))) -> file(mv.from)
      true -> rank(mv.from)
    end
  end

  defp check_mark(pos, mv) do
    next = apply_move(pos, mv)

    cond do
      not in_check?(next, next.turn) -> ""
      legal(next) == [] -> "#"
      true -> "+"
    end
  end

  defp piece_letter(:king), do: "K"
  defp piece_letter(:queen), do: "Q"
  defp piece_letter(:rook), do: "R"
  defp piece_letter(:bishop), do: "B"
  defp piece_letter(:knight), do: "N"
  defp piece_letter(:pawn), do: ""

  defp letter(:knight), do: "n"
  defp letter(:bishop), do: "b"
  defp letter(:rook), do: "r"
  defp letter(:queen), do: "q"
  defp letter(_), do: ""

  defp file(<<f, _r>>), do: <<f>>
  defp rank(<<_f, r>>), do: <<r>>

  @doc "A colour as the wire spells it."
  @spec color_name(color()) :: binary()
  def color_name(:white), do: "white"
  def color_name(:black), do: "black"

  @doc "The colour a wire name asks for, or nil."
  @spec color(binary()) :: color() | nil
  def color("white"), do: :white
  def color("black"), do: :black
  def color(_), do: nil
end
