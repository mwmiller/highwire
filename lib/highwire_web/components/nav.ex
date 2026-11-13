defmodule HighWireWeb.Components.Nav do
  @moduledoc """
  The shared left rail: the top row opens with back and forward through
  this window's page history, then the crab mark (linking to the
  timeline) and the table (linking to the gameroom) — the two
  destinations built from the SSB logs. In the utility corner, beside
  the current identity's avatar (linking to the identity page,
  `/identity`) and the settings gear, a smaller constellation mark
  opens the network page (`/network`): dialing and the network profile
  are local service controls, not another log to read. Pages add their
  own content to the rail through the default slot, below the fixed
  header. Only the page's own content scrolls, so the way into the
  network page is in reach whatever the rail holds.

  The avatar and its title show what followers see: the resolved alias
  and image from the `HighWire.SSB.Profile` read model, with the local
  label in parentheses after the name — the label is this install's
  private nickname for the key, not something a follower could see.
  The rail reads the registry and the read model at render, so pages
  that cannot change identity while mounted need no extra inputs; the
  identity page passes its own row (`identity`) carrying the
  presentation it just resolved, so a profile landing or a switch
  updates the avatar in place. With no identity yet (first run,
  import pending) the link simply does not render.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    router: HighWireWeb.Router,
    endpoint: HighWireWeb.Endpoint,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  alias HighWire.SSB.{Identities, Network, Profile}
  alias HighWireWeb.Components.Avatar

  @doc """
  Renders the rail frame. Anything given as content is placed below the
  header inside the same panel.

  The footer badge carries the gossip state: `connected` is the live
  peer count, `pulse` increments on every gossip event — the keyed dot
  replays its flare whenever it changes.
  """
  attr :gossip, :map, default: %{connected: 0, pulse: 0}, doc: "live gossip state"

  attr :identity, :map,
    default: nil,
    doc:
      "The active identity's public row. The identity page passes it — carrying the resolved name and image — so the avatar and title update in place; everyone else omits it and the rail reads the registry and the Profile read model at render."

  slot :inner_block, doc: "Rail content below the header"

  def rail(assigns) do
    assigns = assign(assigns, :identity, assigns.identity || Identities.active())

    ~H"""
    <aside class="flex w-64 min-w-0 shrink-0 flex-col overflow-hidden border-r border-edge bg-panel">
      <div
        id="rail-header"
        class="flex h-11 shrink-0 w-full items-center justify-between border-b border-edge px-4"
      >
        <div
          id="rail-history"
          phx-hook="HistoryNav"
          class="flex items-center overflow-hidden rounded-md border border-edge"
        >
          <button
            type="button"
            data-history="back"
            title="Back"
            aria-label="Back"
            class="flex h-6 w-6 items-center justify-center text-dim transition hover:bg-raised hover:text-paper disabled:cursor-default disabled:text-faint disabled:hover:bg-transparent"
          >
            <.chevron direction={:back} />
          </button>
          <span class="h-4 w-px shrink-0 bg-edge" aria-hidden="true"></span>
          <button
            type="button"
            data-history="forward"
            title="Forward"
            aria-label="Forward"
            class="flex h-6 w-6 items-center justify-center text-dim transition hover:bg-raised hover:text-paper disabled:cursor-default disabled:text-faint disabled:hover:bg-transparent"
          >
            <.chevron direction={:forward} />
          </button>
        </div>
        <div
          id="rail-pages"
          class="flex items-center overflow-hidden rounded-md border border-edge"
        >
          <.link
            id="rail-timeline"
            navigate="/"
            title="Timeline"
            aria-label="Timeline"
            class="flex h-6 items-center px-2 text-dim transition hover:bg-raised hover:text-paper"
          >
            <.timeline />
          </.link>
          <span class="h-4 w-px shrink-0 bg-edge" aria-hidden="true"></span>
          <.link
            navigate="/games"
            title="Gameroom"
            aria-label="Gameroom"
            class="flex h-6 items-center px-2 text-dim transition hover:bg-raised hover:text-paper"
          >
            <.table />
          </.link>
        </div>
        <div id="rail-utilities" class="flex items-center gap-3">
          <.link
            :if={@identity}
            navigate="/identity"
            title={identity_title(@identity)}
            aria-label="Identity"
            class="block transition hover:opacity-80"
          >
            <Avatar.avatar
              id={@identity["id"]}
              size={28}
              image={identity_image(@identity)}
              rev={Profile.rev()}
            />
          </.link>
          <.link
            id="rail-network"
            navigate="/network"
            title={"Network: #{Network.label(Network.current())}, #{@gossip.connected} live. Click to manage."}
            aria-label="Network"
            class={[
              "flex h-6 w-6 items-center justify-center rounded transition hover:bg-raised hover:text-paper",
              Network.current() == :mainnet && "text-bad",
              Network.current() != :mainnet && "text-dim"
            ]}
          >
            <span class="relative flex h-3.5 w-3.5 items-center justify-center">
              <.network_mark />
              <span
                key={@gossip.pulse}
                class={[
                  "absolute -right-0.5 -top-0.5 h-1 w-1 rounded-full",
                  (@gossip.connected > 0 && "gossip-dot") || "bg-dot"
                ]}
              />
            </span>
          </.link>
          <.link
            navigate="/settings"
            title="Settings"
            aria-label="Settings"
            class="text-dim transition hover:text-paper"
          >
            <.gear />
          </.link>
        </div>
      </div>
      <div id="rail-content" class="min-h-0 flex-1 overflow-y-auto overflow-x-hidden">
        {render_slot(@inner_block)}
      </div>
    </aside>
    """
  end

  @doc """
  A rail section heading — the label above a list or card.
  """
  slot :inner_block, required: true

  def rail_label(assigns) do
    ~H"""
    <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  One row in a rail list: a page (`navigate`) or an in-page anchor
  (`href`). The rail must never sit empty under its header — each page
  fills it with something of its own.
  """
  attr :navigate, :string, default: nil, doc: "live route to navigate to"
  attr :href, :string, default: nil, doc: "plain href (in-page anchor)"
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def rail_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      href={@href}
      title={@title}
      class="flex min-w-0 items-center gap-2 px-4 py-1 text-xs text-muted transition hover:bg-raised hover:text-paper"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # The name leads — it is what a follower of this feed sees — and the
  # local label rides in parentheses after it, where only this install
  # ever reads it. Rows the identity page passes carry the resolution
  # it just received; everyone else resolves from the read model here.
  defp identity_title(%{"name" => name, "label" => label})
       when is_binary(name) and is_binary(label) and label != "",
       do: "You are #{name} (#{label}). Click to manage identities."

  defp identity_title(%{"id" => id, "label" => label})
       when is_binary(label) and label != "",
       do: "You are #{Profile.display_name(id)} (#{label}). Click to manage identities."

  defp identity_title(_identity), do: "Identity. Click to manage."

  defp identity_image(%{"id" => _id, "image" => image}) when is_binary(image), do: image
  defp identity_image(%{"id" => id}), do: Profile.image(id)
  defp identity_image(_identity), do: nil

  # A hub with three peers: the network page's sky reduced to a mark. It
  # sits in the same box as the newspaper and table beside it, so the row
  # keeps one line whichever page the reader is on.
  defp network_mark(assigns) do
    ~H"""
    <svg
      class="h-3.5 w-3.5"
      viewBox="0 0 24 24"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="2.2" />
      <circle cx="12" cy="4" r="1.6" />
      <circle cx="5" cy="18.5" r="1.6" />
      <circle cx="19" cy="18.5" r="1.6" />
      <path d="M12 6v3.6" />
      <path d="M10.2 13.5 6.2 17.2" />
      <path d="M13.8 13.5l4 3.7" />
    </svg>
    """
  end

  # A newspaper and a table: the same move the rest of the rail makes in
  # words — the timeline is what this node has read, the room is the tables
  # it has laid out. Both are ordinary objects drawn in one stroke, so the
  # pair reads as two ways to spend an evening rather than two abstractions.
  #
  # Both are drawn inside the same box, y 5.5 to 16.5 and x 3.5 to 20.5, so
  # redrawing one does not shift it against the other: a change of shape is a
  # move, and the two have to move together.
  defp timeline(assigns) do
    ~H"""
    <svg
      class="h-4 w-4"
      viewBox="0 0 24 24"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M4 5.5h13.5A2.5 2.5 0 0 1 20 8v10.5H6.5A2.5 2.5 0 0 1 4 16V5.5Z" />
      <path d="M4 16a2.5 2.5 0 0 1 2.5-2.5H20" />
      <path d="M7 8.5h8" />
      <path d="M7 11.5h5" />
    </svg>
    """
  end

  attr :direction, :atom, required: true, values: [:back, :forward]

  # A chevron pointing back through the history, and the same mark turned
  # around for forward. Drawn to the same box as the crab's neighbours, so the
  # row keeps its line whichever way the reader is going.
  defp chevron(assigns) do
    ~H"""
    <svg
      class="h-4 w-4"
      viewBox="0 0 24 24"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.8"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d={if @direction == :back, do: "M14 6 8 12l6 6", else: "M10 6l6 6-6 6"} />
    </svg>
    """
  end

  # A table seen from standing height with one piece on it: the view you have
  # walking past the tables in the room. A table seen from directly above
  # turns into a blob at 16px, and a row of them into an app grid.
  defp table(assigns) do
    ~H"""
    <svg
      class="h-4 w-4"
      viewBox="0 0 24 24"
      aria-hidden="true"
      fill="none"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M3.5 5.5h17l-2.5 8h-12Z" />
      <path d="M7 16.5v-3" />
      <path d="M17 16.5v-3" />
      <circle cx="12" cy="9.5" r="1" fill="currentColor" stroke="none" />
    </svg>
    """
  end

  defp gear(assigns) do
    ~H"""
    <svg class="h-4 w-4" viewBox="0 0 24 24" aria-hidden="true">
      <defs>
        <linearGradient id="crab-gear" x1="0" y1="0" x2="1" y2="1">
          <stop stop-color="#fb7185" />
          <stop offset="0.5" stop-color="#e11d48" />
          <stop stop-color="#9f1239" />
        </linearGradient>
      </defs>
      <path
        fill-rule="evenodd"
        fill="url(#crab-gear)"
        stroke="url(#crab-gear)"
        stroke-width="0.6"
        stroke-linejoin="round"
        d="M 10.40 4.26 L 10.10 1.57 L 13.90 1.57 L 13.60 4.26 16.34 5.40 L 18.03 3.28 L 20.72 5.97 L 18.60 7.66 19.74 10.40 L 22.43 10.10 L 22.43 13.90 L 19.74 13.60 18.60 16.34 L 20.72 18.03 L 18.03 20.72 L 16.34 18.60 13.60 19.74 L 13.90 22.43 L 10.10 22.43 L 10.40 19.74 7.66 18.60 L 5.97 20.72 L 3.28 18.03 L 5.40 16.34 4.26 13.60 L 1.57 13.90 L 1.57 10.10 L 4.26 10.40 5.40 7.66 L 3.28 5.97 L 5.97 3.28 L 7.66 5.40 Z M 8.50 12.00 a 3.5 3.5 0 1 0 7.0 0 a 3.5 3.5 0 1 0 -7.0 0 Z"
      />
    </svg>
    """
  end
end
