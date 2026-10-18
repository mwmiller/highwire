defmodule HighWireWeb.IdentityLive do
  @moduledoc """
  Identity management: every feed this install can sign as, and the
  controls to switch, create, disable, export and — from the disabled
  list only — permanently delete them.

  Switching follows the network page's discipline: the engine restart
  underneath (its stop → write → start lives in
  `HighWire.SSB.Sidecar.switch_identity/1`), so the event runs in a
  task and the page says "Switching…" until the result lands. With
  the engine disabled the secret is written directly.

  Deleting is two-stage by design: a click on Delete only arms an
  inline confirmation, and only a disabled identity gets the button
  at all. Export is offered right in the row — the private key leaves
  the registry for good on the second click, and whatever the
  identity published stays in the store either way.
  """

  use HighWireWeb, :live_view

  alias HighWire.SSB.{Identities, Sidecar}
  alias HighWireWeb.Components.{Avatar, Nav}

  @impl true
  def mount(_params, _session, socket) do
    # The registry catches up to whatever secret is running — the page
    # is the place that can heal a first-run install's missing entry.
    _ = Identities.ensure_boot()

    {:ok,
     socket
     |> assign(
       page_title: "Identity",
       switching: false,
       confirming: nil,
       exported: nil,
       notice: nil,
       form_label: ""
     )
     |> reload()}
  end

  @impl true
  def handle_event("switch", %{"id" => id}, socket) do
    cond do
      socket.assigns.switching ->
        {:noreply, socket}

      active_id(socket) == id ->
        {:noreply, socket}

      true ->
        socket = assign(socket, notice: {:info, "Switching to #{label(socket, id)}…"})

        if Sidecar.enabled?() do
          queue_engine_switch(id)
          {:noreply, assign(socket, switching: true)}
        else
          # No engine to restart: the secret write is the whole switch.
          {:noreply, switched(socket, Sidecar.switch_identity(id), id)}
        end
    end
  end

  # The engine stop → write → start takes seconds; the LiveView stays
  # responsive and the result comes back as a message.
  defp queue_engine_switch(id) do
    parent = self()

    Task.start(fn ->
      result =
        try do
          Sidecar.switch_identity(id)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      send(parent, {:identity_switch, result, id})
    end)
  end

  def handle_event("disable", %{"id" => id}, socket) do
    case Identities.disable(id) do
      :ok ->
        {:noreply, socket |> reload() |> assign(notice: {:info, "Disabled"})}

      {:error, reason} ->
        {:noreply, assign(socket, notice: {:error, "Could not disable: #{explain(reason)}"})}
    end
  end

  def handle_event("enable", %{"id" => id}, socket) do
    case Identities.enable(id) do
      :ok ->
        {:noreply, socket |> reload() |> assign(notice: {:info, "Enabled"})}

      {:error, reason} ->
        {:noreply, assign(socket, notice: {:error, "Could not enable: #{explain(reason)}"})}
    end
  end

  # First click arms the confirmation inline; only the second click,
  # on the armed row's own button, actually destroys anything.
  def handle_event("delete", %{"id" => id}, socket) do
    row = Enum.find(socket.assigns.identities, &(&1["id"] == id))

    if is_nil(row) or not row["disabled"] do
      {:noreply, socket}
    else
      {:noreply, assign(socket, confirming: id, exported: nil)}
    end
  end

  def handle_event("delete-cancel", _params, socket) do
    {:noreply, assign(socket, confirming: nil)}
  end

  def handle_event("delete-confirm", %{"id" => id}, socket) do
    case Identities.destroy(id) do
      :ok ->
        notice = {:info, "#{label(socket, id)} was deleted permanently"}

        {:noreply,
         socket
         |> assign(confirming: nil)
         |> reload()
         |> assign(notice: notice)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: {:error, "Could not delete: #{explain(reason)}"})}
    end
  end

  def handle_event("export", %{"id" => id}, socket) do
    case Identities.export(id) do
      {:ok, text} -> {:noreply, assign(socket, exported: {id, text}, confirming: nil)}
      {:error, reason} -> {:noreply, assign(socket, notice: {:error, explain(reason)})}
    end
  end

  def handle_event("export-close", _params, socket) do
    {:noreply, assign(socket, exported: nil)}
  end

  def handle_event("create", %{"label" => label}, socket) do
    case Identities.create(label) do
      {:ok, id} ->
        first? = socket.assigns.active == nil
        fresh = reload(socket)
        created = label(fresh, id)

        notice =
          if first? do
            {:info, "#{created} is your identity now"}
          else
            {:info, "Created #{created} — switch to it when you want to post as it"}
          end

        {:noreply, fresh |> assign(form_label: "") |> assign(notice: notice)}

      {:error, reason} ->
        {:noreply, assign(socket, notice: {:error, "Could not create: #{explain(reason)}"})}
    end
  end

  @impl true
  def handle_info({:identity_switch, result, id}, socket) do
    {:noreply, switched(socket, result, id)}
  end

  defp switched(socket, :ok, id) do
    socket
    |> assign(switching: false)
    |> reload()
    |> assign(notice: {:info, "Now posting as #{label(socket, id)}"})
  end

  defp switched(socket, {:error, reason}, _id) do
    socket
    |> assign(switching: false)
    |> assign(notice: {:error, "Could not switch: #{explain(reason)}"})
  end

  defp reload(socket) do
    assign(socket, identities: Identities.list(), active: Identities.active())
  end

  defp active_id(socket), do: socket.assigns.active && socket.assigns.active["id"]

  defp exporting?({exported_id, _text}, row_id), do: exported_id == row_id
  defp exporting?(_exported, _row_id), do: false

  defp label(socket, id) do
    case Enum.find(socket.assigns.identities, &(&1["id"] == id)) do
      nil -> id
      row -> row["label"]
    end
  end

  defp explain(:unknown_identity), do: "that identity is not in this store"
  defp explain(:disabled_identity), do: "that identity is disabled"
  defp explain(:active_identity), do: "switch away from it first"
  defp explain(:not_disabled), do: "disable it first"
  defp explain(:bad_label), do: "give it a label first"
  defp explain(:duplicate), do: "that identity already exists"
  defp explain(reason) when is_binary(reason), do: reason
  defp explain(reason), do: inspect(reason)

  # The network page's in-page status line, same two tones: dim for
  # what happened, bad for what could not.
  defp notice_class({:error, _text}), do: "mt-3 text-sm text-bad"
  defp notice_class({:info, _text}), do: "mt-3 text-sm text-dim"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail gossip={@gossip} identity={@active}>
        <Nav.rail_label>On this page</Nav.rail_label>
        <Nav.rail_link href="#current">Current identity</Nav.rail_link>
        <Nav.rail_link href="#all">All identities</Nav.rail_link>
        <Nav.rail_link href="#create">Create</Nav.rail_link>
      </Nav.rail>

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <h1 class="text-xl font-bold text-paper">Identity</h1>

          <p class="mt-3 text-sm text-dim">
            Every identity lives in this one store — switching changes who you post as,
            not where your data lives. Deleting is two-stage: an identity must be
            disabled before it can be removed for good.
          </p>

          <p :if={@notice} role="status" class={notice_class(@notice)}>
            {elem(@notice, 1)}
          </p>

          <h2
            id="current"
            class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
          >
            Current identity
          </h2>

          <div
            :if={@active}
            class="mt-4 flex items-start gap-4 rounded-lg border border-edge bg-panel p-4"
          >
            <Avatar.avatar id={@active["id"]} size={48} />
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="font-semibold text-paper">{@active["label"]}</span>
                <span class="rounded bg-raised px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-paper">
                  Active
                </span>
              </div>
              <div class="mt-1 break-all font-mono text-xs text-muted">{@active["id"]}</div>
            </div>
          </div>

          <p
            :if={@active == nil}
            class="mt-4 rounded-lg border border-edge bg-panel p-4 text-sm text-dim"
          >
            No identity yet — the engine mints one on its first boot, or create one below.
          </p>

          <h2
            id="all"
            class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
          >
            All identities
          </h2>

          <div class="mt-4 space-y-3">
            <div :for={row <- @identities} class="rounded-lg border border-edge bg-panel p-4">
              <div class="flex items-center gap-3">
                <Avatar.avatar id={row["id"]} size={32} />
                <div class="min-w-0 flex-1">
                  <div class="flex items-center gap-2">
                    <span class="truncate font-medium text-paper">{row["label"]}</span>
                    <span
                      :if={row["active"]}
                      class="rounded bg-raised px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-paper"
                    >
                      Active
                    </span>
                    <span
                      :if={row["disabled"]}
                      class="rounded bg-raised px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-faint"
                    >
                      Disabled
                    </span>
                  </div>
                  <div class="mt-0.5 truncate font-mono text-xs text-muted" title={row["id"]}>
                    {row["id"]}
                  </div>
                </div>
                <div class="flex shrink-0 items-center gap-2">
                  <button
                    :if={!row["active"] and !row["disabled"]}
                    type="button"
                    class="btn"
                    phx-click="switch"
                    phx-value-id={row["id"]}
                    disabled={@switching}
                  >
                    Switch
                  </button>
                  <button
                    :if={row["active"]}
                    type="button"
                    class="btn"
                    disabled
                    title="Switch to another identity first"
                  >
                    Disable
                  </button>
                  <button
                    :if={!row["active"] and !row["disabled"]}
                    type="button"
                    class="btn"
                    phx-click="disable"
                    phx-value-id={row["id"]}
                  >
                    Disable
                  </button>
                  <button
                    :if={row["disabled"]}
                    type="button"
                    class="btn"
                    phx-click="enable"
                    phx-value-id={row["id"]}
                  >
                    Enable
                  </button>
                  <button
                    type="button"
                    class="btn"
                    phx-click="export"
                    phx-value-id={row["id"]}
                  >
                    Export
                  </button>
                  <button
                    :if={row["disabled"]}
                    type="button"
                    class="btn text-bad"
                    phx-click="delete"
                    phx-value-id={row["id"]}
                  >
                    Delete
                  </button>
                </div>
              </div>

              <%!-- Second stage of the delete: the row itself asks, in
              red, before the key is dropped for good. --%>
              <div
                :if={@confirming == row["id"]}
                class="mt-3 rounded border border-bad/40 bg-bad/5 p-3"
              >
                <p class="text-sm text-paper">
                  Permanently delete “{row["label"]}”? The private key is destroyed —
                  signing as this feed becomes impossible, and there is no recovery.
                </p>
                <p class="mt-1 text-xs text-dim">
                  Whatever it published stays in the store. Export the key first if it
                  still matters.
                </p>
                <div class="mt-3 flex gap-2">
                  <button
                    type="button"
                    class="btn text-bad"
                    phx-click="delete-confirm"
                    phx-value-id={row["id"]}
                  >
                    Delete forever
                  </button>
                  <button type="button" class="btn" phx-click="delete-cancel">
                    Keep
                  </button>
                </div>
              </div>

              <div :if={exporting?(@exported, row["id"])} class="mt-3">
                <div class="flex items-center justify-between">
                  <p class="text-xs text-dim">
                    The ssb-keys secret file — keep it as safe as it keeps you.
                  </p>
                  <button type="button" class="btn" phx-click="export-close">Close</button>
                </div>
                <textarea
                  readonly
                  rows="6"
                  class="mt-2 w-full rounded border border-edge bg-app p-2 font-mono text-xs text-muted"
                >{elem(@exported, 1)}</textarea>
              </div>
            </div>

            <p
              :if={@identities == []}
              class="rounded-lg border border-edge bg-panel p-4 text-sm italic text-faint"
            >
              No identities in the registry yet.
            </p>
          </div>

          <h2
            id="create"
            class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
          >
            Create
          </h2>

          <p class="mt-3 text-sm text-dim">
            A fresh ed25519 keypair, minted here. It starts enabled but inactive —
            switch to it to post as it. To move an existing identity in instead,
            replace the secret file while the engine is stopped.
          </p>

          <form phx-submit="create" class="mt-4 flex items-end gap-3">
            <div class="min-w-0 flex-1">
              <label for="identity-label" class="block text-xs text-faint">Label</label>
              <input
                id="identity-label"
                type="text"
                name="label"
                value={@form_label}
                placeholder="e.g. Main, Bot, Pub account"
                class="mt-1 w-full rounded border border-edge bg-panel px-3 py-1.5 text-sm text-paper"
              />
            </div>
            <button type="submit" class="btn btn-primary">Create identity</button>
          </form>
        </div>
      </section>
    </div>
    """
  end
end
