defmodule HighWire.Chess.EngineTest do
  use ExUnit.Case, async: true

  alias HighWire.Chess.Engine

  defp play(pos, moves) do
    Enum.reduce(moves, pos, fn uci, acc ->
      {:ok, next} = Engine.move(acc, uci)
      next
    end)
  end

  # Perft counts are the standard ones, so a rule this engine gets wrong
  # shows up as a number rather than as a game that only looks plausible.
  defp perft(_pos, 0), do: 1

  defp perft(pos, depth) do
    pos
    |> Engine.legal()
    |> Enum.map(&Engine.apply_move(pos, &1))
    |> Enum.map(&perft(&1, depth - 1))
    |> Enum.sum()
  end

  describe "the opening position" do
    test "has the twenty moves a game starts with" do
      assert length(Engine.legal_moves(Engine.initial())) == 20
    end

    test "matches the reference counts at depth three" do
      assert perft(Engine.initial(), 1) == 20
      assert perft(Engine.initial(), 2) == 400
      assert perft(Engine.initial(), 3) == 8902
    end

    test "sets the en-passant target only after a double push" do
      pos = play(Engine.initial(), ~w(e2e4))
      assert pos.ep == "e3"

      pos = play(Engine.initial(), ~w(e2e3))
      assert pos.ep == nil
    end

    test "refuses a move the position does not allow" do
      assert {:error, :illegal} = Engine.move(Engine.initial(), "e2e5")
      assert {:error, :illegal} = Engine.move(Engine.initial(), "e7e5")
    end
  end

  describe "castling" do
    test "moves the rook with the king" do
      pos = play(Engine.initial(), ~w(e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 e1g1))

      assert Engine.at(pos, "g1") == {:king, :white}
      assert Engine.at(pos, "f1") == {:rook, :white}
      assert Engine.at(pos, "h1") == nil
    end

    test "is refused once the king has moved" do
      pos = play(Engine.initial(), ~w(e2e4 e7e5 g1f3 b8c6 f1c4 f8c5 e1f1 e8f8 g2g3 g8f6))
      refute "e1g1" in Engine.legal_moves(pos)
    end

    test "is refused through an attacked square" do
      # Black's bishop on a6 covers f1, the square the white king crosses.
      position = %{
        board: %{
          "e1" => {:king, :white},
          "h1" => {:rook, :white},
          "a6" => {:bishop, :black},
          "e8" => {:king, :black}
        },
        turn: :white,
        castling: MapSet.new([:wk, :bk]),
        ep: nil,
        halfmove: 0,
        fullmove: 1,
        seen: %{}
      }

      refute "e1g1" in Engine.legal_moves(position)
    end
  end

  describe "pawns" do
    test "take en passant" do
      pos = play(Engine.initial(), ~w(e2e4 a7a6 e4e5 d7d5))
      assert "e5d6" in Engine.legal_moves(pos)

      pos = play(pos, ~w(e5d6))
      assert Engine.at(pos, "d6") == {:pawn, :white}
      assert Engine.at(pos, "d5") == nil
    end

    test "promote to the piece the move names" do
      position = %{
        board: %{"a7" => {:pawn, :white}, "h8" => {:king, :black}, "e1" => {:king, :white}},
        turn: :white,
        castling: MapSet.new(),
        ep: nil,
        halfmove: 0,
        fullmove: 1,
        seen: %{}
      }

      promos = Enum.filter(Engine.legal_moves(position), &String.starts_with?(&1, "a7a8"))
      assert Enum.sort(promos) == ~w(a7a8b a7a8n a7a8q a7a8r)

      {:ok, next} = Engine.move(position, "a7a8n")
      assert Engine.at(next, "a8") == {:knight, :white}
    end
  end

  describe "a piece that cannot move without exposing its king" do
    test "is refused" do
      # The white knight on e2 shields the king on e1 from the rook on e8.
      position = %{
        board: %{
          "e1" => {:king, :white},
          "e2" => {:knight, :white},
          "e8" => {:rook, :black},
          "a8" => {:king, :black}
        },
        turn: :white,
        castling: MapSet.new(),
        ep: nil,
        halfmove: 0,
        fullmove: 1,
        seen: %{}
      }

      refute Enum.any?(Engine.legal_moves(position), &String.starts_with?(&1, "e2"))
    end
  end

  describe "the end of a game" do
    test "is checkmate when the king is attacked and boxed in" do
      pos = play(Engine.initial(), ~w(f2f3 e7e5 g2g4 d8h4))
      assert Engine.status(pos) == {:checkmate, :black}
      assert Engine.san(play(Engine.initial(), ~w(f2f3 e7e5 g2g4)), "d8h4") == "Qh4#"
    end

    test "is stalemate when there is no move and no check" do
      position = %{
        board: %{"a8" => {:king, :black}, "c7" => {:queen, :white}, "c6" => {:king, :white}},
        turn: :black,
        castling: MapSet.new(),
        ep: nil,
        halfmove: 0,
        fullmove: 1,
        seen: %{}
      }

      assert Engine.status(position) == :stalemate
    end

    test "is a draw when neither side can mate" do
      position = %{
        board: %{"e1" => {:king, :white}, "e8" => {:king, :black}, "c1" => {:bishop, :white}},
        turn: :white,
        castling: MapSet.new(),
        ep: nil,
        halfmove: 0,
        fullmove: 1,
        seen: %{}
      }

      assert Engine.status(position) == {:draw, :insufficient_material}
    end
  end

  describe "san/2" do
    test "writes the move the way a player does" do
      pos = Engine.initial()

      assert Engine.san(pos, "g1f3") == "Nf3"
      assert Engine.san(pos, "e2e4") == "e4"

      pos = play(pos, ~w(e2e4 e7e5 g1f3 b8c6 f1b5 a7a6))
      assert Engine.san(pos, "b5c6") == "Bxc6"

      pos = play(Engine.initial(), ~w(e2e4 e7e5 g1f3 b8c6 f1c4 f8c5))
      assert Engine.san(pos, "e1g1") == "O-O"
    end

    test "names the file when two pieces could take the same square" do
      position = %{
        board: %{
          "e1" => {:king, :white},
          "e8" => {:king, :black},
          "b1" => {:knight, :white},
          "f3" => {:knight, :white},
          "d4" => {:pawn, :black}
        },
        turn: :white,
        castling: MapSet.new(),
        ep: nil,
        halfmove: 0,
        fullmove: 1,
        seen: %{}
      }

      assert Engine.san(position, "b1d2") == "Nbd2"
      assert Engine.san(position, "f3d2") == "Nfd2"
    end
  end
end
