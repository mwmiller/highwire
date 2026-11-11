defmodule HighWire.Chess.Legacy do
  @moduledoc """
  The chess already on the network, read in the format it was published in.

  This node writes a `chess/*` namespace of its own, but the store has
  carried a different one for years:

    * `chess_invite` — the author invites `inviting` and takes `myColor`
    * `chess_invite_accept` — the author takes the other side
    * `chess_move` — `orig`, `dest`, `ply`, and the FEN it produced
    * `chess_game_end` — the same, plus `status` and `winner`

  One early client published the same four messages under `ssb_chess_*`,
  and wrote a move's FEN into `pgnMove` and its notation into `fen`. Both
  spellings are read here, and the move fields are translated on the way
  in, so a game folds the same whichever client published it.

  A move arrives with the position it led to, so these games are read rather
  than replayed: the FEN is the position, and reproducing it from the moves
  would be a second opinion nobody asked for. That also keeps the fold cheap
  for a store holding tens of thousands of moves.

  Nothing here is playable. A game in this format is somebody else's to
  finish, so every snapshot says `writable?: false` and the pages leave it
  alone.
  """

  alias HighWire.Chess.Engine

  @types ~w(chess_invite chess_invite_accept chess_move chess_game_end)
  @aliases Enum.map(@types, &("ssb_" <> &1))

  @doc "The canonical message types this module reads."
  def types, do: @types

  @doc "Every raw type this module reads, canonical and prefixed."
  def kinds, do: @types ++ @aliases

  @doc "The canonical name for a type in this format."
  def canonical(type) when type in @aliases, do: String.replace_prefix(type, "ssb_", "")
  def canonical(type), do: type

  @doc "Whether a content map is a chess message in this format."
  def message?(content) when is_map(content), do: content["type"] in kinds()
  def message?(_), do: false

  @doc "Whether a binary names a game in this format."
  def game_id?(id) when is_binary(id) and byte_size(id) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(id, case: :lower))
  end

  def game_id?(_), do: false

  @doc """
  The URL-safe id for a game, from the key of its invite.

  A message key is base64 with `+`, `/` and `=`, which cannot appear
  unescaped in a path; the hex of the same 32 bytes is the shape this node's
  own games use, so a room URL does not say which format a game is in.
  """
  @spec game_id(binary() | nil) :: binary() | nil
  def game_id(key) when is_binary(key) do
    key
    |> String.trim_leading("%")
    |> String.replace_suffix(".sha256", "")
    |> Base.decode64()
    |> case do
      {:ok, <<_::256>> = bytes} -> Base.encode16(bytes, case: :lower)
      _ -> nil
    end
  end

  def game_id(_), do: nil

  @doc """
  One game's snapshot, in the shape the room and the game page read.

  `rows` are that game's messages, in any order — only `ply` orders a game,
  and only the latest position is kept.
  """
  @spec fold([map()]) :: map()
  def fold(rows) when is_list(rows) do
    rows = Enum.map(rows, &normalize/1)
    invite = Enum.find(rows, &(type(&1) == "chess_invite"))
    accept = Enum.find(rows, &(type(&1) == "chess_invite_accept"))

    root_key = root_key(invite, rows)

    # One root can carry more than one line — a game restarted, or a
    # message re-sent on a different branch. Each message names the one it
    # follows, so the game is the chain that ends at the latest leaf, not
    # every message filed under the same root.
    line = line(rows, root_key)

    moves = Enum.filter(line, &(type(&1) == "chess_move"))
    ending = line |> Enum.filter(&(type(&1) == "chess_game_end")) |> List.last()
    {white, black} = players(invite, accept)

    {_last, position, ply} = head(moves, ending)

    winner = winner(ending, position, white, black)

    %{
      game_id: game_id(root_key),
      kind: :chess,
      writable?: false,
      format: :legacy,
      challenger: invite && invite.author,
      accepter: accept && accept.author,
      white: white,
      black: black,
      position: position,
      board: position.board,
      turn: position.turn,
      mover: mover(ply, position, white, black),
      turn_count: ply,
      phase: phase(accept, ending),
      status: status(ending),
      winner: winner,
      verdict: verdict(ending, position),
      history: Enum.map(moves, &history_item/1),
      last_note: nil,
      updated_at: updated_at(rows)
    }
  end

  # Whole milliseconds: envelopes carry a receive time that can arrive with
  # a fraction, and every page that renders an age asks for an integer.
  defp updated_at(rows) do
    rows
    |> Enum.map(&(&1.ts || 0))
    |> Enum.max(fn -> 0 end)
    |> trunc()
  end

  @doc """
  The position a FEN describes.

  A FEN that does not parse reads as the opening position: a malformed one
  is a broken message, and a board nobody can read is better than a page
  that raises.
  """
  @spec position(binary() | nil) :: Engine.t()
  def position(fen) when is_binary(fen) do
    case String.split(fen, " ") do
      [placement, turn, castling, ep | rest] when placement != "" ->
        %{
          Engine.initial()
          | board: placement(placement),
            turn: if(turn == "b", do: :black, else: :white),
            castling: castling(castling),
            ep: if(ep in [nil, "-"], do: nil, else: ep),
            halfmove: number(Enum.at(rest, 0)),
            fullmove: max(number(Enum.at(rest, 1)), 1),
            seen: %{}
        }

      _ ->
        Engine.initial()
    end
  end

  def position(_), do: Engine.initial()

  # -- parsing -----------------------------------------------------------

  # One row in canonical terms: the prefixed type becomes the canonical one,
  # and a prefixed move has its two position fields put back the right way.
  defp normalize(%{content: %{"type" => type} = content} = row) when is_binary(type) do
    canonical = canonical(type)

    content =
      if canonical == "chess_move" and type != "chess_move",
        do: move_fields(Map.put(content, "type", canonical)),
        else: Map.put(content, "type", canonical)

    %{row | content: content}
  end

  defp normalize(row), do: row

  # This client wrote the FEN into `pgnMove` and the notation into `fen`: the
  # FEN is the field with ranks in it, so that is what tells them apart.
  defp move_fields(%{"fen" => fen, "pgnMove" => pgn} = content)
       when is_binary(fen) and is_binary(pgn) do
    if String.contains?(pgn, "/") and not String.contains?(fen, "/") do
      content |> Map.put("fen", pgn) |> Map.put("pgnMove", fen)
    else
      content
    end
  end

  defp move_fields(content), do: content

  defp type(%{content: content}), do: content["type"]

  # The challenge opens the thread; a game whose invite never arrived still
  # names its root on every message that follows it.
  defp root_key(invite, rows) do
    if invite, do: invite.key, else: Enum.find_value(rows, & &1.content["root"])
  end

  # The latest move, or the ending when only an ending arrived, the board it
  # left, and the ply it was played at.
  defp head(moves, ending) do
    last = latest(moves) || ending
    position = position(last && last.content["fen"])
    ply = (last && last.content["ply"]) || length(moves)
    {last, position, ply}
  end

  # Nobody is to move until a move has been played.
  defp mover(0, _position, _white, _black), do: nil
  defp mover(_ply, %{turn: :white}, white, _black), do: white
  defp mover(_ply, _position, _white, black), do: black

  defp latest([]), do: nil
  defp latest(rows), do: Enum.max_by(rows, &(&1.ts || 0))

  defp players(nil, _accept), do: {nil, nil}

  defp players(%{author: author, content: content}, accept) do
    opponent = (accept && accept.author) || content["inviting"]
    if content["myColor"] == "black", do: {opponent, author}, else: {author, opponent}
  end

  defp phase(nil, _), do: :opening
  defp phase(_accept, %{}), do: :finished
  defp phase(_accept, nil), do: :playing

  defp status(%{content: %{"status" => "aborted"}}), do: :withdrawn
  defp status(%{}), do: :finished
  defp status(nil), do: :playing

  # The chain of messages ending at the newest leaf, oldest first. Rows
  # that carry no `branch` (a hand-built test, or an early version of the
  # format) fall back to ply order, which is what they were ordered by.
  defp line(rows, root_key) do
    played = Enum.reject(rows, &(type(&1) in ["chess_invite", "chess_invite_accept"]))

    if Enum.all?(played, &is_nil(&1.content["branch"])) do
      Enum.sort_by(played, &(&1.content["ply"] || 0))
    else
      walk_back(latest(leaf(played)), Map.new(played, &{&1.key, &1}), root_key, [])
    end
  end

  # A leaf is a message nothing else follows.
  defp leaf(played) do
    referenced =
      played
      |> Enum.flat_map(&List.wrap(&1.content["branch"]))
      |> MapSet.new()

    Enum.reject(played, &MapSet.member?(referenced, &1.key))
  end

  defp walk_back(nil, _by_key, _root, acc), do: acc

  defp walk_back(%{key: key} = row, by_key, root, acc) do
    acc = [row | acc]
    next = row.content["branch"]

    cond do
      key == root or next == nil or next == root -> acc
      length(acc) > 5_000 -> acc
      true -> walk_back(Map.get(by_key, next), by_key, root, acc)
    end
  end

  # The winner, from the field when the message carries one and from the
  # position when it does not: older endings name the mate but not the
  # player, and a checkmate already says who delivered it.
  defp winner(%{content: %{"winner" => id}} = ending, _position, _white, _black)
       when is_binary(id),
       do: %{player: id, reason: reason(ending)}

  defp winner(%{content: %{"status" => "mate"}}, position, white, black),
    do: %{player: if(position.turn == :white, do: black, else: white), reason: :checkmate}

  defp winner(%{author: author} = ending, _position, white, black),
    do: %{player: other(author, white, black), reason: reason(ending)}

  defp winner(nil, _position, _white, _black), do: nil

  defp other(id, white, black) when id == white, do: black
  defp other(_id, white, _black), do: white

  defp reason(%{content: %{"status" => status}}) do
    case status do
      "mate" -> :checkmate
      "resign" -> :resign
      "timeout" -> :timeout
      "draw" -> :draw
      _ -> :over
    end
  end

  # The engine's word for the ending, when the message's status says which.
  defp verdict(%{content: %{"status" => "mate"}} = ending, position) do
    case ending.content["winner"] do
      nil -> nil
      _ -> {:checkmate, position.turn}
    end
  end

  defp verdict(_ending, _position), do: nil

  # The position after the move travels with the move: it is what the page
  # draws, and the only thing a game this node does not own can be asked to
  # stand behind.
  defp history_item(%{author: author, content: content}) do
    %{
      ply: content["ply"],
      player: author,
      type: "move",
      uci: uci(content),
      san: content["pgnMove"],
      note: nil,
      fen: content["fen"]
    }
  end

  # Coordinates plus the promotion the move named, when it named one.
  defp uci(%{"orig" => orig, "dest" => dest} = content) do
    case Regex.run(~r/=([A-Z])/, content["pgnMove"] || "") do
      [_, letter] -> orig <> dest <> String.downcase(letter)
      _ -> orig <> dest
    end
  end

  defp uci(_), do: nil

  # Ranks run downward from 8, and a digit is that many empty files, so the
  # file is carried through the row rather than counted afterwards.
  defp placement(placement) do
    placement
    |> String.split("/")
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {row, index}, board -> place_row(row, 8 - index, board) end)
  end

  defp place_row(row, rank, board) do
    row
    |> String.graphemes()
    |> Enum.reduce({1, board}, fn char, {file, acc} -> place(char, file, rank, acc) end)
    |> elem(1)
  end

  # A digit is a run of empty files; a letter is the piece standing here.
  defp place(char, file, rank, board) do
    case Integer.parse(char) do
      {n, ""} -> {file + n, board}
      _ -> {file + 1, put_piece(board, square(file, rank), piece(char))}
    end
  end

  defp put_piece(board, _square, nil), do: board
  defp put_piece(board, square, piece), do: Map.put(board, square, piece)

  defp square(file, rank), do: <<?a + file - 1>> <> Integer.to_string(rank)

  defp piece("P"), do: {:pawn, :white}
  defp piece("N"), do: {:knight, :white}
  defp piece("B"), do: {:bishop, :white}
  defp piece("R"), do: {:rook, :white}
  defp piece("Q"), do: {:queen, :white}
  defp piece("K"), do: {:king, :white}
  defp piece("p"), do: {:pawn, :black}
  defp piece("n"), do: {:knight, :black}
  defp piece("b"), do: {:bishop, :black}
  defp piece("r"), do: {:rook, :black}
  defp piece("q"), do: {:queen, :black}
  defp piece("k"), do: {:king, :black}
  defp piece(_), do: nil

  defp castling("-"), do: MapSet.new()

  defp castling(rights) when is_binary(rights) do
    rights
    |> String.graphemes()
    |> Enum.reduce(MapSet.new(), fn
      "K", set -> MapSet.put(set, :white_king)
      "Q", set -> MapSet.put(set, :white_queen)
      "k", set -> MapSet.put(set, :black_king)
      "q", set -> MapSet.put(set, :black_queen)
      _, set -> set
    end)
  end

  defp castling(_), do: MapSet.new()

  defp number(nil), do: 0

  defp number(value) do
    case Integer.parse(value) do
      {n, _} -> n
      _ -> 0
    end
  end
end
