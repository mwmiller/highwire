defmodule HighWire.Games.InterestTest do
  use ExUnit.Case, async: true

  alias HighWire.Games.Interest
  alias HighWire.SSB.Profile

  @now System.system_time(:millisecond)

  setup do
    # A named feed and a feed with nothing written about it, so `faces/1` has
    # something to tell apart.
    for {id, name} <- [
          {"@followed=.ed25519", "Followed"},
          {"@played=.ed25519", "Played"},
          {"@other=.ed25519", "Other"}
        ] do
      Profile.put_about(id, %{"name" => name})
    end

    :ok
  end

  defp game(overrides) do
    Map.merge(
      %{
        game_id: "g",
        kind: :chess,
        status: :finished,
        white: "@followed=.ed25519",
        black: "@other=.ed25519",
        history: [],
        turn_count: 10,
        updated_at: @now
      },
      Map.new(overrides)
    )
  end

  defp viewer(overrides \\ []) do
    Map.merge(%{self_id: "@me=.ed25519", follows: [], played: []}, Map.new(overrides))
  end

  test "a game with someone you follow outranks one between strangers" do
    followed = game(%{game_id: "followed"})
    strangers = game(%{game_id: "strangers", white: "@other=.ed25519"})

    assert Interest.score(followed, viewer(follows: ["@followed=.ed25519"])).score >
             Interest.score(strangers, viewer(follows: ["@followed=.ed25519"])).score

    assert Interest.score(followed, viewer(follows: ["@followed=.ed25519"])).reasons == [
             "you follow them"
           ]
  end

  test "someone you have played outweighs someone you only follow" do
    played = game(%{game_id: "played", white: "@played=.ed25519"})
    followed = game(%{game_id: "followed", white: "@followed=.ed25519"})

    viewer =
      viewer(
        follows: ["@played=.ed25519", "@followed=.ed25519"],
        played: ["@played=.ed25519"]
      )

    assert Interest.score(played, viewer).score > Interest.score(followed, viewer).score
    assert "you have played them" in Interest.score(played, viewer).reasons
  end

  test "a game left mid-move years ago is not live" do
    stale = game(%{status: :playing, updated_at: @now - 5 * 365 * 24 * 60 * 60 * 1000})
    fresh = game(%{game_id: "fresh", status: :playing, white: "@other=.ed25519"})

    assert Interest.score(fresh, viewer()).score > Interest.score(stale, viewer()).score
  end

  test "a game whose log does not verify ranks below one that does" do
    broken = game(%{game_id: "broken", status: :broken, verdict: nil})
    clean = game(%{game_id: "clean", white: "@other=.ed25519"})

    assert Interest.score(clean, viewer()).score > Interest.score(broken, viewer()).score
  end

  test "players with no name and no picture score below two with faces" do
    named = game(%{game_id: "named"})
    faceless = game(%{game_id: "faceless", white: "@blank=.ed25519", black: "@blank2=.ed25519"})

    assert Interest.score(named, viewer()).score > Interest.score(faceless, viewer()).score
  end

  test "a checkmate beats an abandoned game of the same shape" do
    mate = game(%{game_id: "mate", verdict: {:checkmate, :black}})
    open = game(%{game_id: "open", white: "@other=.ed25519", status: :withdrawn})

    assert Interest.score(mate, viewer()).score > Interest.score(open, viewer()).score
  end

  test "rank puts the most interesting first and says why" do
    followed = game(%{game_id: "followed"})
    stranger = game(%{game_id: "stranger", white: "@other=.ed25519", updated_at: @now - 1_000})

    ranked = Interest.rank([stranger, followed], viewer(follows: ["@followed=.ed25519"]))

    assert Enum.map(ranked, & &1.game_id) == ["followed", "stranger"]
    assert hd(ranked).interest.reasons == ["you follow them"]
    assert List.last(ranked).interest.reasons == []
  end

  test "a viewer who follows nobody still gets a usable order" do
    old = game(%{game_id: "old", updated_at: @now - 30 * 24 * 60 * 60 * 1000})
    new = game(%{game_id: "new", white: "@other=.ed25519"})

    assert Enum.map(Interest.rank([old, new], viewer()), & &1.game_id) == ["new", "old"]
  end
end
