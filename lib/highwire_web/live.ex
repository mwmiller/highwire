defmodule HighWireWeb.Live do
  @moduledoc """
  Phase 0 landing view: identity and engine status until the SSB feed
  UI arrives. Also swallows the Tauri menu/resize events so the shell's
  bridge never crashes the mount before its views exist.
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
  def handle_event("menu", _params, socket), do: {:noreply, socket}
  def handle_event("window-resize", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-3xl p-6">
      <h1 class="text-4xl font-bold tracking-tight">HighWire</h1>
      <p class="mt-2 text-lg text-slate-600 dark:text-slate-400">
        A local-first social network on Secure Scuttlebutt — catenary's
        interface, SSB's network.
      </p>

      <div class="mt-8 grid gap-4 sm:grid-cols-2">
        <div class="rounded-lg border border-slate-300 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
          <h2 class="font-semibold">SSB engine</h2>
          <p class="mt-1 text-sm text-amber-600 dark:text-amber-400">
            erlbutt sidecar — not yet wired (Phase 0 interop spike)
          </p>
        </div>
        <div class="rounded-lg border border-slate-300 bg-white p-4 dark:border-slate-700 dark:bg-slate-800">
          <h2 class="font-semibold">Data directory</h2>
          <p class="mt-1 font-mono text-sm"><%= @home_dir %></p>
        </div>
      </div>

      <p class="mt-8 text-sm text-slate-500">v<%= @version %> · MIT</p>

      <.link patch="/" class="mt-4 block text-sm text-blue-600 hover:underline">
        ← back to home
      </.link>
    </div>
    """
  end
end
