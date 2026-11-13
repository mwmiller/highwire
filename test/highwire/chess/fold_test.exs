defmodule HighWire.Chess.FoldTest do
  use ExUnit.Case, async: true

  alias HighWire.Chess.Fold

  @challenger "@challenger.ed25519"
  @accepter "@accepter.ed25519"

  defp game(overrides \\ %{}) do
    Map.merge(
      %{
        game_id: String.duplicate("a", 64),
        challenger: @challenger,
        accepter: @accepter,
        challenger_color: "white"
      },
      overrides
    )
  end

  defp entry(player, ply, uci, note \\ nil) do
    %{"type" => "move", "player" => player, "ply" => ply, "uci" => uci, "note" => note}
  end

  defp resign(player, ply) do
    %{"type" => "resign", "player" => player, "ply" => ply}
  end

  defp fold(entries, game \\ game()) do
    Fold.fold_game(game, %{
      entries: %{
        @challenger => Enum.filter(entries, &(&1["player"] == @challenger)),
        @accepter => Enum.filter(entries, &(&1["player"] == @accepter))
      }
    })
  end

  describe "a game before it starts" do
    test "an unaccepted challenge is a game in the opening" do
      folded = Fold.fold_game(%{game() | accepter: nil})

      assert folded.phase == :opening
      assert folded.mover == @challenger
      assert folded.history == []
      assert folded.error == :none
      assert folded.turn == :white
    end

    test "an accepted game with no moves waits on white" do
      folded = fold([])

      assert folded.phase == :playing
      assert folded.mover == @challenger
      assert folded.turn_count == 0
      assert folded.board["e2"] == {:pawn, :white}
      assert folded.board["e7"] == {:pawn, :black}
    end
  end

  describe "folding moves" do
    test "a legal sequence folds into the position it produces" do
      folded =
        fold([
          entry(@challenger, 1, "e2e4"),
          entry(@accepter, 2, "e7e5"),
          entry(@challenger, 3, "g1f3")
        ])

      assert folded.error == :none
      assert folded.turn_count == 3
      assert folded.turn == :black
      assert folded.mover == @accepter
      assert folded.board["e4"] == {:pawn, :white}
      assert folded.board["g1"] == nil
      assert folded.board["f3"] == {:knight, :white}
      assert Enum.map(folded.history, & &1.san) == ["e4", "e5", "Nf3"]
      assert folded.verdict == :playing
    end

    test "the challenger's colour decides which side they are" do
      folded =
        fold(
          [entry(@accepter, 1, "e2e4"), entry(@challenger, 2, "e7e5")],
          game(%{challenger_color: "black"})
        )

      assert folded.error == :none
      assert folded.white == @accepter
      assert folded.black == @challenger
      assert folded.turn == :white
      assert folded.mover == @accepter
    end

    test "notes ride along with the move they were written on" do
      folded = fold([entry(@challenger, 1, "e2e4", "your move")])

      assert folded.last_note == "your move"
      assert hd(folded.history).note == "your move"
    end
  end

  describe "a move the fold cannot accept" do
    test "a move out of turn breaks the fold" do
      folded = fold([entry(@accepter, 1, "e7e5")])

      assert folded.error =~ "out of turn"
      assert folded.turn_count == 0
    end

    test "a skipped ply breaks the fold" do
      folded = fold([entry(@challenger, 2, "e2e4")])

      assert folded.error =~ "ply 2 arrived where 1 was due"
    end

    test "a repeated ply breaks the fold" do
      folded = fold([entry(@challenger, 1, "e2e4"), entry(@challenger, 1, "d2d4")])

      assert folded.error =~ "ply 1 arrived where 2 was due"
    end

    test "an illegal move breaks the fold rather than the game" do
      folded = fold([entry(@challenger, 1, "e2e5")])

      assert folded.error =~ "not a legal move"
      assert folded.turn_count == 0
    end
  end

  describe "the end of a game" do
    test "checkmate ends the game with a winner" do
      folded =
        fold([
          entry(@challenger, 1, "f2f3"),
          entry(@accepter, 2, "e7e5"),
          entry(@challenger, 3, "g2g4"),
          entry(@accepter, 4, "d8h4")
        ])

      assert folded.phase == :finished
      assert folded.winner == %{player: @accepter, reason: :checkmate}
      assert folded.verdict == {:checkmate, :black}
      assert folded.history |> List.last() |> Map.fetch!(:san) == "Qh4#"
    end

    test "a resignation gives the game to the other player" do
      folded =
        fold([
          entry(@challenger, 1, "e2e4"),
          resign(@accepter, 2)
        ])

      assert folded.phase == :finished
      assert folded.winner == %{player: @challenger, reason: :resign}
      assert folded.history |> List.last() |> Map.fetch!(:type) == "resign"
    end
  end
end
