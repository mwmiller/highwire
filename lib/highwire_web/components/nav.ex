defmodule HighWireWeb.Components.Nav do
  @moduledoc """
  The shared left rail: the crab mark and application name (linking to
  the timeline) with the settings gear beside it, and — pinned to the
  bottom — the current network badge, which links to the network
  section of settings. Pages add their own content to the rail through
  the default slot. Pages that pass no content get a narrow
  mark-only rail instead of an empty column.
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    router: HighWireWeb.Router,
    endpoint: HighWireWeb.Endpoint,
    statics: ~w(assets fonts images favicon.ico robots.txt)

  alias HighWire.SSB.Network

  @doc """
  Renders the rail frame. Anything given as content is placed below the
  header inside the same panel; without content the rail collapses to
  a slim mark/gear column so the page keeps the space.
  """
  slot :inner_block, doc: "Rail content below the header"

  def rail(assigns) do
    assigns = assign(assigns, compact?: assigns[:inner_block] in [nil, []])

    ~H"""
    <aside class={[
      "shrink-0 overflow-y-auto border-r border-edge bg-panel",
      @compact? && "flex w-16 flex-col",
      !@compact? && "flex w-56 flex-col"
    ]}>
      <div class={[
        "flex h-11 shrink-0 items-center border-b border-edge",
        @compact? && "w-full justify-center",
        !@compact? && "w-full justify-between px-4"
      ]}>
        <.link
          :if={@compact?}
          navigate="/"
          title="Timeline"
          aria-label="Timeline"
          class="flex items-center justify-center"
        >
          <img src={~p"/images/highwire-crab-mark.svg"} alt="" class="h-7 w-7" />
        </.link>
        <.link
          :if={!@compact?}
          navigate="/"
          title="Timeline"
          class="flex items-center gap-2 font-bold tracking-tight text-paper"
        >
          <img src={~p"/images/highwire-crab-mark.svg"} alt="" class="h-6 w-6" /> HighWire
        </.link>
        <.link
          :if={!@compact?}
          navigate="/settings"
          title="Settings"
          aria-label="Settings"
          class="text-dim transition hover:text-paper"
        >
          <.gear />
        </.link>
      </div>
      <.link
        :if={@compact?}
        navigate="/settings"
        title="Settings"
        aria-label="Settings"
        class="flex w-full justify-center py-3 text-dim transition hover:text-paper"
      >
        <.gear />
      </.link>
      {render_slot(@inner_block)}
      <.link
        navigate="/settings"
        title={"Network: #{Network.label(Network.current())} — click to change"}
        aria-label="Network settings"
        class={[
          "mt-auto block border-t border-edge py-2 text-center text-[10px] font-medium uppercase",
          "tracking-wide transition hover:text-paper",
          Network.current() == :mainnet && "text-bad",
          Network.current() != :mainnet && "text-dim"
        ]}
      >
        {if @compact?, do: short_label(Network.current()), else: Network.label(Network.current())}
      </.link>
    </aside>
    """
  end

  defp short_label(:dev), do: "Dev"
  defp short_label(:mainnet), do: "Main"
  defp short_label(_other), do: "?"

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
