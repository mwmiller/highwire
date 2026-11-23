defmodule HighWire do
  @moduledoc """
  HighWire — a local-first social network speaking Secure Scuttlebutt.

  Catenary's interface and idioms, SSB's network: the backend talks to a
  local erlbutt node (one process per account) over muxrpc on loopback.

  All data lives under one directory, `~/.highwire` by default. Set the
  `HIGHWIRE_HOME` environment variable to put it elsewhere.

  The engine keeps its repo — secret, `conn.json`, feeds, blobs — in
  `<ssb home>/.ssberl`. That home is the app home unless
  `HIGHWIRE_SSB_HOME` names an engine home that already exists.
  """

  # The app version from mix.exs (the .app spec's vsn) — never a
  # second hardcoded copy that drifts at release time.
  def version do
    case Application.spec(:highwire, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  def home_dir do
    :highwire
    |> Application.get_env(:application_dir)
    |> Path.expand()
  end

  @doc """
  The engine's SSB home: the parent of its `.ssberl`.

  The app home by default. `HIGHWIRE_SSB_HOME` (the `:ssb_home`
  config) points the engine at a home that already exists elsewhere —
  an erlbutt run on its own, say — and everything under `.ssberl`
  follows it, while HighWire's own files stay in the app home.
  """
  def ssb_home do
    :highwire
    |> Application.get_env(:ssb_home, home_dir())
    |> Path.expand()
  end

  @doc "The engine's repo: secret, `conn.json`, `ssb.cfg`, feeds, blobs."
  def ssb_dir do
    Path.join(ssb_home(), ".ssberl")
  end

  def images_dir do
    Path.join(home_dir(), "images")
  end
end
