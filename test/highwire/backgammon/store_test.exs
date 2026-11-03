defmodule HighWire.Backgammon.StoreTest do
  use ExUnit.Case, async: false

  alias HighWire.Backgammon.{Chain, Game, Store}

  setup do
    Store.clear()
    :ok
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp envelope(author, content, key \\ nil) do
    key = key || "%#{System.unique_integer([:positive])}.sha256"
    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end

  # A challenge and the accept that answers it, with real chains behind both
  # commitments so a fold over them can verify.
  defp opening do
    game_id = Game.new_id()
    spec = %{"length" => 8}
    chall = Chain.generate(:crypto.strong_rand_bytes(32), spec)
    accept = Chain.generate(:crypto.strong_rand_bytes(32), spec)

    challenger = "@challenger.ed25519"
    accepter = "@accepter.ed25519"

    challenge = Game.challenge(game_id, hex(Chain.commit(chall)))

    accept_content =
      Game.accept(game_id, "%challenge.sha256", hex(Chain.commit(accept)), hex(List.last(accept)))

    %{
      game_id: game_id,
      challenger: challenger,
      accepter: accepter,
      challenge: envelope(challenger, challenge, "%challenge.sha256"),
      accept: envelope(accepter, accept_content, "%accept.sha256")
    }
  end

  test "a challenge alone opens a game and waits for an accepter" do
    %{game_id: id, challenger: challenger, challenge: challenge} = opening()

    assert {:ok, ^id} = Store.ingest(challenge)

    game = Store.get(id)
    assert game.challenger == challenger
    assert game.accepter == nil
    assert game.position != nil
    # Rows without both players are not games yet.
    assert Store.games() == []
  end

  test "an accept completes the pairing" do
    %{
      game_id: id,
      challenger: challenger,
      accepter: accepter,
      challenge: challenge,
      accept: accept
    } =
      opening()

    Store.ingest(challenge)
    assert {:ok, ^id} = Store.ingest(accept)

    game = Store.get(id)
    assert game.challenger == challenger
    assert game.accepter == accepter
    assert game.phase == :opening
    assert game.status == :opening
    assert game.mover == challenger
    assert game.error == :none
    assert [^id] = Enum.map(Store.games(), & &1.game_id)
  end

  test "delivery order does not matter" do
    %{game_id: id, challenge: challenge, accept: accept} = opening()

    Store.ingest(accept)
    Store.ingest(challenge)

    game = Store.get(id)
    assert game.challenger != nil
    assert game.accepter != nil
    assert game.error == :none
  end

  test "a re-delivered message is filed once" do
    %{game_id: id, challenge: challenge} = opening()

    assert {:ok, ^id} = Store.ingest(challenge)
    assert :seen = Store.ingest(challenge)

    assert Store.get(id).entries == 0
  end

  test "messages outside the namespace are ignored" do
    assert :ignored =
             Store.ingest(envelope("@someone.ed25519", %{"type" => "post", "text" => "hi"}))
  end

  test "a game message without a usable id is ignored" do
    content = %{"type" => "backgammon/turn", "game_id" => "not-an-id", "turn" => 1}
    assert :ignored = Store.ingest(envelope("@someone.ed25519", content))
  end

  test "only the challenger can withdraw" do
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

    Store.ingest(envelope(accepter, Game.withdraw(id, "%challenge.sha256")))
    refute Store.get(id).withdrawn?

    Store.ingest(envelope(challenger, Game.withdraw(id, "%challenge.sha256")))
    assert Store.get(id).withdrawn?
    assert Store.get(id).status == :withdrawn
  end

  test "a directed challenge keeps its addressee" do
    %{game_id: id, challenge: challenge} = opening()
    content = Map.put(challenge["value"]["content"], "to", "@friend.ed25519")
    challenge = put_in(challenge, ["value", "content"], content)

    Store.ingest(challenge)
    assert Store.get(id).directed_to == "@friend.ed25519"
  end
end
