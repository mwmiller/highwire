defmodule HighWireWeb.LiveDashboardHooks do
  @moduledoc """
  On-mount hooks for the Phoenix LiveDashboard route.

  The LiveDashboard uses its own root layout and JavaScript, so HighWire's
  normal `MenuBridge` LiveView hook (from `app.js`) is not mounted there and
  the native "Go" menu items stop working. This hook injects a lightweight
  standalone listener into the dashboard's head that forwards the same
  `highwire-menu` events by navigating back to the main application at the
  chosen view.
  """
  import Phoenix.Component
  alias Phoenix.LiveDashboard.PageBuilder

  def on_mount(:default, _params, _session, socket) do
    {:cont, PageBuilder.register_after_opening_head_tag(socket, &after_opening_head_tag/1)}
  end

  defp after_opening_head_tag(assigns) do
    ~H"""
    <script nonce={@csp_nonces[:script]}>
      if (window.__TAURI__) {
        window.__TAURI__.event.listen("highwire-menu", (event) => {
          const view = event.payload && event.payload.view
          if (view && view !== "dashboard") {
            window.location.href = "/?view=" + encodeURIComponent(view)
          }
        })
      }
    </script>
    """
  end
end
