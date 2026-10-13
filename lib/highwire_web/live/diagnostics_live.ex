defmodule HighWireWeb.DiagnosticsLive do
  @moduledoc """
  The diagnostics page — a live health report for the engine views the
  timeline depends on.

  One probe per view (`createHistoryStream`, `get`, the paged roots tabs)
  plus the sidecar status and the local window summary, each scored
  `:ok` / `:warn` / `:fail` with a short human note. The point is to make
  engine breakage and window under-fill *visible* instead of letting them
  masquerade as an empty "no messages yet" — so a blank timeline can be
  told apart from a broken one at a glance.

  Probes run on demand (the page re-probes on a short timer while it is
  the active tab) through `HighWire.Timeline.diagnose/0`, which reuses the
  authenticated engine client, so the numbers reflect the live engine and
  not a cached guess. Reaches here from Settings → Information.
  """

  use HighWireWeb, :live_view

  alias HighWire.Timeline
  alias HighWireWeb.Components.Nav

  # Re-probe while the tab is active; short enough to feel live, long
  # enough that a stream of probes never hammers the engine.
  @reprobe_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Process.send_after(self(), :reprobe, @reprobe_ms)
    end

    {:ok,
     socket
     |> assign_new(:gossip, fn -> %{connected: 0, pulse: 0} end)
     |> assign(:page_title, "Diagnostics")
     |> assign(:report, Timeline.diagnose())
     |> assign(:reprobe_s, div(@reprobe_ms, 1000))
     |> assign(:version, HighWire.version())}
  end

  @impl true
  def handle_info(:reprobe, socket) do
    if connected?(socket) do
      Process.send_after(self(), :reprobe, @reprobe_ms)
    end

    {:noreply, assign(socket, :report, Timeline.diagnose())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail gossip={@gossip}>
        <Nav.rail_label>On this page</Nav.rail_label>
        <Nav.rail_link href="#engine">Engine views</Nav.rail_link>
        <Nav.rail_link href="#window">Local window</Nav.rail_link>
      </Nav.rail>

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <h1 class="text-xl font-bold text-paper">Diagnostics</h1>
          <p class="mt-2 text-sm text-dim">
            Live health of the engine views the timeline reads from. Re-probes every {@reprobe_s}s while this page is open.
          </p>

          <h2
            id="engine"
            class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
          >
            Engine views
          </h2>

          <p class="mt-3 text-sm text-dim">
            Sidecar:
            <span class={sidecar_class(@report.sidecar)}>{sidecar_label(@report.sidecar)}</span>
          </p>

          <ul class="mt-4 space-y-2">
            <li :for={p <- @report.probes} class="flex items-start gap-3 text-sm">
              <span class={level_class(p.level)}>{level_label(p.level)}</span>
              <span class="min-w-0">
                <span class="font-medium text-paper">{p.name}</span>
                <span class="text-dim"> — {p.note}</span>
              </span>
            </li>
          </ul>

          <h2
            id="window"
            class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
          >
            Local window
          </h2>

          <p :if={@report.window} class="mt-3 text-sm text-dim">
            {@report.window.per_feed} messages per feed · {@report.window.follows} follows · {@report.window.acc} accumulated · {@report.window.messages} in payload
          </p>
          <p :if={is_nil(@report.window)} class="mt-3 text-sm text-dim">
            Timeline is not running.
          </p>

          <p class="mt-10 text-xs text-dim">HighWire {@version} · diagnostics</p>
        </div>
      </section>
    </div>
    """
  end

  defp level_class(:ok), do: "shrink-0 text-ok"
  defp level_class(:warn), do: "shrink-0 text-warn"
  defp level_class(:fail), do: "shrink-0 text-bad"

  defp level_label(:ok), do: "OK"
  defp level_label(:warn), do: "WARN"
  defp level_label(:fail), do: "FAIL"

  defp sidecar_class(:ready), do: "text-ok"
  defp sidecar_class(:down), do: "text-bad"
  defp sidecar_class(_), do: "text-warn"

  defp sidecar_label(:ready), do: "ready"
  defp sidecar_label(:down), do: "down"
  defp sidecar_label(:disabled), do: "disabled"
  defp sidecar_label(other), do: to_string(other)
end
