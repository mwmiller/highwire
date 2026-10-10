defmodule HighWireWeb.NetworkLive do
  @moduledoc """
  The network page — the general place to manage dialing and the
  engine's view of the network.

  Sections, top to bottom: which network the engine is on (the
  profile switcher, moved here from Settings so all network concerns
  live on one page), the dialer's live state with enable/disable and
  dial-now controls, who we are connected to right now (one row per
  live peer, Patchwork's "connected pubs" affordance generalised to
  any peer), the `conn.json` address book, and the recent dial
  attempts with their backoff state.

  Read paths come from `HighWire.Timeline` (the shared client polls
  `gossip.peers` + `admin.peers.known` every 10s while a tab is
  active; this view refreshes every 5s). Write paths — the profile
  switch and the dialer controls — go through `HighWire.SSB.Sidecar`
  and `HighWire.SSB.Admin` respectively; both answer asynchronously
  and surface their outcome in a status line.
  """

  use HighWireWeb, :live_view

  alias HighWire.Avatar, as: Ident
  alias HighWire.SSB.{Admin, Network, Sidecar}
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Nav

  import HighWireWeb.Components.Time, only: [rel_time: 1]

  # How long the profile switch polls the sidecar for the engine to
  # come back (1s intervals), matching Settings' old behaviour.
  @switch_polls 60

  # The address book is read-only here; cap the rows so a large book
  # never buries the dial attempts below it.
  @known_peers_cap 50

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
     |> assign(:report, Timeline.network())
     |> assign(active: true, tick_timer: tick_timer)
     |> assign(
       network: Network.current(),
       net_status: Sidecar.status(),
       switching: false,
       switch_notice: nil,
       polls: 0,
       dial_notice: nil,
       dialing: false,
       known_peers_cap: @known_peers_cap
     )}
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
        |> assign(:report, Timeline.network())

      {:noreply, assign(socket, :tick_timer, Process.send_after(self(), :tick, 5_000))}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:network_switch, :ok, profile}, socket) do
    send(self(), :poll_net_status)

    {:noreply,
     assign(socket,
       switching: false,
       network: profile,
       polls: 0,
       switch_notice: "Network set to #{Network.label(profile)} — starting the engine…"
     )}
  end

  def handle_info({:network_switch, {:error, reason}, _profile}, socket) do
    {:noreply,
     assign(socket,
       switching: false,
       network: Network.current(),
       net_status: Sidecar.status(),
       switch_notice:
         "Still set to #{Network.label(Network.current())} — switch failed: #{switch_error(reason)}"
     )}
  end

  def handle_info(:poll_net_status, socket) do
    status = Sidecar.status()

    cond do
      status == :ready ->
        # Engine is back: pull a fresh report instead of waiting for
        # the next tick, so connections/dialer reflect the new network.
        send(self(), :tick)

        {:noreply,
         assign(socket,
           net_status: :ready,
           switch_notice: "Connected to #{Network.label(socket.assigns.network)}."
         )}

      socket.assigns.polls >= @switch_polls ->
        {:noreply,
         assign(socket,
           net_status: status,
           switch_notice: "The engine has not come back yet — reload this page shortly."
         )}

      true ->
        Process.send_after(self(), :poll_net_status, 1_000)
        {:noreply, assign(socket, net_status: status, polls: socket.assigns.polls + 1)}
    end
  end

  def handle_info({:dialer_result, :enable, {:ok, _}}, socket) do
    # Optimistic flip: the next report poll confirms from the engine.
    report =
      case socket.assigns.report do
        nil -> nil
        r -> Map.put(r, "enabled", true)
      end

    {:noreply,
     socket
     |> assign(dialing: false, dial_notice: "Auto-dial on.", report: report)
     |> refresh_report()}
  end

  def handle_info({:dialer_result, :disable, {:ok, _}}, socket) do
    report =
      case socket.assigns.report do
        nil -> nil
        r -> Map.put(r, "enabled", false)
      end

    {:noreply,
     socket
     |> assign(dialing: false, dial_notice: "Auto-dial off.", report: report)
     |> refresh_report()}
  end

  def handle_info({:dialer_result, :trigger, {:ok, _}}, socket) do
    {:noreply,
     socket
     |> assign(dialing: false, dial_notice: "Dial round started.")
     |> refresh_report()}
  end

  def handle_info({:dialer_result, _op, {:error, reason}}, socket) do
    {:noreply,
     assign(socket, dialing: false, dial_notice: "Dialer call failed: #{dial_error(reason)}")}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

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

  # -- network profile switch ---------------------------------------------

  def handle_event("switch_network", %{"network" => want}, socket)
      when want in ["dev", "mainnet"] do
    profile = String.to_existing_atom(want)

    if socket.assigns.switching or profile == socket.assigns.network do
      {:noreply, socket}
    else
      parent = self()

      Task.start(fn ->
        result =
          try do
            Sidecar.switch_network(profile)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:network_switch, result, profile})
      end)

      {:noreply,
       assign(socket,
         switching: true,
         net_status: :starting,
         switch_notice: "Switching to #{Network.label(profile)}…"
       )}
    end
  end

  def handle_event("switch_network", _params, socket), do: {:noreply, socket}

  # -- dialer controls ----------------------------------------------------

  def handle_event("dialer-toggle", _params, socket) do
    cond do
      socket.assigns.dialing ->
        {:noreply, socket}

      socket.assigns.report == nil ->
        {:noreply, assign(socket, :dial_notice, "No engine report — is the engine up?")}

      true ->
        want = if socket.assigns.report["enabled"], do: :disable, else: :enable
        parent = self()

        Task.start(fn ->
          result =
            try do
              if want == :enable, do: Admin.dialer_enable(), else: Admin.dialer_disable()
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(parent, {:dialer_result, want, result})
        end)

        {:noreply, assign(socket, dialing: true, dial_notice: "Saving dialer setting…")}
    end
  end

  def handle_event("dialer-trigger", _params, socket) do
    cond do
      socket.assigns.dialing ->
        {:noreply, socket}

      socket.assigns.report == nil ->
        {:noreply, assign(socket, :dial_notice, "No engine report — is the engine up?")}

      true ->
        parent = self()

        Task.start(fn ->
          result =
            try do
              Admin.dialer_trigger()
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(parent, {:dialer_result, :trigger, result})
        end)

        {:noreply, assign(socket, dialing: true, dial_notice: "Starting a dial round…")}
    end
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

          <%!-- Which network — the profile switcher. All network
          concerns live on this one page. --%>
          <section class="mt-6">
            <h2 class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint">
              Which network
            </h2>

            <p class="mt-3 text-sm">
              Network set to:
              <span class={if(@network == :mainnet, do: "text-bad", else: "text-paper")}>
                {Network.label(@network)}
              </span>
            </p>

            <p class="mt-2 text-sm text-dim">
              Switching rewrites the engine's overrides file and restarts the local
              engine — feeds and blobs carry over either way.
            </p>

            <div class="mt-3 flex flex-wrap gap-3" role="group" aria-label="Network">
              <button
                :for={{key, label} <- Network.profiles()}
                type="button"
                class="pref-choice"
                phx-click="switch_network"
                phx-value-network={to_string(key)}
                aria-pressed={to_string(@network == key)}
                disabled={@switching}
              >
                {label}
              </button>
            </div>

            <p :if={@switch_notice} role="status" class="mt-2 text-sm text-dim">
              {@switch_notice}
            </p>

            <p :if={@network == :custom} class="mt-2 text-sm text-bad">
              Unknown network id in overrides.cfg
              (<span class="font-mono text-xs">{Network.current_id()}</span>) — this is not a
              network HighWire knows. Switch to Development or Mainnet.
            </p>
          </section>

          <%!-- Dialer: live state from the report, controls through the
          engine's admin namespace. --%>
          <section class="mt-8">
            <h2 class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint">
              Dialer
            </h2>

            <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
              <span class={[
                @report != nil && @report["enabled"] && "text-ok",
                @report != nil && !@report["enabled"] && "text-dim",
                @report == nil && "text-dim"
              ]}>
                {cond do
                  @report == nil -> "auto-dial unknown"
                  @report["enabled"] -> "auto-dial on"
                  true -> "auto-dial off"
                end}
              </span>
              <span :if={@report != nil} class="text-dim">
                {@report["lanCandidates"]} on LAN
              </span>
              <span :if={@report != nil} class="text-dim">
                {@report["autoconnectCandidates"]} announced
              </span>
            </div>

            <div class="mt-3 flex flex-wrap gap-3">
              <button
                type="button"
                class="pref-choice"
                phx-click="dialer-toggle"
                disabled={@dialing or @report == nil}
              >
                {if @report != nil and @report["enabled"],
                  do: "Turn auto-dial off",
                  else: "Turn auto-dial on"}
              </button>
              <button
                type="button"
                class="pref-choice"
                phx-click="dialer-trigger"
                disabled={@dialing or @report == nil}
              >
                Dial now
              </button>
            </div>

            <p :if={@dial_notice} role="status" class="mt-2 text-sm text-dim">
              {@dial_notice}
            </p>
          </section>

          <p :if={@report == nil} class="mt-6 text-sm text-dim">
            No report from the local engine — it is starting up, disabled, or the
            running erlbutt predates the <span class="font-mono">gossip.peers</span> RPC.
          </p>

          <div :if={@report != nil} class="mt-8 space-y-8">
            <%!-- Patchwork's "connected pubs" affordance: one row per live
            peer, each with its own status dot — never a lone global claim. --%>
            <section>
              <h2 class="text-sm font-semibold uppercase tracking-wider text-faint">
                Connections · {length(@report["connections"] || [])} / {@report["cap"]}
              </h2>

              <div :if={@report["connections"] == []} class="mt-2 text-sm text-dim">
                No peers connected.
              </div>

              <div class="mt-2 space-y-1">
                <div
                  :for={id <- @report["connections"] || []}
                  class="flex items-center gap-2.5 rounded px-2 py-1.5 hover:bg-raised"
                >
                  <span class="h-2 w-2 shrink-0 rounded-full bg-dot-ok"></span>
                  <Avatar.avatar
                    id={id}
                    size={20}
                    image={image_of(id, @profiles)}
                    rev={blob_rev(@report)}
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
                Known peers · {length(@report["knownPeers"] || [])}
              </h2>

              <div :if={@report["knownPeers"] in [nil, []]} class="mt-2 text-sm text-dim">
                The address book is empty — it fills as pubs announce themselves.
              </div>

              <div :if={@report["knownPeers"] not in [nil, []]} class="mt-2 space-y-1">
                <div
                  :for={peer <- Enum.take(@report["knownPeers"], @known_peers_cap)}
                  class="flex items-baseline gap-3 border-b border-edge-soft px-2 py-1.5 text-xs"
                  title={peer["address"]}
                >
                  <span class="min-w-0 flex-1 break-all font-mono text-sub">
                    {addr_text(peer["address"])}
                  </span>
                  <span :if={peer["source"]} class="w-16 shrink-0 text-right text-faint">
                    {peer["source"]}
                  </span>
                  <span class={[
                    "w-20 shrink-0 text-right",
                    peer["autoconnect"] && "text-ok",
                    !peer["autoconnect"] && "text-faint"
                  ]}>
                    {if peer["autoconnect"], do: "auto", else: "manual"}
                  </span>
                </div>

                <p
                  :if={length(@report["knownPeers"]) > @known_peers_cap}
                  class="px-2 pt-1 text-[11px] text-faint"
                >
                  Showing first {@known_peers_cap} of {length(@report["knownPeers"])}.
                </p>
              </div>
            </section>

            <section>
              <h2 class="text-sm font-semibold uppercase tracking-wider text-faint">
                Recent dials
              </h2>

              <div :if={@report["dialTry"] == []} class="mt-2 text-sm text-dim">
                Nothing dialed yet.
              </div>

              <div :if={@report["dialTry"] != []} class="mt-2 space-y-1">
                <div
                  :for={try_row <- @report["dialTry"] || []}
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

  # After a successful dialer action, pull a fresh report now instead
  # of waiting for the next tick. Best-effort: a fresh report may still
  # lag the action by a beat; the tick poll is the backstop.
  defp refresh_report(socket) do
    if socket.assigns.active and connected?(socket) do
      if socket.assigns.tick_timer, do: Process.cancel_timer(socket.assigns.tick_timer)
      send(self(), :tick)
      assign(socket, :tick_timer, nil)
    else
      socket
    end
  end

  defp switch_error(:disabled), do: "the SSB engine is disabled in this configuration."

  defp switch_error(:port_busy),
    do: "the engine port is still in use — a leftover engine is holding it."

  defp switch_error(reason), do: inspect(reason)

  defp dial_error({:exit, reason}), do: inspect(reason)
  defp dial_error(:timeout), do: "the engine did not answer in time."
  defp dial_error(:no_secret), do: "no account secret found."
  defp dial_error(reason), do: inspect(reason)

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

  defp blob_rev(report) do
    report["blobRev"] || 0
  end
end
