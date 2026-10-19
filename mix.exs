defmodule HighWire.MixProject do
  use Mix.Project

  def project do
    [
      app: :highwire,
      version: "1.4.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      releases: releases(),
      aliases: aliases(),
      listeners: [Phoenix.CodeReloader],
      deps: deps()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp releases do
    [
      highwire: [
        include_executables_for: [:unix],
        steps: [:assemble, &HighWire.Release.bundle_libsodium/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64],
            linux_arm: [os: :linux, cpu: :aarch64],
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {HighWire.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Protocol deps (baby, baobab, quagga_def) and deferred-feature deps
  # (watusi, cbor, scrypt_ex, toml, tz) are intentionally absent:
  # HighWire speaks SSB via the erlbutt sidecar, and the app platform
  # / backgammon import in later phases. excon is present: deterministic
  # identicon images for feeds/blobs without an image. mdex renders
  # post bodies (comrak).
  defp deps do
    [
      {:tidewave, "~> 0.9", only: [:dev]},
      {:burrito, "~> 1.6", runtime: false},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:excon, "~> 4.1"},
      {:mdex, "~> 0.14.2"},
      {:memoize, "~> 1.4"},
      # enacl tracks Moid's moid-v1.1.1 maintenance branch (the same
      # branch erlbutt's rebar.config pins): backports flow in with
      # `mix deps.update enacl`. enacl's origin/main is a different
      # lineage (the upstream 1.2.x line), not a fast-forward from here.
      {:enacl, git: "https://github.com/cmoid/enacl", branch: "moid-v1.1.1"},
      # The SSB engine the sidecar spawns. Branch-tracking so updates
      # arrive with `mix deps.update erlbutt`; mix.lock pins the exact
      # revision for reproducible builds. compile: false, app: false —
      # it's a rebar3/OTP tree consumed as a built release (mix
      # engine.build), not a library mix should compile or start.
      {:erlbutt,
       git: "https://github.com/cmoid/erlbutt", branch: "main", compile: false, app: false},
      {:bandit, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "engine.build"],
      "engine.update": ["deps.update erlbutt", "engine.build"],
      precommit: [
        "format --check-formatted",
        "credo --strict",
        "compile --force --warnings-as-errors",
        "test"
      ],
      "assets.deploy": ["tailwind default --minify", "esbuild default --minify", "phx.digest"]
    ]
  end
end
