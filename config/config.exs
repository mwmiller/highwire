# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Use the `tz` IANA time zone database for DateTime timezone handling

# Configures the endpoint
config :highwire, HighWireWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: HighWireWeb.ErrorHTML, json: HighWireWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HighWire.PubSub,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true,
  live_view: [signing_salt: "7c42r28o"]

config :tailwind,
  version: "3.4.17",
  default: [
    args: ~w(
    --config=tailwind.config.js
    --input=css/app.css
    --output=../priv/static/assets/app.css
  ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configure esbuild (the version is required).
config :esbuild,
  version: "0.25.9",
  default: [
    args: ~w(js/app.js --bundle --target=es2016 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
