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
            HighWire starts on Mainnet. Switching rewrites the engine's overrides
            file and restarts the local engine — feeds and blobs carry over either way.
          </p>

          <div class="mt-4 flex flex-wrap gap-3" role="group" aria-label="Network">
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

          <p :if={@switch_notice} role="status" class="mt-3 text-sm text-dim">
            {@switch_notice}
          </p>

          <p class="mt-3 text-sm text-dim">Engine: {status_text(@net_status)}</p>

          <p :if={@network == :custom} class="mt-4 text-sm text-bad">
            Unknown network id in overrides.cfg
            (<span class="font-mono text-xs">{Network.current_id()}</span>) — this is not a
            network HighWire knows. Switch to Development or Mainnet.
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
