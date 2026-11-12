defmodule HighWireWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :highwire

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_highwire_key",
    signing_salt: "MYiBJzn4"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  if Mix.env() == :prod do
    # The release build digests the assets and writes a .gz beside each, so
    # serve the compressed copy to a client that takes it. Dev keeps gzip
    # off: old .gz files sit beside fresh sources there.
    plug Plug.Static,
      at: "/",
      from: :highwire,
      gzip: true,
      only: ~w(assets fonts images favicon.ico robots.txt)
  else
    plug Plug.Static,
      at: "/",
      from: :highwire,
      gzip: false,
      only: ~w(assets fonts images favicon.ico robots.txt)
  end

  # Serve images directly from the application images directory.
  # Path is resolved at runtime because Application.compile_env bakes in
  # the GHA runner's home directory when the Burrito release is built there.
  plug :serve_cat_images

  # Tidewave (browser eval / MCP server). Dev only; never in releases.
  if Mix.env() == :dev do
    plug Tidewave
  end

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug HighWireWeb.Router

  defp serve_cat_images(conn, _opts) do
    from =
      HighWire.home_dir()
      |> Path.join("images")

    Plug.Static.call(conn, Plug.Static.init(at: "/cat_images", from: from, gzip: false))
  end
end
