defmodule HighWireWeb.GamesLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.Backgammon.{Chain, Game, Store}
  alias HighWire.Chess
  alias HighWire.Games.Catalog

  setup do
    Store.clear()
    Chess.Store.clear()
    Chess.Legacy.Store.clear()
    Catalog.clear()
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

  test "the room offers to open a game on either side", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/games")

    assert html =~ "new chess game as"
    assert html =~ "phx-value-color=\"white\""
    assert html =~ "phx-value-color=\"black\""
  end

  test "accepting a challenge publishes it and joins the game", %{conn: conn} do
    game_id = seed_chess_unaccepted()
    stub_publisher()

    {:ok, view, _html} = live(conn, "/games")

    view |> element("button[phx-value-id='#{game_id}']", "accept") |> render_click()

    # The store folded the accept the stub filed, so the card moved on from
    # waiting to the opening position with both players on it.
    game = Chess.Store.get(game_id)
    assert game.accepter == "@accepter.ed25519"
    assert game.status == :playing
  end

  test "a board you cannot move in takes no clicks", %{conn: conn} do
    game_id = seed_chess()

    {:ok, _view, html} = live(conn, "/games/#{game_id}")

    refute html =~ "phx-click=\"square\""
    refute html =~ "resign"
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

  test "a challenge with no opponent is a game to take, not one to watch", %{conn: conn} do
    seed_chess_unaccepted()

    {:ok, view, html} = live(conn, "/games")

    assert html =~ "Open games"
    assert view |> element("button", "accept") |> has_element?()
    refute html =~ "Spectate"
  end

  test "a game already paired is one to watch", %{conn: conn} do
    seed_chess()

    {:ok, _view, html} = live(conn, "/games")

    assert html =~ "Spectate"
    refute html =~ "Open games"
  end

  test "a game's moves are listed in numbered pairs", %{conn: conn} do
    game_id = seed_chess()

    {:ok, _view, html} = live(conn, "/games/#{game_id}")

    assert html =~ "1."
    assert html =~ "e4"
    assert html =~ "e5"
  end

  test "stepping back shows the position the game came from", %{conn: conn} do
    game_id = seed_chess()

    {:ok, view, html} = live(conn, "/games/#{game_id}")
    refute html =~ "Showing the position after move"

    html = view |> element("button[phx-value-to='first']") |> render_click()
    assert html =~ "Showing the position after move 0 of 2"

    # The board is a picture of an earlier position, so it takes no clicks.
    refute html =~ ~s(phx-click="square")

    # Two ways back to the end of the line: the transport's last button and
    # the chip that appears once you have stepped away from it.
    html = view |> element("button[title='The latest position']") |> render_click()
    refute html =~ "Showing the position after move"
  end

  test "a move in the list jumps to the position it made", %{conn: conn} do
    game_id = seed_chess()

    {:ok, view, _html} = live(conn, "/games/#{game_id}")

    html = view |> element("button[phx-value-to='1']") |> render_click()
    assert html =~ "Showing the position after move 1 of 2"
  end

  test "playing the game back walks the line a ply at a time and stops at the end", %{conn: conn} do
    game_id = seed_chess()

    {:ok, view, html} = live(conn, "/games/#{game_id}")

    refute html =~ "Stop playing back"

    html = view |> element("button[title='Play the game from here']") |> render_click()
    assert html =~ "Stop playing back"
    assert html =~ "Looking back at move 0 of 2"

    send(view.pid, :tick)
    assert render(view) =~ "Looking back at move 1 of 2"

    # The last position is the live one, so reaching it ends playback rather
    # than leaving the reader pinned to a copy of the board.
    send(view.pid, :tick)
    html = render(view)
    refute html =~ "Looking back at move"
    refute html =~ "Stop playing back"
  end

  test "a move arriving while the game is being looked back keeps the reader's place", %{
    conn: conn
  } do
    game_id = seed_chess()

    {:ok, view, _html} = live(conn, "/games/#{game_id}")
    view |> element("button[phx-value-to='first']") |> render_click()

    Chess.Store.ingest(
      envelope(challenger(), Chess.Game.move(game_id, "%c1.sha256", 3, "b1c3"), "%c5.sha256")
    )

    assert render(view) =~ "Looking back at move 0 of 3"
  end

  test "a log that stops verifying keeps the moves before the break", %{conn: conn} do
    # The network's own games arrive with their moves already written down,
    # so a ply this node cannot follow is found on the way through the log
    # rather than refused at the door.
    game_id =
      seed_legacy([
        {1, "e2", "e4", "e4"},
        {2, "e7", "e5", "e5"},
        {3, "e2", "e4", "e4"}
      ])

    {:ok, view, html} = live(conn, "/games/#{game_id}")

    assert html =~ "The log stops verifying at move 3"
    assert html =~ ~r/runs as far as\s+move 2/

    html = view |> element("button[phx-value-to='1']") |> render_click()
    assert html =~ "Looking back at move 1 of 2"
  end

  test "a game can be walked to the next one without going back to the room", %{conn: conn} do
    first = seed_chess()
    second = seed_chess_unaccepted()

    # The room's order is the catalog's, so open the newest and expect the
    # other to be one step away from it.
    [newest | _] = Catalog.recent(10) |> Enum.map(fn {_kind, id} -> id end)
    other = Enum.find([first, second], &(&1 != newest))

    {:ok, _view, html} = live(conn, "/games/#{newest}")

    assert html =~ "/games/#{other}"
  end

  test "one game opens on its own board", %{conn: conn} do
    game_id = seed_game()

    {:ok, _view, html} = live(conn, "/games/#{game_id}")

    assert html =~ "History"
    assert html =~ "No turns played yet"
    assert html =~ "mover&#39;s view"
  end

  # A publisher standing in for the engine: it files what it was handed so
  # the store can fold it, exactly as the tail would when the message comes
  # back from the network.
  defp stub_publisher do
    previous = Application.get_env(:highwire, :game_publisher)

    Application.put_env(:highwire, :game_publisher, fn content ->
      key = "%stub-#{System.unique_integer([:positive])}.sha256"

      Chess.Store.ingest(%{
        "key" => key,
        "value" => %{"author" => "@accepter.ed25519", "content" => content}
      })

      {:ok, key}
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :game_publisher, previous),
        else: Application.delete_env(:highwire, :game_publisher)
    end)
  end

  defp seed_chess_unaccepted do
    game_id = Chess.Game.new_id()

    Chess.Store.ingest(
      envelope("@challenger.ed25519", Chess.Game.challenge(game_id, "white"), "%e1.sha256")
    )

    game_id
  end

  defp challenger, do: "@challenger.ed25519"

  defp seed_chess do
    game_id = Chess.Game.new_id()
    challenger = challenger()
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

  # A game in the network's own format, as the timeline files it: one row per
  # move, naming the game it belongs to and the ply it was played as.
  defp seed_legacy(moves, opts \\ []) do
    bytes = :binary.copy(<<Keyword.get(opts, :byte, 0xAB)>>, 32)
    ts = Keyword.get(opts, :ts, 1_000)
    root = "%" <> Base.encode64(bytes) <> ".sha256"

    for move <- moves do
      {ply, orig, dest, san, fen} =
        case move do
          {ply, orig, dest, san} -> {ply, orig, dest, san, nil}
          {ply, orig, dest, san, fen} -> {ply, orig, dest, san, fen}
        end

      HighWire.Chess.Legacy.Store.ingest(%{
        "key" => "%m#{ply}.sha256",
        "value" => %{
          "author" => "@legacy.ed25519",
          "timestamp" => ts + ply,
          "content" => %{
            "type" => "chess_move",
            "root" => root,
            "ply" => ply,
            "orig" => orig,
            "dest" => dest,
            "pgnMove" => san,
            "fen" => fen
          }
        }
      })
    end

    Base.encode16(bytes, case: :lower)
  end

  test "the room puts the game most worth watching first", %{conn: conn} do
    now = System.system_time(:millisecond)
    moves = [{1, "e2", "e4", "e4"}, {2, "e7", "e5", "e5"}]

    stale = seed_legacy(moves, byte: 0xAB, ts: now - 5 * 365 * 24 * 60 * 60 * 1000)
    fresh = seed_legacy(moves, byte: 0xCD, ts: now - 60_000)

    {:ok, _view, html} = live(conn, "/games")

    fresh_at = :binary.match(html, fresh) |> elem(0)
    stale_at = :binary.match(html, stale) |> elem(0)

    assert fresh_at < stale_at
  end

  test "a network game is stepped through from the positions it published", %{conn: conn} do
    # Our engine would refuse a4b3 here — there is no black king on a4 after
    # 1. e4 — but the game published the position it reached, and a game this
    # node does not own is its own authority on where its pieces stood.
    game_id =
      seed_legacy([
        {1, "e2", "e4", "e4", "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"},
        {2, "a4", "b3", "Kb3", "8/8/8/8/8/1k6/8/4K3 w - - 0 2"}
      ])

    {:ok, view, html} = live(conn, "/games/#{game_id}")

    refute html =~ "stops verifying"
    assert html =~ "2 / 2"

    # The last position is the live one, so stepping into it leaves replay.
    html = view |> element("button[phx-value-to='1']") |> render_click()
    assert html =~ "Looking back at move 1 of 2"
  end

  test "the room can be narrowed by how long a game ran", %{conn: conn} do
    now = System.system_time(:millisecond)

    medium =
      seed_legacy(
        [
          {1, "e2", "e4", "e4"},
          {2, "e7", "e5", "e5"},
          {3, "g1", "f3", "Nf3"},
          {4, "b8", "c6", "Nc6"},
          {5, "f1", "b5", "Bb5"},
          {6, "a7", "a6", "a6"},
          {7, "b5", "a4", "Ba4"},
          {8, "g8", "f6", "Nf6"},
          {9, "e1", "g1", "O-O"},
          {10, "f8", "e7", "Be7"},
          {11, "f1", "e1", "Re1"},
          {12, "b7", "b5", "b5"}
        ],
        byte: 0xAB,
        ts: now - 60_000
      )

    short = seed_legacy([{1, "d2", "d4", "d4"}], byte: 0xCD, ts: now - 60_000)

    {:ok, view, html} = live(conn, "/games")

    assert html =~ "2 of 2 shown"

    html = view |> element("button[data-facet='length'][data-value='short']") |> render_click()

    assert html =~ "1 of 2 shown"
    assert html =~ short
    refute html =~ medium
  end

  test "the room can be read a period at a time", %{conn: conn} do
    now = System.system_time(:millisecond)

    seed_legacy([{1, "e2", "e4", "e4"}], byte: 0xAB, ts: now - 60_000)
    seed_legacy([{1, "d2", "d4", "d4"}], byte: 0xCD, ts: now - 3 * 365 * 24 * 60 * 60 * 1000)

    {:ok, view, html} = live(conn, "/games")

    refute html =~ "Today"

    html = view |> element("button[data-group='period']") |> render_click()

    assert html =~ "Today"
    assert html =~ "Older"
  end

  test "clearing the filters puts the room back", %{conn: conn} do
    seed_legacy([{1, "e2", "e4", "e4"}], byte: 0xAB)

    {:ok, view, html} = live(conn, "/games")
    refute html =~ "clear"

    html = view |> element("button[data-facet='kind'][data-value='backgammon']") |> render_click()
    assert html =~ "0 of 1 shown"
    refute html =~ "phx-value-id"
    assert html =~ "No game in this window matches"

    html = view |> element("button", "clear") |> render_click()
    assert html =~ "1 of 1 shown"
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
