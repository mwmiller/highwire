defmodule HighWireWeb.Hooks do
  @moduledoc """
  `on_mount` hooks shared by the router's live sessions.

  The gate is the whole point right now: while the sidecar holds an
  unanswered first-run import (`:import_pending`, `:importing`,
  `:import_failed`), every app route halts its mount into `/import`.
  The page itself sits outside the gated session, so the hook can never
  bounce its own target back and forth.

  The first-run gate follows the same shape for a fresh identity: while
  the install has a welcome page unanswered, every app route halts into
  `/welcome`, which also lives outside this session.

  The gossip hook is the shared sign of life: it subscribes every page
  to connection-set changes and assigns `%{connected, pulse}` for the
  rail's footer badge.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, redirect: 2]

  alias HighWire.FirstRun
  alias HighWire.SSB.Sidecar
  alias HighWire.Timeline

  @import_states [:import_pending, :importing, :import_failed]

  @doc """
  Redirect to `/import` while the sidecar is mid-offer; pass through
  otherwise (engine states like `:starting`/`:ready`/`:down` are the
  app's own business — they render as-is).
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:import_gate, _params, _session, socket) do
    if Sidecar.status() in @import_states do
      {:halt, redirect(socket, to: "/import")}
    else
      {:cont, socket}
    end
  end

  # The first-run gate: a fresh identity has no peers and no feed, so
  # every app route leads to the welcome page until the reader answers
  # it. It runs after the import gate — an unopened import offer is the
  # earlier decision, and its page is the one to answer first. The page
  # itself sits outside this session, so the hook can never bounce its
  # own target.
  def on_mount(:first_run, _params, _session, socket) do
    if FirstRun.pending?() do
      {:halt, redirect(socket, to: "/welcome")}
    else
      {:cont, socket}
    end
  end

  # Gossip: assign %{connected, pulse} for the rail badge and subscribe
  # while live. Every event bumps the pulse; the badge's keyed dot
  # replays its flare when it changes, and a fresh count replaces the
  # old one. (No @doc — Elixir allows one per function, and the gate's
  # clause above already speaks for on_mount/4.)
  def on_mount(:gossip, _params, _session, socket) do
    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(HighWire.PubSub, Timeline.gossip_topic())
        attach_hook(socket, :gossip, :handle_info, &handle_gossip/2)
      else
        socket
      end

    {:cont, assign(socket, :gossip, %{connected: connected_count(), pulse: 0})}
  end

  def on_mount(_hook, _params, _session, socket), do: {:cont, socket}

  # Halted: the gossip topic is the hook's own, no page handler wants
  # the message. Everything else passes straight through untouched.
  defp handle_gossip({Timeline, :gossip, event}, socket) do
    gossip = socket.assigns.gossip
    connected = Map.get(event, :connected, gossip.connected)
    {:halt, assign(socket, :gossip, %{connected: connected, pulse: gossip.pulse + 1})}
  end

  defp handle_gossip(_msg, socket), do: {:cont, socket}

  defp connected_count do
    # The count the last network poll left behind, not a fresh report:
    # a mount must not wait on the timeline's in-flight work.
    Timeline.connection_count()
  end
end
