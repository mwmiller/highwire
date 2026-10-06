defmodule HighWireWeb.Router do
  use HighWireWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {HighWireWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", HighWireWeb do
    pipe_through :browser

    live("/", TimelineLive)
    live("/about", Live)
    live("/profile", ProfileLive)
    live("/network", NetworkLive)
    live("/settings", SettingsLive)
    live("/post/:key", PostLive)
  end

  # Blobs are static bytes: no session, CSRF or format negotiation.
  scope "/", HighWireWeb do
    get "/blob/:key", BlobController, :show
    get "/identicon/:key", BlobController, :ident
  end

  # Other scopes may use custom stacks.
  # scope "/api", HighWireWeb do
  #   pipe_through :api
  # end

  import Phoenix.LiveDashboard.Router

  scope "/" do
    pipe_through :browser

    live_dashboard "/dashboard",
      metrics: HighWireWeb.Telemetry,
      on_mount: HighWireWeb.LiveDashboardHooks
  end
end
