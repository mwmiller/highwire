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

      <%!-- The answer to the desktop menu's "Check for Updates…", shown
      only when the reader asks; in a browser there is no updater, so the
      element stays hidden and says nothing. --%>
      <div
        id="update-banner"
        phx-hook="UpdateBanner"
        class="fixed bottom-4 right-4 z-50 hidden max-w-sm rounded-lg border border-edge bg-panel p-4 shadow-lg"
        role="status"
        aria-live="polite"
      >
        <p class="text-sm font-semibold text-paper" data-update-version>
          A new version is ready.
        </p>
        <p class="mt-1 text-xs text-dim" data-update-status>
          Install it here, and HighWire reopens on the new version.
        </p>
        <div class="mt-3 flex items-center gap-2">
          <button
            type="button"
            data-update-install
            class="rounded-md border border-accent px-3 py-1.5 text-xs font-semibold text-accent transition hover:bg-accent hover:text-paper disabled:opacity-60"
          >
            Install and restart
          </button>
          <button
            type="button"
            data-update-later
            class="rounded-md px-2 py-1.5 text-xs text-dim transition hover:text-paper"
          >
            Not now
          </button>
        </div>
      </div>
    </div>
    """
  end
end
