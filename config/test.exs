import Config

# Tests must be hermetic: never read or write the user's real ~/.highwire.
config :highwire,
  application_dir: Path.expand("~/.highwire-test"),
  blob_source: Path.expand("~/.highwire-test/blobs/sha256")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :highwire, HighWireWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "SPxKtYJrt9CsLLapQ3vv2Lzr5P2AvjZnbbdCMMWfxW6Y5g1OBpeLJs29iveA6CrC",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :highwire, :ssb, enabled: false
