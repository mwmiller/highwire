defmodule HighWireWeb.Components.Nav do
  @moduledoc """
  The shared left rail: the current identity's avatar (linking to the
  identity page, `/identity`) beside the crab mark (linking to the
  timeline), the settings gear at the other end, and — pinned to the
  bottom — the current network badge, which links to the network page
  (`/network`) — the general place to manage dialing and the network
  profile. Pages add their own content to the rail through the default
  slot; pages that pass none get the same wide frame, so the column
  never jumps between pages.

  The avatar comes from the identity registry: pages that cannot
  change identity while mounted let the rail read it at render, and
  the identity page passes its own row (`identity`) so a switch
  updates the avatar in place. With no identity yet (first run,
  import pending) the link simply does not render.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    router: HighWireWeb.Router,
    endpoint: HighWireWeb.Endpoint,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  alias HighWire.SSB.{Identities, Network}
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
      "The active identity's public row. Pages that can change identity while mounted (the identity page) pass it so the avatar updates in place; everyone else omits it and the rail reads the registry at render."

  slot :inner_block, doc: "Rail content below the header"

  def rail(assigns) do
    assigns = assign(assigns, :identity, assigns.identity || Identities.active())

    ~H"""
    <aside class="flex w-56 min-w-0 shrink-0 flex-col overflow-y-auto overflow-x-hidden border-r border-edge bg-panel">
      <div class="flex h-11 shrink-0 w-full items-center justify-between border-b border-edge px-4">
        <div class="flex items-center gap-2">
          <.link
            :if={@identity}
            navigate="/identity"
            title={identity_title(@identity)}
            aria-label="Identity"
            class="block transition hover:opacity-80"
          >
            <Avatar.avatar id={@identity["id"]} size={20} />
          </.link>
          <.link
            navigate="/"
            title="Timeline"
            aria-label="Timeline"
            class="flex items-center text-paper"
          >
            <img src={~p"/images/highwire-crab-mark.svg"} alt="" class="h-7 w-7" />
          </.link>
        </div>
        <.link
          navigate="/settings"
          title="Settings"
          aria-label="Settings"
          class="text-dim transition hover:text-paper"
        >
          <.gear />
        </.link>
      </div>
      {render_slot(@inner_block)}
      <.link
        navigate="/network"
        title={"Network: #{Network.label(Network.current())} — #{@gossip.connected} live — click to manage"}
        aria-label="Network"
        class={[
          "mt-auto block border-t border-edge py-2 text-center text-[10px] font-medium uppercase",
          "tracking-wide transition hover:text-paper",
          Network.current() == :mainnet && "text-bad",
          Network.current() != :mainnet && "text-dim"
        ]}
      >
        <span class="flex items-center justify-center gap-1.5">
          <span
            key={@gossip.pulse}
            class={[
              "inline-block h-1.5 w-1.5 rounded-full",
              (@gossip.connected > 0 && "gossip-dot") || "bg-dot"
            ]}
          />
          {Network.label(Network.current())}
          <span :if={@gossip.connected > 0} class="font-normal">
            · {@gossip.connected}
          </span>
        </span>
      </.link>
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

  defp identity_title(%{"label" => label}) when is_binary(label) and label != "",
    do: "You are #{label} — click to manage identities"

  defp identity_title(_identity), do: "Identity — click to manage"

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
