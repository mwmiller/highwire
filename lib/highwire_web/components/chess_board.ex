defmodule HighWireWeb.Components.ChessBoard do
  @moduledoc """
  A read-only chess board.

  The fold's board is a map of occupied squares, so drawing it is a walk of
  the rank and file names rather than of the map: empty squares are the ones
  the map does not have, and a board drawn from its keys would lose them.

  Pieces are text, not images — the same glyph every platform has, sized by
  the type scale — so the gameroom needs no sprite sheet and a spectator
  reads the position at any zoom.
  """

  use Phoenix.Component

  @files ~w(a b c d e f g h)
  @ranks ~w(8 7 6 5 4 3 2 1)

  @glyphs %{
    {:king, :white} => "♔",
    {:queen, :white} => "♕",
    {:rook, :white} => "♖",
    {:bishop, :white} => "♗",
    {:knight, :white} => "♘",
    {:pawn, :white} => "♙",
    {:king, :black} => "♚",
    {:queen, :black} => "♛",
    {:rook, :black} => "♜",
    {:bishop, :black} => "♝",
    {:knight, :black} => "♞",
    {:pawn, :black} => "♟"
  }

  attr :board, :map, required: true, doc: "the fold's board: square => {type, colour}"
  attr :compact, :boolean, default: false

  def board(assigns) do
    squares =
      for rank <- @ranks, file <- @files do
        square = file <> rank
        # a8 is a light square, and the colour alternates from there.
        light? = rem(String.to_integer(rank) + (stoi(file) - ?a), 2) == 0
        {square, Map.get(assigns.board, square), light?}
      end

    assigns = assign(assigns, :squares, squares)

    ~H"""
    <div class="rounded border border-edge bg-panel p-1.5">
      <div class="grid grid-cols-8">
        <.square
          :for={{_square, piece, light?} <- @squares}
          piece={piece}
          light?={light?}
          compact={@compact}
        />
      </div>
    </div>
    """
  end

  attr :piece, :any, default: nil
  attr :light?, :boolean, required: true
  attr :compact, :boolean, default: false

  defp square(assigns) do
    ~H"""
    <div class={[
      "flex aspect-square items-center justify-center leading-none",
      @light? && "bg-raised",
      !@light? && "bg-panel",
      @compact && "text-[11px]",
      !@compact && "text-2xl"
    ]}>
      <span :if={@piece}>{glyph(@piece)}</span>
    </div>
    """
  end

  defp stoi(<<c>>), do: c
  defp glyph(piece), do: Map.get(@glyphs, piece, "")
end
