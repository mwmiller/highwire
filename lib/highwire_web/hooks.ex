defmodule HighWireWeb.Hooks do
  @moduledoc """
  `on_mount` hooks shared by the router's live sessions.

  The gate is the whole point right now: while the sidecar holds an
  unanswered first-run import (`:import_pending`, `:importing`,
  `:import_failed`), every app route halts its mount into `/import`.
  The page itself sits outside the gated session, so the hook can never
  bounce its own target back and forth.
  """

  import Phoenix.LiveView, only: [redirect: 2]

  alias HighWire.SSB.Sidecar

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

  def on_mount(_hook, _params, _session, socket), do: {:cont, socket}
end
