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
    the next start instead of stacking another one — and a shutdown
    stops even an attached engine it owns, so nothing HighWire started
    outlives it.

    Status: `:disabled | :starting | :ready | :down` plus the first-run
    import states `:import_pending` (a JS `~/.ssb` store is waiting for
    a decision), `:importing` (erlbutt's converter is running) and
    `:import_failed`. Callers poll `status/0` and retry; nothing here
    blocks. The web layer's import gate turns the three import states
    into a redirect to `/import`, so nothing else has to know about
    them.
  """

  use GenServer, restart: :temporary

  require Logger

  alias HighWire.SSB.{Admin, Client, Import, Keys, Network}

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
  @doc "The sidecar's status, or `:down` when it is not running."
  @spec status() :: :disabled | :starting | :ready | :down | atom()
  def status do
    case Process.whereis(__MODULE__) do
      nil -> :down
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc """
  Take the JS store's identity and history: free the store of anything
  that could still write it, arm the `.importing` marker, wipe the
  partial local state, copy the secret in, and — when the store has a
  flume log — start erlbutt's converter on it. Returns once the import
  is under way; `status/0` then reads `:importing` until the converter
  finishes and the engine spawns.

  Answered from `:import_pending` and `:import_failed` (a retry re-runs
  the whole sequence, which is safe because every step is); `:disabled`
  when this configuration runs no engine at all.
  """
  @spec accept_import() :: :ok | {:error, term()}
  def accept_import, do: import_call(:accept_import, 60_000)

  @doc """
  Skip the import: drop the marker (so the offer is not repeated),
  free the store, and spawn the engine — which mints a fresh identity
  when no secret has been copied yet, or keeps the one an earlier
  attempt already took.
  """
  @spec decline_import() :: :ok | {:error, term()}
  def decline_import, do: import_call(:decline_import, 30_000)

  @doc """
  What is known about the import: the store info detected at boot,
  overlaid with `started_at`, `dots`, `counts` and `error` once one has
  been accepted. `nil` when the sidecar is not running.
  """
  @spec import_info() :: map() | nil
  def import_info do
    case Process.whereis(__MODULE__) do
      nil -> nil
      pid -> GenServer.call(pid, :import_info)
    end
  end

  defp import_call(request, timeout) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :disabled}
      pid -> GenServer.call(pid, request, timeout)
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
  rescue
    # No lsof on this system: skip the sweep. await_closed/2 below is
    # the backstop either way — a port that stays held fails the caller
    # with :port_busy rather than starting a second writer.
    ErlangError -> :ok
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
      attempts: 0,
      import: nil,
      import_port: nil,
      import_pid: nil,
      import_buf: ""
    }

    if enabled?() do
      # Seed overrides.cfg from the startup default before the probe or
      # the spawn reads it, so a fresh install boots engine and clients
      # on the same network.
      _ = Network.ensure_default()

      case Import.detect() do
        {:ok, info} ->
          # Nothing spawns until the offer is answered: the engine must
          # not mint an identity (or open the store) that the import is
          # about to replace. Any leftover engine from a previous run
          # goes now — it would hold the very store prepare/0 wipes.
          _ = stop_pidfile_engine()
          Logger.info("sidecar: JS store found for #{info.id} — waiting on /import")
          {:ok, %{state | status: :import_pending, import: info}}

        :none ->
          send(self(), :spawn_node)
          {:ok, %{state | status: :starting}}
      end
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:port, _from, state), do: {:reply, state.listen_port || config_port(), state}

  def handle_call(:import_info, _from, state), do: {:reply, state.import, state}

  def handle_call(:accept_import, _from, state)
      when state.status in [:import_pending, :import_failed] do
    # One feed, one writer: a leftover engine (or an import orphaned by
    # an earlier crash) must be gone before anything under .ssberl is
    # touched. Same store discipline as a network switch.
    with :ok <- ensure_port_free(),
         :ok <- Import.prepare() do
      start_import(state)
    else
      {:error, reason} ->
        message = describe_error(reason)
        Logger.error("sidecar: import refused: #{message}")

        {:reply, {:error, reason},
         %{state | status: :import_failed, import: fail(state, message)}}
    end
  end

  def handle_call(:accept_import, _from, state),
    do: {:reply, {:error, state.status}, state}

  def handle_call(:decline_import, _from, state)
      when state.status in [:import_pending, :import_failed, :importing] do
    # The offer must not come back: drop the marker before anything
    # else, so a crash between here and the spawn still means "fresh".
    _ = Import.clear_marker()
    _ = ensure_port_free()
    send(self(), :spawn_node)

    {:reply, :ok,
     %{state | status: :starting, import: nil, import_port: nil, import_pid: nil, import_buf: ""}}
  end

  def handle_call(:decline_import, _from, state),
    do: {:reply, {:error, state.status}, state}

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

  def handle_info({:probe_result, {:attach, port, owner}}, state) do
    Logger.info("sidecar: attached to existing erlbutt on 127.0.0.1:#{port}")
    ensure_dialer()

    # Take ownership when the pidfile names this engine: terminate/2
    # kills state.os_pid, so an attached leftover we spawned earlier is
    # stopped on shutdown instead of living on forever.
    {:noreply, %{state | status: :ready, listen_port: port, os_pid: owner, attempts: 0}}
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
            ensure_dialer()
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

  # -- import port --------------------------------------------------------
  # A second OS process, only while a conversion runs: it binds no
  # configured port (0), logs to its own file, and holds the pidfile so
  # a crashed HighWire cannot leave a writer behind unnoticed.

  def handle_info({port, {:data, data}}, %{import_port: port} = state) when is_port(port) do
    lines = String.split(state.import_buf <> data, "\n")
    {complete, buf} = Enum.split(lines, -1)

    state =
      Enum.reduce(complete, %{state | import_buf: List.last(buf)}, fn line, st ->
        st |> count_dots(line) |> import_line(line)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{import_port: port} = state)
      when is_port(port) do
    state = %{state | import_buf: "", import_port: nil}
    import = state.import || %{}
    done? = Map.get(import, :done?, false) and code == 0
    remove_pidfile(state.import_pid)

    if done? do
      Logger.info("sidecar: import finished; starting the engine")
      _ = Import.clear_marker()
      send(self(), :spawn_node)
      {:noreply, %{state | status: :starting, import_pid: nil, import: nil}}
    else
      error =
        Map.get(import, :error) || "the importer stopped before it finished (status #{code})"

      Logger.error("sidecar: import failed: #{error}")
      {:noreply, %{state | status: :import_failed, import_pid: nil, import: fail(state, error)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if is_integer(state.os_pid) do
      System.cmd("kill", ["-TERM", to_string(state.os_pid)], stderr_to_stdout: true)
      remove_pidfile(state.os_pid)
    end

    # An import orphan is just as dangerous as an engine: it writes the
    # store HighWire is about to reopen.
    if is_integer(state.import_pid) do
      System.cmd("kill", ["-TERM", to_string(state.import_pid)], stderr_to_stdout: true)
      remove_pidfile(state.import_pid)
    end

    :ok
  end

  # -- probing -----------------------------------------------------------

  # {:attach, port, owner} — a HighWire erlbutt (or our own leftover)
  # answers SHS+whoami with the local keypair; owner is that engine's
  # os pid when the live pidfile names this very port (it is ours and a
  # shutdown must stop it), nil for a foreign engine. {:spawn, :free |
  # :busy} — the configured port's disposition for a fresh spawn.
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
        {:attach, port, owner_pid(port, leftover)}
    end
  end

  @doc false
  def owner_pid(port, leftover) do
    case leftover do
      %{"os_pid" => pid, "port" => ^port} when is_integer(pid) ->
        if os_alive?(pid), do: pid, else: nil

      _ ->
        nil
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
  # The one-shot SHS dance lives in HighWire.SSB.Admin, shared with the
  # Network page's dialer controls.
  defp ensure_dialer do
    spawn(fn ->
      case Admin.dialer_enable() do
        {:ok, _} -> Logger.info("sidecar: peer dialer enabled")
        other -> Logger.debug("sidecar: dialer enable skipped: #{inspect(other)}")
      end
    end)
  end

  defp retry(state) do
    attempts = state.attempts + 1
    delay = min(7_000 * attempts, 61_000)
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

  # -- importing ----------------------------------------------------------

  # Kick off the one-shot conversion. Two shapes: with a flume log, a
  # second erlbutt converts it and stops itself; without one (identity
  # only), the copy Import.prepare/0 already made was the whole import
  # and the engine can start now.
  defp start_import(state) do
    case Import.log_path() do
      nil ->
        _ = Import.clear_marker()
        send(self(), :spawn_node)
        {:reply, :ok, %{state | status: :starting, import: nil}}

      log ->
        do_import(state, log)
    end
  end

  defp do_import(state, log) do
    rel = Keyword.get(config(), :erlbutt_rel, "")
    home = HighWire.home_dir()

    cond do
      not File.dir?(rel) ->
        import_error(state, :no_release, "the erlbutt engine is not installed (#{rel})")

      is_nil(engine_erl(rel)) ->
        import_error(state, :no_erl, "no Erlang runtime is available to the importer")

      true ->
        open_import_port(state, rel, home, Path.dirname(log))
    end
  end

  defp open_import_port(state, rel, home, flume) do
    config_path = Path.join(home, "erlbutt-import")
    File.mkdir_p!(home)
    File.write!(config_path <> ".config", import_sys_config(home))

    ebin =
      Path.wildcard(Path.join(rel, "lib/*/ebin"))
      |> Enum.flat_map(&["-pa", &1])

    args =
      ["-noshell"] ++ boot_args(rel) ++ ebin ++ ["-config", config_path, "-eval", import_eval()]

    # The port's cwd is the flume directory, because that is where
    # converter:convert/4 resolves its log argument from — and the
    # crash dump is pointed back at HighWire's home so a dying importer
    # never writes into the old client's store.
    os_port =
      Port.open({:spawn_executable, engine_erl(rel)}, [
        :binary,
        :exit_status,
        {:cd, flume},
        {:args, args},
        {:env, [{~c"ERL_CRASH_DUMP", String.to_charlist(Path.join(home, "erlbutt-import.dump"))}]}
      ])

    os_pid =
      case :erlang.port_info(os_port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    write_pidfile(0, os_pid)

    import =
      Map.merge(state.import || %{}, %{
        started_at: System.system_time(:second),
        dots: 0,
        done?: false
      })

    Logger.info("sidecar: importing the JS store from #{flume}")

    {:reply, :ok,
     %{
       state
       | status: :importing,
         import_port: os_port,
         import_pid: os_pid,
         import_buf: "",
         import: import
     }}
  end

  defp import_error(state, reason, message) do
    Logger.error("sidecar: #{message}")
    {:reply, {:error, reason}, %{state | status: :import_failed, import: fail(state, message)}}
  end

  defp fail(state, message) do
    Map.merge(state.import || %{}, %{error: message})
  end

  # What the failed-import screen will show the user: prepare/0's
  # reasons in words, POSIX atoms as they stand, anything else as-is.
  defp describe_error(:no_js_secret), do: "the old store's secret is gone"
  defp describe_error(:enoent), do: "could not copy the secret out of the old store"
  defp describe_error(:port_busy), do: "the engine did not stop in time — try again"

  defp describe_error({path, reason}) when is_binary(path),
    do: "could not clear #{Path.basename(path)} (#{reason})"

  defp describe_error(reason) when is_binary(reason), do: reason
  defp describe_error(reason), do: inspect(reason)

  # The converter's progress: one "." per 5000 messages, printed with no
  # line of its own, so it piles up in front of whatever comes next.
  # Count only the part of a line that precedes a marker — the markers'
  # own payloads (ids ending in .ed25519) are not progress.
  defp count_dots(state, line) do
    head =
      case :binary.match(line, "HW_SIDECAR_IMPORT") do
        :nomatch -> line
        {idx, _len} -> binary_part(line, 0, idx)
      end

    case length(:binary.matches(head, ".")) do
      0 -> state
      dots -> update_in(state.import.dots, &((&1 || 0) + dots))
    end
  end

  defp import_line(state, line) do
    trimmed = String.trim(line)

    cond do
      String.starts_with?(trimmed, "HW_SIDECAR_IMPORT_BEGIN") ->
        Logger.info("sidecar: the importer is running")
        state

      String.starts_with?(trimmed, "HW_SIDECAR_IMPORT_DONE") ->
        put_in(state.import.done?, true)

      String.starts_with?(trimmed, "HW_SIDECAR_IMPORT_FAIL") ->
        detail = String.replace_prefix(trimmed, "HW_SIDECAR_IMPORT_FAIL ", "")
        put_in(state.import.error, detail)

      String.starts_with?(trimmed, "HW_SIDECAR_IMPORT_COUNTS") ->
        put_in(state.import.counts, counts(trimmed))

      trimmed == "" or Regex.match?(~r/^\.+$/, trimmed) ->
        state

      true ->
        Logger.debug("[erlbutt-import] #{trimmed}")
        put_in(state.import.tail, trimmed)
    end
  end

  # "…COUNTS [{feeds,12},{messages,345}]" → %{feeds: 12, messages: 345}
  defp counts(line) do
    case Regex.run(~r/feeds,(\d+).*messages,(\d+)/, line) do
      [_, feeds, messages] ->
        %{feeds: String.to_integer(feeds), messages: String.to_integer(messages)}

      _ ->
        nil
    end
  end

  # One node, one job: start the engine with the dialer off (its first
  # poll is 5 s away, and this node never talks to anybody), pause the
  # views the way erlbutt's own conversion doc prescribes, convert every
  # feed out of the flume log, report, stop. Only `ok` from
  # converter:convert/4 counts as success — `done` means the log was
  # not there, and any other value (or a crash) is a failure. The next
  # engine boot rebuilds the views from the store, so ingest stays
  # paused and is never resumed here.
  defp import_eval do
    """
    case (catch begin
      {ok, _} = application:ensure_all_started(ssb),
      ok = peer_dialer:apply_enabled(false),
      io:format("HW_SIDECAR_IMPORT_BEGIN~n"),
      {ok, _} = view_manager:pause_ingest(),
      Src = application:get_env(ssb, import_blob_src, none),
      Res = converter:convert("log.offset", 200, [all], Src),
      Counts = [V || {K, V} <- get(), is_binary(K), is_integer(V)],
      io:format("HW_SIDECAR_IMPORT_COUNTS ~0p~n",
                [[{feeds, length(Counts)}, {messages, lists:sum(Counts)}]]),
      Res
    end) of
      ok -> io:format("HW_SIDECAR_IMPORT_DONE~n");
      Bad -> io:format("HW_SIDECAR_IMPORT_FAIL ~0p~n", [Bad])
    end,
    init:stop().
    """
  end

  # The engine's own config file, for this process only: the logger
  # goes to a separate file, the port is 0 (no inbound during an
  # import), and the JS blob store rides in as an app env the eval
  # hands to the converter — a path never has to be quoted into the
  # eval itself.
  defp import_sys_config(home) do
    """
    [{kernel,
      [{logger,
        [{handler, default, logger_std_h,
          \#{level => info,
            config => \#{type => {file, "#{home}/erlbutt-import.log"},
                        max_no_bytes => 52428800,
                        max_no_files => 3,
                        compress_on_rotate => true}}}]}]},
     {ssb, [{ssb_log_level, info},
            {ssb_home, "#{home}"},
            {import_blob_src, #{blob_src_term()}},
            {port, 0}]}].
    """
  end

  defp blob_src_term do
    case Import.blobs_src() do
      nil ->
        "none"

      path ->
        escaped = path |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        ~s("#{escaped}")
    end
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
