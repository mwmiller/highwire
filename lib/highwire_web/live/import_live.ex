defmodule HighWireWeb.ImportLive do
  @moduledoc """
  The first-run import gate — the one page reachable while the sidecar
  holds an unanswered offer to take the JS client's store.

  Three faces, one per import state: consent (what was found, Import
  or Start fresh), progress (the converter's dot stream, no buttons —
  an in-flight conversion is not a place to improvise, and relaunching
  re-offers the decision), and failure (what went wrong, with Retry and
  Start fresh). Plus the honest panel when this configuration runs no
  engine at all.

  Every face reads the sidecar fresh on mount, on its 1s tick, and
  after each button: the moment the sidecar leaves the import states
  (accepted → engine starting, declined → engine starting) the page
  routes home, where the gate waves it through.
  """

  use HighWireWeb, :live_view

  alias HighWire.SSB.{Import, Sidecar}
  alias HighWireWeb.Components.Nav

  # One dot is one 5000 messages, and the converter prints the first at
  # zero — so dots on screen overstate by exactly one.
  @dot_size 5_000

  @import_states [:import_pending, :importing, :import_failed]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 1_000)

    {:ok, socket |> assign(:page_title, "Import") |> refresh()}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket = refresh(socket)

    if socket.assigns.mode in @import_states do
      Process.send_after(self(), :tick, 1_000)
    end

    {:noreply, socket}
  end

  # Buttons answer through a task so a slow sidecar call (the port-free
  # sweep waits out a dying engine) never freezes the page.
  def handle_info({:import_result, _action, _result}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("accept", _params, socket) do
    run_import(:accept, &Sidecar.accept_import/0)
    {:noreply, socket}
  end

  def handle_event("decline", _params, socket) do
    run_import(:decline, &Sidecar.decline_import/0)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail />

      <section class="flex flex-1 items-center justify-center overflow-y-auto px-6 py-12">
        <div class="w-full max-w-xl">
          <div :if={@mode == :import_pending} class="space-y-5">
            <div>
              <img src={~p"/images/highwire-mark.png"} alt="" class="h-16 w-16 rounded-2xl" />
              <h1 class="mt-4 text-2xl font-bold text-paper">Bring your old feed along</h1>
              <p class="mt-2 text-sm text-sub">
                HighWire found data from another Secure Scuttlebutt client.
                Take it over, with its identity, history and blobs, or start with a
                clean one.
              </p>
            </div>

            <dl class="divide-y divide-edge-soft rounded-lg border border-edge bg-panel px-4 text-sm">
              <div class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">Account</dt>
                <dd class="min-w-0 break-all text-right font-mono text-paper">{@info[:id]}</dd>
              </div>
              <div class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">Location</dt>
                <dd class="min-w-0 break-all text-right font-mono text-xs text-sub">
                  {Import.js_home()}
                </dd>
              </div>
              <div class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">History</dt>
                <dd class="text-right text-paper">
                  {if is_integer(@info[:log_size]),
                    do: "#{human_size(@info[:log_size])} of messages",
                    else: "identity only, no history log found"}
                </dd>
              </div>
              <div class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">Blobs</dt>
                <dd class="text-right text-paper">
                  {if @info[:blobs], do: "present, they come too", else: "none found"}
                </dd>
              </div>
            </dl>

            <p class="rounded-lg border border-edge bg-panel p-3 text-sm text-warn">
              Quit the old client before importing. Two programs publishing from one
              identity fork your feed: permanently, signed, and unrecoverable.
            </p>

            <div class="flex flex-wrap gap-3">
              <button type="button" class="btn btn-primary" phx-click="accept">
                Import it
              </button>
              <button type="button" class="btn" phx-click="decline">Start fresh</button>
            </div>
          </div>

          <div :if={@mode == :importing} class="space-y-5">
            <div>
              <h1 class="text-2xl font-bold text-paper">Converting your history</h1>
              <p class="mt-2 text-sm text-sub">
                Reading the old data and rebuilding it for HighWire. Keep the old
                client closed; HighWire starts when it finishes.
              </p>
            </div>

            <dl class="divide-y divide-edge-soft rounded-lg border border-edge bg-panel px-4 text-sm">
              <div class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">Elapsed</dt>
                <dd class="text-right font-mono text-paper">{elapsed(@info)}</dd>
              </div>
              <div
                :if={is_integer(@info[:log_size])}
                class="flex items-baseline justify-between gap-4 py-2.5"
              >
                <dt class="shrink-0 text-dim">Converting</dt>
                <dd class="text-right text-paper">{human_size(@info[:log_size])}</dd>
              </div>
              <div class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">Read so far</dt>
                <dd class="text-right text-paper">
                  {cond do
                    @info[:counts] -> "#{commas(@info[:counts].messages)} messages"
                    @info[:dots] -> "≈ #{commas(est_messages(@info[:dots]))} messages"
                    true -> "starting…"
                  end}
                </dd>
              </div>
              <div :if={@info[:counts]} class="flex items-baseline justify-between gap-4 py-2.5">
                <dt class="shrink-0 text-dim">Feeds</dt>
                <dd class="text-right text-paper">{commas(@info[:counts].feeds)}</dd>
              </div>
            </dl>

            <p :if={@info[:tail]} class="break-all font-mono text-xs text-faint">
              {@info[:tail]}
            </p>
          </div>

          <div :if={@mode == :import_failed} class="space-y-5">
            <div>
              <h1 class="text-2xl font-bold text-paper">The import stopped</h1>
              <p class="mt-2 text-sm text-sub">
                Nothing finished, and the old data was not touched. Trying again
                re-runs the whole import; starting fresh creates a new identity
                instead.
              </p>
            </div>

            <p class="rounded-lg border border-edge bg-panel p-3 text-sm text-bad">
              {@info[:error] || "The importer failed without saying why."}
            </p>

            <p :if={@info[:tail]} class="break-all font-mono text-xs text-faint">
              {@info[:tail]}
            </p>

            <div class="flex flex-wrap gap-3">
              <button type="button" class="btn btn-primary" phx-click="accept">
                Try again
              </button>
              <button type="button" class="btn" phx-click="decline">Start fresh</button>
            </div>
          </div>

          <div :if={@mode == :disabled} class="space-y-5">
            <div>
              <h1 class="text-2xl font-bold text-paper">Nothing to import into</h1>
              <p class="mt-2 text-sm text-sub">
                SSB is disabled in this configuration, so there is nothing to bring an
                old feed into.
              </p>
            </div>

            <.link navigate="/" class="btn">Back to HighWire</.link>
          </div>

          <%!-- Set only on the way out: the redirect that follows never
        renders this, but HEEx still wants a branch for it. --%>
          <div :if={@mode == :gone} class="text-sm text-dim"></div>
        </div>
      </section>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------

  # Read the sidecar and decide the page's face. Import states keep it
  # here; :disabled gets its own panel; anything else (the import is
  # over, or there never was one) sends the visitor home, where the
  # route gate re-checks and lets them through.
  defp refresh(socket) do
    status = Sidecar.status()

    cond do
      status in @import_states ->
        socket
        |> assign(mode: status, info: Sidecar.import_info() || %{})

      status == :disabled ->
        assign(socket, mode: :disabled, info: %{})

      true ->
        socket |> assign(mode: :gone, info: %{}) |> redirect(to: "/")
    end
  end

  defp run_import(action, fun) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          fun.()
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      send(parent, {:import_result, action, result})
    end)
  end

  defp elapsed(%{started_at: started}) when is_integer(started) do
    seconds = max(System.system_time(:second) - started, 0)
    "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
  end

  defp elapsed(_info), do: "not yet"

  defp est_messages(dots) when is_integer(dots), do: max(dots - 1, 0) * @dot_size

  defp human_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1_024 -> "#{div(bytes, 1_024)} KB"
      true -> "#{bytes} B"
    end
  end

  # 1234567 → "1,234,567", without leaning on a number library.
  defp commas(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.digits()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end
end
