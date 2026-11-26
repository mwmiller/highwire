defmodule HighWire.Backgammon.Store do
  @moduledoc """
  The local record of every backgammon game this node has seen, kept in a
  DETS file.

  Two things make the store necessary rather than convenient. SSB has no
  query for "the messages of one game" — a reader would have to walk whole
  feeds — and the social timeline is the wrong place to answer "whose move
  is it". So every `backgammon/*` message that arrives is filed here, keyed
  by game, and the page reads the store rather than the feed.

  The fold runs on read: a game is a few hundred small maps, so folding is
  cheaper than keeping a derived cache in step with an append-only log. The
  store persists the *entries* — that is what makes a game replayable after
  a restart, and it is the part that cannot be recomputed from anything else.
  The filing itself is `HighWire.Games.Store`; what is here is what a
  backgammon row is.

  Nothing here decides whether a message is true. A row records what was
  published; the fold decides whether those entries make a legal game, and
  `error` on a snapshot is the fold saying they do not.
  """

  use HighWire.Games.Store

  @impl true
  def kind, do: :backgammon

  @impl true
  def table, do: :highwire_backgammon

  @impl true
  def topic, do: "backgammon"

  @impl true
  def file, do: "backgammon.dets"

  @impl true
  def game_module, do: HighWire.Backgammon.Game

  @impl true
  def fold_module, do: HighWire.Backgammon.Fold

  @impl true
  def reader_module, do: HighWire.Backgammon.Reader

  # The fold verifies both commitments against one another, so it reads them
  # with the pairing; the reveal arrives with the accept.
  @impl true
  def snapshot_game(row) do
    %{
      challenger: row.challenger,
      accepter: row.accepter,
      game_id: row.game_id,
      challenge_commit: row.challenge_commit,
      accept_commit: row.accept_commit
    }
  end

  @impl true
  def fold_extras(row), do: %{accept_reveal: row.accept_reveal}

  @impl true
  def snapshot_extras(_row), do: %{}

  # A challenge with no acceptor is not a game to watch; it waits in the room
  # as an invitation instead.
  @impl true
  def listed?(game), do: game.challenger != nil and game.accepter != nil

  @impl true
  def status(%{phase: :finished, winner: %{player: player}}, _row) when is_binary(player),
    do: :finished

  def status(%{error: error}, _row) when error != :none, do: :broken
  def status(_folded, %{withdrawn?: true}), do: :withdrawn
  def status(%{phase: :opening}, _row), do: :opening
  def status(_folded, _row), do: :playing

  @impl true
  def new_row(game_id) do
    %{
      game_id: game_id,
      challenger: nil,
      accepter: nil,
      challenge_key: nil,
      accept_key: nil,
      challenge_commit: nil,
      accept_commit: nil,
      accept_reveal: nil,
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
        challenge_commit: content["commit"],
        challenge: content
    }
  end

  def put_message(row, %{type: "accept", author: author, content: content} = read) do
    Map.merge(row, %{
      accepter: row.accepter || author,
      accept_key: read.key,
      accept_commit: content["commit"],
      accept_reveal: content["reveal"],
      accept: content
    })
  end

  def put_message(row, %{type: "withdraw", author: author}) do
    Map.put(row, :withdrawn?, row.challenger == author)
  end

  def put_message(row, _read), do: row

  defp now, do: System.system_time(:millisecond)
end
