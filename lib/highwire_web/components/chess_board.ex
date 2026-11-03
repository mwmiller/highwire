defmodule HighWireWeb.Components.ChessBoard do
  @moduledoc """
  A read-only chess board.

  The fold's board is a map of occupied squares, so drawing it is a walk of
  the rank and file names rather than of the map: empty squares are the ones
  the map does not have, and a board drawn from its keys would lose them.

  Pieces are text, not images — the same glyph every platform has — so the
  gameroom needs no sprite sheet and a spectator reads the position at any
  zoom. White and black are the same filled silhouette coloured differently,
  at a share of the square's width: a font that draws white as an outline and
  black as a solid offers two piece sets, and the outlined one fades out on
  the board.

  A font's glyphs are drawn to no common measure, so the board hands each
  piece to the `PieceInk` hook, which sizes every one of them to the same
  share of its square.
  """

  use Phoenix.Component

  @files ~w(a b c d e f g h)
  @ranks ~w(8 7 6 5 4 3 2 1)

  @glyphs %{
    king: "♚",
    queen: "♛",
    rook: "♜",
    bishop: "♝",
    knight: "♞",
    pawn: "♟"
  }

  attr :id, :string, default: nil, doc: "names the board so the piece hook can find it"
  attr :board, :map, required: true, doc: "the fold's board: square => {type, colour}"
  attr :compact, :boolean, default: false

  attr :movable, :list, default: [], doc: "squares whose pieces can be picked up"
  attr :targets, :list, default: [], doc: "squares the picked-up piece can reach"
  attr :selected, :string, default: nil
  attr :playable, :boolean, default: false
  attr :last, :list, default: [], doc: "squares the last move touched"

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
    <div id={@id} phx-hook={@id && "PieceInk"} class="rounded border border-edge bg-panel p-1.5">
      <div class="grid grid-cols-8">
        <.square
          :for={{square, piece, light?} <- @squares}
          square={square}
          piece={piece}
          light?={light?}
          compact={@compact}
          selected={@selected == square}
          last={square in @last}
          movable={square in @movable}
          target={square in @targets}
          playable={@playable}
        />
      </div>
    </div>
    """
  end

  attr :square, :string, required: true
  attr :piece, :any, default: nil
  attr :light?, :boolean, required: true
  attr :compact, :boolean, default: false
  attr :selected, :boolean, default: false
  attr :movable, :boolean, default: false
  attr :target, :boolean, default: false
  attr :playable, :boolean, default: false
  attr :last, :boolean, default: false

  defp square(assigns) do
    ~H"""
    <div
      phx-click={@playable && "square"}
      phx-value-sq={@square}
      class={[
        "chess-square relative flex aspect-square items-center justify-center leading-none",
        @playable && "cursor-pointer",
        @light? && "board-light",
        !@light? && "board-dark",
        @selected && "ring-2 ring-inset ring-focus",
        @movable && !@selected && "hover:ring-1 hover:ring-inset hover:ring-focus"
      ]}
    >
      <%!-- The squares the move being looked at touched, so replaying a
           game shows where the piece came from. --%>
      <span :if={@last} class="absolute inset-0 bg-accent/20" />

      <span :if={@piece} class="chess-piece" data-colour={colour(@piece)} data-type={type(@piece)}>
        {glyph(@piece)}
      </span>

      <%!-- A reachable square says so under the piece as well as on an
           empty one, so a capture reads as a move and not as a colour. --%>
      <span
        :if={@target && @piece == nil}
        class="absolute h-2 w-2 rounded-full bg-accent opacity-70"
      />
      <span
        :if={@target && @piece != nil}
        class="absolute inset-0 rounded-sm ring-2 ring-inset ring-accent"
      />
    </div>
    """
  end

  defp stoi(<<c>>), do: c

  defp glyph({type, _colour}), do: Map.get(@glyphs, type, "")
  defp colour({_type, colour}), do: to_string(colour)
  defp type({type, _colour}), do: to_string(type)
end
