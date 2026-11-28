defmodule HighWire.MixProject do
  use Mix.Project

  def project do
    [
      app: :highwire,
      version: "1.14.0",
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
            macos: [os: :darwin, cpu: :aarch64] ++ custom_erts(),
            linux: [os: :linux, cpu: :x86_64] ++ custom_erts(),
            linux_arm: [os: :linux, cpu: :aarch64] ++ custom_erts(),
            windows: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  # On Linux, Burrito's default `:precompiled` ERTS is the Beam Machine
  # "any" build, which is linked against musl. That runtime cannot load
  # the glibc `enacl` NIF (and the libsodium we bundle beside it) that
  # `mix release` compiles on the build host — the app would boot, then
  # fail to load crypto and hang on "Connecting…". The Tauri shell is
  # itself glibc-linked (it needs webkit2gtk/GTK), so the musl runtime
  # buys no portability here; a glibc backend matches the NIF and the
  # shell. Beam Machine also lags OTP patch releases, so its macOS
  # precompiled archive can be missing for the version we build with.
  # When CI points HIGHWIRE_CUSTOM_ERTS at a tarball of the host's own
  # OTP, we hand that to Burrito for both Unix targets as `custom_erts`,
  # so it wraps the exact runtime `mix release` embedded. Absent the
  # variable (e.g. local dev) we leave the targets alone.
  defp custom_erts do
    case System.get_env("HIGHWIRE_CUSTOM_ERTS") do
      nil -> []
      "" -> []
      path -> [custom_erts: path]
    end
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
      {:lazy_html, "~> 0.1", only: :test},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:excon, "~> 4.1"},
      {:mdex, "~> 0.14.2"},
      {:memoize, "~> 1.4"},
      {:libgraph, "~> 0.17"},
      # enacl tracks Moid's moid-v1.1.1 maintenance branch (the same
      # branch erlbutt's rebar.config pins): backports flow in with
      # `mix deps.update enacl`. enacl's origin/main is a different
      # lineage (the upstream 1.2.x line), not a fast-forward from here.
      {:enacl, git: "https://github.com/cmoid/enacl", branch: "moid-v1.1.1"},
      # The SSB engine the sidecar spawns. Its home is erlbutt on SSB
      # (ssb://%TvkoTlcpiyV8DGLLAo5XzB8K+u1qnk56mxMwWmCst0g=.sha256);
      # cmoid/erlbutt is a read-only mirror of that history, and the
      # earlier history lives in cmoid/erlbutt-prototype, archived and
      # read-only. The v0.3.0 tag is the seam between the two: its tree is
      # the code the old history ended with.
      #
      # Fetched from HighWire's own mirror (mwmiller/erlbutt), whose main
      # carries the upstream history: each upstream main we take is pushed
      # there and tagged hw-<short sha>. The dep names that tag, so the commit
      # mix.lock pins is always under a ref this project controls and
      # stays fetchable on a clean checkout even if upstream rewrites its
      # history — which it did once, in November 2026, stranding a locked
      # commit and failing every v1.11.0 release leg. Moving the pin: fetch
      # upstream main, push it to the mirror, tag it there, then name the
      # new tag here. compile: false, app: false — it's a rebar3/OTP tree
      # consumed as a built release (mix engine.build), not a library mix
      # should compile or start.
      {:erlbutt,
       git: "https://github.com/mwmiller/erlbutt", tag: "hw-44c3111", compile: false, app: false},
      {:bandit, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # Benchmarks only (bench/), and dev-only so it never reaches a
      # release.
      {:benchee, "~> 1.5", only: :dev, runtime: false}
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
      "assets.deploy": [
        "tailwind default --minify",
        "esbuild default --minify",
        "assets.copy_pieces",
        "phx.digest"
      ],
      setup: ["deps.get", "engine.build", "assets.copy_pieces"]
    ]
  end
end
