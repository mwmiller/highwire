defmodule HighWireWeb.GameLiveBackgammonFlowTest do
  use HighWireWeb.ConnCase

  alias HighWire.Backgammon.{Engine, Game, Log, Store}
  alias HighWire.SSB.Identities

  import Phoenix.LiveViewTest

  @doc false
  def fake_publish(_content), do: {:ok, "%a.sha256"}

  @doc false
  def fake_file(_key, _content, _opts), do: :ok

  @doc false
  def with_identity(name) do
    {:ok, id} = Identities.create(name)
    :ok = Identities.activate(id)
    id
  end

  @doc false
  def envelope(author, content, key: key) when is_binary(key) do
    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end

  setup do
    :ok = Identities.ensure_boot()

    unless Identities.active_id() do
      {:ok, main} = Identities.create("Main")
      :ok = Identities.activate(main)
    end

    main_id =
      Identities.active_id()
      |> then(fn id -> if id, do: id, else: raise("no active identity") end)

    {:ok, opponent} = Identities.create("Opponent")

    # Hand each identity's secret explicitly into the Log calls in every test,
    # so the page-side actions never fall back to the active identity and never
    # attempt a real publish through Timeline.publish_content/1.
    #
    # Identities.secret/0 returns the currently active identity's secret, so we
    # swap the active identity once per id and read it while it is active.
    main_secret =
      Identities.activate(main_id)
      |> then(fn :ok -> Identities.secret() end)

    opponent_secret =
      Identities.activate(opponent)
      |> then(fn :ok -> Identities.secret() end)

    # Leave the active identity set to main for the page-side assertions.
    :ok = Identities.activate(main_id)

    %{
      main_id: main_id,
      opponent_id: opponent,
      main_secret: main_secret,
      opponent_secret: opponent_secret
    }
  end

  describe "a backgammon game from the player's point of view" do
    test "an open challenge shows accept to the opponent and withdraw to the challenger", %{
      main_id: main_id,
      opponent_id: opponent_id,
      opponent_secret: opponent_secret
    } do
      {:ok, game_id, _key} =
        Log.open(
          author: opponent_id,
          secret: opponent_secret,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      Store.ingest(
        envelope(opponent_id, Game.challenge(game_id, "abcd", note: "a game?"), key: "%c.sha256")
      )

      {:ok, main_view, _} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      assert main_view |> element("button", "accept the challenge") |> has_element?()
      refute main_view |> element("button", "withdraw challenge") |> has_element?()

      # The challenger sees withdraw instead.
      {:ok, opponent_view} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: opponent_id}) end)

      refute opponent_view |> element("button", "accept the challenge") |> has_element?()
      assert opponent_view |> element("button", "withdraw challenge") |> has_element?()
    end

    test "a challenger cannot accept their own challenge", %{
      main_id: main_id,
      opponent_id: opponent_id,
      main_secret: main_secret
    } do
      {:ok, game_id, _key} =
        Log.open(
          author: main_id,
          secret: main_secret,
          to: opponent_id,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      Store.ingest(
        envelope(main_id, Game.challenge(game_id, "abcd", to: opponent_id), key: "%c.sha256")
      )

      {:ok, view, _} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      refute view |> element("button", "accept the challenge") |> has_element?()
      assert view |> element("button", "withdraw challenge") |> has_element?()
    end

    test "an open challenge the author encounters again still can withdraw", %{
      main_id: main_id,
      opponent_id: opponent_id,
      main_secret: main_secret
    } do
      {:ok, game_id, _key} =
        Log.open(
          author: main_id,
          secret: main_secret,
          to: opponent_id,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      Store.ingest(
        envelope(main_id, Game.challenge(game_id, "abcd", to: opponent_id), key: "%c.sha256")
      )

      {:ok, view, _} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      assert view |> element("button", "withdraw challenge") |> has_element?()

      view
      |> element("button", "withdraw challenge")
      |> render_click()

      {:ok, view} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      game = Store.get(game_id)

      assert game.status == :withdrawn
      refute view |> element("button", "withdraw challenge") |> has_element?()
    end

    test "accepting starts the game and puts the accepter into the opening roll", %{
      main_id: main_id,
      opponent_id: opponent_id,
      main_secret: main_secret,
      opponent_secret: opponent_secret
    } do
      {:ok, game_id, _key} =
        Log.open(
          author: opponent_id,
          secret: opponent_secret,
          to: main_id,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      Store.ingest(
        envelope(opponent_id, Game.challenge(game_id, "abcd", to: main_id), key: "%c.sha256")
      )

      # The accepter accepts through the page.
      {:ok, view, _} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      assert view |> element("button", "accept the challenge") |> has_element?()

      view
      |> element("button", "accept the challenge")
      |> render_click()

      # The page now says the game is waiting on the challenger's roll.
      assert has_element?(view, ".text-xs.italic.text-faint")
      refute view |> element("button", "roll the dice") |> has_element?()

      {:ok, view} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      game = Store.get(game_id)

      assert game.accepter == main_id
      assert game.phase == :opening
      assert game.mover == game.challenger
    end

    test "the challenger rolls the opening after the opponent has accepted", %{
      main_id: main_id,
      opponent_id: opponent_id,
      main_secret: main_secret,
      opponent_secret: opponent_secret
    } do
      {:ok, game_id, _key} =
        Log.open(
          author: opponent_id,
          secret: opponent_secret,
          to: main_id,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      Store.ingest(
        envelope(opponent_id, Game.challenge(game_id, "abcd", to: main_id), key: "%c.sha256")
      )

      # Accept through the writer, so the game is paired before the challenger's
      # page reloads.
      {:ok, _accept_key} =
        Log.accept(
          Store.get(game_id),
          author: main_id,
          secret: main_secret,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      game = Store.get(game_id)

      assert game.accepter == main_id
      assert game.phase == :opening
      assert game.mover == game.challenger

      # The challenger now has exactly one affordance: roll the dice.
      {:ok, view} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: opponent_id}) end)

      assert view |> element("button", "roll the dice") |> has_element?()
    end

    test "a resign is available only when it is the player's turn in play", %{
      main_id: main_id,
      opponent_id: opponent_id,
      main_secret: main_secret,
      opponent_secret: opponent_secret
    } do
      {:ok, game_id, _key} =
        Log.open(
          author: main_id,
          secret: main_secret,
          to: opponent_id,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      Store.ingest(
        envelope(main_id, Game.challenge(game_id, "abcd", to: opponent_id), key: "%c.sha256")
      )

      {:ok, _accept_key} =
        Log.accept(
          Store.get(game_id),
          author: opponent_id,
          secret: opponent_secret,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      game = roll_until_playing(game_id, main_secret)

      [d1, d2] = game.opener.dice
      [moves | _] = Engine.legal_plays(game.position, {d1, d2})

      {:ok, _} =
        Log.play(
          game,
          moves,
          author: main_id,
          secret: main_secret,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      game = Store.get(game_id)
      assert game.phase == :playing
      assert game.mover == main_id

      {:ok, view} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      assert view |> element("button", "resign") |> has_element?()
      assert view |> element("button", "play the turn") |> has_element?()

      view
      |> element("button", "resign")
      |> render_click()

      {:ok, view} =
        build_conn()
        |> then(fn conn -> live(conn, "/games/#{game_id}", session: %{self_id: main_id}) end)

      game = Store.get(game_id)

      assert game.status == :finished
      assert game.winner.player == opponent_id

      refute view |> element("button", "resign") |> has_element?()
    end
  end

  # -- help the test reads stay close to the wire --------------------------------

  defp roll_until_playing(game_id, roller_secret) do
    game = Store.get(game_id)

    if game.phase == :playing do
      game
    else
      # The opening is rolled by whichever side is to roll next; after a direct
      # acceptance the challenger is the first roller, so roll as them.
      {:ok, _} =
        Log.roll(
          game,
          author: game.mover || game.challenger,
          secret: roller_secret,
          publish: &fake_publish/1,
          file: &fake_file/3
        )

      roll_until_playing(game_id, roller_secret)
    end
  end
end
