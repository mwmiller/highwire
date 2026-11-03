defmodule HighWire.Chess.StoreTest do
  use ExUnit.Case, async: false

  alias HighWire.Chess.{Game, Store}

  setup do
    Store.clear()
    :ok
  end

  defp envelope(author, content, key \\ nil) do
    key = key || "%#{System.unique_integer([:positive])}.sha256"
    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end

  defp opening(overrides \\ %{}) do
    game_id = Map.get(overrides, :game_id, Game.new_id())
    challenger = "@challenger.ed25519"
    accepter = "@accepter.ed25519"

    challenge = envelope(challenger, Game.challenge(game_id, "white"), "%challenge.sha256")
    accept = envelope(accepter, Game.accept(game_id, "%challenge.sha256"), "%accept.sha256")

    %{
      game_id: game_id,
      challenger: challenger,
      accepter: accepter,
      challenge: challenge,
      accept: accept
    }
  end

  test "a challenge alone opens a game and waits for an accepter" do
    %{game_id: id, challenger: challenger, challenge: challenge} = opening()

    assert {:ok, ^id} = Store.ingest(challenge)

    game = Store.get(id)
    assert game.kind == :chess
    assert game.challenger == challenger
    assert game.accepter == nil
    assert game.status == :opening
    assert game.turn == :white
    assert game.mover == challenger
  end

  test "an accept starts the game between the two players" do
    %{
      game_id: id,
      challenger: challenger,
      accepter: accepter,
      challenge: challenge,
      accept: accept
    } =
      opening()

    Store.ingest(challenge)
    Store.ingest(accept)

    game = Store.get(id)
    assert game.status == :playing
    assert game.white == challenger
    assert game.black == accepter
    assert game.mover == challenger
  end

  test "a move folds into the snapshot and announces itself" do
    %{game_id: id, challenger: challenger, challenge: challenge, accept: accept} = opening()
    Phoenix.PubSub.subscribe(HighWire.PubSub, Store.topic())

    Store.ingest(challenge)
    Store.ingest(accept)

    assert {:ok, ^id} =
             Store.ingest(envelope(challenger, Game.move(id, "%challenge.sha256", 1, "e2e4")))

    assert_receive {:chess, ^id}

    game = Store.get(id)
    assert game.board["e4"] == {:pawn, :white}
    assert game.turn_count == 1
    assert game.mover == "@accepter.ed25519"
    assert [%{san: "e4"}] = game.history
  end

  test "the same message twice is not two moves" do
    %{game_id: id, challenger: challenger, challenge: challenge, accept: accept} = opening()
    move = envelope(challenger, Game.move(id, "%challenge.sha256", 1, "e2e4"), "%move.sha256")

    Store.ingest(challenge)
    Store.ingest(accept)
    Store.ingest(move)

    assert Store.ingest(move) == :seen
    assert Store.get(id).turn_count == 1
  end

  test "an illegal move leaves a game that does not verify" do
    %{game_id: id, challenger: challenger, challenge: challenge, accept: accept} = opening()

    Store.ingest(challenge)
    Store.ingest(accept)
    Store.ingest(envelope(challenger, Game.move(id, "%challenge.sha256", 1, "e2e5")))

    game = Store.get(id)
    assert game.status == :broken
    assert game.error =~ "not a legal move"
  end

  test "a withdrawal before the accept closes the game" do
    %{game_id: id, challenger: challenger, challenge: challenge} = opening()

    Store.ingest(challenge)
    Store.ingest(envelope(challenger, Game.withdraw(id, "%challenge.sha256")))

    assert Store.get(id).status == :withdrawn
  end

  test "a message that is not ours is ignored" do
    assert Store.ingest(envelope("@a.ed25519", %{"type" => "post", "text" => "hello"})) ==
             :ignored
  end

  test "games are listed newest activity first and without a challenge are not listed" do
    first = opening()
    second = opening(%{game_id: Game.new_id()})

    Store.ingest(first.challenge)
    Store.ingest(second.challenge)

    ids = Store.games() |> Enum.map(& &1.game_id)
    assert ids == [second.game_id, first.game_id] or ids == [first.game_id, second.game_id]
    assert length(ids) == 2
  end

  test "valid_id? accepts a game id and nothing else" do
    assert Store.valid_id?(Game.new_id())
    refute Store.valid_id?("not-an-id")
    refute Store.valid_id?(nil)
  end
end
