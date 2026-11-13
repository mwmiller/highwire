defmodule HighWire.Backgammon.FoldTest do
  use ExUnit.Case, async: true

  alias HighWire.Backgammon.{Chain, Engine, Fold, Game, Notation}

  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp short_spec, do: %{"length" => 8}

  defp fold(game, entries, accept_reveal) do
    Fold.fold_game(game, %{entries: entries, accept_reveal: accept_reveal, spec: short_spec()})
  end

  defp next_reveals(chain, remaining), do: Chain.reveal_pair(chain, remaining)

  defp new_roll(player, round, reveals, r_cur, r_next) do
    %{
      "type" => "roll",
      "player" => player,
      "round" => round,
      "reveals" => reveals,
      "r_cur" => hex(r_cur),
      "r_next" => hex(r_next)
    }
  end

  defp new_turn(player, turn, reveals, r_cur, r_next, moves, opp_half) do
    [d1, d2] = Chain.dice(r_cur, opp_half)

    %{
      "type" => "turn",
      "player" => player,
      "turn" => turn,
      "roll" => Game.roll_string(d1, d2),
      "moves" => Notation.turn(moves),
      "r_cur" => hex(r_cur),
      "r_next" => hex(r_next),
      "reveals" => reveals
    }
  end

  # A two-turn game: the opening round resolves for the challenger, who then
  # plays turn 1 with the opener dice and the accepter answers at turn 2.
  # Both chains are real, so every reveal verifies against its commitment.
  defp two_turn_game do
    len = short_spec()["length"]

    {chall, accept} =
      Enum.reduce_while(Stream.repeatedly(fn -> :next end), nil, fn _, _ ->
        chall = Chain.generate(:crypto.strong_rand_bytes(32), short_spec())
        accept = Chain.generate(:crypto.strong_rand_bytes(32), short_spec())

        {c0, c0_next} = next_reveals(chall, len)
        {a0, _} = next_reveals(accept, len - 1)

        dc = Chain.dice(c0, List.last(accept), 1) |> hd()
        da = Chain.dice(a0, c0_next, 1) |> hd()

        if dc > da, do: {:halt, {chall, accept}}, else: {:cont, nil}
      end)

    accept_reveal = List.last(accept)
    challenger = "@challenger.ed25519"
    accepter = "@accepter.ed25519"

    game = %{
      challenger: challenger,
      accepter: accepter,
      game_id: hex(:crypto.strong_rand_bytes(32)),
      challenge_commit: hex(Chain.commit(chall)),
      accept_commit: hex(Chain.commit(accept))
    }

    {c0_cur, c0_next} = next_reveals(chall, len)
    {a0_cur, a0_next} = next_reveals(accept, len - 1)
    d_c = Chain.dice(c0_cur, accept_reveal, 1) |> hd()
    d_a = Chain.dice(a0_cur, c0_next, 1) |> hd()
    true = d_c > d_a

    r0c = new_roll(challenger, 0, len, c0_cur, c0_next)
    r0a = new_roll(accepter, 0, len - 1, a0_cur, a0_next)

    {c1_cur, c1_next} = next_reveals(chall, len - 2)
    {a2_cur, a2_next} = next_reveals(accept, len - 3)

    play1 = Engine.legal_plays(Engine.initial(), {d_c, d_a}) |> hd()
    pos2 = Engine.mirror(Engine.apply(Engine.initial(), play1))

    [d2a, d2b] = Chain.dice(a2_cur, c1_next)
    play2 = Engine.legal_plays(pos2, {d2a, d2b}) |> hd()

    turn1 =
      new_turn(challenger, 1, len - 2, c1_cur, c1_next, play1, a0_next)
      |> Map.put("roll", Game.roll_string(d_c, d_a))

    turn2 = new_turn(accepter, 2, len - 3, a2_cur, a2_next, play2, c1_next)

    %{
      game: game,
      accept_reveal: hex(accept_reveal),
      entries: %{challenger => [r0c, turn1], accepter => [r0a, turn2]},
      pos2: pos2,
      play2: play2,
      turn1_roll: Game.roll_string(d_c, d_a)
    }
  end

  describe "folding play" do
    test "folds a legal two-turn game into position, history and mover" do
      %{game: game, accept_reveal: accept_reveal, entries: entries, pos2: pos2, play2: play2} =
        two_turn_game()

      folded = fold(game, entries, accept_reveal)

      assert folded.error == :none
      assert folded.phase == :playing
      assert folded.turn_count == 2
      assert folded.mover == game.challenger
      assert folded.opener.starter == game.challenger
      assert folded.position == Engine.mirror(Engine.apply(pos2, play2))

      assert [first, second] = folded.history
      assert first.player == game.challenger
      assert first.turn == 1
      assert second.player == game.accepter
      assert second.turn == 2
      assert length(first.frames) == length(Notation.parse(first.moves)) + 1
    end
  end

  describe "reveals and authorship" do
    test "the reveal counters step down two per entry" do
      %{game: game, accept_reveal: accept_reveal, entries: entries} = two_turn_game()

      folded = fold(game, entries, accept_reveal)

      assert folded.remaining[game.challenger] == 8 - 4
      assert folded.remaining[game.accepter] == 7 - 4
    end

    test "a forged reveal stops the fold with a chain violation" do
      %{game: game, accept_reveal: accept_reveal, entries: entries} = two_turn_game()

      forged =
        Map.update!(entries, game.challenger, fn [roll, turn] ->
          [roll, %{turn | "r_cur" => hex(:crypto.strong_rand_bytes(32))}]
        end)

      folded = fold(game, forged, accept_reveal)

      assert folded.error =~ "chain violation"
      assert folded.turn_count == 0
    end

    test "an entry claiming the wrong author stops the fold" do
      %{game: game, accept_reveal: accept_reveal, entries: entries} = two_turn_game()

      # Turn 2 is the accepter's; the challenger tries to play it again, and
      # the accepter's real turn 2 is dropped so authorship is the only
      # thing wrong with the entry.
      twice = %{
        "type" => "turn",
        "player" => game.challenger,
        "turn" => 2,
        "roll" => "3-1",
        "moves" => "13/10 13/12",
        "reveals" => 5,
        "r_cur" => nil,
        "r_next" => nil
      }

      impostor =
        entries
        |> Map.update!(game.challenger, &(&1 ++ [twice]))
        |> Map.update!(game.accepter, fn [roll, _turn] -> [roll] end)

      folded = fold(game, impostor, accept_reveal)

      assert folded.error =~ "turn 2 authored by"
    end
  end

  describe "the opening" do
    test "a game with no entries folds to the opening position" do
      %{game: game} = two_turn_game()

      folded = Fold.fold_game(game, %{entries: %{}, spec: short_spec()})

      assert folded.error == :none
      assert folded.phase == :opening
      assert folded.turn_count == 0
      assert folded.mover == game.challenger
      assert folded.position == Engine.initial()
    end
  end

  describe "bad input" do
    test "a malformed game id is reported, not raised" do
      folded = Fold.fold_game(%{game_id: "nope"}, %{entries: %{}})

      assert folded.error == "unreadable game id"
    end
  end
end
