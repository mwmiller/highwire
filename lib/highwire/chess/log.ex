defmodule HighWire.Chess.Log do
  @moduledoc """
  The writes a chess game makes: open one, accept one, play a move, resign,
  or withdraw an unanswered challenge.

  By default a game write persists the local copy and does not post to the
  player's timeline. The feed is only used when there is commentary to go with
  the move — otherwise the game is carried by the store and the fold, and the
  timeline stays quiet during live play.

  The local copy is filed into the store as soon as the engine hands back its
  key — through the call, not the cast, because the player's next page reads
  the game straight away. The tail's later delivery of the same message is
  still a no-op: the store keys on the message, so the second copy is
  recognised and folds nothing twice.

  A move is checked against the folded position before it goes out. The wire
  cannot carry an illegal move from this client, so a game that disagrees can
  only be the other player's doing — which is what the fold's `:broken` is
  for.
  """

  alias HighWire.Chess.{Engine, Game, Store}
  alias HighWire.SSB.Identities
  alias HighWire.Timeline

  @doc """
  Open a game as `color`. Options: `:to` (a feed to challenge directly),
  `:note`, `:game_id` (tests), and `:publish` (a `content -> {:ok, key}`
  function; tests swap it for a stub).

  This writes the local store copy first. If there is `:commentary` content,
  it is posted to the timeline as a chess chat message, otherwise the game
  quiet write is silent and the returned key is throwaway.
  """
  @spec open(String.t(), keyword()) :: {:ok, binary(), binary()} | {:error, term()}
  def open(color, opts \\ []) when color in ["white", "black"] do
    game_id = Keyword.get(opts, :game_id) || Game.new_id()
    content = Game.challenge(game_id, color, to: opts[:to], note: opts[:note])

    with {:ok, key} <- publish(content, opts) do
      file(key, content, opts)
      {:ok, game_id, key}
    end
  end

  @doc "Accept a challenge: the accepter takes the side the challenger left."
  @spec accept(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def accept(game, opts \\ []) do
    publish_and_file(Game.accept(game.game_id, game.challenge_key, note: opts[:note]), opts)
  end

  @doc """
  Play `uci` in `game`. The ply is the next one the fold expects, and the
  move is refused here if the folded position does not allow it.
  """
  @spec play(map(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def play(game, uci, opts \\ []) do
    with :ok <- legal?(game, uci) do
      content =
        Game.move(game.game_id, game.challenge_key, game.turn_count + 1, uci, note: opts[:note])

      publish_and_file(content, opts)
    end
  end

  @doc "Resign: the game goes to the other player."
  @spec resign(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def resign(game, opts \\ []) do
    content =
      Game.resign(game.game_id, game.challenge_key, game.turn_count + 1, note: opts[:note])

    publish_and_file(content, opts)
  end

  @doc "Withdraw a challenge nobody has accepted yet."
  @spec withdraw(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def withdraw(game, opts \\ []) do
    publish_and_file(Game.withdraw(game.game_id, game.challenge_key), opts)
  end

  defp legal?(%{position: position}, uci) when is_map(position) do
    case Engine.move(position, uci) do
      {:ok, _next} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp legal?(_game, _uci), do: {:error, :no_position}

  defp default_publisher do
    Application.get_env(:highwire, :game_publisher, &Timeline.publish_content/1)
  end

  defp file(key, content, opts) do
    case author(opts) do
      nil ->
        :ok

      id ->
        Store.ingest(%{
          "key" => key,
          "value" => %{"author" => id, "content" => content}
        })
    end
  end

  defp author(opts) do
    Keyword.get(opts, :author) || active_identity()
  end

  defp active_identity do
    case Identities.active() do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp publish_and_file(content, opts) do
    with {:ok, key} <- publish(content, opts) do
      file(key, content, opts)
      {:ok, key}
    end
  end

  defp publish(content, opts) do
    publisher = Keyword.get(opts, :publish) || default_publisher()
    publisher.(content)
  end
end
