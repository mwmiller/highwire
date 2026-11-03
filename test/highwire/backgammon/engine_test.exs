defmodule HighWire.Backgammon.EngineTest do
  use ExUnit.Case, async: true

  alias HighWire.Backgammon.Engine

  doctest Engine

  defp board(points, opts \\ []) do
    struct(Engine,
      points: points,
      bar: Keyword.get(opts, :bar, 0),
      opp_bar: Keyword.get(opts, :opp_bar, 0),
      off: Keyword.get(opts, :off, 0),
      opp_off: Keyword.get(opts, :opp_off, 0)
    )
  end

  describe "initial/0 and mirror/1" do
    test "initial position has the standard 15 checkers a side" do
      b = Engine.initial()
      assert Engine.checkers(b) == 15
      assert Engine.checkers(Engine.mirror(b)) == 15
    end

    test "initial board is symmetric under mirror" do
      assert Engine.mirror(Engine.initial()) == Engine.initial()
    end

    test "mirror is an involution" do
      b = board(%{4 => 2, 20 => -1, 1 => 1}, bar: 1, opp_bar: 3, off: 2, opp_off: 4)
      assert Engine.mirror(Engine.mirror(b)) == b
    end

    test "mirror flips signs, reverses points, and swaps bar/off counts" do
      b = board(%{4 => 2, 20 => -1}, bar: 1, off: 2)
      m = Engine.mirror(b)

      assert m.points == %{5 => 1, 21 => -2}
      assert m.bar == 0
      assert m.opp_bar == 1
      assert m.off == 0
      assert m.opp_off == 2
    end
  end

  describe "roll_dies/1" do
    test "plain rolls keep both dice" do
      assert Engine.roll_dies({3, 5}) == [3, 5]
      assert Engine.roll_dies({6, 1}) == [6, 1]
    end

    test "doubles expand to four dice" do
      assert Engine.roll_dies({5, 5}) == [5, 5, 5, 5]
    end
  end

  describe "moves_for/2 basics" do
    test "a lone checker grabs the single die move" do
      b = board(%{13 => 1})
      assert Engine.moves_for(b, 5) == [{13, 8}]
      assert Engine.moves_for(b, 6) == [{13, 7}]
    end

    test "regular moves step toward home and stop at 1" do
      b = board(%{24 => 2})
      assert Engine.moves_for(b, 6) == [{24, 18}]
    end

    test "every self checker on a high point produces its own die move" do
      b = board(%{8 => 2, 5 => 1})
      assert Engine.moves_for(b, 3) |> Enum.sort() == [{5, 2}, {8, 5}]
    end

    test "a single opponent checker may be hit" do
      b = board(%{8 => 1, 5 => -1})
      assert Engine.moves_for(b, 3) == [{8, 5}]
    end

    test "two or more opponent checkers block the landing" do
      b = board(%{8 => 1, 5 => -2})
      assert Engine.moves_for(b, 3) == []
    end
  end

  describe "bar entry" do
    test "while on the bar, only re-entries are legal" do
      b = board(%{8 => 1}, bar: 1)
      assert Engine.moves_for(b, 5) == [{:bar, 20}]
    end

    test "all dice must be entry dice even in the home board" do
      b = board(%{2 => 5}, bar: 1)
      assert Engine.moves_for(b, 6) == [{:bar, 19}]
      refute Enum.any?(Engine.moves_for(b, 6), &match?({2, :off}, &1))
    end

    test "entry is blocked by a made point" do
      b = board(%{24 => -2}, bar: 1)
      assert Engine.moves_for(b, 1) == []
    end

    test "hitting on entry puts the opponent on the opponent's bar" do
      b = board(%{19 => -1}, bar: 1)
      assert Engine.moves_for(b, 6) == [{:bar, 19}]
      after_move = Engine.apply_move(b, {:bar, 19})
      assert Engine.count(after_move, 19) == 1
      assert after_move.opp_bar == 1
    end
  end

  describe "bearing off" do
    test "cannot bear off while a checker is outside the home board" do
      b = board(%{2 => 5, 8 => 1})
      refute Engine.moves_for(b, 6) |> Enum.member?({2, :off})
      assert Engine.moves_for(b, 6) == [{8, 2}]
    end

    test "bears from the exact point with the matching die" do
      b = board(%{3 => 2, 1 => 1})
      assert Engine.moves_for(b, 3) |> Enum.member?({3, :off})
    end

    test "a die larger than any remaining checker still bears the lowest pieces" do
      b = board(%{2 => 2})
      assert Engine.moves_for(b, 6) == [{2, :off}]
    end

    test "highest usable point first" do
      b = board(%{5 => 1, 2 => 1})
      assert Engine.moves_for(b, 5) == [{5, :off}]
      assert Engine.moves_for(b, 6) == [{5, :off}]
    end

    test "a higher point the die cannot reach does not block a lower bear, but still moves" do
      b = board(%{5 => 1, 3 => 1})
      assert Engine.moves_for(b, 3) |> Enum.sort() == [{3, :off}, {5, 2}]
    end
  end

  describe "legal_plays/2" do
    test "every maximal play is realizable in some move order" do
      b = Engine.initial()

      for roll <- [{2, 5}, {4, 4}, {6, 1}, {3, 3}],
          play <- Engine.legal_plays(b, roll) do
        refute play == []
        assert Enum.any?(permutations(play), &Engine.legal_play?(b, roll, &1))
      end
    end

    test "doubles consume up to four dice" do
      b = board(%{6 => 4, 4 => 2, 2 => 1})
      assert Engine.legal_play?(b, {4, 4}, [{6, 2}, {6, 2}, {6, 2}, {6, 2}])
      refute Engine.legal_play?(b, {4, 4}, [{6, 2}, {6, 2}])
    end

    test "plays are canonical: no duplicates, all maximal" do
      b = Engine.initial()
      plays = Engine.legal_plays(b, {5, 6})

      assert length(plays) == Enum.uniq(plays) |> length()
      assert Enum.all?(plays, &Engine.legal_play?(b, {5, 6}, &1))
    end

    test "a play that consumes fewer dice than possible is not returned" do
      b = board(%{6 => 2, 3 => 1})
      refute [{6, 4}] in Engine.legal_plays(b, {2, 5})
      assert [{6, 1}, {6, 4}] in Engine.legal_plays(b, {2, 5})
    end
  end

  describe "legal_play?/3" do
    test "accepts a maximal play and rejects short or wrong moves" do
      b = board(%{6 => 2, 3 => 1})
      assert Engine.legal_play?(b, {2, 5}, [{6, 4}, {6, 1}])
      refute Engine.legal_play?(b, {2, 5}, [{6, 4}])
      refute Engine.legal_play?(b, {2, 5}, [])
    end

    test "a move whose implied die is not in the roll is rejected" do
      b = board(%{8 => 1})
      assert Engine.legal_play?(b, {2, 5}, [{8, 6}, {6, 1}])
      refute Engine.legal_play?(b, {2, 5}, [{8, 2}])
    end

    test "an impossible or malformed move is rejected" do
      b = board(%{8 => 1})
      refute Engine.legal_play?(b, {2, 5}, [{9, 7}])
      refute Engine.legal_play?(b, {2, 5}, [{8, 3, 2}])
      refute Engine.legal_play?(b, {2, 5}, [{8, 8}])
    end

    test "ordering matters when early moves change the board" do
      # Hitting a blot makes a later move legal that would not be beforehand.
      b = board(%{13 => 1, 8 => -1})
      refute Engine.legal_play?(b, {5, 5}, [{13, 8}, {13, 8}])
    end

    test "stand is legal exactly when nothing can move" do
      b = board(%{2 => 1}, bar: 1)
      refute Engine.legal_play?(b, {6, 1}, [])

      # Barred out: every re-entry point is a made opponent point.
      locked = board(%{19 => -2, 20 => -2, 21 => -2, 22 => -2, 23 => -2, 24 => -2}, bar: 2)

      assert Engine.legal_play?(locked, {6, 1}, [])
    end
  end

  describe "mirror round-trip after playing a turn" do
    test "a full turn mirrors to an equal board from the other side" do
      b = board(%{13 => 1, 5 => -1})
      play = [{13, 8}, {8, 7}]
      assert Engine.legal_play?(b, {5, 1}, play)

      after_self = Enum.reduce(play, b, &Engine.apply_move(&2, &1))
      m = Engine.mirror(after_self)

      assert Engine.checkers(after_self) == Engine.checkers(m)
      assert Engine.mirror(m) == after_self
      assert m.points == %{18 => -1, 20 => 1}
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for head <- list,
        tail <- permutations(List.delete(list, head)) do
      [head | tail]
    end
  end
end
