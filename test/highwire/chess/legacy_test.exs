defmodule HighWire.Chess.LegacyTest do
  use ExUnit.Case, async: true

  alias HighWire.Chess.Legacy

  @invite_key "%ADH7dzQ1qJDBrvDEcnC+++NxeGHQnL6nEhlhiz2Q8xM=.sha256"
  @white "@white.ed25519"
  @black "@black.ed25519"

  defp row(key, author, content, ts) do
    %{key: key, author: author, content: content, ts: ts}
  end

  defp invite(opts \\ []) do
    row(
      @invite_key,
      Keyword.get(opts, :author, @white),
      %{
        "type" => "chess_invite",
        "myColor" => Keyword.get(opts, :color, "white"),
        "inviting" => Keyword.get(opts, :inviting, @black)
      },
      1
    )
  end

  defp accept(author \\ @black) do
    row("%accept.sha256", author, %{"type" => "chess_invite_accept", "root" => @invite_key}, 2)
  end

  defp move(ply, orig, dest, san, fen, author, ts) do
    row(
      "%move#{ply}.sha256",
      author,
      %{
        "type" => "chess_move",
        "root" => @invite_key,
        "ply" => ply,
        "orig" => orig,
        "dest" => dest,
        "pgnMove" => san,
        "fen" => fen
      },
      ts
    )
  end

  @after_e4 "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1"

  describe "folding a rematch" do
    test "the second challenger does not take over both sides" do
      rematch =
        row(
          "%rematch.sha256",
          @black,
          %{"type" => "chess_invite", "myColor" => "black", "inviting" => @white},
          3
        )

      game =
        Legacy.fold([
          rematch,
          move(1, "e2", "e4", "e4", @after_e4, @white, 4),
          accept(),
          invite()
        ])

      assert game.challenger == @white
      assert game.accepter == @black
      assert {game.white, game.black} == {@white, @black}
    end
  end

  describe "game ids" do
    test "a message key becomes the same shape this node's own games use" do
      id = Legacy.game_id(@invite_key)

      assert byte_size(id) == 64
      assert String.match?(id, ~r/^[0-9a-f]{64}$/)
      assert Legacy.game_id?(id)
    end

    test "the same key always yields the same id" do
      assert Legacy.game_id(@invite_key) == Legacy.game_id(@invite_key)
    end

    test "anything that is not a key yields nothing" do
      assert Legacy.game_id("nope") == nil
      assert Legacy.game_id(nil) == nil
    end
  end

  describe "reading a FEN" do
    test "the opening position comes through square by square" do
      position = Legacy.position("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1")

      assert position.turn == :white
      assert position.board["e1"] == {:king, :white}
      assert position.board["d8"] == {:queen, :black}
      assert position.board["a2"] == {:pawn, :white}
      assert map_size(position.board) == 32
      assert MapSet.member?(position.castling, :white_king)
    end

    test "an empty rank does not shift the files beside it" do
      position = Legacy.position(@after_e4)

      assert position.board["e4"] == {:pawn, :white}
      refute Map.has_key?(position.board, "e2")
      assert position.turn == :black
      assert position.ep == "e3"
    end

    test "a FEN that does not parse reads as the opening position" do
      assert Legacy.position("nonsense").board == Legacy.position(nil).board
    end
  end

  describe "folding a game" do
    test "the ssb_-prefixed format folds as the same game" do
      invite =
        row(
          @invite_key,
          @white,
          %{"type" => "ssb_chess_invite", "inviting" => @black, "myColor" => "white"},
          1
        )

      # This client wrote the FEN into `pgnMove` and the notation into `fen`.
      moved =
        row(
          "%move1.sha256",
          @white,
          %{
            "type" => "ssb_chess_move",
            "root" => @invite_key,
            "ply" => 1,
            "orig" => "e2",
            "dest" => "e4",
            "pgnMove" => @after_e4,
            "fen" => "e4"
          },
          2
        )

      game = Legacy.fold([invite, moved])

      assert game.white == @white
      assert game.black == @black
      assert game.board["e4"] == {:pawn, :white}
      assert [%{ply: 1, san: "e4", uci: "e2e4"}] = game.history
    end

    test "both spellings are one namespace" do
      assert Legacy.message?(%{"type" => "ssb_chess_invite"})
      assert Legacy.message?(%{"type" => "chess_move"})
      refute Legacy.message?(%{"type" => "chess_chat"})
      assert Legacy.canonical("ssb_chess_move") == "chess_move"
      assert Legacy.canonical("chess_move") == "chess_move"
    end

    test "an invite with no accept is waiting, with the sides the invite named" do
      game = Legacy.fold([invite()])

      assert game.status == :playing
      assert game.phase == :opening
      assert game.white == @white
      assert game.black == @black
      assert game.writable? == false
      assert game.turn_count == 0
    end

    test "a player who takes black invites with myColor black" do
      game = Legacy.fold([invite(color: "black", inviting: @black), accept()])

      assert game.black == @white
      assert game.white == @black
      assert game.challenger == @white
      assert game.accepter == @black
    end

    test "moves read from the position each one carries" do
      game =
        Legacy.fold([
          invite(),
          accept(),
          move(1, "e2", "e4", "e4", @after_e4, @white, 3)
        ])

      assert game.turn_count == 1
      assert game.turn == :black
      assert game.mover == @black
      assert game.board["e4"] == {:pawn, :white}
      assert [%{ply: 1, san: "e4", uci: "e2e4", player: @white}] = game.history
    end

    test "the last position wins, whatever order the rows arrive in" do
      two = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

      game =
        Legacy.fold([
          move(2, "e7", "e5", "e5", two, @black, 4),
          move(1, "e2", "e4", "e4", @after_e4, @white, 3),
          invite()
        ])

      assert game.turn_count == 2
      assert game.board["e5"] == {:pawn, :black}
      assert Enum.map(game.history, & &1.ply) == [1, 2]
    end

    test "a promotion keeps the piece it promoted to" do
      fen = "4k3/1P6/8/8/8/8/8/4K3 b - - 0 1"
      game = Legacy.fold([invite(), accept(), move(1, "b7", "b8", "b8=Q+", fen, @white, 3)])

      assert [%{uci: "b7b8q", san: "b8=Q+"}] = game.history
    end

    test "an ending names the winner and finishes the game" do
      ending =
        row(
          "%end.sha256",
          @white,
          %{
            "type" => "chess_game_end",
            "root" => @invite_key,
            "ply" => 2,
            "orig" => "d1",
            "dest" => "h5",
            "pgnMove" => "Qh5#",
            "fen" => "4k3/8/8/8/8/8/8/4K2Q b - - 0 1",
            "status" => "mate",
            "winner" => @white
          },
          5
        )

      game = Legacy.fold([invite(), accept(), ending])

      assert game.status == :finished
      assert game.phase == :finished
      assert game.winner == %{player: @white, reason: :checkmate}
      assert game.verdict == {:checkmate, :black}
    end

    test "an invite with moves but no accept names the other seat" do
      game = Legacy.fold([invite(), move(1, "e2", "e4", "e4", @after_e4, @white, 3)])

      assert game.challenger == @white
      assert game.accepter == @black
      assert {game.white, game.black} == {@white, @black}
      assert game.phase == :playing
    end

    test "a game with no invite still names the player who moved" do
      game = Legacy.fold([move(1, "e2", "e4", "e4", @after_e4, @white, 3)])

      assert game.white == @white
      assert game.black == nil
      assert game.challenger == @white
      assert game.phase == :playing
      assert game.turn_count == 1
      assert game.game_id != nil
    end

    test "a game with no invite or accept still names both sides and whose move it is" do
      two = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

      game =
        Legacy.fold([
          move(2, "e7", "e5", "e5", two, @black, 4),
          move(1, "e2", "e4", "e4", @after_e4, @white, 3)
        ])

      assert {game.white, game.black} == {@white, @black}
      assert game.challenger == @white
      assert game.accepter == @black
      assert game.mover == @white
      assert game.phase == :playing
      assert game.status == :playing
    end

    test "a late-arriving earlier move does not walk the board backwards" do
      after_e5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

      game =
        Legacy.fold([
          invite(),
          accept(),
          move(1, "e2", "e4", "e4", @after_e4, @white, 9),
          move(2, "e7", "e5", "e5", after_e5, @black, 3)
        ])

      assert game.turn_count == 2
      assert game.turn == :white
      assert game.board["e5"] == {:pawn, :black}
      assert game.mover == @white
    end

    test "a missing reply link does not cut off the moves that follow it" do
      two = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"
      three = "rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2"

      # This move answers a message the node never stored: a chat between
      # the moves, or a delivery it missed.
      third =
        row(
          "%move3.sha256",
          @white,
          %{
            "type" => "chess_move",
            "root" => @invite_key,
            "ply" => 3,
            "orig" => "g1",
            "dest" => "f3",
            "pgnMove" => "Nf3",
            "fen" => three,
            "branch" => "%never-arrived.sha256"
          },
          5
        )

      game =
        Legacy.fold([
          invite(),
          accept(),
          move(1, "e2", "e4", "e4", @after_e4, @white, 3),
          move(2, "e7", "e5", "e5", two, @black, 4),
          third
        ])

      assert Enum.map(game.history, & &1.ply) == [1, 2, 3]
      assert game.turn_count == 3
      assert game.mover == @black
    end

    test "an accept without the invite puts the challenger on the other side" do
      two = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

      game =
        Legacy.fold([
          accept(@white),
          move(1, "e7", "e5", "e5", @after_e4, @black, 3),
          move(2, "e2", "e4", "e4", two, @white, 4)
        ])

      assert {game.white, game.black} == {@black, @white}
      assert game.challenger == @black
      assert game.accepter == @white
    end

    test "a move's position names the side that moved, whatever the ply says" do
      after_e5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

      game = Legacy.fold([move(4, "e7", "e5", "e5", after_e5, @black, 3)])

      assert game.black == @black
      assert game.white == nil
    end

    test "a game this node holds only the tail of still names both sides" do
      after_e5 = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq e6 0 2"

      game =
        Legacy.fold([
          move(12, "e2", "e4", "e4", @after_e4, @white, 3),
          move(13, "e7", "e5", "e5", after_e5, @black, 4)
        ])

      assert {game.white, game.black} == {@white, @black}
      assert game.challenger == @white
      assert game.accepter == @black
      assert game.mover == @white
      assert game.phase == :playing
      assert Enum.map(game.history, & &1.ply) == [12, 13]
    end

    test "two lines under one root are read through their links" do
      after_d4 = "rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq d3 0 1"
      after_d5 = "rnbqkbnr/ppp1pppp/8/3p4/3P4/8/PPP1PPPP/RNBQKBNR w KQkq d6 0 2"

      first =
        row(
          "%line-a.sha256",
          @white,
          %{
            "type" => "chess_move",
            "root" => @invite_key,
            "ply" => 1,
            "orig" => "e2",
            "dest" => "e4",
            "pgnMove" => "e4",
            "fen" => @after_e4,
            "branch" => @invite_key
          },
          3
        )

      restart =
        row(
          "%line-b.sha256",
          @white,
          %{
            "type" => "chess_move",
            "root" => @invite_key,
            "ply" => 1,
            "orig" => "d2",
            "dest" => "d4",
            "pgnMove" => "d4",
            "fen" => after_d4,
            "branch" => @invite_key
          },
          4
        )

      reply =
        row(
          "%line-b2.sha256",
          @black,
          %{
            "type" => "chess_move",
            "root" => @invite_key,
            "ply" => 2,
            "orig" => "d7",
            "dest" => "d5",
            "pgnMove" => "d5",
            "fen" => after_d5,
            "branch" => "%line-b.sha256"
          },
          5
        )

      game = Legacy.fold([invite(), accept(), first, restart, reply])

      assert Enum.map(game.history, & &1.uci) == ["d2d4", "d7d5"]
      assert Enum.map(game.history, & &1.ply) == [1, 2]
      assert game.turn_count == 2
      assert game.mover == @white
    end
  end
end
