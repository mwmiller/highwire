defmodule HighWireWeb.GamesLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.Backgammon.{Chain, Game, Store}
  alias HighWire.Chess

  setup do
    Store.clear()
    Chess.Store.clear()
    :ok
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp envelope(author, content, key) do
    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end

  defp seed_game do
    spec = %{"length" => 8}
    game_id = Game.new_id()
    chall = Chain.generate(:crypto.strong_rand_bytes(32), spec)
    accept = Chain.generate(:crypto.strong_rand_bytes(32), spec)
    challenger = "@challenger.ed25519"
    accepter = "@accepter.ed25519"

    Store.ingest(
      envelope(
        challenger,
        Game.challenge(game_id, hex(Chain.commit(chall))),
        "%challenge.sha256"
      )
    )

    Store.ingest(
      envelope(
        accepter,
        Game.accept(
          game_id,
          "%challenge.sha256",
          hex(Chain.commit(accept)),
          hex(List.last(accept))
        ),
        "%accept.sha256"
      )
    )

    game_id
  end

  test "the gameroom starts empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/games")

    assert html =~ "Gameroom"
    assert html =~ "No games yet"
  end

  test "a paired game appears in the gameroom", %{conn: conn} do
    seed_game()

    {:ok, _view, html} = live(conn, "/games")

    refute html =~ "No games yet"
    assert html =~ "opening"
    assert html =~ "turn 0"
  end

  test "one game opens on its own board", %{conn: conn} do
    game_id = seed_game()

    {:ok, _view, html} = live(conn, "/games/#{game_id}")

    assert html =~ "History"
    assert html =~ "No turns played yet"
    assert html =~ "mover&#39;s view"
  end

  defp seed_chess do
    game_id = Chess.Game.new_id()
    challenger = "@challenger.ed25519"
    accepter = "@accepter.ed25519"

    Chess.Store.ingest(envelope(challenger, Chess.Game.challenge(game_id, "white"), "%c1.sha256"))
    Chess.Store.ingest(envelope(accepter, Chess.Game.accept(game_id, "%c1.sha256"), "%c2.sha256"))

    Chess.Store.ingest(
      envelope(challenger, Chess.Game.move(game_id, "%c1.sha256", 1, "e2e4"), "%c3.sha256")
    )

    Chess.Store.ingest(
      envelope(accepter, Chess.Game.move(game_id, "%c1.sha256", 2, "e7e5"), "%c4.sha256")
    )

    game_id
  end

  test "a chess game sits in the same gameroom", %{conn: conn} do
    seed_chess()

    {:ok, _view, html} = live(conn, "/games")

    refute html =~ "No games yet"
    assert html =~ "1. move"
  end

  test "a chess game opens on its own board with its moves", %{conn: conn} do
    game_id = seed_chess()

    {:ok, _view, html} = live(conn, "/games/#{game_id}")

    assert html =~ "Moves"
    assert html =~ "e4"
    assert html =~ "e5"
    assert html =~ "in play"
    # The board draws pieces, both sides, from the folded squares.
    assert html =~ "♙"
    assert html =~ "♟"
  end

  test "a chess game that does not verify says so", %{conn: conn} do
    game_id = Chess.Game.new_id()
    challenger = "@challenger.ed25519"
    accepter = "@accepter.ed25519"

    Chess.Store.ingest(envelope(challenger, Chess.Game.challenge(game_id, "white"), "%d1.sha256"))
    Chess.Store.ingest(envelope(accepter, Chess.Game.accept(game_id, "%d1.sha256"), "%d2.sha256"))

    Chess.Store.ingest(
      envelope(accepter, Chess.Game.move(game_id, "%d1.sha256", 1, "e7e5"), "%d3.sha256")
    )

    {:ok, _view, html} = live(conn, "/games/#{game_id}")

    assert html =~ "does not verify"
    assert html =~ "out of turn"
  end

  test "an unknown game says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/games/" <> String.duplicate("ab", 32))

    assert html =~ "No game with that id"
  end
end
