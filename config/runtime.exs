import Config

home = System.get_env("HIGHWIRE_HOME", "~/.highwire")

if config_env() != :test do
  config :highwire, application_dir: home

  # The engine's SSB home: the parent of the `.ssberl` that holds its
  # secret, conn.json, feeds, blobs and DETS. It is the app home unless
  # HIGHWIRE_SSB_HOME names an engine home that already exists, which is
  # how HighWire attaches to an erlbutt already running on its own.
  if ssb_home = System.get_env("HIGHWIRE_SSB_HOME") do
    config :highwire, ssb_home: ssb_home
  end

  # A blob store outside the engine's home, for a setup that keeps only
  # the blobs elsewhere. Otherwise store_root/0 is `<ssb home>/.ssberl/
  # blobs`.
  if blob_store = System.get_env("HIGHWIRE_BLOB_STORE") do
    config :highwire, blob_store: blob_store
  end

  # Who runs the engine for that repo. HighWire spawns and stops it on
  # its own app home; a home named from outside belongs to whatever
  # engine already writes it, so there HighWire only attaches. `spawn`
  # opts into starting one anyway; `attach` never starts one.
  case System.get_env("HIGHWIRE_ENGINE") do
    "spawn" -> config :highwire, engine: :spawn
    "attach" -> config :highwire, engine: :attach
    nil -> :ok
    other -> raise "HIGHWIRE_ENGINE must be spawn or attach, got #{inspect(other)}"
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
