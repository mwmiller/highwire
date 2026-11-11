defmodule HighWireWeb.Components.Shell do
  @moduledoc """
  The frame every page sits in: the rail on the left and the page's own
  column beside it, inside one screen that never scrolls as a whole.

  A page puts whatever it adds to the rail in the `:rail` slot — its
  heading, its anchors, its own lists — and everything else it renders
  becomes the column beside the rail. The frame, the rail's live state
  and the resting attributes pages hang on it (`id`, `phx-hook`) live
  here once, so a page that gains a control in the rail gains it in one
  place and every page keeps the same edge.
  """

  use Phoenix.Component

  alias HighWireWeb.Components.Nav

  attr :gossip, :map, default: %{connected: 0, pulse: 0}, doc: "live gossip state"

  attr :identity, :map,
    default: nil,
    doc: "the presentation the page resolved for the active identity, when it has one"

  attr :rest, :global, doc: "attributes on the frame itself, such as a page hook"

  slot :rail, doc: "the page's content for the rail, below its header"
  slot :inner_block, required: true, doc: "the page's own column"

  def app(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink" {@rest}>
      <Nav.rail gossip={@gossip} identity={@identity}>
        {render_slot(@rail)}
      </Nav.rail>
      {render_slot(@inner_block)}
    </div>
    """
  end
end
