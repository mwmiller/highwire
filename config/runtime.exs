import Config

if config_env() != :test do
  config :highwire,
    application_dir: System.get_env("HIGHWIRE_HOME", "~/.highwire")
end
