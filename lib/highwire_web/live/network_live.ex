defmodule HighWireWeb.NetworkLive do
  @moduledoc """
  The network page — the general place to manage dialing and the
  engine's view of the network.

  Sections, top to bottom: which network the engine is on (the
  profile switcher, moved here from Settings so all network concerns
  live on one page), the dialer's live state with enable/disable and
  dial-now controls, the constellation — a radial map of the same
  facts the lists below state (self at centre, rings outward as a
  ladder of connectivity: a session open now, an address whose last
  handshake worked, one we are backing off after, and an address-book
  entry with no result at all) — who we are connected to right now
  (one row per live peer, Patchwork's "connected pubs" affordance
  generalised to any peer), the `conn.json` address book, and the
  recent dial attempts with their backoff state. Dialing and book
  peers are selectable in either the sky or their list row — both
  highlight together and the row scrolls into view; live peers are
  named links to their profiles.

  Node positions hash from each peer's address, so the sky holds
  still between polls — membership changes add or remove a node
  without reshuffling its neighbours. A flare on the live ring rides
  the same gossip pulse the rail badge breathes by.

  Read paths come from `HighWire.Timeline` (the shared client polls
  `gossip.peers` + `admin.peers.known` every 10s while a tab is
  active; this view refreshes every 5s). Write paths — the profile
  switch and the dialer controls — go through `HighWire.SSB.Sidecar`
  and `HighWire.SSB.Admin` respectively; both answer asynchronously
  and surface their outcome in a status line.
  """

  use HighWireWeb, :live_view

  alias HighWire.Avatar, as: Ident
  alias HighWire.SSB.{Admin, ConnSuppress, Network, Sidecar}
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Nav

  import HighWireWeb.Components.Time, only: [age: 1]

  # How long the profile switch polls the sidecar for the engine to
  # come back (2s intervals), matching Settings' old 60-second window.
  @switch_polls 30

  # Show the full address book/history rather than capping it.
  @known_peers_cap :all

  # Consecutive failed dials, with no handshake at all on record, before
  # an address is marked as one that never replies. A single failure is
  # a blip — the engine backs off and tries again, and most do answer.
  @no_reply_min_attempts 2

  # The sky's centre and its four rings as {rx, ry} pairs. The rings are
  # ellipses rather than circles because the panel is wide: a circle
  # sized to the height strands a third of the width unused. They are a
  # ladder of connectivity, innermost best, and a peer is drawn on the
  # innermost rung it qualifies for — improving moves a dot inward
  # rather than adding a second one.
  @sky_cx 320
  @sky_cy 175
  @sky_rings [live: {86, 54}, ok: {136, 86}, retry: {188, 119}, book: {240, 152}]

  # How far recency nudges a node along its ring — ±10% inward for a
  # peer the cache just heard of, outward for one it has gone quiet on.
  @sky_spread 0.1

  # Two keys hashing within a few buckets of the same ring would draw
  # on top of each other — a merged pair reads as a missing peer. A
  # node landing this close to an already-placed one rotates around
  # the ring in @sky_kick_step slices until it clears.
  @sky_min_sep 10
  @sky_kick_step 2 * :math.pi() / 20
  @sky_kick_steps 4

  # Peer metadata older than this reads as fully cold.
  @sky_recency_span :timer.hours(24)

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
     # Isolated test mounts skip the session's gossip hook; keep a
     # zeroed default so the rail badge still renders. assign_new so a
     # live count set by the hook survives.
     |> assign_new(:gossip, fn -> %{connected: 0, pulse: 0} end)
     |> assign(:page_title, "Network")
     |> assign(:status, status)
     |> assign(:profiles, Map.get(payload, :profiles, %{}))
     |> assign(:report, report_or_seed(Timeline.network(), Timeline.peer_meta()))
     |> assign(:peer_meta, Timeline.peer_meta())
     |> assign(active: true, tick_timer: tick_timer)
     |> assign(selected: nil)
     |> assign(
       network: Network.current(),
       net_status: Sidecar.status(),
       switching: false,
       switch_notice: nil,
       polls: 0,
       dial_notice: nil,
       dialing: false,
       known_peers_cap: @known_peers_cap,
       suppress_preview: nil,
       suppress_notice: nil,
       suppressing: false
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.tick_timer, do: Process.cancel_timer(socket.assigns.tick_timer)
    socket = assign(socket, :tick_timer, nil)

    if socket.assigns.active and connected?(socket) do
      Timeline.set_activity(self(), true)
      {status, payload} = Timeline.snapshot()
      peer_meta = Timeline.peer_meta()

      socket =
        socket
        |> assign(:status, status)
        |> assign(:profiles, Map.get(payload, :profiles, %{}))
        |> assign(:report, report_or_seed(Timeline.network(), peer_meta))
        |> assign(:peer_meta, peer_meta)

      {:noreply, assign(socket, :tick_timer, Process.send_after(self(), :tick, 7_000))}
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
       switch_notice: "Network set to #{Network.label(profile)}. Starting up…"
     )}
  end

  def handle_info({:network_switch, {:error, reason}, _profile}, socket) do
    {:noreply,
     assign(socket,
       switching: false,
       network: Network.current(),
       net_status: Sidecar.status(),
       switch_notice:
         "Still set to #{Network.label(Network.current())}. The switch failed: #{switch_error(reason)}"
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
           switch_notice: "The service has not come back yet. Reload this page shortly."
         )}

      true ->
        Process.send_after(self(), :poll_net_status, 2_000)
        {:noreply, assign(socket, net_status: status, polls: socket.assigns.polls + 1)}
    end
  end

  def handle_info({:dialer_result, :enable, {:ok, _}}, socket) do
    # Optimistic flip: the next report poll confirms from the engine.
    report = Map.put(socket.assigns.report, "enabled", true)

    {:noreply,
     socket
     |> assign(dialing: false, dial_notice: "Auto-dial on.", report: report)
     |> refresh_report()}
  end

  def handle_info({:dialer_result, :disable, {:ok, _}}, socket) do
    report = Map.put(socket.assigns.report, "enabled", false)

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

  def handle_info({:suppress_result, result}, socket) do
    notice =
      case result do
        {:ok, changed, backup} ->
          "Suppressed #{changed} address#{if changed == 1, do: "", else: "es"}; " <>
            "the service was restarted to pick it up. Backup: #{Path.basename(backup)}"

        {:error, {:restart_failed, reason, changed, backup}} ->
          "Wrote #{changed} suppression#{if changed == 1, do: "", else: "s"} (backup #{Path.basename(backup)}), " <>
            "but the service would not restart: #{inspect(reason)}"

        {:error, reason} ->
          "Suppression failed: #{inspect(reason)}"
      end

    {:noreply, socket |> assign(suppressing: false, suppress_notice: notice) |> refresh_report()}
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

      socket.assigns.report["seeded"] ->
        {:noreply, assign(socket, :dial_notice, "No report yet. Is the service up?")}

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

      socket.assigns.report["seeded"] ->
        {:noreply, assign(socket, :dial_notice, "No report yet. Is the service up?")}

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

  # -- suppression ---------------------------------------------------------

  # Preview is pure: classify the address book on disk against the dial
  # cache the page already holds, and show what would change before
  # anything is written. The book, not the report, is the source: the
  # report's knownPeers drops the autoconnect flag, so it cannot tell an
  # already-suppressed entry from a live one, and it is the book that
  # apply/1 edits.
  def handle_event("suppress-preview", _params, socket) do
    {addrs, counts} = ConnSuppress.classify(ConnSuppress.book_peers(), socket.assigns.peer_meta)

    {:noreply, assign(socket, suppress_preview: %{addrs: addrs, counts: counts})}
  end

  def handle_event("suppress-cancel", _params, socket) do
    {:noreply, assign(socket, suppress_preview: nil)}
  end

  # Applying stops and restarts the engine, so it runs off the socket
  # process; the tick poll refreshes the report when the engine is back.
  def handle_event("suppress-apply", _params, socket) do
    case socket.assigns.suppress_preview do
      %{addrs: [_ | _] = addrs} ->
        parent = self()

        Task.start(fn ->
          result =
            try do
              Sidecar.apply_conn_suppression(addrs)
            catch
              kind, reason -> {:error, {kind, reason}}
            end

          send(parent, {:suppress_result, result})
        end)

        {:noreply,
         assign(socket,
           suppressing: true,
           suppress_preview: nil,
           suppress_notice: "Saving connection settings and restarting…"
         )}

      _ ->
        {:noreply, assign(socket, suppress_preview: nil, suppress_notice: "Nothing to suppress.")}
    end
  end

  # -- constellation ------------------------------------------------------

  # A dialing or book node and its list row are the same peer; selecting
  # one highlights both, and the SkyScroll hook brings the row into view.
  # Clicking the selected peer again retires the selection.
  def handle_event("sky-select", %{"addr" => addr}, socket) do
    selected = if socket.assigns.selected == addr, do: nil, else: addr
    {:noreply, assign(socket, :selected, selected)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="network-root"
      phx-hook="TabActivity"
      class="flex h-screen overflow-hidden bg-app text-ink"
    >
      <Nav.rail gossip={@gossip}>
        <Nav.rail_label>On this page</Nav.rail_label>
        <Nav.rail_link href="#which-network">Which network</Nav.rail_link>
        <Nav.rail_link href="#dialer">Dialer</Nav.rail_link>
        <Nav.rail_link href="#constellation">Constellation</Nav.rail_link>
        <Nav.rail_link href="#connections">Connections</Nav.rail_link>
        <Nav.rail_link href="#known-peers">Known peers</Nav.rail_link>
        <Nav.rail_link href="#dials">Recent dials</Nav.rail_link>
      </Nav.rail>

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
            <h2
              id="which-network"
              class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint"
            >
              Which network
            </h2>

            <p class="mt-3 text-sm">
              Network set to:
              <span class={if(@network == :mainnet, do: "text-bad", else: "text-paper")}>
                {Network.label(@network)}
              </span>
            </p>

            <p class="mt-2 text-sm text-dim">
              Switching rewrites the local configuration and restarts the service.
              Feeds and blobs carry over either way.
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
              (<span class="font-mono text-xs">{Network.current_id()}</span>). This is not a
              network HighWire knows. Switch to Development or Mainnet.
            </p>
          </section>

          <%!-- Dialer: live state from the report, controls through the
          engine's admin namespace. --%>
          <section class="mt-8">
            <h2
              id="dialer"
              class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint"
            >
              Dialer
            </h2>

            <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
              <span class={[
                @report["enabled"] == true && "text-ok",
                @report["enabled"] == false && "text-dim",
                is_nil(@report["enabled"]) && "text-dim"
              ]}>
                {cond do
                  is_nil(@report["enabled"]) -> "auto-dial unknown"
                  @report["enabled"] -> "auto-dial on"
                  true -> "auto-dial off"
                end}
              </span>
              <span :if={not is_nil(@report["lanCandidates"])} class="text-dim">
                {@report["lanCandidates"]} on LAN
              </span>
              <span :if={not is_nil(@report["autoconnectCandidates"])} class="text-dim">
                {@report["autoconnectCandidates"]} announced
              </span>
            </div>

            <div class="mt-3 flex flex-wrap gap-3">
              <button
                type="button"
                class="pref-choice"
                phx-click="dialer-toggle"
                aria-pressed={to_string(@report["enabled"])}
                disabled={@dialing or @report["seeded"]}
              >
                {if @report["enabled"],
                  do: "Turn auto-dial off",
                  else: "Turn auto-dial on"}
              </button>
              <button
                type="button"
                class="pref-choice"
                phx-click="dialer-trigger"
                disabled={@dialing or @report["seeded"]}
              >
                Dial now
              </button>
            </div>

            <p :if={@dial_notice} role="status" class="mt-2 text-sm text-dim">
              {@dial_notice}
            </p>
          </section>

          <p :if={@report["seeded"]} class="mt-6 text-sm text-dim" role="status">
            The local service is not answering, so this is the cache from the last
            session that did. Connections and dial history are unknown.
          </p>

          <div class="mt-8 space-y-8">
            <%!-- The sky: the lists below stated in one glance. Self at
            centre, rings outward as a ladder of connectivity — a muxrpc
            session open now (tethered, green, named), an address whose
            last handshake worked (blue), one we are backing off after
            (amber, an open ring: still trying, so it carries less ink
            than a state we have attained), an address-book entry with
            no result at all (plain). A peer sits on the innermost rung
            it qualifies for, so improving moves a dot inward rather
            than adding a second one.
            Positions hash from the feed id, so nodes hold still between
            polls and while climbing; each drifts outward and fades when
            we have gone quiet on it. Dialing and book peers are
            clickable; live peers are links to their profiles. --%>
            <section>
              <h2
                id="constellation"
                class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint"
              >
                Constellation
              </h2>

              <div class="mt-3 rounded border border-edge bg-panel py-2">
                <svg
                  viewBox="0 0 640 350"
                  preserveAspectRatio="xMidYMid meet"
                  class="w-full"
                  role="img"
                  aria-label={sky_summary(@report)}
                >
                  <%!-- The rings are ellipses carrying the panel's own
                  proportion, so the sky fills the width it is given
                  instead of stranding a small circle in a wide box. --%>
                  <ellipse
                    :for={{rx, ry} <- sky_rings()}
                    cx={sky_cx()}
                    cy={sky_cy()}
                    rx={rx}
                    ry={ry}
                    class="fill-none stroke-edge-soft"
                  />

                  <%!-- Each ring names itself and counts what it
                  carries, so the picture says what it is without a
                  trip down to the key. --%>
                  <text
                    :for={{ring, label, n} <- sky_ring_labels(@report)}
                    x={sky_cx()}
                    y={sky_cy() - sky_ring_ry(ring) - 7}
                    text-anchor="middle"
                    class="fill-faint text-[9px] sky-label"
                  >
                    {label} · {n}
                  </text>

                  <%!-- Outermost rung first, so the connected ring is
                  never buried under the ones describing peers we are
                  not talking to. Only a socket we actually hold earns a
                  tether; the rest are places on a ladder. --%>
                  <line
                    :for={{peer, recency, x, y} <- sky_stage(@report, @peer_meta, :book)}
                    :if={peer["autoconnect"]}
                    x1={sky_cx()}
                    y1={sky_cy()}
                    x2={x}
                    y2={y}
                    opacity={sky_dim(recency, 0.5)}
                    stroke-dasharray="2 4"
                    class="stroke-edge-soft"
                  />

                  <g
                    :for={{peer, recency, x, y} <- sky_stage(@report, @peer_meta, :book)}
                    key={"known-" <> (peer["address"] || "")}
                  >
                    <circle
                      :if={@selected == peer["address"]}
                      cx={x}
                      cy={y}
                      r={9}
                      class="fill-none stroke-accent"
                    />
                    <circle
                      cx={x}
                      cy={y}
                      r={3.5}
                      opacity={sky_opacity(recency)}
                      class="fill-dot"
                    />
                    <circle
                      cx={x}
                      cy={y}
                      r={12}
                      class="cursor-pointer fill-transparent"
                      phx-click="sky-select"
                      phx-value-addr={peer["address"]}
                    />
                    <title>{sky_peer_title(peer["address"], @profiles)}</title>
                  </g>

                  <g
                    :for={{try_row, recency, x, y} <- sky_stage(@report, @peer_meta, :retry)}
                    key={"retry-" <> (try_row["addr"] || "")}
                  >
                    <circle
                      :if={@selected == try_row["addr"]}
                      cx={x}
                      cy={y}
                      r={9}
                      class="fill-none stroke-accent"
                    />
                    <circle
                      cx={x}
                      cy={y}
                      r={4}
                      stroke-width={1.25}
                      opacity={sky_opacity(recency)}
                      class="fill-none stroke-warn"
                    />
                    <circle
                      cx={x}
                      cy={y}
                      r={12}
                      class="cursor-pointer fill-transparent"
                      phx-click="sky-select"
                      phx-value-addr={try_row["addr"]}
                    />
                    <title>
                      {"retrying " <>
                        sky_peer_title(try_row["addr"], @profiles) <>
                        ". #{try_row["attempts"] || 0} fails"}
                    </title>
                  </g>

                  <g
                    :for={{try_row, recency, x, y} <- sky_stage(@report, @peer_meta, :ok)}
                    key={"ok-" <> (try_row["addr"] || "")}
                  >
                    <circle
                      :if={@selected == try_row["addr"]}
                      cx={x}
                      cy={y}
                      r={9}
                      class="fill-none stroke-accent"
                    />
                    <circle cx={x} cy={y} r={4.5} opacity={sky_opacity(recency)} class="fill-info" />
                    <circle
                      cx={x}
                      cy={y}
                      r={12}
                      class="cursor-pointer fill-transparent"
                      phx-click="sky-select"
                      phx-value-addr={try_row["addr"]}
                    />
                    <title>
                      {"reached " <>
                        sky_peer_title(try_row["addr"], @profiles) <>
                        ". Last handshake"}
                    </title>
                  </g>

                  <line
                    :for={{_id, recency, x, y} <- sky_stage(@report, @peer_meta, :live)}
                    x1={sky_cx()}
                    y1={sky_cy()}
                    x2={x}
                    y2={y}
                    opacity={sky_opacity(recency)}
                    class="stroke-edge-soft"
                  />

                  <%!-- Self reads as a target rather than another
                  peer: a ring around the dot, so the centre never
                  competes with the blue of a peer we merely reached. --%>
                  <circle
                    cx={sky_cx()}
                    cy={sky_cy()}
                    r={10}
                    fill="none"
                    stroke="var(--accent)"
                    stroke-width="1"
                    opacity="0.45"
                  />
                  <circle cx={sky_cx()} cy={sky_cy()} r={4.5} class="fill-accent" />
                  <text
                    x={sky_cx()}
                    y={sky_cy() + 17}
                    text-anchor="middle"
                    class="fill-faint text-[9px] sky-label"
                  >
                    you
                  </text>

                  <%!-- The live ring keys on the gossip pulse: a real
                  connection change replaces the group, replaying the
                  nodes' flare exactly when the sky's membership moved.
                  --%>
                  <g key={@gossip.pulse}>
                    <g :for={{id, recency, x, y} <- sky_stage(@report, @peer_meta, :live)}>
                      <.link navigate={profile_href(id)} class="group">
                        <%!-- A generous hit ring: the name is the reward
                        for hovering, so the thing you hover must not be
                        a five-pixel dot. --%>
                        <circle cx={x} cy={y} r={12} pointer-events="all" class="fill-none" />
                        <circle
                          cx={x}
                          cy={y}
                          r={5}
                          opacity={sky_opacity(recency)}
                          class="fill-dot-ok gossip-node-flare"
                        />
                        <%!-- Names surface under the pointer rather than
                        all at once: four labels landing on one another
                        carried less information than four green dots.
                        pointer-events keeps a hidden name from acting
                        as an invisible hover zone. --%>
                        <text
                          x={sky_label(x, y).x}
                          y={sky_label(x, y).y}
                          text-anchor={sky_label(x, y).anchor}
                          pointer-events="none"
                          class="fill-sub text-[10px] sky-label opacity-0 transition-opacity group-hover:opacity-100 group-focus:opacity-100"
                        >
                          {sky_short_name(id, @profiles)}
                        </text>
                        <title>{Ident.display_name(id, @profiles)}</title>
                      </.link>
                    </g>
                  </g>
                </svg>

                <span
                  id="sky-scroll"
                  phx-hook="SkyScroll"
                  data-target={@selected}
                  class="hidden"
                ></span>

                <div class="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 px-3 pb-1 text-[11px] text-faint">
                  <span class="flex items-center gap-1.5">
                    <span class="flex h-2.5 w-2.5 items-center justify-center rounded-full border border-accent">
                      <span class="h-1 w-1 rounded-full bg-accent"></span>
                    </span>
                    you
                  </span>
                  <span
                    class="flex items-center gap-1.5"
                    title="a muxrpc session is open right now"
                  >
                    <span class="h-1.5 w-1.5 rounded-full bg-dot-ok"></span>connected
                  </span>
                  <span
                    class="flex items-center gap-1.5"
                    title="the last dial completed a handshake, but no session is open now"
                  >
                    <span class="h-1.5 w-1.5 rounded-full bg-dot-info"></span>reached
                  </span>
                  <span
                    class="flex items-center gap-1.5"
                    title="handshakes are failing and the dialer is backing off. Still trying, so drawn as an open ring"
                  >
                    <span class="h-2 w-2 rounded-full border border-warn"></span>retrying
                  </span>
                  <span
                    class="flex items-center gap-1.5"
                    title="in the address book, never successfully dialed"
                  >
                    <span class="h-1.5 w-1.5 rounded-full bg-dot"></span>never tried
                  </span>
                  <span class="flex items-center gap-1.5">
                    <span class="h-2.5 w-2.5 rounded-full border border-accent"></span>selected
                  </span>
                  <span class="flex items-center gap-1.5">
                    <span class="block h-0 w-4 border-t-2 border-dashed border-edge"></span>
                    <span>autoconnect</span>
                  </span>
                  <span class="text-sub">hover a peer for its name</span>
                  <span class="text-sub">
                    faded and rimmed peers are ones we have gone quiet on
                  </span>
                </div>
              </div>

              <p :if={sky_empty?(@report)} class="mt-2 text-sm text-dim">
                Quiet sky. No peers, no pending dials, empty address book.
              </p>
            </section>

            <%!-- Patchwork's "connected pubs" affordance: one row per live
            peer, each with its own status dot — never a lone global claim. --%>
            <section>
              <h2
                id="connections"
                class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint"
              >
                Connections · {connections_header(@report)}
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
                    {Ident.display_name(id, @profiles)}
                  </.link>
                  <span class="ml-auto shrink-0 font-mono text-[11px] text-faint">
                    {Ident.short_id(id)}
                  </span>
                </div>
              </div>
            </section>

            <section>
              <h2
                id="known-peers"
                class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint"
              >
                All known peers (history) · {length(@report["knownPeers"] || [])}
              </h2>

              <div :if={@report["knownPeers"] in [nil, []]} class="mt-2 text-sm text-dim">
                The address book is empty. It fills as pubs announce themselves.
              </div>

              <div class="mt-2 rounded border border-edge-soft bg-panel px-3 py-2">
                <p class="text-xs text-dim">
                  Stop dialing addresses that can never answer: loopback and
                  private announce addresses, <code class="text-faint">.onion</code>,
                  IPv6 literals, wrong ports, and any address the dialer has
                  failed repeatedly with no handshake on record. An address that
                  has ever answered is never listed. Each is marked
                  <code class="text-faint">autoconnect: false</code>
                  in <code class="text-faint">conn.json</code>, which survives
                  re-announcement; applying it restarts the service to take effect.
                </p>

                <div class="mt-2 flex flex-wrap items-center gap-3">
                  <button
                    type="button"
                    class="pref-choice"
                    phx-click="suppress-preview"
                    disabled={@suppressing or @report["seeded"]}
                  >
                    Preview suppression
                  </button>

                  <button
                    :if={@suppress_preview}
                    type="button"
                    class="pref-choice"
                    phx-click="suppress-apply"
                    disabled={@suppressing or @suppress_preview.addrs == []}
                  >
                    Suppress {@suppress_preview.counts[:total] || 0} &amp; restart
                  </button>

                  <button
                    :if={@suppress_preview}
                    type="button"
                    class="pref-choice"
                    phx-click="suppress-cancel"
                    disabled={@suppressing}
                  >
                    Cancel
                  </button>
                </div>

                <p
                  :if={@suppress_preview && @suppress_preview.addrs != []}
                  class="mt-2 text-xs text-dim"
                >
                  {suppress_summary(@suppress_preview.counts)}
                </p>

                <p
                  :if={@suppress_preview && @suppress_preview.addrs == []}
                  class="mt-2 text-xs text-dim"
                >
                  Nothing to suppress. Every book entry could still answer.
                </p>

                <p :if={@suppress_notice} role="status" class="mt-2 text-xs text-dim">
                  {@suppress_notice}
                </p>
              </div>

              <div
                :if={@report["knownPeers"] not in [nil, []]}
                id="known-peer-rows"
                class="mt-3 space-y-1"
              >
                <div
                  :for={{peer, id} <- known_rows(@report, @known_peers_cap)}
                  data-sky-key={peer["address"]}
                  phx-click="sky-select"
                  phx-value-addr={peer["address"]}
                  title={peer["address"]}
                  class={[
                    "flex cursor-pointer items-center gap-3 border-b border-edge-soft px-2 py-1.5 text-xs",
                    @selected == peer["address"] && "bg-raised"
                  ]}
                >
                  <Avatar.avatar
                    :if={id}
                    id={id}
                    size={18}
                    image={image_of(id, @profiles)}
                    rev={blob_rev(@report)}
                    class="shrink-0"
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sub">
                      {if id,
                        do: Ident.display_name(id, @profiles),
                        else: addr_text(peer["address"])}
                    </span>
                    <span :if={id} class="block truncate font-mono text-[11px] text-faint">
                      {addr_text(peer["address"])}
                    </span>
                  </span>
                  <span
                    :if={no_reply?(peer["address"], @peer_meta)}
                    class="shrink-0 text-bad"
                    data-no-reply={peer["address"]}
                    title={no_reply_note(peer["address"], @peer_meta)}
                  >
                    no reply
                  </span>
                  <span
                    :if={ever_connected?(peer["address"], @peer_meta)}
                    class="shrink-0 text-ok"
                    title={ever_connected_note(peer["address"], @peer_meta)}
                  >
                    connected
                  </span>
                  <span
                    :if={
                      ever_ok?(peer["address"], @peer_meta) and
                        !ever_connected?(peer["address"], @peer_meta)
                    }
                    class="shrink-0 text-info"
                    title={ever_ok_note(peer["address"], @peer_meta)}
                  >
                    ok
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
                  :if={
                    is_integer(@known_peers_cap) and
                      length(@report["knownPeers"] || []) > @known_peers_cap
                  }
                  class="px-2 pt-1 text-[11px] text-faint"
                >
                  Showing first {@known_peers_cap} of {length(@report["knownPeers"] || [])}.
                </p>
              </div>
            </section>

            <section>
              <h2
                id="dials"
                class="border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wider text-faint"
              >
                Recent dials
              </h2>

              <p class="mt-2 text-sm text-dim">
                Addresses the dialer has tried {dial_window(@report["dialTry"])} are not
                open sockets. <span class="text-ok">ok</span> means the last handshake
                completed; <span class="text-warn">fails</span> counts consecutive
                failures.
              </p>

              <div :if={@report["dialTry"] in [nil, []]} class="mt-2 text-sm text-dim">
                {if @report["partial"],
                  do: "Nothing dialed yet. This build does not report dial history.",
                  else: "Nothing dialed yet."}
              </div>

              <div :if={@report["dialTry"] not in [nil, []]} id="dial-rows" class="mt-2 space-y-1">
                <div
                  :for={try_row <- @report["dialTry"] || []}
                  data-sky-key={try_row["addr"]}
                  phx-click="sky-select"
                  phx-value-addr={try_row["addr"]}
                  class={[
                    "flex cursor-pointer items-baseline gap-3 border-b border-edge-soft px-2 py-1.5 text-xs",
                    @selected == try_row["addr"] && "bg-raised"
                  ]}
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
                    <.age ts={try_row["lastTry"]} />
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

  defp switch_error(:disabled), do: "SSB is disabled in this configuration."

  defp switch_error(:port_busy),
    do: "the port is still in use. A leftover process is holding it."

  defp switch_error(reason), do: inspect(reason)

  defp dial_error({:exit, reason}), do: inspect(reason)
  defp dial_error(:timeout), do: "Connection timed out."
  defp dial_error(:no_secret), do: "no account secret found."
  defp dial_error(reason), do: inspect(reason)

  defp status_dot(:ok), do: "bg-dot-ok"
  defp status_dot(:connecting), do: "bg-dot-info animate-pulse"
  defp status_dot(:loading), do: "bg-dot-info animate-pulse"
  defp status_dot(:down), do: "bg-dot-bad"
  defp status_dot(_), do: "bg-dot"

  defp status_text(:ok), do: "service online"
  defp status_text(:connecting), do: "connecting…"
  defp status_text(:loading), do: "loading feeds…"
  defp status_text(:down), do: "service down"
  defp status_text(_), do: "service disabled"

  # The rows the address book shows: each entry paired with the feed id
  # behind it — the engine's own `key` when it carries one, else the
  # shs key in the address, which is the same key in its bare form. The
  # id is what the identicon and the alias-aware name hang on; a row
  # with none falls back to showing its address as the name.
  defp known_rows(report, :all) do
    (report["knownPeers"] || [])
    |> Enum.map(fn peer -> {peer, peer_id(peer)} end)
  end

  defp known_rows(report, cap) when is_integer(cap) do
    (report["knownPeers"] || [])
    |> Enum.take(cap)
    |> Enum.map(fn peer -> {peer, peer_id(peer)} end)
  end

  defp peer_id(%{"key" => id}) when is_binary(id), do: id
  defp peer_id(%{"address" => addr}) when is_binary(addr), do: sky_key(addr)
  defp peer_id(_peer), do: nil

  # "net:host:port~shs:key" → "host:port" (the key is noise in a list;
  # the full string stays in the title attribute).
  defp addr_text("net:" <> rest) do
    rest
    |> String.split("~shs:", parts: 2)
    |> hd()
  end

  defp addr_text(other), do: other

  # An address the engine has dialed and never once seen answer. The
  # verdict comes from the peer cache, which the timeline keeps from
  # every report the engine sends: the ledger itself carries only the
  # most recent rows, so the cache is what lets the mark outlive a row
  # that has rotated away. A handshake anywhere on record clears it — an
  # address that has answered once is not one that never will.
  defp no_reply?(addr, peer_meta) when is_binary(addr) do
    m = HighWire.PeersMeta.get(peer_meta, addr)

    is_integer(m["dial_attempts"]) and m["dial_attempts"] >= @no_reply_min_attempts and
      (m["dial_ok_at"] || 0) == 0
  end

  defp no_reply?(_addr, _peer_meta), do: false

  defp no_reply_note(addr, peer_meta) do
    m = HighWire.PeersMeta.get(peer_meta, addr)
    "dialed #{m["dial_attempts"]} times, never completed a handshake"
  end

  defp ever_ok?(addr, peer_meta) when is_binary(addr) do
    m = HighWire.PeersMeta.get(peer_meta, addr)
    (m["dial_ok_at"] || 0) > 0
  end

  defp ever_ok?(_addr, _peer_meta), do: false

  defp ever_ok_note(addr, peer_meta) do
    m = HighWire.PeersMeta.get(peer_meta, addr)
    ts = m["dial_ok_at"]

    if is_integer(ts) and ts > 0 do
      "handshake succeeded at least once (#{DateTime.from_unix!(div(ts, 1000))})"
    else
      "handshake succeeded at least once"
    end
  rescue
    _ -> "handshake succeeded at least once"
  end

  defp ever_connected?(addr, peer_meta) when is_binary(addr) do
    m = HighWire.PeersMeta.get(peer_meta, addr)
    c = m["last_connected_at"] || m["last_activity_at"]
    is_integer(c) and c > 0
  end

  defp ever_connected?(_addr, _peer_meta), do: false

  defp ever_connected_note(addr, peer_meta) do
    m = HighWire.PeersMeta.get(peer_meta, addr)
    ts = m["last_connected_at"] || m["last_activity_at"]

    if is_integer(ts) and ts > 0 do
      "connected at least once (#{DateTime.from_unix!(div(ts, 1000))})"
    else
      "connected at least once"
    end
  rescue
    _ -> "connected at least once"
  end

  # "12 loopback · 30 private · 4 onion · 260 no reply" — the labels the
  # classification counted, in a stable order, with zeroes dropped.
  defp suppress_summary(counts) do
    order = [
      {:loopback, "loopback"},
      {:rfc1918, "private"},
      {:onion, "onion"},
      {:ipv6, "IPv6"},
      {:scheme, "wrong scheme"},
      {:port, "bad port"},
      {:unparseable, "unparseable"},
      {:no_reply, "no reply"}
    ]

    parts =
      for {key, label} <- order, (n = counts[key] || 0) > 0, do: "#{n} #{label}"

    case parts do
      [] -> "Nothing to suppress."
      _ -> Enum.join(parts, " · ") <> " → #{counts[:total] || 0} to suppress"
    end
  end

  defp profile_href("@" <> _ = id), do: "/profile?id=" <> URI.encode_www_form(id)
  defp profile_href(_id), do: "/"

  defp image_of(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{image: image}} -> image
      _ -> nil
    end
  end

  defp blob_rev(report) do
    report["blobRev"] || 0
  end

  # The ledger keeps a month of rows, but what this report shows is only
  # as wide as its oldest row; say that, rather than a window that is
  # sometimes a day and sometimes thirty.
  defp dial_window(rows) when is_list(rows) do
    times = for row <- rows, is_number(row["lastTry"]), do: row["lastTry"]

    case times do
      [] ->
        "at some point"

      _ ->
        days = (Enum.max(times) - Enum.min(times)) / 86_400_000

        if days >= 1,
          do: "over the last #{days |> round() |> max(1)} days",
          else: "in the last day"
    end
  end

  defp dial_window(_rows), do: "at some point"

  # One contiguous "1 / 8" header line — a fallback report may carry no
  # cap, and the span used to render would split the text across lines.
  defp connections_header(report) do
    n = length(report["connections"] || [])

    case report["cap"] do
      cap when is_integer(cap) -> "#{n} / #{cap}"
      _ -> "#{n}"
    end
  end

  # -- constellation ------------------------------------------------------

  defp sky_cx, do: @sky_cx

  defp sky_cy, do: @sky_cy

  defp sky_rings, do: Keyword.values(@sky_rings)

  # The four rings, named at their apex and carrying what they hold —
  # so the picture explains itself without a trip down to the key.
  defp sky_ring_labels(report) do
    [
      {:live, "connected", length(report["connections"] || [])},
      {:ok, "reached", length(sky_ok_rows(report))},
      {:retry, "retrying", length(sky_retry_rows(report))},
      {:book, "never tried", length(sky_book_rows(report))}
    ]
  end

  defp sky_ring_ry(ring) when is_atom(ring), do: elem(Keyword.fetch!(@sky_rings, ring), 1)

  # -- the connectivity ladder ------------------------------------------
  #
  # dialTry is a retry ledger, not a list of open sockets: its rows live
  # for a month, and a row with attempts = 0 is an address whose last
  # handshake succeeded. Each peer is drawn once, on the innermost rung
  # it qualifies for, so a socket we hold now is never also a retry and a
  # peer with dial history is never also a bare address-book entry.
  # Returns {item, recency, x, y}.
  defp sky_stage(report, peer_meta, :live) do
    sky_nodes(report["connections"] || [], :live, & &1, &sky_recency(&1, peer_meta))
  end

  defp sky_stage(report, _peer_meta, :ok) do
    sky_nodes(sky_ok_rows(report), :ok, &sky_key(&1["addr"]), &sky_recency_at(&1["lastTry"]))
  end

  defp sky_stage(report, _peer_meta, :retry) do
    sky_nodes(
      sky_retry_rows(report),
      :retry,
      &sky_key(&1["addr"]),
      &sky_recency_at(&1["lastTry"])
    )
  end

  defp sky_stage(report, peer_meta, :book) do
    sky_nodes(
      sky_book_rows(report),
      :book,
      &sky_key(&1["address"]),
      &sky_recency(sky_key(&1["address"]), peer_meta)
    )
  end

  # Dial rows, most recent first, one per peer, minus anyone already on
  # the connected ring.
  defp sky_dial_rows(report) do
    connected = MapSet.new(report["connections"] || [])

    (report["dialTry"] || [])
    |> Enum.map(fn row -> {sky_key(row["addr"]), row} end)
    |> Enum.reject(fn {key, _row} -> is_nil(key) or MapSet.member?(connected, key) end)
    |> Enum.sort_by(fn {_key, row} -> -(row["lastTry"] || 0) end)
    |> Enum.uniq_by(fn {key, _row} -> key end)
    |> Enum.map(fn {_key, row} -> row end)
  end

  defp sky_ok_rows(report) do
    dial_ok =
      Enum.filter(sky_dial_rows(report), &(&1["attempts"] in [0, nil]))

    peer_meta = report["peer_meta"] || %{}
    connected = MapSet.new(report["connections"] || [])

    tried_keys =
      (report["dialTry"] || [])
      |> Enum.map(fn row -> sky_key(row["addr"]) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    hist_ok =
      peer_meta
      |> Enum.flat_map(fn {k, v} ->
        cond do
          is_binary(k) and String.starts_with?(k, "net:") and is_map(v) ->
            key = sky_key(k)
            dial_ok_at = v["dial_ok_at"] || 0
            last_connected_at = v["last_connected_at"] || v["last_activity_at"] || 0

            if is_binary(key) and not MapSet.member?(connected, key) and
                 not MapSet.member?(tried_keys, key) and
                 (dial_ok_at > 0 or last_connected_at > 0) do
              [
                %{
                  "addr" => k,
                  "attempts" => 0,
                  "lastTry" => max(dial_ok_at, last_connected_at)
                }
              ]
            else
              []
            end

          true ->
            []
        end
      end)

    (dial_ok ++ hist_ok)
    |> Enum.uniq_by(fn row -> sky_key(row["addr"]) end)
  end

  defp sky_retry_rows(report),
    do: Enum.filter(sky_dial_rows(report), &(is_integer(&1["attempts"]) and &1["attempts"] > 0))

  # Address book entries the dialer has no result for at all.
  defp sky_book_rows(report) do
    connected = MapSet.new(report["connections"] || [])
    tried = MapSet.new(Enum.map(sky_dial_rows(report), &sky_key(&1["addr"])))
    known = known_peers_for_sky(report)
    peer_meta = report["peer_meta"] || %{}

    known
    |> Enum.map(fn peer -> {sky_key(peer["address"]), peer} end)
    |> Enum.reject(fn {key, peer} ->
      addr = peer["address"]

      cond do
        is_nil(key) ->
          true

        MapSet.member?(connected, key) ->
          true

        MapSet.member?(tried, key) ->
          true

        is_binary(addr) ->
          m = HighWire.PeersMeta.get(peer_meta, addr)
          (m["dial_ok_at"] || 0) > 0 or (m["last_connected_at"] || m["last_activity_at"] || 0) > 0

        true ->
          false
      end
    end)
    |> Enum.uniq_by(fn {key, _peer} -> key end)
    |> Enum.map(fn {_key, peer} -> peer end)
  end

  defp known_peers_for_sky(report) do
    case @known_peers_cap do
      :all -> report["knownPeers"] || []
      cap when is_integer(cap) -> Enum.take(report["knownPeers"] || [], cap)
      _ -> report["knownPeers"] || []
    end
  end

  # "net:host:port~shs:KEY" → "@KEY.ed25519" — the same id the
  # connections list uses, which is what lets the ladder tell one peer
  # from another across its three naming schemes. Nil when the address
  # carries no shs key, so such a row is dropped rather than stacked on
  # every other nameless one.
  defp sky_key(addr) when is_binary(addr) do
    case String.split(addr, "~shs:", parts: 2) do
      [_pre, key] when byte_size(key) > 0 -> "@" <> key <> ".ed25519"
      _ -> nil
    end
  end

  defp sky_key(_addr), do: nil

  # "net:host:port~shs:KEY" → "host:port" — the part of the address a
  # person actually recognises. Nil when the address carries no host, so
  # callers fall back to the short key form.
  defp sky_host(addr) when is_binary(addr) do
    addr
    |> String.split("~", parts: 2)
    |> hd()
    |> case do
      "net:" <> hostport -> hostport
      _ -> nil
    end
  end

  defp sky_host(_addr), do: nil

  # The hover label for a peer we are not talking to: the name it goes
  # by and where it lives, not the full multi-hundred-character address
  # plus a sentence of protocol narrative. The address stays in the
  # list row below, which has room for it. The name is the same
  # alias-aware one the lists and the node labels show — the identity
  # behind the address, not the raw key.
  defp sky_peer_title(addr, profiles) do
    case {sky_key(addr), sky_host(addr)} do
      {nil, nil} -> addr || ""
      {key, nil} -> Ident.display_name(key, profiles)
      {nil, host} -> host
      {key, host} -> "#{Ident.display_name(key, profiles)} · #{host}"
    end
  end

  # Items placed around an elliptical ring at an angle hashed from their
  # identity key — stable across renders, so membership changes add or
  # remove a node without reshuffling its neighbours. The hash is the
  # feed id, so a peer keeps its angle as it climbs the ladder inward.
  # Each node also slides along its radius by recency: a fresh one sits
  # inside the guide ring, a cold or unknown one drifts past it.
  #
  # Hash buckets are coarse enough that two keys on a small ring can
  # land on top of each other — five connected peers showing as four
  # dots. So nodes claim their spot in list order: one that would draw
  # within @sky_min_sep of an already-placed neighbour rotates around
  # the ring until it clears. A node with no near-tie keeps its exact
  # hash position, so the common sky still holds still.
  defp sky_nodes(list, ring, key_fun, recency_fun)
       when is_list(list) and is_function(key_fun, 1) and is_function(recency_fun, 1) do
    {rx, ry} = Keyword.fetch!(@sky_rings, ring)

    list
    |> Enum.map(fn item ->
      key = key_fun.(item) || ""
      angle = 2 * :math.pi() * :erlang.phash2(key, 10_000) / 10_000
      recency = recency_fun.(item)
      spread = 1.0 + @sky_spread * (0.5 - recency) * 2
      {item, recency, angle, spread}
    end)
    |> sky_claim(rx, ry, [])
    |> Enum.map(fn {item, recency, _angle, x, y} -> {item, recency, x, y} end)
  end

  defp sky_nodes(_list, _ring, _key_fun, _recency_fun), do: []

  # Each placed node keeps its spot, so the next one tests itself
  # against every neighbour already down. Steps try the hash angle
  # first, then ±1, ±2… slices of @sky_kick_step; when even the
  # outermost slice is occupied the node keeps its hash and the
  # overlap stands — better a crowded corner than a lost node.
  defp sky_claim([], _rx, _ry, placed), do: Enum.reverse(placed)

  defp sky_claim([{item, recency, angle, spread} | rest], rx, ry, placed) do
    step =
      0..@sky_kick_steps
      |> Enum.flat_map(&[&1, -&1])
      |> Enum.find(0, fn step ->
        {x, y} = sky_spot(rx, ry, angle + step * @sky_kick_step, spread)
        sky_clear?(x, y, placed)
      end)

    angle = angle + step * @sky_kick_step
    {x, y} = sky_spot(rx, ry, angle, spread)
    sky_claim(rest, rx, ry, [{item, recency, angle, x, y} | placed])
  end

  defp sky_spot(rx, ry, angle, spread),
    do: {@sky_cx + rx * spread * :math.cos(angle), @sky_cy + ry * spread * :math.sin(angle)}

  # Far enough apart that two dots read as two dots.
  defp sky_clear?(x, y, placed) do
    Enum.all?(placed, fn {_item, _recency, _angle, px, py} ->
      :math.sqrt((px - x) * (px - x) + (py - y) * (py - y)) >= @sky_min_sep
    end)
  end

  # 1.0 when something was noted a moment ago, sliding to 0.0 a day
  # later — and straight to 0.0 when there is no clock to read.
  defp sky_recency_at(t) when is_number(t),
    do: min(1.0, max(0.0, 1.0 - (System.system_time(:millisecond) - t) / @sky_recency_span))

  defp sky_recency_at(_t), do: 0.0

  # The peer cache is keyed by feed id and says nothing about an address,
  # so only the connected ring reads it; the ledger carries its own clock.
  # The cache is a UI hint; the engine's report stays authoritative.
  defp sky_recency(key, meta) when is_binary(key) do
    hint = HighWire.PeersMeta.get(meta, key)
    sky_recency_at(hint["last_activity_at"] || hint["last_connected_at"] || hint["last_seen_at"])
  end

  defp sky_recency(_key, _meta), do: 0.0

  # Cold metadata fades a node back toward the panel, so the bright core
  # of the sky is the part the engine actually knows something about.
  defp sky_opacity(recency) when is_number(recency),
    do: Float.round(0.35 + 0.65 * recency, 2)

  # A tether that is context rather than content — an autoconnect line,
  # say — carries a fraction of the ink, so a crowded book cannot shout
  # over the peers that are actually connected.
  defp sky_dim(recency, weight) when is_number(recency),
    do: Float.round(sky_opacity(recency) * weight, 2)

  # A name goes outward from the middle, past its own node, so live
  # labels never pile up on "you" or on each other. Nodes sitting nearly
  # above or below the centre have no outward side to favour, so they
  # stay centred and flip upward when they are in the top half.
  defp sky_label(x, y) do
    dx = x - @sky_cx
    dy = y - @sky_cy
    dist = :math.sqrt(dx * dx + dy * dy)

    cond do
      dist < 1.0 -> %{x: x, y: y + 15, anchor: "middle"}
      dx >= dist * 0.35 -> %{x: x + 13, y: y + 3, anchor: "start"}
      dx <= -dist * 0.35 -> %{x: x - 13, y: y + 3, anchor: "end"}
      dy < 0 -> %{x: x, y: y - 11, anchor: "middle"}
      true -> %{x: x, y: y + 15, anchor: "middle"}
    end
  end

  defp sky_short_name(id, profiles) do
    name = Ident.display_name(id, profiles)
    if String.length(name) > 16, do: String.slice(name, 0, 15) <> "…", else: name
  end

  defp sky_summary(report) do
    "Constellation: #{length(report["connections"] || [])} connected, " <>
      "#{length(sky_ok_rows(report))} reached, " <>
      "#{length(sky_retry_rows(report))} retrying, " <>
      "#{length(sky_book_rows(report))} never tried"
  end

  defp sky_empty?(report) do
    report["connections"] in [nil, []] and report["dialTry"] in [nil, []] and
      report["knownPeers"] in [nil, []]
  end

  # A report the engine could not produce — down, starting, or an erlbutt
  # older than the admin RPCs — is not the same as an engine reporting an
  # empty network. Falling back to the cache keeps the constellation
  # populated from the last session that did answer, so the page opens on
  # the peers we know rather than on nothing.
  defp report_or_seed(nil, peer_meta), do: HighWire.PeersMeta.seed_report(peer_meta)
  defp report_or_seed(report, _peer_meta) when is_map(report), do: report
  defp report_or_seed(_report, peer_meta), do: HighWire.PeersMeta.seed_report(peer_meta)
end
