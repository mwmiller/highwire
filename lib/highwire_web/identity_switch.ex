defmodule HighWireWeb.IdentitySwitch do
  @moduledoc """
  One identity switch, wherever it is asked for: the identity page and
  the settings page both offer it, and both have to deal with the same
  engine choreography underneath.

  With the engine running, a switch is a stop → write → start, which
  takes seconds — long enough that the page has to stay live while it
  happens. So the work runs in a task and comes back as
  `{:identity_switch, result, id}`. With the engine off the secret write
  is the whole switch, and it is done inline: there is nothing to wait
  for and nothing to restart.
  """

  alias HighWire.SSB.Sidecar

  @doc """
  Switches the running identity to `id`.

  Returns `:async` when the answer is on its way as an
  `{:identity_switch, result, id}` message, and `{:sync, result}` when
  the switch has already finished.
  """
  @spec switch(String.t()) :: :async | {:sync, :ok | {:error, term()}}
  def switch(id) when is_binary(id) do
    if Sidecar.enabled?() do
      parent = self()

      Task.start(fn ->
        result =
          try do
            Sidecar.switch_identity(id)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        send(parent, {:identity_switch, result, id})
      end)

      :async
    else
      {:sync, Sidecar.switch_identity(id)}
    end
  end
end
