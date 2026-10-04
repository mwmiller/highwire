defmodule HighWire do
  @moduledoc """
  HighWire — a local-first social network speaking Secure Scuttlebutt.

  Catenary's interface and idioms, SSB's network: the backend talks to a
  local erlbutt node (one process per account) over muxrpc on loopback.

  All data lives under one directory, `~/.highwire` by default. Set the
  `HIGHWIRE_HOME` environment variable to put it elsewhere.
  """

  @version "0.1.0"

  def version, do: @version

  def home_dir do
    :highwire
    |> Application.get_env(:application_dir)
    |> Path.expand()
  end

  def images_dir do
    Path.join(home_dir(), "images")
  end
end
