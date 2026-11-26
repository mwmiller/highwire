defmodule HighWire.Chess.Store do
  @moduledoc """
  The local record of every chess game this node has seen, kept in a DETS
  file of its own.

  One table per game, because the two games have nothing in common to file:
  a backgammon row carries commitments, reveals and a chain position, a chess
  row a colour choice and moves. What both share — reading an envelope once,
  keyed by the game it belongs to, and folding the entries on read — is
  `HighWire.Games.Store`; what is here is what a chess row is.

  Nothing here decides whether a move is true. A row records what was
  published; the fold decides whether those moves make a legal game, and
  `:broken` on a snapshot is the fold saying they do not.
  """

  use HighWire.Games.Store

  @impl true
  def kind, do: :chess

  @impl true
  def table, do: :highwire_chess

  @impl true
  def topic, do: "chess"

  @impl true
  def file, do: "chess.dets"

  @impl true
  def game_module, do: HighWire.Chess.Game

  @impl true
  def fold_module, do: HighWire.Chess.Fold

  @impl true
  def reader_module, do: HighWire.Chess.Reader

  # The fold reads the pairing and the challenger's colour; the colour is
  # also carried on the snapshot for the page that lights up a player's side.
  @impl true
  def snapshot_game(row) do
    %{
      challenger: row.challenger,
      accepter: row.accepter,
      game_id: row.game_id,
      challenger_color: row.challenger_color
    }
  end

  @impl true
  def snapshot_extras(row), do: %{challenger_color: row.challenger_color}

  # A challenge with no acceptor is still a game — it is the room's open
  # invitation rather than a game in flight.
  @impl true
  def listed?(game), do: game.challenger != nil

  @impl true
  def fold_extras(_row), do: %{}

  @impl true
  def status(%{error: error}, _row) when error != :none, do: :broken
  def status(%{phase: :finished}, _row), do: :finished
  def status(_folded, %{withdrawn?: true}), do: :withdrawn
  def status(%{phase: :opening}, _row), do: :opening
  def status(_folded, _row), do: :playing

  @impl true
  def new_row(game_id) do
    %{
      game_id: game_id,
      challenger: nil,
      accepter: nil,
      challenger_color: nil,
      challenge_key: nil,
      accept_key: nil,
      challenge: nil,
      accept: nil,
      entries: [],
      keys: %{},
      withdrawn?: false,
      created_at: now(),
      updated_at: now()
    }
  end

  @impl true
  def put_message(row, %{type: "challenge", author: author, content: content} = read) do
    %{
      row
      | challenger: row.challenger || author,
        challenge_key: read.key,
        challenger_color: content["color"] || "white",
        challenge: content
    }
  end

  def put_message(row, %{type: "accept", author: author, content: content} = read) do
    Map.merge(row, %{accepter: row.accepter || author, accept_key: read.key, accept: content})
  end

  def put_message(row, %{type: "withdraw", author: author}) do
    Map.put(row, :withdrawn?, row.challenger == author)
  end

  def put_message(row, _read), do: row

  defp now, do: System.system_time(:millisecond)
end
