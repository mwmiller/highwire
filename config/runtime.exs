import Config

home = System.get_env("HIGHWIRE_HOME", "~/.highwire")

if config_env() != :test do
  config :highwire, application_dir: home

  # The engine's blob store, which `/blob/<hex>` serves from. HighWire's
  # own engine keeps it under the app home, but an engine that runs
  # elsewhere — `ERLBUTT_REL` pointed at a checkout, or a node already up
  # with its own SSB home — keeps its blobs where that engine does.
  # HIGHWIRE_BLOB_STORE names that directory.
  if blob_store = System.get_env("HIGHWIRE_BLOB_STORE") do
    config :highwire, blob_store: blob_store
  end
end

# The packaged app: the release workflow builds erlbutt's prod profile
# (real network id, its own ERTS) into priv/erlbutt, and the sidecar
# spawns that — no system Erlang required. If the dir is absent the app
# still boots with the engine off.
if config_env() == :prod do
  engine =
    case :code.priv_dir(:highwire) do
      {:error, _} -> ""
      dir -> Path.join(to_string(dir), "erlbutt")
    end

  config :highwire, :ssb,
    enabled: engine != "" and File.dir?(engine),
    port: 8899,
    erlbutt_rel: engine,
    net_id: "1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYRan/s=",
    max_feeds: 400,
    # Per-author window depth. The thread page seats reply-to-a-reply
    # forks from this window, so it must reach past an active author's
    # recent traffic — 10 dropped the known forks (author-feed rank
    # 11-16). 20 seats them while keeping first paint light; deeper
    # history rides the cursor pages.
    messages_per_feed: 20

  # The signing key for the UI's cookies and CSRF tokens: minted per
  # install on first boot and kept in the app home, never in the
  # repository or the binary.
  config :highwire, HighWireWeb.Endpoint,
    secret_key_base: HighWire.WebSecret.fetch(Path.expand(home))
end
