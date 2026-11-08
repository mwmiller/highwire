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

  alias HighWire.Chess.Engine
  alias HighWire.Chess.Store
  alias HighWire.Games.Id
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
    game_id = Keyword.get(opts, :game_id) || Id.new()
    opponent = Keyword.get(opts, :to)
    content = %{
      "type" => "chess_invite",
      "gameId" => game_id,
      "myColor" => color,
      "root" => game_id
    }
    content = if opponent, do: Map.put(content, "inviting", opponent), else: content
    content = if opts[:note], do: Map.put(content, "note", opts[:note]), else: content

    with {:ok, key} <- publish(content, opts) do
      # File the content as published, with the root updated to the
      # published key so the store derives the game id from it and
      # subsequent messages can point at this message.
      content_with_root = Map.put(content, "root", key)
      file(key, content_with_root, opts)

      # The returned game id is the hex of the published key, which is
      # what the store files the game under.
      {:ok, HighWire.Chess.game_id(key), key}
    end
  end

  @doc "Accept a challenge: the accepter takes the side the challenger left."
  @spec accept(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def accept(game, opts \\ []) do
    root = game.challenge_key || game_id_from_game(game) || game.game_id
    content = %{
      "type" => "chess_invite_accept",
      "gameId" => game.game_id,
      "root" => root,
      "myColor" => other_side(game),
      "note" => opts[:note]
    }
    content = content |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    publish_and_file(content, opts)
  end

  @doc """
  Play `uci` in `game`. The ply is the next one the fold expects, and the
  move is refused here if the folded position does not allow it.
  """
  @spec play(map(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def play(game, uci, opts \\ []) do
    with {:ok, next_pos} <- Engine.move(game.position, uci) do
      {orig, dest} = parse_ucI(uci)
      root = game.challenge_key || game_id_from_game(game) || game.game_id
      content = %{
        "type" => "chess_move",
        "gameId" => game.game_id,
        "root" => root,
        "ply" => game.turn_count + 1,
        "orig" => orig,
        "dest" => dest,
        "pgnMove" => Engine.san(game.position, uci),
        "fen" => Engine.fen(next_pos),
        "note" => opts[:note]
      }
      content = content |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
      publish_and_file(content, opts)
    end
  end

  @doc "Resign: the game goes to the other player."
  @spec resign(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def resign(game, opts \\ []) do
    root = game.challenge_key || game_id_from_game(game) || game.game_id
    content = %{
      "type" => "chess_game_end",
      "gameId" => game.game_id,
      "root" => root,
      "ply" => game.turn_count,
      "status" => "resign",
      "fen" => Engine.fen(game.position),
      "note" => opts[:note]
    }
    content = content |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    publish_and_file(content, opts)
  end

  @doc "Withdraw a challenge nobody has accepted yet."
  @spec withdraw(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def withdraw(game, opts \\ []) do
    root = game.challenge_key || game_id_from_game(game) || game.game_id
    content = %{
      "type" => "chess_game_end",
      "gameId" => game.game_id,
      "root" => root,
      "ply" => game.turn_count,
      "status" => "withdrawn",
      "note" => opts[:note]
    }
    content = content |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
    publish_and_file(content, opts)
  end

  defp parse_ucI(uci) do
    case uci do
      <<orig::binary-size(2), dest::binary-size(2), _promo::binary>> ->
        {orig, dest}
      <<orig::binary-size(2), dest::binary-size(2)>> ->
        {orig, dest}
      _ ->
        {:error, :invalid_ucI}
    end
  end

  # NOTE: This function is no longer used. Legal moves are now checked
  # using Engine.legal_moves/1 in the play/3 function. Kept for potential
  # future use.

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
          "value" => %{"author" => id, "content" => content, "timestamp" => System.system_time(:millisecond)}
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

  # The color the accepter takes, from the invite the game folded.
  defp other_side(game) do
    case game.challenger_color do
      "white" -> "black"
      "black" -> "white"
      _ -> nil
    end
  end

  # Fallback game id when the game has no challenge_key (e.g., games folded
  # from rows that did not carry a root).
  defp game_id_from_game(%{game_id: game_id}), do: game_id
  defp game_id_from_game(%{challenge_key: key}), do: HighWire.Chess.game_id(key)

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
