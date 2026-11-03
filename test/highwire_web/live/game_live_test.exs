defmodule HighWireWeb.GameLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.Backgammon.{Chain, Game, Log, Store}
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
    secret = :crypto.strong_rand_bytes(32)
    other_secret = :crypto.strong_rand_bytes(32)
    publish = fn _content -> {:ok, "%#{System.unique_integer([:positive])}.sha256"} end

    {:ok, game_id, _} =
      Log.open(author: "@challenger.ed25519", secret: secret, publish: publish)

    {:ok, _} =
      Log.accept(Store.get(game_id),
        author: "@accepter.ed25519",
        secret: other_secret,
        publish: publish
      )

    game = roll_out(game_id, secret, other_secret, publish)

    if game.mover == "@challenger.ed25519" do
      [d1, d2] = game.opener.dice
      [moves | _] = HighWire.Backgammon.Engine.legal_plays(game.position, {d1, d2})

      {:ok, _} =
        Log.play(game, moves, author: "@challenger.ed25519", secret: secret, publish: publish)
    else
      [d1, d2] = game.opener.dice
      [moves | _] = HighWire.Backgammon.Engine.legal_plays(game.position, {d1, d2})

      {:ok, _} =
        Log.play(game, moves, author: "@accepter.ed25519", secret: other_secret, publish: publish)
    end

    game_id
  end

  defp roll_out(game_id, secret, other_secret, publish) do
    game = Store.get(game_id)

    if game.phase == :playing do
      game
    else
      if game.mover == "@challenger.ed25519" do
        {:ok, _} = Log.roll(game, author: "@challenger.ed25519", secret: secret, publish: publish)
      else
        {:ok, _} =
          Log.roll(game, author: "@accepter.ed25519", secret: other_secret, publish: publish)
      end

      roll_out(game_id, secret, other_secret, publish)
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
