defmodule HighWire.Backgammon.LogTest do
  use ExUnit.Case, async: false

  alias HighWire.Backgammon.{Chain, Engine, Game, Log, Notation, Store}

  @challenger "@challenger.ed25519"
  @accepter "@accepter.ed25519"

  setup do
    Store.clear()
    :ok
  end

  # Publishing is the engine's job, so the tests hand the Log a stub that
  # returns a key of its own. Everything after that is the real path: the
  # store files the message and the fold reads it back.
  defp publisher do
    key = "%#{System.unique_integer([:positive])}.sha256"
    test = self()

    fn content ->
      send(test, {:published, content})
      {:ok, key}
    end
  end

  defp as(author, secret) do
    [author: author, secret: secret, publish: publisher()]
  end

  defp published do
    receive do
      {:published, content} -> content
    after
      0 -> flunk("nothing was published")
    end
  end

  describe "opening a game" do
    test "publishes a challenge and files it against the challenger" do
      opts = as(@challenger, :crypto.strong_rand_bytes(32))

      assert {:ok, game_id, key} = Log.open(opts)
      assert is_binary(key)

      game = Store.get(game_id)
      assert game.challenger == @challenger
      assert game.accepter == nil
      assert game.phase == :opening
      # The commitment is what the reveal chain is checked against later, so
      # it has to be the hash of that chain's last value — not a placeholder
      # the fold would reject as soon as the first roll arrives.
      assert %{"commit" => commit} = published()
      assert {:ok, value} = Game.unhex32(commit)
      assert byte_size(value) == 32
    end

    # A challenge that never reached the network is an error the page can
    # say out loud, not a game the store half-believes in.
    test "reports a publish that did not happen" do
      opts = [author: @challenger, secret: :crypto.strong_rand_bytes(32)]

      assert {:error, reason} = Log.open(opts)
      assert reason != nil
    end
  end

  describe "an opening roll" do
    test "spends two links and keeps the chain verifiable" do
      challenger_secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, challenger_secret))
      game = Store.get(game_id)

      assert {:ok, _key} = Log.accept(game, as(@accepter, accepter_secret))
      game = Store.get(game_id)

      # The accepter's accept reveal spends the first link, so it is the
      # challenger's turn to roll and each side has a different budget.
      assert game.mover == @challenger
      assert game.remaining[@accepter] == game.remaining[@challenger] - 1

      assert {:ok, _key} = Log.roll(game, as(@challenger, challenger_secret))

      # Two links spent, and the half the roll revealed is the one the
      # opponent will mix with next time.
      game = Store.get(game_id)
      assert game.error == :none
      assert game.remaining[@challenger] == 1022
      assert is_binary(game.halves[@challenger])
    end

    test "refuses to roll for the side that is not to roll" do
      challenger_secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, challenger_secret))
      {:ok, _} = Log.accept(Store.get(game_id), as(@accepter, accepter_secret))

      assert {:error, :not_your_turn} =
               Log.roll(Store.get(game_id), as(@accepter, accepter_secret))
    end
  end

  describe "a turn" do
    test "publishes a play the fold accepts, with the roll both sides can recompute" do
      challenger_secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, challenger_secret))

      # Roll the opening out until one die is higher: ties re-roll, so this
      # is a loop over rounds rather than a fixed number of messages.
      game = roll_until_opener(game_id, challenger_secret, accepter_secret)

      dice = game.opener.dice
      [moves | _] = Engine.legal_plays(game.position, {List.first(dice), List.last(dice)})
      mover = game.mover
      secret = if mover == @challenger, do: challenger_secret, else: accepter_secret

      assert {:ok, _key} = Log.play(game, moves, as(mover, secret))

      after_turn = Store.get(game_id)
      assert after_turn.error == :none
      assert after_turn.turn_count == 1
      assert length(after_turn.history) == 1
      assert after_turn.mover != mover
    end

    test "refuses a play that is not the whole roll" do
      challenger_secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, challenger_secret))
      game = roll_until_opener(game_id, challenger_secret, accepter_secret)

      dice = game.opener.dice
      [partial | _] = Engine.legal_plays(game.position, {List.first(dice), List.last(dice)})
      shorter = Enum.drop(partial, -1)

      mover = game.mover
      secret = if mover == @challenger, do: challenger_secret, else: accepter_secret

      assert {:error, :illegal_moves} = Log.play(game, shorter, as(mover, secret))
      assert Store.get(game_id).turn_count == 0
    end

    test "accepts the play as the notation a reader would type" do
      challenger_secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, challenger_secret))
      game = roll_until_opener(game_id, challenger_secret, accepter_secret)

      dice = game.opener.dice
      [moves | _] = Engine.legal_plays(game.position, {List.first(dice), List.last(dice)})
      mover = game.mover
      secret = if mover == @challenger, do: challenger_secret, else: accepter_secret

      assert {:ok, _key} =
               Log.play(game, Notation.turn(moves), as(mover, secret))

      assert Store.get(game_id).turn_count == 1
    end
  end

  describe "closing a game" do
    test "withdraws a challenge nobody answered" do
      secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, secret))
      assert {:ok, _key} = Log.withdraw(Store.get(game_id), as(@challenger, secret))

      assert Store.get(game_id).status == :withdrawn
      assert {:error, :closed} = Log.withdraw(Store.get(game_id), as(@challenger, secret))
    end

    test "resigns a game in play, and the other player wins it" do
      challenger_secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, challenger_secret))
      game = roll_until_opener(game_id, challenger_secret, accepter_secret)

      mover = game.mover
      other = if mover == @challenger, do: @accepter, else: @challenger
      secret = if mover == @challenger, do: challenger_secret, else: accepter_secret

      assert {:ok, _key} = Log.resign(game, as(mover, secret))

      game = Store.get(game_id)
      assert game.status == :finished
      assert game.winner.player == other
    end
  end

  describe "the chain is recovered rather than kept" do
    test "the reveal in the challenge's first roll is the committed chain's" do
      secret = :crypto.strong_rand_bytes(32)
      accepter_secret = :crypto.strong_rand_bytes(32)

      {:ok, game_id, _} = Log.open(as(@challenger, secret))
      assert %{"commit" => commit} = published()

      {:ok, _} = Log.accept(Store.get(game_id), as(@accepter, accepter_secret))
      _accept = published()
      {:ok, _} = Log.roll(Store.get(game_id), as(@challenger, secret))

      roll = published()
      {:ok, revealed} = Game.unhex32(roll["r_cur"])

      # Neither the writer nor the reader ever stored this value: both derive
      # the chain from the secret, so the commitment made at the challenge is
      # what verifies the reveal years later, on any device.
      assert Game.hex(Chain.commit(revealed)) == commit
    end
  end

  # Play the opening out. Each round both sides roll; the higher single die
  # starts, and a tie rolls another round.
  defp roll_until_opener(game_id, challenger_secret, accepter_secret) do
    game = Store.get(game_id)

    if game.accepter == nil do
      {:ok, _} = Log.accept(game, as(@accepter, accepter_secret))
    end

    game = Store.get(game_id)

    cond do
      game.phase != :opening ->
        game

      game.mover == @challenger ->
        {:ok, _} = Log.roll(game, as(@challenger, challenger_secret))
        roll_until_opener(game_id, challenger_secret, accepter_secret)

      true ->
        {:ok, _} = Log.roll(game, as(@accepter, accepter_secret))
        roll_until_opener(game_id, challenger_secret, accepter_secret)
    end
  end
end
