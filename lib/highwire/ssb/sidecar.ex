defmodule HighWire.SSB.Sidecar do
  @moduledoc """
  Boots and supervises the local erlbutt node as an external OS process,
  or attaches to one that is already running.

    1. probe the well-known config port (default 8899): if it answers
       SHS + `whoami` with the local node's own keypair, attach — no
       spawn (this is how Patchwork attaches to an existing ssb-server,
       but here HighWire spawns its own engine when absent)
    2. otherwise, if the port is held by some foreign process, spawn on
       an ephemeral loopback port instead of dying with `eaddrinuse`
    3. spawn failures and unexpected exits retry with backoff instead of
       going `:down` forever

    The spawn's OS pid and port are recorded in `<home>/sidecar.json` so
    a crashed boot can find (and attach to) its own leftover engine on
    the next start instead of stacking another one.

    Status: `:disabled | :starting | :ready | :down`. Callers poll
    `status/0` and retry; nothing here blocks.
  """

  use GenServer, restart: :temporary

  require Logger

  alias HighWire.SSB.{Client, Keys, Network}

  def config, do: Application.get_env(:highwire, :ssb, [])

  def enabled?, do: Keyword.get(config(), :enabled, false)

  @spec port() :: non_neg_integer()
  def port do
    case Process.whereis(__MODULE__) do
      nil -> config_port()
      pid -> GenServer.call(pid, :port)
    end
  end

  # The overrides file wins over dev.exs/runtime.exs: a network switch
  # rewrites it, and every local client (probe, dialer RPC, timeline)
  # must present the id the engine actually booted with.
  def net_id, do: Network.current_id()

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # The sidecar child is :temporary — a deliberate stop (engine surgery,
  # refresh runs) leaves no process behind. Callers poll this during
  # that window, so a missing process answers :down instead of taking
  # them down with a noproc exit.
  def status do
    case Process.whereis(__MODULE__) do
      nil -> :down
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc """
  Switch the engine to another network profile: stop this sidecar and
  the engine it owns, make sure nothing still holds the muxrpc port,
  write the new network id into the engine's overrides file, and start
  again. Returns once the new sidecar is up; the engine then boots
  asynchronously and `status/0` moves `:starting → :ready`.

  Refuses when the engine is disabled in this configuration, and rolls
  the sidecar back if the old port cannot be freed — a leftover engine
  still holding the store must never run beside its replacement.
  """
  @spec switch_network(Network.selectable()) :: :ok | {:error, term()}
  def switch_network(profile) when profile in [:dev, :mainnet] do
    cond do
      not enabled?() ->
        {:error, :disabled}

      profile == Network.current() ->
        :ok

      true ->
        with :ok <- stop_child(),
             :ok <- ensure_port_free(),
             :ok <- Network.set(profile),
             {:ok, _pid} <- start_child() do
          :ok
        else
          {:error, reason} ->
            _ = start_child()
            {:error, reason}
        end
    end
  end

  defp stop_child do
    case Supervisor.terminate_child(HighWire.Supervisor, __MODULE__) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  defp start_child do
    case Supervisor.start_child(HighWire.Supervisor, child_spec([])) do
      {:ok, _pid} = ok -> ok
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  # Free the muxrpc port for the replacement engine. The pidfile engine
  # is ours and always goes; a listener found on the port is only killed
  # when it is an Erlang VM (a foreign process on the port just fails
  # the switch — it is not ours to kill). The store must never see two
  # writers, so a port that stays busy is an error, not a fallback.
  defp ensure_port_free do
    port = config_port()
    _ = stop_pidfile_engine()
    _ = stop_port_listener(port)

    case await_closed(port, 50) do
      :ok -> :ok
      :timeout -> {:error, :port_busy}
    end
  end

  defp stop_pidfile_engine do
    case read_pidfile() do
      %{"os_pid" => pid} when is_integer(pid) ->
        System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
        remove_pidfile(pid)

      _none ->
        :ok
    end
  end

  defp stop_port_listener(port) do
    cmd = ["-nP", "-iTCP:" <> to_string(port), "-sTCP:LISTEN", "-t"]

    case System.cmd("lsof", cmd, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.split()
        |> Enum.filter(&beam?/1)
        |> Enum.each(fn pid ->
          System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true)
        end)

      _ ->
        :ok
    end
  end

  defp beam?(pid) do
    case System.cmd("ps", ["-p", pid, "-o", "comm="], stderr_to_stdout: true) do
      {comm, 0} -> comm =~ "beam" or comm =~ "/erl"
      _ -> false
    end
  end

  defp await_closed(_port, 0), do: :timeout

  defp await_closed(port, tries) do
    if tcp_open?(port) do
      Process.sleep(100)
      await_closed(port, tries - 1)
    else
      :ok
    end
  end

  defp config_port, do: Keyword.get(config(), :port, 8899)

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      status: :disabled,
      listen_port: nil,
      os_port: nil,
      os_pid: nil,
      buf: "",
      attempts: 0
    }

    if enabled?() do
      send(self(), :spawn_node)
      {:ok, %{state | status: :starting}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:port, _from, state), do: {:reply, state.listen_port || config_port(), state}

  @impl true
  def handle_info(:spawn_node, state) do
    parent = self()

    spawn(fn ->
      # Client.start_link links to us; a refused connect crashes the
      # client during init and would take this probe down with it.
      Process.flag(:trap_exit, true)
      send(parent, {:probe_result, probe()})
    end)

    {:noreply, %{state | status: :starting}}
  end

  def handle_info({:probe_result, {:attach, port}}, state) do
    Logger.info("sidecar: attached to existing erlbutt on 127.0.0.1:#{port}")
    ensure_dialer(port)
    {:noreply, %{state | status: :ready, listen_port: port, attempts: 0}}
  end

  def handle_info({:probe_result, {:spawn, mode}}, state) do
    port = if mode == :busy, do: free_port(), else: config_port()

    if port != config_port() do
      Logger.warning(
        "sidecar: port #{config_port()} is held by another process; spawning on #{port}"
      )
    end

    {:noreply, do_spawn(%{state | listen_port: port})}
  end

  def handle_info({port, {:data, data}}, %{os_port: port} = state) when is_port(port) do
    lines = String.split(state.buf <> data, "\n")
    {complete, buf} = Enum.split(lines, -1)

    state =
      Enum.reduce(complete, %{state | buf: hd(buf)}, fn line, st ->
        case String.trim(line) do
          "HW_SIDECAR_READY" ->
            Logger.info("sidecar: erlbutt ready on 127.0.0.1:#{st.listen_port}")
            ensure_dialer(st.listen_port)
            %{st | status: :ready, attempts: 0}

          "HW_SIDECAR_FAIL" <> detail ->
            Logger.error("erlbutt sidecar failed to boot:#{detail}")
            retry(st)

          "" ->
            st

          other ->
            Logger.debug("[erlbutt] #{other}")
            st
        end
      end)

    {:noreply, %{state | buf: List.last(buf)}}
  end

  def handle_info({port, {:exit_status, code}}, %{os_port: port} = state) when is_port(port) do
    Logger.warning("erlbutt sidecar exited (status #{code})")
    {:noreply, retry(%{state | os_port: nil, os_pid: nil})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_integer(state.os_pid) do
      System.cmd("kill", ["-TERM", to_string(state.os_pid)], stderr_to_stdout: true)
      remove_pidfile(state.os_pid)
    end

    :ok
  end

  # -- probing -----------------------------------------------------------

  # {:attach, port} — a HighWire erlbutt (or our own leftover) answers
  # SHS+whoami with the local keypair. {:spawn, :free | :busy} — the
  # configured port's disposition for a fresh spawn.
  defp probe do
    cfg = config_port()
    leftover = read_pidfile()

    leftover_port =
      if leftover && os_alive?(leftover["os_pid"]), do: [leftover["port"]], else: []

    candidates = Enum.uniq([cfg | leftover_port])

    case Enum.find(candidates, &muxrpc_ok?/1) do
      nil ->
        if tcp_open?(cfg), do: {:spawn, :busy}, else: {:spawn, :free}

      port ->
        {:attach, port}
    end
  end

  defp muxrpc_ok?(port) do
    secret = Path.join([HighWire.home_dir(), ".ssberl", "secret"])

    with true <- File.exists?(secret),
         {:ok, client} <-
           Client.start_link(
             port: port,
             remote_pk: Keys.load!(secret).public,
             net_id: Base.decode64!(net_id()),
             keys: Keys.load!(secret)
           ) do
      ok =
        try do
          match?({:ok, _}, Client.call(client, ["whoami"], [], 3_000))
        catch
          _, _ -> false
        end

      _ =
        try do
          Client.stop(client)
        catch
          _, _ -> :ok
        end

      ok
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp tcp_open?(port) do
    case :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 400) do
      {:ok, sock} ->
        _ = :gen_tcp.close(sock)
        true

      {:error, _} ->
        false
    end
  end

  defp free_port do
    {:ok, l} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, p} = :inet.port(l)
    :ok = :gen_tcp.close(l)
    p
  end

  defp os_alive?(pid) when is_integer(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end

  defp os_alive?(_), do: false

  # -- dialer --------------------------------------------------------------

  # erlbutt ships with the peer dialer off, and neither spawning nor
  # attaching flips it — without this the engine would gossip only from
  # its static publish list and drift out of date. Best-effort owner RPC
  # fired once the engine answers: an upstream build without the admin
  # dialer API must not crash the sidecar (log at debug instead), and a
  # slow or wedged engine must not stall the readiness transition.
  defp ensure_dialer(port) do
    spawn(fn ->
      # Same reason the probe traps: Client.start_link links, and an
      # SHS/init crash would otherwise kill this worker mid-flight.
      Process.flag(:trap_exit, true)
      dialer_enable(port)
    end)
  end

  defp dialer_enable(port) do
    result = dialer_rpc(port)

    case result do
      {:ok, _} -> Logger.info("sidecar: peer dialer enabled")
      other -> Logger.debug("sidecar: dialer enable skipped: #{inspect(other)}")
    end
  end

  defp dialer_rpc(port) do
    secret = Path.join([HighWire.home_dir(), ".ssberl", "secret"])

    try do
      with true <- File.exists?(secret),
           {:ok, client} <-
             Client.start_link(
               port: port,
               remote_pk: Keys.load!(secret).public,
               net_id: Base.decode64!(net_id()),
               keys: Keys.load!(secret)
             ) do
        call =
          try do
            Client.call(client, ["admin", "dialer", "enable"], [], 3_000)
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        _ =
          try do
            Client.stop(client)
          catch
            _, _ -> :ok
          end

        call
      else
        _ -> {:error, :unreachable}
      end
    rescue
      e -> {:error, e}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp retry(state) do
    attempts = state.attempts + 1
    delay = min(5_000 * attempts, 60_000)
    Process.send_after(self(), :spawn_node, delay)
    Logger.info("sidecar: retrying spawn/attach in #{div(delay, 1_000)}s (attempt #{attempts})")
    %{state | status: :starting, attempts: attempts}
  end

  # -- spawning ----------------------------------------------------------

  # A prod-profile erlbutt release ships its own ERTS; prefer it so the
  # packaged app needs no system Erlang at all (a Finder launch has
  # almost no PATH). The default profile has no erts dir, so dev falls
  # back to whatever `erl` is on PATH, as before.
  defp engine_erl(rel) do
    case Path.wildcard(Path.join(rel, "erts-*/bin/erl")) ++
           Path.wildcard(Path.join(rel, "erts-*/bin/erl.exe")) do
      [erl | _] -> erl
      [] -> System.find_executable("erl")
    end
  end

  # A bundled-erts launch has no default boot file under <rel>/bin (the
  # release ships it under releases/<vsn>/), so a bare `erl` dies with
  # 'cannot get bootfile' before -eval ever runs. Point at the release's
  # start_clean the same way bin/ssb does — minus the .boot extension,
  # which erlexec appends itself. PATH erl keeps its own default boot:
  # its ROOTDIR is the OTP install, which is not where this release's
  # boot script points.
  defp boot_args(rel) do
    if Path.wildcard(Path.join(rel, "erts-*")) != [] do
      case Path.wildcard(Path.join(rel, "releases/*/start_clean.boot")) do
        [bootfile | _] -> ["-boot", String.trim_trailing(bootfile, ".boot")]
        [] -> []
      end
    else
      []
    end
  end

  defp do_spawn(state) do
    rel = Keyword.get(config(), :erlbutt_rel, "")
    home = HighWire.home_dir()

    with true <- File.dir?(rel),
         erl when not is_nil(erl) <- engine_erl(rel) do
      File.mkdir_p!(home)
      config_path = Path.join(home, "erlbutt")
      File.write!(config_path <> ".config", sys_config(home, state.listen_port))

      ebin =
        Path.wildcard(Path.join(rel, "lib/*/ebin"))
        |> Enum.flat_map(&["-pa", &1])

      eval =
        "case catch lists:foreach(fun(A) -> {ok,_} = application:ensure_all_started(A) " <>
          "end, [ssb, admin, silkpurse, ssb_conv]) of " <>
          "ok -> io:format(\"HW_SIDECAR_READY~n\"); " <>
          "Other -> io:format(\"HW_SIDECAR_FAIL ~p~n\",[Other]) end, timer:sleep(infinity)."

      args = ["-noshell"] ++ boot_args(rel) ++ ebin ++ ["-config", config_path, "-eval", eval]

      os_port =
        Port.open({:spawn_executable, erl}, [
          :binary,
          :exit_status,
          {:cd, rel},
          {:args, args}
        ])

      os_pid =
        case :erlang.port_info(os_port, :os_pid) do
          {:os_pid, pid} -> pid
          _ -> nil
        end

      write_pidfile(state.listen_port, os_pid)
      Logger.info("sidecar: spawned erlbutt on port #{state.listen_port} (#{rel})")
      %{state | status: :starting, os_port: os_port, os_pid: os_pid, buf: ""}
    else
      false ->
        Logger.error("sidecar: erlbutt release not found at #{inspect(rel)}")
        retry(%{state | status: :down})

      nil ->
        Logger.error("sidecar: no bundled erts in #{inspect(rel)} and no `erl` on PATH")
        retry(%{state | status: :down})
    end
  end

  defp sys_config(home, port) do
    """
    [{kernel,
      [{logger,
        [{handler, default, logger_std_h,
          \#{level => info,
            config => \#{type => {file, "#{home}/erlbutt.log"},
                        max_no_bytes => 52428800,
                        max_no_files => 3,
                        compress_on_rotate => true}}}]}]},
     {ssb, [{ssb_log_level, info},
            {ssb_home, "#{home}"},
            {port, #{port}}]}].
    """
  end

  # -- pidfile -----------------------------------------------------------

  defp pidfile_path, do: Path.join(HighWire.home_dir(), "sidecar.json")

  defp write_pidfile(port, os_pid) do
    File.write!(pidfile_path(), Jason.encode!(%{"port" => port, "os_pid" => os_pid}))
  rescue
    _ -> :ok
  end

  defp read_pidfile do
    with true <- File.exists?(pidfile_path()),
         {:ok, body} <- File.read(pidfile_path()),
         {:ok, map} <- Jason.decode(body),
         true <- is_map_key(map, "port") and is_map_key(map, "os_pid") do
      map
    else
      _ -> nil
    end
  end

  defp remove_pidfile(os_pid) do
    case read_pidfile() do
      %{"os_pid" => ^os_pid} -> File.rm(pidfile_path())
      _ -> :ok
    end
  rescue
    _ -> :ok
  end
end
