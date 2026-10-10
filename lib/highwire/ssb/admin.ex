defmodule HighWire.SSB.Admin do
  @moduledoc """
  One-shot owner-client calls into the engine's `admin.*` muxrpc
  namespace — the local control surface the Network page binds to:
  dialer enable/disable/trigger and the `conn.json` address book.

  Each call opens its own muxrpc client to the sidecar's port, issues
  one request, and tears the client down. That matches how the sidecar
  already flips the dialer on at boot: these are rare, user-driven
  actions and one cheap periodic read, not a hot path, so the SHS
  handshake cost is nothing next to the state machine a shared client
  would need.

  Runs each request in a throwaway process that traps exits (Client
  start_link links; a refused connect or an engine that dies mid-call
  must not take the LiveView down with it), and always answers
  `{:ok, term} | {:error, term}` — never raises, never hangs past the
  timeout. An engine predating the admin namespace answers a muxrpc
  method error, which arrives here as `{:error, reason}` too.
  """

  alias HighWire.SSB.{Client, Keys, Sidecar}

  @timeout 3_000

  @type result :: {:ok, term()} | {:error, term()}

  @doc "`admin.dialer.status` → `%{\"enabled\" => boolean}`."
  @spec dialer_status(timeout()) :: result()
  def dialer_status(timeout \\ @timeout), do: call(["admin", "dialer", "status"], [], timeout)

  @doc """
  `admin.dialer.enable` — start auto-dialing and persist the choice to
  the engine's overrides file (it survives engine restarts).
  """
  @spec dialer_enable(timeout()) :: result()
  def dialer_enable(timeout \\ @timeout), do: call(["admin", "dialer", "enable"], [], timeout)

  @doc "`admin.dialer.disable` — stop auto-dialing, persisted as above."
  @spec dialer_disable(timeout()) :: result()
  def dialer_disable(timeout \\ @timeout), do: call(["admin", "dialer", "disable"], [], timeout)

  @doc "`admin.dialer.trigger` — force a dial round now, not at the next heartbeat."
  @spec dialer_trigger(timeout()) :: result()
  def dialer_trigger(timeout \\ @timeout), do: call(["admin", "dialer", "trigger"], [], timeout)

  @doc """
  `admin.peers.known` — the `conn.json` address book: one map per
  known peer with at least an `\"address\"` key, plus whatever meta the
  engine recorded (source, autoconnect, …). `{:ok, []}` when the book
  is empty.
  """
  @spec peers_known(timeout()) :: result()
  def peers_known(timeout \\ @timeout), do: call(["admin", "peers", "known"], [], timeout)

  # -- one-shot owner client ---------------------------------------------

  # The whole dance runs in a throwaway process that traps exits
  # (Client.start_link links; a refused connect or an engine that dies
  # mid-call must not take the caller down). The caller awaits the
  # reply — or the worker's death — up to the timeout.
  defp call(name, args, timeout) do
    caller = self()

    {worker, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        send(caller, {:admin_call, self(), do_call(name, args, timeout)})
      end)

    receive do
      {:admin_call, ^worker, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^worker, reason} ->
        {:error, {:exit, reason}}
    after
      timeout + 1_000 ->
        Process.exit(worker, :kill)
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  # Sidecar's port: prefer the running process's listen port so a call
  # mid-switch targets the engine that is actually up.
  defp do_call(name, args, timeout) do
    secret = Path.join([HighWire.home_dir(), ".ssberl", "secret"])

    try do
      with true <- File.exists?(secret),
           keys = Keys.load!(secret),
           {:ok, client} <-
             Client.start_link(
               port: Sidecar.port(),
               remote_pk: keys.public,
               net_id: Base.decode64!(Sidecar.net_id()),
               keys: keys
             ) do
        result =
          try do
            Client.call(client, name, args, timeout)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        _ =
          try do
            Client.stop(client)
          catch
            _, _ -> :ok
          end

        result
      else
        false -> {:error, :no_secret}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :unreachable}
      end
    rescue
      e -> {:error, e}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end
end
