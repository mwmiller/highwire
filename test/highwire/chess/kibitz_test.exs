defmodule HighWire.Chess.KibitzTest do
  use ExUnit.Case, async: false

  alias HighWire.Chess.{Game, Kibitz, Legacy, Store}

  setup do
    Store.clear()
    Kibitz.clear()
    :ok
  end

  describe "filing a kibitz" do
    test "a public chess_chat lands under the game its root names" do
      game_id = open_game()

      assert :ok =
               Kibitz.ingest(envelope("@watcher.ed25519", chat("%challenge.sha256", "nice fork")))

      assert [%{author: "@watcher.ed25519", text: "nice fork"}] =
               Kibitz.thread(Store.get(game_id))
    end

    test "a kibitz about the network's format is found by the game it names" do
      root = "%" <> Base.encode64(:crypto.strong_rand_bytes(32)) <> ".sha256"

      assert :ok = Kibitz.ingest(envelope("@watcher.ed25519", chat(root, "good luck")))

      assert [%{text: "good luck"}] = Kibitz.thread(%{game_id: Legacy.game_id(root)})
    end

    test "the same message delivered twice is one kibitz" do
      game_id = open_game()

      msg = envelope("@watcher.ed25519", chat("%challenge.sha256", "hello"), "%chat.sha256")

      assert :ok = Kibitz.ingest(msg)
      assert :seen = Kibitz.ingest(msg)
      assert [%{text: "hello"}] = Kibitz.thread(Store.get(game_id))
    end

    test "anything that is not a kibitz about a game is ignored" do
      assert :ignored =
               Kibitz.ingest(envelope("@watcher.ed25519", %{"type" => "post", "text" => "hi"}))

      assert :ignored = Kibitz.ingest(envelope("@watcher.ed25519", %{"type" => "chess_chat"}))
    end
  end

  describe "posting a kibitz" do
    test "publishes the network's chess_chat, rooted at the challenge" do
      game_id = open_game()
      parent = self()

      publish = fn content ->
        send(parent, {:published, content})
        {:ok, "%kibitz.sha256"}
      end

      assert {:ok, "%kibitz.sha256"} =
               Kibitz.post(Store.get(game_id), "  nice fork  ",
                 author: "@watcher.ed25519",
                 publish: publish
               )

      assert_received {:published,
                       %{
                         "type" => "chess_chat",
                         "root" => "%challenge.sha256",
                         "msg" => "nice fork"
                       }}

      assert [%{author: "@watcher.ed25519", text: "nice fork"}] =
               Kibitz.thread(Store.get(game_id))
    end

    test "an empty kibitz is not published" do
      game_id = open_game()

      assert {:error, :empty} =
               Kibitz.post(Store.get(game_id), "   ",
                 author: "@watcher.ed25519",
                 publish: fn _content -> flunk("published an empty kibitz") end
               )
    end
  end

  describe "who sees it" do
    test "a spectator sees the talk, a player does not while the game is in play" do
      game = %{challenger: "@white.ed25519", accepter: "@black.ed25519", status: :playing}

      assert Kibitz.visible?(game, "@watcher.ed25519")
      assert Kibitz.visible?(game, nil)
      refute Kibitz.visible?(game, "@white.ed25519")
      refute Kibitz.visible?(game, "@black.ed25519")
    end

    test "once the game is over a player can read what was said about it" do
      game = %{challenger: "@white.ed25519", accepter: "@black.ed25519", status: :finished}

      assert Kibitz.visible?(game, "@white.ed25519")
    end
  end

  defp open_game do
    game_id = Game.new_id()

    Store.ingest(
      envelope("@challenger.ed25519", Game.challenge(game_id, "white"), "%challenge.sha256")
    )

    game_id
  end

  defp chat(root, msg), do: %{"type" => "chess_chat", "root" => root, "msg" => msg}

  defp envelope(author, content, key \\ nil) do
    key = key || "%#{System.unique_integer([:positive])}.sha256"
    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end
end
