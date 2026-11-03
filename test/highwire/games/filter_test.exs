defmodule HighWire.Games.FilterTest do
  use ExUnit.Case, async: true

  alias HighWire.Games.Filter

  @now System.system_time(:millisecond)
  @hour 60 * 60 * 1000
  @day 24 * @hour
  @year 365 * @day

  defp game(overrides \\ []) do
    Map.merge(
      %{
        game_id: "g",
        kind: :chess,
        status: :finished,
        white: "@a=.ed25519",
        black: "@b=.ed25519",
        history: [],
        turn_count: 20,
        updated_at: @now - @hour
      },
      Map.new(overrides)
    )
  end

  defp viewer(overrides \\ []) do
    Map.merge(%{self_id: "@me=.ed25519", follows: [], played: []}, Map.new(overrides))
  end

  describe "what a game is" do
    test "each facet names the game's place in the room" do
      # Who it is about, from the sharpest relation to the bluntest.
      assert Filter.facets_of(game(white: "@me=.ed25519"), viewer()).who == :mine

      assert Filter.facets_of(
               game(white: "@friend=.ed25519"),
               viewer(played: ["@friend=.ed25519"])
             ).who ==
               :played

      assert Filter.facets_of(
               game(white: "@friend=.ed25519"),
               viewer(follows: ["@friend=.ed25519"])
             ).who == :followed

      assert Filter.facets_of(game(), viewer()).who == :strangers

      # Length is plies, which is what a game is; rows would count two moves
      # as one.
      assert Filter.facets_of(game(turn_count: 6), viewer()).length == :short
      assert Filter.facets_of(game(turn_count: 20), viewer()).length == :medium
      assert Filter.facets_of(game(turn_count: 80), viewer()).length == :long
      assert Filter.facets_of(game(turn_count: 0), viewer()).length == :unknown

      # Age comes off the last move, not the challenge.
      assert Filter.facets_of(game(updated_at: @now - @hour), viewer()).age == :today
      assert Filter.facets_of(game(updated_at: @now - 3 * @day), viewer()).age == :week
      assert Filter.facets_of(game(updated_at: @now - 3 * @year), viewer()).age == :older
    end
  end

  describe "narrowing" do
    test "every facet that asks for something has to match, and any does not narrow" do
      long_and_old = game(turn_count: 80, updated_at: @now - 3 * @year)
      short_and_new = game(game_id: "new", turn_count: 4, updated_at: @now - @hour)

      games = [long_and_old, short_and_new]

      assert Filter.apply(games, viewer(), %{}) |> Enum.map(& &1.game_id) == ["g", "new"]
      assert Filter.apply(games, viewer(), %{length: :long}) |> Enum.map(& &1.game_id) == ["g"]
      assert Filter.apply(games, viewer(), %{length: :long, age: :today}) == []

      both_kinds = [game(), game(game_id: "other", kind: :backgammon)]

      assert Filter.apply(both_kinds, viewer(), %{kind: :any}) |> length() == 2

      assert Filter.apply(both_kinds, viewer(), %{kind: :backgammon})
             |> Enum.map(& &1.game_id) == ["other"]
    end
  end

  describe "titles" do
    test "periods and results wear the words the room groups by" do
      assert Filter.period(game(updated_at: @now - @hour)) == "Today"
      assert Filter.period(game(updated_at: @now - 3 * @year)) == "Older"
      assert Filter.period(game(updated_at: nil)) == "Undated"

      assert Filter.result(game(verdict: {:checkmate, :white})) == "Checkmate"
      assert Filter.result(game(status: :playing)) == "Unfinished"
      assert Filter.result(game(status: :broken)) == "Does not verify"
      assert Filter.result(game(status: :withdrawn)) == "Withdrawn"
    end
  end
end
