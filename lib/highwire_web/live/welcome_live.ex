defmodule HighWireWeb.WelcomeLive do
  @moduledoc """
  The first page a fresh identity reaches.

  A new identity has no address book, so it has no connection to hear
  anything from: the timeline stays empty until a pub carries the feed.
  This page says so once, where the reader first looks, and offers the
  invite form that joins one — the same round-trip the Network page
  runs, with the wording shared through `HighWireWeb.InviteCopy`.

  Two ways out, both of which retire the page through
  `HighWire.FirstRun.dismiss/0`: join a pub, or look around first. A
  reader with a peer address in hand takes the weaker route on the
  Network page instead.

  The page sits outside the gated session, like `/import`, so the hook
  that sends every app route here can never bounce its own target. It
  polls the sidecar while the engine starts: redeeming before the
  engine answers would only report a missing identity, so the form says
  what it is waiting for instead.
  """

  use HighWireWeb, :live_view

  alias HighWire.FirstRun
  alias HighWire.SSB.{Invite, Sidecar}
  alias HighWireWeb.Components.Shell
  alias HighWireWeb.InviteCopy

  # The engine comes up in seconds; the poll stops when it is ready or
  # after two minutes, so a page left open does not tick forever.
  @tick_ms 1_000
  @tick_limit 120

  @impl true
  def mount(_params, _session, socket) do
    if FirstRun.pending?() do
      if connected?(socket), do: Process.send_after(self(), :tick, @tick_ms)

      {:ok,
       assign(socket,
         page_title: "Welcome",
         status: Sidecar.status(),
         ticks: 0,
         invite_code: "",
         redeeming: false,
         notice: nil,
         joined: nil
       )}
    else
      {:ok, redirect(socket, to: "/")}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    status = Sidecar.status()
    socket = assign(socket, status: status, ticks: socket.assigns.ticks + 1)

    if status != :ready and socket.assigns.ticks < @tick_limit and FirstRun.pending?() do
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:noreply, socket}
  end

  # The pub round-trip lands here, off the socket the same way the
  # Network page runs it. A successful join retires the page at once:
  # the reader has answered it, whatever the feed does next.
  def handle_info({:invite_result, result}, socket) do
    socket = assign(socket, redeeming: false, notice: InviteCopy.notice(result))

    socket =
      case result do
        {:ok, invite} ->
          _ = FirstRun.dismiss()
          assign(socket, joined: invite, invite_code: "")

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("join-pub", %{"invite" => code}, socket) do
    code = String.trim(code)

    cond do
      socket.assigns.redeeming ->
        {:noreply, socket}

      code == "" ->
        {:noreply, assign(socket, notice: "Paste an invite code to join a pub.")}

      true ->
        join(code, socket)
    end
  end

  def handle_event("join-pub", _params, socket), do: {:noreply, socket}

  # Keep the field's text in an assign so the poll does not clear it.
  def handle_event("invite-type", %{"invite" => code}, socket),
    do: {:noreply, assign(socket, invite_code: code)}

  def handle_event("invite-type", _params, socket), do: {:noreply, socket}

  def handle_event("skip", _params, socket) do
    _ = FirstRun.dismiss()
    {:noreply, push_navigate(socket, to: "/")}
  end

  def handle_event("skip-to-network", _params, socket) do
    _ = FirstRun.dismiss()
    {:noreply, push_navigate(socket, to: "/network#add-a-peer")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Shell.app>
      <section class="flex flex-1 items-center justify-center overflow-y-auto px-6 py-12">
        <div class="w-full max-w-xl space-y-5">
          <div>
            <img src={~p"/images/highwire-mark.png"} alt="" class="h-16 w-16 rounded-2xl" />
            <h1 class="mt-4 text-2xl font-bold text-paper">Welcome to HighWire</h1>
            <p class="mt-2 text-sm text-sub">
              This identity is new, and the network has not met it yet. A pub carries
              it: join one and the feeds it knows begin to arrive here.
            </p>
          </div>

          <div :if={@joined} class="space-y-3 rounded-lg border border-edge bg-panel p-4">
            <p class="text-sm text-paper">{@notice}</p>
            <p class="text-sm text-dim">
              Your timeline fills as the pub sends what it has. The first feed can take
              a few minutes to arrive.
            </p>
            <.link navigate="/" class="btn btn-primary">Go to the feed</.link>
          </div>

          <div :if={is_nil(@joined)} class="rounded-lg border border-edge bg-panel p-4">
            <h2 class="text-sm font-semibold text-paper">Join a pub</h2>
            <p class="mt-1 text-sm text-dim">
              Paste the invite code a pub gave you. It names the pub and the key it
              expects, and joining saves the address so the dialer keeps the
              connection.
            </p>

            <form
              id="welcome-invite"
              phx-change="invite-type"
              phx-submit="join-pub"
              class="mt-3 flex items-end gap-3"
            >
              <div class="min-w-0 flex-1">
                <label for="invite-code" class="block text-xs text-faint">Invite code</label>
                <input
                  id="invite-code"
                  type="text"
                  name="invite"
                  value={@invite_code}
                  placeholder="host:port:@key.ed25519~seed"
                  autocomplete="off"
                  spellcheck="false"
                  class="mt-1 w-full rounded border border-edge bg-raised px-3 py-1.5 font-mono text-sm text-paper"
                />
              </div>
              <button type="submit" class="btn btn-primary" disabled={@redeeming}>
                {if @redeeming, do: "Joining…", else: "Join pub"}
              </button>
            </form>

            <p :if={@notice} role="status" class="mt-2 text-sm text-dim">{@notice}</p>

            <p :if={@status != :ready} class="mt-3 text-sm text-faint">
              {status_note(@status)}
            </p>
          </div>

          <div :if={is_nil(@joined)} class="space-y-3">
            <div class="flex flex-wrap items-center gap-3">
              <button type="button" class="btn" phx-click="skip">Skip for now</button>
              <button
                type="button"
                class="text-sm text-dim underline-offset-2 transition hover:text-paper hover:underline"
                phx-click="skip-to-network"
              >
                I have a peer address instead
              </button>
            </div>
            <p class="text-xs text-faint">
              The Network page keeps both ways onto the network, so joining a pub can
              wait.
            </p>
          </div>
        </div>
      </section>
    </Shell.app>
    """
  end

  # Parse first: a malformed code is a local, cheap answer, and it is the
  # same one whatever the engine is doing. Only a well-formed code waits
  # on, or reaches, the pub.
  defp join(code, socket) do
    case Invite.parse(code) do
      {:error, :bad_invite} ->
        {:noreply,
         assign(socket,
           notice:
             "That is not a valid invite code. It should look like host:port:@key.ed25519~seed."
         )}

      {:ok, invite} ->
        redeem_or_wait(invite, code, socket)
    end
  end

  defp redeem_or_wait(invite, _code, %{assigns: %{status: :ready}} = socket),
    do: redeem(invite, socket)

  # A well-formed code is worth keeping in the box: the engine comes up
  # in seconds, and the same code works once it answers.
  defp redeem_or_wait(_invite, code, socket) do
    {:noreply,
     assign(socket,
       invite_code: code,
       notice: "The local service is not answering yet. The code is ready to use once it starts."
     )}
  end

  defp redeem(invite, socket) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          Invite.redeem(invite)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      send(parent, {:invite_result, result})
    end)

    {:noreply,
     assign(socket,
       redeeming: true,
       invite_code: "",
       notice: "Joining #{invite.host}:#{invite.port}…"
     )}
  end

  defp status_note(:disabled),
    do: "This configuration runs no engine, so a pub cannot be joined here."

  defp status_note(:starting),
    do: "The local service is starting. The invite field works as soon as it answers."

  defp status_note(_status),
    do: "The local service is not answering. The invite field works as soon as it starts."
end
