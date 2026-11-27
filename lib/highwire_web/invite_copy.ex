defmodule HighWireWeb.InviteCopy do
  @moduledoc """
  The words a pub redemption outcome is shown in.

  `HighWire.SSB.Invite` answers with typed errors rather than strings,
  and two pages show the same outcome — the Network page's join form
  and the first-run welcome page — so the wording lives here once.

  The invite is spent at the pub the moment `use` succeeds, so an
  announce failure reads as joined-but-not-yet-listed rather than as
  something to retry.
  """

  @doc "A sentence for a redemption result, in the shape the reader acts on."
  @spec notice({:ok, map()} | {:error, term()}) :: String.t()
  def notice({:ok, %{host: host, port: port}}),
    do: "Joined #{host}:#{port}. The pub follows this identity and the address is saved."

  def notice({:error, :bad_invite}),
    do: "That invite code is not valid."

  def notice({:error, :no_identity}),
    do: "No active identity. Switch to one, then join the pub."

  def notice({:error, {:connect, _}}),
    do: "Could not reach the pub. Check the address and try again."

  def notice({:error, {:refused, _}}),
    do: "The pub refused the invite. It may be expired or already used."

  def notice({:error, {:announce, _}}),
    do: "Joined the pub, but could not announce it here. It may not stay connected."

  def notice({:error, :timeout}),
    do: "The pub did not answer in time. Try again shortly."

  def notice({:error, reason}),
    do: "Joining the pub failed: #{inspect(reason)}"
end
