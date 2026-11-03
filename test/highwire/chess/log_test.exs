defmodule HighWire.Chess.LogTest do
  use ExUnit.Case, async: false

  alias HighWire.Chess.{Game, Log, Store}

  @challenger "@challenger.ed25519"
  @accepter "@accepter.ed25519"

  setup do
    Store.clear()

    # Stand in for the engine: record what would be published and hand back
    # a key, so the store can file it the way it files a delivered message.
    publisher = fn content ->
      send(self(), {:published, content})
      {:ok, "%published-#{System.unique_integer([:positive])}.sha256"}
    end

    {:ok, publisher: publisher}
  end

  defp open_game(publisher, color \\ "white") do
    {:ok, game_id, _key} = Log.open(color, publish: publisher, author: @challenger)
    game_id
  end

  defp flush_published do
    receive do
      {:published, _} -> flush_published()
    after
      0 -> :ok
    end
  end

  defp accepted(publisher) do
    game_id = open_game(publisher)
    game = Store.get(game_id)

    {:ok, _key} =
      Log.accept(game, publish: publisher, author: @accepter)

    Store.get(game_id)
  end

  test "opening a game publishes a challenge and files it", %{publisher: publisher} do
    {:ok, game_id, key} = Log.open("white", publish: publisher, author: @challenger)

    assert_receive {:published, %{"type" => "chess/challenge", "color" => "white"} = content}
    assert content["game_id"] == game_id

    game = Store.get(game_id)
    assert game.challenger == @challenger
    assert game.challenge_key == key
    assert game.status == :opening
  end

  test "opening as black puts the challenger on the black side", %{publisher: publisher} do
    game_id = open_game(publisher, "black")

    game = Store.get(game_id)
    assert game.challenger_color == "black"
  end

  test "accepting publishes the accept and joins the game", %{publisher: publisher} do
    game = accepted(publisher)

    assert_receive {:published, %{"type" => "chess/accept"}}

    game = Store.get(game.game_id)
    assert game.accepter == @accepter
    assert game.status == :playing
    assert game.mover == @challenger
  end

  test "a legal move goes out with the next ply", %{publisher: publisher} do
    game = accepted(publisher)

    assert {:ok, _key} = Log.play(game, "e2e4", publish: publisher, author: @challenger)
    assert_receive {:published, %{"type" => "chess/move", "ply" => 1, "uci" => "e2e4"}}

    game = Store.get(game.game_id)
    assert game.turn_count == 1
    assert game.board["e4"] == {:pawn, :white}
    assert game.mover == @accepter
  end

  test "an illegal move never reaches the wire", %{publisher: publisher} do
    game = accepted(publisher)
    flush_published()

    assert {:error, :illegal} = Log.play(game, "e2e5", publish: publisher, author: @challenger)
    refute_received {:published, _}
    assert Store.get(game.game_id).turn_count == 0
  end

  test "the second player's move is ply two", %{publisher: publisher} do
    game = accepted(publisher)
    {:ok, _} = Log.play(game, "e2e4", publish: publisher, author: @challenger)

    game = Store.get(game.game_id)
    assert {:ok, _key} = Log.play(game, "e7e5", publish: publisher, author: @accepter)
    assert_receive {:published, %{"type" => "chess/move", "ply" => 2, "uci" => "e7e5"}}
  end

  test "resigning ends the game for the other player", %{publisher: publisher} do
    game = accepted(publisher)

    assert {:ok, _key} = Log.resign(game, publish: publisher, author: @challenger)
    assert_receive {:published, %{"type" => "chess/resign", "ply" => 1}}

    game = Store.get(game.game_id)
    assert game.status == :finished
    assert game.winner == %{player: @accepter, reason: :resign}
  end

  test "withdrawing an unanswered challenge closes it", %{publisher: publisher} do
    game_id = open_game(publisher)

    assert {:ok, _key} = Log.withdraw(Store.get(game_id), publish: publisher, author: @challenger)
    assert_receive {:published, %{"type" => "chess/withdraw"}}

    assert Store.get(game_id).status == :withdrawn
  end

  test "a game id is minted for each opened game", %{publisher: publisher} do
    {:ok, first, _} = Log.open("white", publish: publisher, author: @challenger)
    {:ok, second, _} = Log.open("white", publish: publisher, author: @challenger)

    assert Game.id?(first)
    assert first != second
  end
end
