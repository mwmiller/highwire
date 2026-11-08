defmodule HighWire.Chess.LogTest do
  use ExUnit.Case, async: false

  alias HighWire.Chess.Log
  alias HighWire.Chess
  alias HighWire.Chess.Store, as: LegacyStore

  @challenger "@challenger.ed25519"
  @accepter "@accepter.ed25519"

  setup do
    LegacyStore.clear()

    # Stand in for the engine: record what would be published and hand back
    # a key, so the store can file it the way it files a delivered message.
    publisher = fn content ->
      send(self(), {:published, content})
      # Use a valid SSB key format: %<base64-32-bytes>.sha256
      key = "%#{Base.encode64(:crypto.strong_rand_bytes(32))}.sha256"
      {:ok, key}
    end

    {:ok, publisher: publisher}
  end

  defp open_game(publisher, color \\ "white") do
    {:ok, game_id, key} = Log.open(color, publish: publisher, author: @challenger)
    game = LegacyStore.get(game_id)
    {game_id, key}
  end

  defp flush_published do
    receive do
      {:published, _} -> flush_published()
    after
      0 -> :ok
    end
  end

  defp accepted(publisher) do
    {:ok, game_id, _key} = Log.open("white", publish: publisher, author: @challenger)
    flush_published()

    game = LegacyStore.get(game_id)

    {:ok, _key} =
      Log.accept(game, publish: publisher, author: @accepter)
    flush_published()

    game = LegacyStore.get(game_id)

    game
  end

  test "opening a game publishes a challenge and files it", %{publisher: publisher} do
    {:ok, returned_game_id, key} = Log.open("white", publish: publisher, author: @challenger)

    assert_received {:published, %{"type" => "chess_invite", "myColor" => "white", "root" => published_root, "gameId" => published_game_id} = content}
    # The published root and gameId are the pre-publish game id (Id.new()).
    # The store files the game under returned_game_id = HighWire.Chess.game_id(key).
    assert returned_game_id == HighWire.Chess.game_id(key)
    assert published_root != returned_game_id
    assert published_game_id != returned_game_id

    game = LegacyStore.get(returned_game_id)
    assert game.challenger == @challenger
    assert game.challenge_key == key
    assert game.status == :playing
  end

  test "opening as black puts the challenger on the black side", %{publisher: publisher} do
    {:ok, game_id, _key} = Log.open("black", publish: publisher, author: @challenger)
    flush_published()

    game = LegacyStore.get(game_id)
    assert game.challenger_color == "black"
  end

  test "accepting publishes the accept and joins the game", %{publisher: publisher} do
    game = accepted(publisher)

    assert game.accepter == @accepter
    assert game.status == :playing
    assert game.mover == @challenger
  end

  test "a legal move goes out with the next ply", %{publisher: publisher} do
    {:ok, game_id, _key} = Log.open("white", publish: publisher, author: @challenger)
    flush_published()

    game = LegacyStore.get(game_id)
    {:ok, _key} = Log.accept(game, publish: publisher, author: @accepter)
    flush_published()

    game = LegacyStore.get(game_id)

    assert {:ok, _key} = Log.play(game, "e2e4", publish: publisher, author: @challenger)
    assert_receive {:published, %{"type" => "chess_move", "ply" => 1, "orig" => "e2", "dest" => "e4", "pgnMove" => "e4"}}

    game = LegacyStore.get(game.game_id)
    assert game.turn_count == 1
    assert game.board["e4"] == {:pawn, :white}
    assert game.mover == @accepter
  end

  test "an illegal move never reaches the wire", %{publisher: publisher} do
    game = accepted(publisher)
    flush_published()

    assert {:error, :illegal} = Log.play(game, "e2e5", publish: publisher, author: @challenger)
    refute_received {:published, _}
    assert LegacyStore.get(game.game_id).turn_count == 0
  end

  test "the second player's move is ply two", %{publisher: publisher} do
    {:ok, game_id, _key} = Log.open("white", publish: publisher, author: @challenger)
    flush_published()

    game = LegacyStore.get(game_id)
    {:ok, _key} = Log.accept(game, publish: publisher, author: @accepter)

    game = LegacyStore.get(game.game_id)
    {:ok, _} = Log.play(game, "e2e4", publish: publisher, author: @challenger)
    flush_published()

    game = LegacyStore.get(game.game_id)
    assert {:ok, _key} = Log.play(game, "e7e5", publish: publisher, author: @accepter)
    assert_receive {:published, %{"type" => "chess_move", "ply" => 2, "orig" => "e7", "dest" => "e5", "pgnMove" => "e5"}}
  end

  test "resigning ends the game for the other player", %{publisher: publisher} do
    {:ok, game_id, _key} = Log.open("white", publish: publisher, author: @challenger)
    flush_published()

    game = LegacyStore.get(game_id)
    {:ok, _key} = Log.accept(game, publish: publisher, author: @accepter)
    flush_published()

    game = LegacyStore.get(game_id)

    {:ok, _key} = Log.resign(game, publish: publisher, author: @challenger)

    assert_receive {:published, %{"type" => "chess_game_end", "status" => "resign", "ply" => 0}}
    flush_published()

    game = LegacyStore.get(game.game_id)
    assert game.status == :finished

    assert game.winner == %{player: @accepter, reason: :resign}
  end

  test "withdrawing an unanswered challenge closes it", %{publisher: publisher} do
    {:ok, game_id, _key} = Log.open("white", publish: publisher, author: @challenger)
    flush_published()

    assert {:ok, _key} = Log.withdraw(LegacyStore.get(game_id), publish: publisher, author: @challenger)
    assert_receive {:published, %{"type" => "chess_game_end", "status" => "withdrawn"}}

    assert LegacyStore.get(game_id).status == :withdrawn
  end

  test "a game id is minted for each opened game", %{publisher: publisher} do
    {:ok, first, _} = Log.open("white", publish: publisher, author: @challenger)
    {:ok, second, _} = Log.open("white", publish: publisher, author: @challenger)

    assert Chess.id?(first)
    assert first != second
  end
end
