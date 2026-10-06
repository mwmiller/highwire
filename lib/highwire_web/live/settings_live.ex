defmodule HighWireWeb.SettingsLive do
  @moduledoc """
  Application settings — Patchwork's settings page, packaged for the
  browser: colour scheme, font size, font family, the opt-in
  "Participating" tab, spellchecking, and the version line.

  Every preference is client-side: the value lives in `localStorage`
  and is applied to `<html>` by the `Prefs` hook the moment a control
  changes, with the root-layout script reapplying it before first paint
  on the next load. The server only renders the controls; aria-pressed
  and checkbox checked states mark the active choice in the DOM, so
  they survive LiveView patches.
  """

  use HighWireWeb, :live_view

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
       version: HighWire.version()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail />

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <h1 class="text-xl font-bold text-paper">Settings</h1>

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
