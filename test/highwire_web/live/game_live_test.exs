defmodule HighWireWeb.GameLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.Backgammon.{Chain, Engine, Game, Log, Store}
  alias HighWire.Games.Catalog

  setup do
    Store.clear()
    Catalog.clear()
    :ok
  end

  describe "a backgammon game" do
    test "draws the position, the reveal budget and the history", %{conn: conn} do
      game_id = seed_opening()
      {:ok, _view, html} = live(conn, "/games/#{game_id}")

      # The board draws every point as a place a checker can be, whether or
      # not this reader may pick one up.
      assert html =~ ~s(data-point="24")
      assert html =~ ~s(data-point="1")
      assert html =~ "reveals left"
      assert html =~ "opened by"
      assert html =~ "No turns played yet."
      # The reader holds neither side, so the page says where they stand
      # rather than offering moves that are not theirs to make.
      assert html =~ "spectating"
      refute html =~ "roll the dice"
    end

    # A game with a turn on it is the case that matters: the history, the
    # roll and the moves have to survive being read back out of the fold.
    test "lists a played turn with its roll and moves", %{conn: conn} do
      game_id = seed_played()
      {:ok, _view, html} = live(conn, "/games/#{game_id}")

      assert html =~ "turn"
      refute html =~ "No turns played yet."
      refute html =~ "This game does not verify"
    end

    test "a game that does not verify says so instead of drawing a position", %{conn: conn} do
      game_id = seed_broken()
      {:ok, _view, html} = live(conn, "/games/#{game_id}")

      assert html =~ "This game does not verify"
    end
  end

  # A game opened, accepted, rolled out and played a turn — through the
  # writer, so the messages are the ones the client would really publish.
  defp seed_played do
    secrets = %{
      "@challenger.ed25519" => :crypto.strong_rand_bytes(32),
      "@accepter.ed25519" => :crypto.strong_rand_bytes(32)
    }

    as = fn player ->
      [
        author: player,
        secret: secrets[player],
        publish: fn _content -> {:ok, "%#{System.unique_integer([:positive])}.sha256"} end
      ]
    end

    {:ok, game_id, _} = Log.open(as.("@challenger.ed25519"))
    {:ok, _} = Log.accept(Store.get(game_id), as.("@accepter.ed25519"))

    game = roll_until_playing(game_id, as)
    [d1, d2] = game.opener.dice
    [moves | _] = Engine.legal_plays(game.position, {d1, d2})
    {:ok, _} = Log.play(game, moves, as.(game.mover))

    game_id
  end

  defp roll_until_playing(game_id, as) do
    game = Store.get(game_id)

    if game.phase == :playing do
      game
    else
      {:ok, _} = Log.roll(game, as.(game.mover))
      roll_until_playing(game_id, as)
    end
  end

  defp seed_opening do
    spec = %{"length" => 8}
    game_id = Game.new_id()
    chall = Chain.generate(:crypto.strong_rand_bytes(32), spec)
    accept = Chain.generate(:crypto.strong_rand_bytes(32), spec)

    Store.ingest(
      envelope(
        "@challenger.ed25519",
        Game.challenge(game_id, hex(Chain.commit(chall))),
        "%b1.sha256"
      )
    )

    Store.ingest(
      envelope(
        "@accepter.ed25519",
        Game.accept(
          game_id,
          "%b1.sha256",
          hex(Chain.commit(accept)),
          hex(List.last(accept))
        ),
        "%b2.sha256"
      )
    )

    game_id
  end

  # An accept whose reveal does not answer the commitment it was made
  # against: the fold stops, and the page has to say why rather than show a
  # board nobody can trust.
  defp seed_broken do
    spec = %{"length" => 8}
    game_id = Game.new_id()
    chall = Chain.generate(:crypto.strong_rand_bytes(32), spec)
    other = Chain.generate(:crypto.strong_rand_bytes(32), spec)

    Store.ingest(
      envelope(
        "@challenger.ed25519",
        Game.challenge(game_id, hex(Chain.commit(chall))),
        "%b3.sha256"
      )
    )

    Store.ingest(
      envelope(
        "@accepter.ed25519",
        Game.accept(game_id, "%b3.sha256", hex(Chain.commit(other)), hex(List.last(chall))),
        "%b4.sha256"
      )
    )

    Store.ingest(
      envelope(
        "@challenger.ed25519",
        Game.roll(game_id, "%b3.sha256", 0, hex(List.last(chall)), hex(List.last(other)), 8),
        "%b5.sha256"
      )
    )

    game_id
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp envelope(author, content, key) do
    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end
end
