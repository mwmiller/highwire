defmodule HighWireWeb.SettingsLive do
  @moduledoc """
  Application settings — Patchwork's settings page, packaged for the
  browser: colour scheme, font size, font family, the opt-in
  "Participating" tab, spellchecking, and the version line.

  Appearance preferences are client-side: the value lives in
  `localStorage` and is applied to `<html>` by the `Prefs` hook the
  moment a control changes, with the root-layout script reapplying it
  before first paint on the next load. The server only renders the
  controls; aria-pressed and checkbox checked states mark the active
  choice in the DOM, so they survive LiveView patches.

  Network concerns — the network profile switcher and the dialer
  controls — live on the Network page (`/network`), not here. What this
  page does carry is the identity switcher: who this install posts as,
  and a button per other identity, so switching does not require a
  detour through `/identity` (where creating, disabling, exporting and
  deleting identities live).
  """

  use HighWireWeb, :live_view

  alias HighWire.Avatar, as: Ident
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Nav}
  alias HighWireWeb.IdentitySwitch

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
     socket
     |> assign(
       page_title: "Settings",
       modes: @modes,
       font_sizes: @font_sizes,
       font_families: @font_families,
       version: HighWire.version(),
       switching: false,
       switch_notice: nil
     )
     |> reload_identities()}
  end

  @impl true
  def handle_event("switch", %{"id" => id}, socket) do
    cond do
      socket.assigns.switching ->
        {:noreply, socket}

      active_id(socket) == id ->
        {:noreply, socket}

      true ->
        notice = {:info, "Switching to #{label(socket, id)}…"}

        case IdentitySwitch.switch(id) do
          :async -> {:noreply, assign(socket, switching: true, switch_notice: notice)}
          {:sync, result} -> {:noreply, switched(socket, result, id)}
        end
    end
  end

  @impl true
  def handle_info({:identity_switch, result, id}, socket) do
    {:noreply, switched(socket, result, id)}
  end

  # Nothing else should message this page, but a live view that matches
  # only its own messages dies on anything else; a settings page must
  # not be the thing that falls over.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp switched(socket, :ok, id) do
    socket
    |> reload_identities()
    |> assign(switching: false, switch_notice: {:info, "Now posting as #{label(socket, id)}"})
  end

  defp switched(socket, {:error, reason}, _id) do
    assign(socket,
      switching: false,
      switch_notice: {:error, "Could not switch: #{explain(reason)}"}
    )
  end

  defp reload_identities(socket) do
    identities = Identities.list()
    active = Enum.find(identities, & &1["active"])

    # Only identities that could be switched to now: the active one is
    # already showing above, and a disabled one is off the switch list.
    others = Enum.filter(identities, &(!&1["active"] and !&1["disabled"]))

    profiles = Profile.take(Enum.map(identities, & &1["id"]))

    # What followers see, resolved once per id: HEEx calls no local
    # helpers, and the rows want the same name and avatar here as on
    # the identity page.
    people =
      Map.new(identities, fn row ->
        id = row["id"]

        {id,
         %{
           name: Ident.display_name(id, profiles),
           image:
             case profiles do
               %{^id => %{image: image}} -> image
               _ -> nil
             end
         }}
      end)

    assign(socket,
      identities: identities,
      active: active,
      others: others,
      profiles: profiles,
      people: people
    )
  end

  defp active_id(socket), do: socket.assigns.active && socket.assigns.active["id"]

  defp label(socket, id) do
    case Enum.find(socket.assigns.identities, &(&1["id"] == id)) do
      nil -> id
      row -> row["label"]
    end
  end

  defp explain(:unknown_identity), do: "that identity is not here"
  defp explain(:disabled_identity), do: "that identity is disabled"
  defp explain(:active_identity), do: "switch away from it first"
  defp explain(reason) when is_binary(reason), do: reason
  defp explain(reason), do: inspect(reason)

  defp notice_class({:error, _text}), do: "mt-3 text-sm text-bad"
  defp notice_class({:info, _text}), do: "mt-3 text-sm text-dim"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail gossip={@gossip}>
        <Nav.rail_label>On this page</Nav.rail_label>
        <Nav.rail_link href="#identity">Identity</Nav.rail_link>
        <Nav.rail_link href="#appearance">Appearance</Nav.rail_link>
        <Nav.rail_link href="#notifications">Notification options</Nav.rail_link>
        <Nav.rail_link href="#writing">Writing</Nav.rail_link>
        <Nav.rail_link href="#information">Information</Nav.rail_link>
      </Nav.rail>

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <h1 class="text-xl font-bold text-paper">Settings</h1>

          <h2
            id="identity"
            class="mt-6 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
          >
            Identity
          </h2>

          <p class="mt-3 text-sm text-dim">
            Switching changes who you write as; your data stays in one place.
          </p>

          <div class="mt-4 rounded-lg border border-edge bg-panel p-4">
            <div :if={@active} class="flex items-center gap-3">
              <Avatar.avatar
                id={@active["id"]}
                size={32}
                image={@people[@active["id"]].image}
                rev={Profile.rev()}
              />
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span class="truncate font-medium text-paper">
                    {@people[@active["id"]].name}
                  </span>
                  <span class="rounded bg-raised px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wide text-paper">
                    Posting as
                  </span>
                </div>
                <div class="mt-0.5 truncate font-mono text-xs text-muted" title={@active["id"]}>
                  {@active["id"]}
                </div>
              </div>
            </div>

            <p :if={@active == nil} class="text-sm text-dim">
              No identity yet. One is created on first run.
            </p>

            <div
              :if={@others != []}
              class="mt-4 flex flex-wrap items-center gap-2 border-t border-edge pt-3"
            >
              <span class="text-xs uppercase tracking-wide text-faint">Post as</span>
              <button
                :for={row <- @others}
                type="button"
                class="btn"
                phx-click="switch"
                phx-value-id={row["id"]}
                disabled={@switching}
              >
                {@people[row["id"]].name}
                <span class="font-normal text-faint">({row["label"]})</span>
              </button>
            </div>

            <p :if={@switch_notice} role="status" class={notice_class(@switch_notice)}>
              {elem(@switch_notice, 1)}
            </p>
          </div>

          <.link
            navigate="/identity"
            class="mt-3 inline-block text-sm text-accent underline-offset-2 hover:underline"
          >
            Manage identities →
          </.link>

          <div phx-hook="Prefs" id="prefs">
            <h2
              id="appearance"
              class="mt-6 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
            >
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

            <h2
              id="notifications"
              class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
            >
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

            <h2
              id="writing"
              class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
            >
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

            <h2
              id="information"
              class="mt-8 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub"
            >
              Information
            </h2>

            <p class="mt-3 text-sm text-dim">HighWire {@version} · MIT</p>

            <.link
              navigate="/diagnostics"
              class="mt-3 inline-block text-sm text-accent underline-offset-2 hover:underline"
            >
              Diagnostics →
            </.link>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
