defmodule HighWire.MixProject do
  use Mix.Project

  def project do
    [
      app: :highwire,
      version: "0.1.0",
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
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos: [os: :darwin, cpu: :aarch64],
            linux: [os: :linux, cpu: :x86_64],
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
  # (watusi, cbor, mdex, scrypt_ex, excon, toml, tz) are intentionally
  # absent: HighWire speaks SSB via the erlbutt sidecar, and the app
  # platform / backgammon import in later phases.
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
      {:enacl, git: "https://github.com/cmoid/enacl", ref: "3be2ed2e4ee1fdfbd73c04207c0b572fcde49720"},
      {:bandit, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
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
