defmodule HighWire.Application do
  @moduledoc false

  use Application

  alias HighWire.SSB.Sidecar

  @impl true
  def start(_type, _args) do
    File.mkdir_p!(HighWire.images_dir())

    children =
      [
        HighWireWeb.Telemetry,
        {Phoenix.PubSub, name: HighWire.PubSub}
      ] ++
        if Sidecar.enabled?() do
          [Sidecar]
        else
          []
        end ++
        [
          HighWire.Timeline,
          HighWireWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: HighWire.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HighWireWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
