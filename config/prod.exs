import Config

config :highwire, HighWireWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 24042],
  http_options: [idle_timeout: 98947],
  # Websocket upgrades must come from the UI itself: a page the user
  # visits reaches loopback as easily as the app does (DNS rebinding
  # even makes it same-origin), and the Origin header is what sets the
  # app's own windows apart from one. No port is named, so any port
  # the UI is served on matches.
  check_origin: ["//127.0.0.1", "//localhost"]

# Do not print debug messages in production
config :logger, level: :error
