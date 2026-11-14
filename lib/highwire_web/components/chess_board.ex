defmodule HighWireWeb.Components.ChessBoard do
  @moduledoc """
  A read-only chess board.

  The fold's board is a map of occupied squares, so drawing it is a walk of
  the rank and file names rather than of the map: empty squares are the ones
  the map does not have, and a board drawn from its keys would lose them.

  Pieces are the Lichess cburnett SVGs — a small per-side set (white and
  black each get their own drawings), served as static assets. Each side's
  pieces are their own silhouettes, so the two rows read as different pieces
  at a glance, and the white pieces carry a black outline that holds on dark
  squares the same way a real set does.
  """

  use Phoenix.Component

  @files ~w(a b c d e f g h)
  @ranks ~w(8 7 6 5 4 3 2 1)

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
    <div id={@id} class="rounded border border-edge bg-panel p-1.5">
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
      phx-value-sq={@playable && @square}
      class={[
        "chess-square",
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

      <%!-- A piece renders as its cburnett SVG, sized as a share of the
           square and vertically centred. The white set carries its own black
           outline, so a white piece holds on a dark square the way a real
           white piece does. --%>
      <.piece
        :if={@piece}
        type={type(@piece)}
        colour={colour(@piece)}
        compact={@compact}
      />

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

  attr :type, :string, required: true
  attr :colour, :string, required: true
  attr :compact, :boolean, default: false

  def piece(assigns) do
    ~H"""
    <img
      src={"/assets/chess/" <> (if(assigns.colour == "white", do: "w", else: "b")) <> piece_letter(assigns.type) <> ".svg"}
      class={"chess-piece" <> (if(assigns.compact, do: " chess-piece--compact", else: ""))}
      alt=""
      draggable="false"
    />
    """
  end

  defp piece_letter("king"), do: "K"
  defp piece_letter("queen"), do: "Q"
  defp piece_letter("rook"), do: "R"
  defp piece_letter("bishop"), do: "B"
  defp piece_letter("knight"), do: "N"
  defp piece_letter("pawn"), do: "P"
  defp piece_letter(other), do: other

  defp stoi(<<c>>), do: c

  defp colour({_type, colour}), do: to_string(colour)
  defp type({type, _colour}), do: to_string(type)
end
