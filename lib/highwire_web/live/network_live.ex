defmodule HighWireWeb.NetworkLive do
  @moduledoc """
  The network page: erlbutt's `gossip.peers` report rendered as a
  dashboard — engine status, who we are connected to right now (one row
  per live peer, Patchwork's "connected pubs" affordance generalised to
  any peer), the dialer's candidate sources, and the recent dial
  attempts with their backoff state.

  Kept read-only: the dialer's enable/disable and invite redemption are
  affordances for a later pass. Data comes from `HighWire.Timeline`
  (polled every 10s server-side while a tab is active; this view
  refreshes every 5s).
  """

  use HighWireWeb, :live_view

  alias HighWire.Avatar, as: Ident
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Nav

  import HighWireWeb.Components.Time, only: [rel_time: 1]

  @impl true
  def mount(_params, _session, socket) do
    tick_timer =
      if connected?(socket) do
        Timeline.set_activity(self(), true)
        Process.send_after(self(), :tick, 100)
      end

    {status, payload} = Timeline.snapshot()

    {:ok,
     socket
     |> assign(:page_title, "Network")
     |> assign(:status, status)
     |> assign(:profiles, Map.get(payload, :profiles, %{}))
     |> assign(:network, Timeline.network())
     |> assign(active: true, tick_timer: tick_timer)}
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.tick_timer, do: Process.cancel_timer(socket.assigns.tick_timer)
    socket = assign(socket, :tick_timer, nil)

    if socket.assigns.active and connected?(socket) do
      Timeline.set_activity(self(), true)
      {status, payload} = Timeline.snapshot()

      socket =
        socket
        |> assign(:status, status)
        |> assign(:profiles, Map.get(payload, :profiles, %{}))
        |> assign(:network, Timeline.network())

      {:noreply, assign(socket, :tick_timer, Process.send_after(self(), :tick, 5_000))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("tab-active", _params, socket) do
    Timeline.set_activity(self(), true)

    if socket.assigns.active do
      {:noreply, socket}
    else
      send(self(), :tick)
      {:noreply, assign(socket, :active, true)}
    end
  end

  def handle_event("tab-inactive", _params, socket) do
    Timeline.set_activity(self(), false)
    if socket.assigns.tick_timer, do: Process.cancel_timer(socket.assigns.tick_timer)

    {:noreply, socket |> assign(:active, false) |> assign(:tick_timer, nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="network-root"
      phx-hook="TabActivity"
      class="flex h-screen overflow-hidden bg-app text-ink"
    >
      <Nav.rail />

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <div class="flex items-baseline gap-3">
            <h1 class="text-xl font-bold text-paper">Network</h1>
            <span class="flex items-center gap-1.5 text-xs text-dim">
              <span class={["h-2 w-2 rounded-full", status_dot(@status)]}></span>
              {status_text(@status)}
            </span>
          </div>

          <p :if={@network == nil} class="mt-4 text-sm text-dim">
            No report from the local engine — it is starting up, disabled, or the
            running erlbutt predates the <span class="font-mono">gossip.peers</span> RPC.
          </p>

          <div :if={@network != nil} class="mt-6 space-y-8">
            <%!-- Patchwork's "connected pubs" affordance: one row per live
            peer, each with its own status dot — never a lone global claim. --%>
            <section>
              <h2 class="text-sm font-semibold uppercase tracking-wider text-faint">
                Connections · {length(@network["connections"] || [])} / {@network["cap"]}
              </h2>

              <div :if={@network["connections"] == []} class="mt-2 text-sm text-dim">
                No peers connected.
              </div>

              <div class="mt-2 space-y-1">
                <div
                  :for={id <- @network["connections"] || []}
                  class="flex items-center gap-2.5 rounded px-2 py-1.5 hover:bg-raised"
                >
                  <span class="h-2 w-2 shrink-0 rounded-full bg-dot-ok"></span>
                  <Avatar.avatar
                    id={id}
                    size={20}
                    image={image_of(id, @profiles)}
                    rev={blob_rev(@network)}
                  />
                  <.link
                    navigate={profile_href(id)}
                    class="min-w-0 truncate text-sm text-ink hover:underline"
                  >
                    {display_name(id, @profiles)}
                  </.link>
                  <span class="ml-auto shrink-0 font-mono text-[11px] text-faint">
                    {Ident.short_id(id)}
                  </span>
                </div>
              </div>
            </section>

            <section>
              <h2 class="text-sm font-semibold uppercase tracking-wider text-faint">
                Dialer
              </h2>
              <div class="mt-2 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
                <span class={[
                  @network["enabled"] && "text-ok",
                  !@network["enabled"] && "text-dim"
                ]}>
                  {if @network["enabled"], do: "auto-dial on", else: "auto-dial off"}
                </span>
                <span class="text-dim">
                  {@network["lanCandidates"]} on LAN
                </span>
                <span class="text-dim">
                  {@network["autoconnectCandidates"]} announced
                </span>
              </div>
            </section>

            <section>
              <h2 class="text-sm font-semibold uppercase tracking-wider text-faint">
                Recent dials
              </h2>

              <div :if={@network["dialTry"] == []} class="mt-2 text-sm text-dim">
                Nothing dialed yet.
              </div>

              <div :if={@network["dialTry"] != []} class="mt-2 space-y-1">
                <div
                  :for={try_row <- @network["dialTry"] || []}
                  class="flex items-baseline gap-3 border-b border-edge-soft px-2 py-1.5 text-xs"
                >
                  <span class="min-w-0 flex-1 break-all font-mono text-sub">
                    {addr_text(try_row["addr"])}
                  </span>
                  <span class={[
                    "w-16 shrink-0 text-right font-mono",
                    try_row["attempts"] == 0 && "text-ok",
                    try_row["attempts"] > 0 && "text-warn"
                  ]}>
                    {if try_row["attempts"] == 0, do: "ok", else: "#{try_row["attempts"]} fails"}
                  </span>
                  <span class="w-24 shrink-0 text-right text-faint">
                    {rel_time(try_row["lastTry"])}
                  </span>
                </div>
              </div>
            </section>
          </div>
        </div>
      </section>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------

  defp status_dot(:ok), do: "bg-dot-ok"
  defp status_dot(:connecting), do: "bg-dot-info animate-pulse"
  defp status_dot(:loading), do: "bg-dot-info animate-pulse"
  defp status_dot(:down), do: "bg-dot-bad"
  defp status_dot(_), do: "bg-dot"

  defp status_text(:ok), do: "engine online"
  defp status_text(:connecting), do: "connecting…"
  defp status_text(:loading), do: "loading feeds…"
  defp status_text(:down), do: "engine down"
  defp status_text(_), do: "engine disabled"

  # "net:host:port~shs:key" → "host:port" (the key is noise in a list;
  # the full string stays in the title attribute).
  defp addr_text("net:" <> rest) do
    rest
    |> String.split("~shs:", parts: 2)
    |> hd()
  end

  defp addr_text(other), do: other

  defp profile_href("@" <> _ = id), do: "/profile?id=" <> URI.encode_www_form(id)
  defp profile_href(_id), do: "/"

  defp display_name(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{name: name}} when is_binary(name) -> name
      _ -> Ident.short_id(id)
    end
  end

  defp image_of(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{image: image}} -> image
      _ -> nil
    end
  end

  defp blob_rev(network) do
    network["blobRev"] || 0
  end
end
