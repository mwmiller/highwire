defmodule HighWireWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, live views, live components and so on.

  This can be used in your application as:

      use HighWireWeb, :controller
      use HighWireWeb, :live_view

  The definitions below will be executed for every live view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define any helper function in modules
  and import those modules here.
  """

  def controller do
    quote do
      use Phoenix.Controller, formats: [html: "HTML", json: "JSON"]

      import Plug.Conn
      import Phoenix.LiveView.Controller
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView,
        layout: {HighWireWeb.Layouts, :live}

      unquote(view_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(view_helpers())
    end
  end

  def router do
    quote do
      use Phoenix.Router

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.HTML

      # Include shared imports and aliases for views
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: HighWireWeb.Endpoint,
        router: HighWireWeb.Router,
        as: :Routes,
        statics: ~w(assets)
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  defp view_helpers do
    quote do
      # Import LiveView helpers (live_render, live_patch, <.form>, etc)
      import Phoenix.LiveView

      # Routes generation with the ~p sigil
      unquote(verified_routes())
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
