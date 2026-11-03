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
    Map.merge(
      %{self_id: "@me=.ed25519", follows: [], played: []},
      Map.new(overrides)
    )
  end

  test "who a game is about: yours, played, followed, or strangers" do
    assert Filter.facets_of(game(white: "@me=.ed25519"), viewer()).who == :mine

    assert Filter.facets_of(game(white: "@friend=.ed25519"), viewer(played: ["@friend=.ed25519"])).who ==
             :played

    assert Filter.facets_of(
             game(white: "@friend=.ed25519"),
             viewer(follows: ["@friend=.ed25519"])
           ).who ==
             :followed

    assert Filter.facets_of(game(), viewer()).who == :strangers
  end

  test "length is measured in plies, not in rows" do
    assert Filter.facets_of(game(turn_count: 6), viewer()).length == :short
    assert Filter.facets_of(game(turn_count: 20), viewer()).length == :medium
    assert Filter.facets_of(game(turn_count: 80), viewer()).length == :long
    assert Filter.facets_of(game(turn_count: 0), viewer()).length == :unknown
  end

  test "age is read off the last move" do
    assert Filter.facets_of(game(updated_at: @now - @hour), viewer()).age == :today
    assert Filter.facets_of(game(updated_at: @now - 3 * @day), viewer()).age == :week
    assert Filter.facets_of(game(updated_at: @now - 3 * 365 * @day), viewer()).age == :older
  end

  test "every facet that asks for something has to match" do
    long_and_old = game(turn_count: 80, updated_at: @now - 3 * @year)
    short_and_new = game(game_id: "new", turn_count: 4, updated_at: @now - @hour)

    games = [long_and_old, short_and_new]

    assert Filter.apply(games, viewer(), %{}) |> Enum.map(& &1.game_id) == ["g", "new"]

    assert Filter.apply(games, viewer(), %{length: :long}) |> Enum.map(& &1.game_id) == ["g"]

    assert Filter.apply(games, viewer(), %{length: :long, age: :today}) == []
  end

  test "a facet set to any does not narrow" do
    games = [game(), game(game_id: "other", kind: :backgammon)]

    assert Filter.apply(games, viewer(), %{kind: :any}) |> length() == 2

    assert Filter.apply(games, viewer(), %{kind: :backgammon}) |> Enum.map(& &1.game_id) == [
             "other"
           ]
  end

  test "periods and results wear the titles the room groups by" do
    assert Filter.period(game(updated_at: @now - @hour)) == "Today"
    assert Filter.period(game(updated_at: @now - 3 * @year)) == "Older"
    assert Filter.period(game(updated_at: nil)) == "Undated"

    assert Filter.result(game(verdict: {:checkmate, :white})) == "Checkmate"
    assert Filter.result(game(status: :playing)) == "Unfinished"
    assert Filter.result(game(status: :broken)) == "Does not verify"
    assert Filter.result(game(status: :withdrawn)) == "Withdrawn"
  end
end
