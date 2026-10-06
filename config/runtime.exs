import Config

if config_env() != :test do
  config :highwire,
    application_dir: System.get_env("HIGHWIRE_HOME", "~/.highwire")
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
    messages_per_feed: 10
end
