defmodule HighWireWeb.SettingsLive do
  @moduledoc """
  Application settings — Patchwork's settings page, packaged for the
  browser: colour scheme, font size, font family, the opt-in
  "Participating" tab, spellchecking, the network selector, and the
  version line.

  Appearance preferences are client-side: the value lives in
  `localStorage` and is applied to `<html>` by the `Prefs` hook the
  moment a control changes, with the root-layout script reapplying it
  before first paint on the next load. The server only renders the
  controls; aria-pressed and checkbox checked states mark the active
  choice in the DOM, so they survive LiveView patches.

  The Network section is server-side: switching rewrites the engine's
  overrides file and restarts the erlbutt process, so the LiveView
  tracks the switch asynchronously and polls the sidecar until the
  engine answers again.
  """

  use HighWireWeb, :live_view

  alias HighWire.SSB.{Network, Sidecar}
  alias HighWireWeb.Components.Nav

  @modes ["system", "light", "dark"]

  @mainnet_key Network.id(:mainnet)

  @font_sizes [
    {"", "Default"},
    {"8px", "8px"},
    {"10px", "10px"},
    {"12px", "12px"},
    {"14px", "14px"},
    {"16px", "16px"},
    {"18px", "18px"},
    {"20px", "20px"}
  ]

  @font_families [
    {"", "Default"},
    {"serif", "Serif"},
    {"sans-serif", "Sans"},
    {"cursive", "Cursive"},
    {"fantasy", "Fantasy"},
    {"monospace", "Monospace"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Settings",
       modes: @modes,
       lock_key: @mainnet_key,
       font_sizes: @font_sizes,
       font_families: @font_families,
       version: HighWire.version(),
       network: Network.current(),
       net_status: Sidecar.status(),
       switching: false,
       switch_notice: nil,
       polls: 0
     )}
  end

  @impl true
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
        {:noreply,
         assign(socket,
           net_status: :ready,
           switch_notice: "Connected to #{Network.label(socket.assigns.network)}."
         )}

      socket.assigns.polls >= 60 ->
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

  def handle_info(_other, socket), do: {:noreply, socket}

  defp switch_error(:disabled), do: "the SSB engine is disabled in this configuration."

  defp switch_error(:port_busy),
    do: "the engine port is still in use — a leftover engine is holding it."

  defp switch_error(reason), do: inspect(reason)

  defp status_text(:ready), do: "connected"
  defp status_text(:starting), do: "starting"
  defp status_text(:down), do: "stopped"
  defp status_text(:disabled), do: "disabled"
  defp status_text(other), do: inspect(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail />

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <h1 class="text-xl font-bold text-paper">Settings</h1>

          <h2 class="mt-6 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub">
            Network
          </h2>

          <p class="mt-3 text-sm">
            Network set to:
            <span class={if(@network == :mainnet, do: "text-bad", else: "text-paper")}>
              {Network.label(@network)}
            </span>
          </p>

          <p class="mt-3 text-sm text-dim">
            The network selector is a luggage lock, and the combination is the key itself —
            printed below, the way a luggage tag prints it. Type the whole thing into the
            boxes, click the shackle, and the engine reboots onto the real SSB mainnet; the
            plate on the lock keeps score of which network you're on — and once the lock is
            open it takes a deliberate hold to snap it shut.
          </p>

          <div
            id="net-lock"
            class="mt-5 flex flex-col items-start"
            role="group"
            aria-label="Network combination lock"
            phx-hook="LockDials"
            data-combo={@lock_key}
            data-lock-state={if(@network == :mainnet, do: "open", else: "closed")}
          >
            <div class="relative w-fit pt-10">
              <button
                type="button"
                class="absolute left-1/2 top-0 -translate-x-1/2"
                phx-click="switch_network"
                phx-value-network="mainnet"
                data-unlock
                aria-pressed={to_string(@network == :mainnet)}
                aria-label="Click the shackle onto Mainnet"
                disabled={@switching}
              >
                <span class="lock-shackle block h-12 w-20 rounded-t-full border-[6px] border-b-0 border-paper"></span>
              </button>

              <div class="lock-body flex w-[min(26rem,calc(100vw-6rem))] flex-col items-center gap-2 rounded-md border border-edge bg-raised px-4 py-3 shadow md:w-fit">
                <div
                  class="hidden max-w-[26rem] flex-wrap gap-x-2 gap-y-1.5 md:flex"
                  role="group"
                  aria-label="Type the whole mainnet network key"
                >
                  <div :for={g <- 0..10} class="flex gap-1">
                    <input
                      :for={o <- 0..3}
                      type="text"
                      class="lock-char"
                      data-idx={g * 4 + o}
                      data-value={
                        if(@network == :mainnet, do: String.at(@lock_key, g * 4 + o), else: "")
                      }
                      value={if(@network == :mainnet, do: String.at(@lock_key, g * 4 + o), else: "")}
                      maxlength="1"
                      autocomplete="off"
                      spellcheck="false"
                      tabindex={if(g == 0 and o == 0, do: "0", else: "-1")}
                      aria-label={"Key character #{g * 4 + o + 1} of #{String.length(@lock_key)}"}
                    />
                  </div>
                </div>
                <div class="lock-key-wrap w-full md:hidden">
                  <span class="lock-mirror" aria-hidden="true"></span>
                  <input
                    type="text"
                    class="lock-key-field"
                    data-value={if(@network == :mainnet, do: @lock_key, else: "")}
                    value={if(@network == :mainnet, do: @lock_key, else: "")}
                    maxlength={String.length(@lock_key)}
                    autocomplete="off"
                    spellcheck="false"
                    aria-label="The whole mainnet network key"
                  />
                </div>
                <p class="text-[10px] uppercase tracking-[0.3em] text-faint" aria-hidden="true">
                  type the whole key
                </p>
                <div aria-hidden="true">
                  <div class="mx-auto h-3 w-3 rounded-full bg-faint"></div>
                  <div class="mx-auto h-2 w-[3px] bg-faint"></div>
                </div>

                <button
                  type="button"
                  class="pref-choice lock-leave mt-1 w-full px-2 text-center text-xs"
                  phx-click="switch_network"
                  phx-value-network="dev"
                  aria-pressed={to_string(@network == :dev)}
                  title={
                    if(@network == :mainnet,
                      do: "Press and hold to leave the Mainnet",
                      else: "Already on Development"
                    )
                  }
                  data-leave="true"
                  disabled={@switching}
                >
                  {if @network == :mainnet,
                    do: "Hold to snap shut — Development",
                    else: "Locked: Development"}
                </button>
              </div>
            </div>

            <p
              id="net-lock-status"
              class="mt-2 min-h-[1rem] text-xs text-dim"
              role="status"
              aria-live="polite"
            >
            </p>

            <div class="lock-combo mt-4 flex flex-col items-start gap-1 transition-colors duration-200">
              <p class="text-xs uppercase tracking-widest text-faint">The combination</p>
              <div class="flex items-center gap-2">
                <button
                  type="button"
                  class="select-all break-all text-left font-mono text-sm text-paper"
                  data-fill="true"
                  title="Fill the lock boxes with the mainnet key"
                >
                  {Network.id(:mainnet)}
                </button>
                <button
                  type="button"
                  class="shrink-0 text-xs text-faint transition hover:text-paper"
                  data-copy="true"
                >
                  Copy
                </button>
              </div>
              <p class="max-w-md text-xs text-dim">
                Type or paste the whole mainnet key into the boxes — green characters agree,
                red ones vary. Click the shackle when it's all green.
              </p>
            </div>
          </div>

          <p :if={@switch_notice} role="status" class="mt-3 text-sm text-dim">
            {@switch_notice}
          </p>

          <p class="mt-3 text-sm text-dim">Engine: {status_text(@net_status)}</p>

          <p :if={@network == :mainnet} class="mt-4 text-sm text-bad">
            Connected to Mainnet: receiving and replicating from mainnet peers is active,
            but posting, replying, liking and following are disabled while Patchwork still
            publishes this identity — two writers would fork the feed.
          </p>

          <p :if={@network == :custom} class="mt-4 text-sm text-bad">
            Unknown network id in overrides.cfg
            (<span class="font-mono text-xs">{Network.current_id()}</span>) — posting is
            disabled. Snap the lock shut for Development to continue.
          </p>

          <div phx-hook="Prefs" id="prefs">
            <h2 class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub">
              Appearance
            </h2>

            <p class="mt-3 text-sm text-dim">
              Colour scheme for HighWire. The choice is stored in this browser;
              "system" follows your operating system's light/dark preference.
            </p>

            <div class="mt-4 flex flex-wrap gap-3" role="group" aria-label="Colour scheme">
              <button
                :for={mode <- @modes}
                type="button"
                class="pref-choice"
                data-pref-key="theme"
                data-pref-value={mode}
                aria-pressed="false"
              >
                {String.capitalize(mode)}
              </button>
            </div>

            <p class="mt-6 text-sm text-dim">
              Base text size for the whole interface.
            </p>

            <div class="mt-3 flex flex-wrap gap-3" role="group" aria-label="Font size">
              <button
                :for={{value, label} <- @font_sizes}
                type="button"
                class="pref-choice"
                data-pref-key="font-size"
                data-pref-value={value}
                aria-pressed="false"
              >
                {label}
              </button>
            </div>

            <p class="mt-6 text-sm text-dim">
              Typeface for the whole interface, as in Patchwork.
            </p>

            <div class="mt-3 flex flex-wrap gap-3" role="group" aria-label="Font family">
              <button
                :for={{value, label} <- @font_families}
                type="button"
                class="pref-choice"
                data-pref-key="font-family"
                data-pref-value={value}
                aria-pressed="false"
              >
                {label}
              </button>
            </div>

            <h2 class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub">
              Notification options
            </h2>

            <label class="mt-3 flex items-start gap-2 text-sm text-dim">
              <input
                type="checkbox"
                data-pref-key="participating"
                data-pref-on="on"
                data-pref-off="off"
                class="mt-0.5 h-4 w-4 rounded border-edge accent-accent"
              /> Include "Participating" tab in the navigation bar
            </label>

            <h2 class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub">
              Writing
            </h2>

            <label class="mt-3 flex items-start gap-2 text-sm text-dim">
              <input
                type="checkbox"
                data-pref-key="spellcheck"
                data-pref-on="on"
                data-pref-off="off"
                class="mt-0.5 h-4 w-4 rounded border-edge accent-accent"
              /> Enable spellchecking in text fields
            </label>

            <h2 class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub">
              Information
            </h2>

            <p class="mt-3 text-sm text-dim">HighWire {@version} · MIT</p>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
