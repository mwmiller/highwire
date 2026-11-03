defmodule HighWireWeb.GamesLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.Backgammon.{Chain, Game, Store}

  setup do
    Store.clear()
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

  test "an unknown game says so", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/games/" <> String.duplicate("ab", 32))

    assert html =~ "No game with that id"
  end
end
