import Config

config :highwire, HighWireWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}, port: 24042],
  http_options: [idle_timeout: 98947],
  check_origin: false,
  secret_key_base: "5FLVVS9UwaB5UWAnrPIXBTk9eEJGr+vTvqOp742c1utBPSQxJUs6rFsmIklpCMT0"

# Do not print debug messages in production
config :logger, level: :error
