import Config

# Tests must be hermetic: never read or write the user's real ~/.highwire.
# Each run gets its own store directory — test_helper.exs mints one under
# the system temp dir and points HIGHWIRE_TEST_HOME here — so a stale run
# or two suites at once cannot read each other's files. The default stays
# the shared ~/.highwire-test for anyone invoking ExUnit some other way.
test_home = System.get_env("HIGHWIRE_TEST_HOME") || Path.expand("~/.highwire-test")

config :highwire,
  application_dir: test_home,
  blob_store: Path.join(test_home, ".ssberl/blobs")

# …and never the real ~/.ssb either: detection would otherwise offer a
# first-run import (and read a real store) on any machine that has one.
config :highwire, :ssb, js_home: Path.join(test_home, "no-js-store")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :highwire, HighWireWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "SPxKtYJrt9CsLLapQ3vv2Lzr5P2AvjZnbbdCMMWfxW6Y5g1OBpeLJs29iveA6CrC",
  server: false

# Quiet test output: the suite deliberately exercises resilience paths
# that log at warning level (unreadable overrides.cfg, a missing
# first-run secret), and echoing those expected-path warnings on every
# run buries the results. Errors still print.
config :logger, level: :error

config :highwire, :ssb, enabled: false

# The contact drain must never open its own SHS connection in tests —
# there is no sidecar, and the real secret must never be dialed.
config :highwire, :ssb, drain_connection: false
