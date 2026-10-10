defmodule HighWireWeb.Live do
  @moduledoc """
  Landing view: engine status and data directory.
  """
  use HighWireWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "HighWire")
     |> assign(:version, HighWire.version())
     |> assign(:home_dir, HighWire.home_dir())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6">
      <img src={~p"/images/highwire-crab.svg"} alt="" class="mt-2 h-32 w-32 rounded-2xl" />
      <h1 class="mt-4 text-4xl font-bold tracking-tight">HighWire</h1>
      <p class="mt-2 text-lg text-sub">
        A local-first social network on Secure Scuttlebutt — catenary's
        interface, SSB's network.
      </p>

      <div class="mt-8 grid gap-4 sm:grid-cols-2">
        <div class="rounded-lg border border-edge bg-panel p-4">
          <h2 class="font-semibold text-paper">SSB engine</h2>
          <p class="mt-1 text-sm text-warn">erlbutt sidecar — local muxrpc over loopback</p>
        </div>
        <div class="rounded-lg border border-edge bg-panel p-4">
          <h2 class="font-semibold text-paper">Data directory</h2>
          <p class="mt-1 font-mono text-sm text-muted">{@home_dir}</p>
        </div>
      </div>

      <p class="mt-8 text-sm text-dim">v{@version} · MIT</p>

      <.link patch="/" class="btn mt-4">
        <span aria-hidden="true">←</span> Back to home
      </.link>
    </div>
    """
  end
end
