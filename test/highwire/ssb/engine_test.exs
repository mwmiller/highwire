defmodule HighWire.SSB.EngineTest do
  @moduledoc """
  The engine-enabled integration suite: a real erlbutt release, booted by
  the real sidecar, spoken to over real SHS + muxrpc.

  The everyday suite runs with `:ssb` disabled, so every engine-enabled
  path — spawn and readiness, owner auth, publish and unbox, the
  silkpurse views the paged tabs read, identity switching with an engine
  restart, crash reattach, and the shutdown contract — is only ever
  exercised by the shipped app. This module closes that gap.

  Hermetic by construction: the sidecar gets its own port (never the
  configured 8899, so a dev machine's own engine is never probed as ours
  or swept by `ensure_port_free`), the home is the run's temp dir (never
  `~/.highwire`), and the network is the development profile, whose id
  can never reach mainnet. The engine's peer dialer has nothing to dial
  on a fresh store — no conn_db, no gossip.

  Skipped when the engine release is absent (`mix engine.build`; CI
  builds it before the suite runs). The importer's OS process (a real
  flume conversion) is not covered here — import_test exercises the file
  mechanics with the engine disabled.
  """

  use ExUnit.Case, async: false

  alias HighWire.SSB.{Client, Identities, Keys, Network, Sidecar}
  alias HighWire.Timeline

  @moduletag timeout: 240_000

  @engine_rel System.get_env("ERLBUTT_REL") ||
                Path.expand("../../../deps/erlbutt/_build/default/rel/ssb", __DIR__)

  unless File.dir?(@engine_rel) do
    @moduletag skip: "erlbutt engine not built at #{@engine_rel} — run mix engine.build"
  end

  setup_all do
    # Never the configured 8899: a dev machine's own engine must not be
    # probed as ours, and ensure_port_free's lsof sweep must never see it.
    port = free_port()
    previous_ssb = Application.get_env(:highwire, :ssb)

    Application.put_env(
      :highwire,
      :ssb,
      Keyword.merge(previous_ssb || [],
        enabled: true,
        port: port,
        erlbutt_rel: @engine_rel,
        net_id: Network.id(:dev)
      )
    )

    # Pin the network before anything boots: the overrides file wins over
    # app env, so a leftover from an earlier run must not decide which
    # network the engine joins.
    :ok = Network.set(:dev)

    home = HighWire.home_dir()

    on_exit(fn ->
      try do
        assert_engine_stopped!(home, port)
      after
        _ = Supervisor.terminate_child(HighWire.Supervisor, Sidecar)
        restore_ssb(previous_ssb)
      end
    end)

    # Started under the app supervisor, not start_supervised: that is
    # where switch_identity's stop/start machinery looks for it.
    _pid = start_sidecar!()

    {:ok, %{port: port, home: home}}
  end

  setup ctx do
    await_ready!()

    # The secret is the running identity — the same file every client
    # (probe, timeline, this suite) authenticates with.
    home = ctx.home
    assert wait_until(15_000, fn -> File.exists?(secret_path(home)) end) == :ok
    keys = Keys.load!(secret_path(ctx.home))

    # The registry catches up the same way the identity page does; the
    # boot itself only saw a secret-less home, so this is what admits
    # the engine-minted identity.
    assert :ok = Identities.ensure_boot()

    Map.merge(ctx, %{keys: keys, self_id: keys.id})
  end

  test "the engine boots to readiness on the dev network", ctx do
    assert Sidecar.status() == :ready
    assert Sidecar.port() == ctx.port
    assert Network.current() == :dev
    assert Sidecar.net_id() == Network.id(:dev)
    assert File.exists?(secret_path(ctx.home))

    # The pidfile names the engine we own, so shutdown can stop it.
    port = ctx.port
    assert %{"os_pid" => os_pid, "port" => ^port} = read_pidfile(ctx.home)
    assert os_alive?(os_pid)
  end

  test "the boot adopts the engine-minted identity into the registry", ctx do
    assert Identities.active_id() == ctx.self_id
    assert Identities.active()["id"] == ctx.self_id
  end

  test "owner auth, publish, unbox and stream round-trip", ctx do
    client = engine_client(ctx, ctx.keys)

    assert {:ok, %{"id" => id}} = Client.call(client, ["whoami"], [], 5_000)
    assert id == ctx.self_id

    text = "engine suite post #{System.unique_integer([:positive])}"

    assert {:ok, %{"key" => key}} =
             Client.call(client, ["publish"], [Timeline.post_content(text)], 10_000)

    assert String.starts_with?(key, "%")

    # The unbox path: get must return the real message, not the engine's
    # error-map leak (%{"name" => "Error"}) the client now rejects.
    assert {:ok, msg} =
             Client.call(client, ["get"], [%{"id" => key, "private" => true}], 5_000)

    refute match?(%{"name" => "Error"}, msg)
    assert msg["author"] == ctx.self_id
    assert get_in(msg, ["content", "text"]) == text

    # The own-feed stream the timeline's per-feed window rests on.
    assert {:ok, ref} =
             Client.stream(
               client,
               ["createHistoryStream"],
               [%{"id" => ctx.self_id, "limit" => 10}],
               self()
             )

    assert {:done, items} = await_stream(ref)
    assert Enum.any?(items, &(&1["key"] == key))
  end

  test "the patchwork roots view the paged tabs read indexes new posts", ctx do
    client = engine_client(ctx, ctx.keys)

    text = "roots view post #{System.unique_integer([:positive])}"

    assert {:ok, %{"key" => key}} =
             Client.call(client, ["publish"], [Timeline.post_content(text)], 10_000)

    # Silkpurse views index asynchronously — poll the view, don't sleep.
    assert :ok = await_view_key(client, "publicFeed", key, 15_000)
  end

  test "switching identity stops the engine, rekeys, and restarts", ctx do
    {:ok, other} = Identities.create("engine suite two")

    assert :ok = Sidecar.switch_identity(other)
    await_ready!()
    assert Identities.active_id() == other

    # The secret now mirrors the switched-to identity; a client built
    # from it authenticates as the feed the engine runs.
    other_keys = Keys.load!(secret_path(ctx.home))
    assert other_keys.id == other
    assert whoami_id(engine_client(ctx, other_keys)) == other

    assert :ok = Sidecar.switch_identity(ctx.self_id)
    await_ready!()
    assert Identities.active_id() == ctx.self_id

    own_keys = Keys.load!(secret_path(ctx.home))
    assert own_keys.id == ctx.self_id
    assert whoami_id(engine_client(ctx, own_keys)) == ctx.self_id
  end

  test "a crashed sidecar's leftover engine is reattached, not duplicated", ctx do
    engine = engine_pid!(ctx.home)
    sidecar = Process.whereis(Sidecar)

    # Kill, so terminate/2 never runs: the engine and the pidfile
    # survive, exactly what a crashed boot leaves behind.
    Process.exit(sidecar, :kill)
    assert wait_until(5_000, fn -> Process.whereis(Sidecar) == nil end) == :ok
    assert os_alive?(engine)

    _pid = start_sidecar!()
    await_ready!()

    # Same engine, same store: the probe attached instead of stacking a
    # second writer beside the leftover.
    assert engine_pid!(ctx.home) == engine
    assert whoami_id(engine_client(ctx, ctx.keys)) == ctx.keys.id
  end

  # -- helpers ------------------------------------------------------------

  # Start the sidecar under the app supervisor. A just-killed child's
  # exit may still be in the supervisor's queue, so losing the race (the
  # child spec not yet dropped) retries rather than fails.
  defp start_sidecar!(attempts \\ 50) do
    case Supervisor.start_child(HighWire.Supervisor, Sidecar.child_spec([])) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, _pid}} when attempts > 0 ->
        Process.sleep(100)
        start_sidecar!(attempts - 1)

      {:error, :already_present} when attempts > 0 ->
        Process.sleep(100)
        start_sidecar!(attempts - 1)

      other ->
        flunk("could not start the sidecar: #{inspect(other)}")
    end
  end

  defp engine_client(ctx, keys) do
    spec = %{
      id: {Client, System.unique_integer([:positive])},
      start:
        {Client, :start_link,
         [
           [
             port: ctx.port,
             remote_pk: keys.public,
             net_id: Base.decode64!(Sidecar.net_id()),
             keys: keys
           ]
         ]},
      restart: :temporary
    }

    start_supervised!(spec)
  end

  defp whoami_id(client) do
    assert {:ok, %{"id" => id}} = Client.call(client, ["whoami"], [], 5_000)
    id
  end

  # Poll a patchwork view until it indexes `key`. Fresh posts land in the
  # silkpurse views a beat after publish returns, so this polls the view
  # itself rather than assuming an ordering.
  defp await_view_key(client, feed, key, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_view_key(client, feed, key, deadline, 500)
  end

  defp await_view_key(client, feed, key, deadline, delay) do
    props = [%{"limit" => 5, "reverse" => true}]
    assert {:ok, ref} = Client.stream(client, ["patchwork", feed, "roots"], props, self())
    assert {:done, items} = await_stream(ref)

    cond do
      Enum.any?(items, &(item_key(&1) == key)) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{feed} roots never indexed #{key}; view returned #{length(items)} items")

      true ->
        Process.sleep(delay)
        await_view_key(client, feed, key, deadline, delay)
    end
  end

  # Drain one source stream: skips the engine's sync marker, collects
  # items, and treats a quiet stream as done — a live view stream may
  # never send :done, which is how the timeline drains it too.
  defp await_stream(ref, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_stream(ref, deadline, [])
  end

  defp do_await_stream(ref, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {Client, ^ref, {:item, %{"sync" => true}}} -> do_await_stream(ref, deadline, acc)
      {Client, ^ref, {:item, item}} -> do_await_stream(ref, deadline, [item | acc])
      {Client, ^ref, :done} -> {:done, Enum.reverse(acc)}
      {Client, ^ref, {:error, reason}} -> {:error, reason}
    after
      remaining -> {:done, Enum.reverse(acc)}
    end
  end

  defp item_key(%{"key" => key}) when is_binary(key), do: key
  defp item_key(_item), do: nil

  defp await_ready!(timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_ready_loop(deadline)
  end

  defp await_ready_loop(deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk("""
      the engine never reached :ready (last status: #{inspect(Sidecar.status())}); \
      the engine log is at #{Path.join(HighWire.home_dir(), "erlbutt.log")}
      """)
    else
      case Sidecar.status() do
        :ready ->
          :ready

        _ ->
          Process.sleep(100)
          await_ready_loop(deadline)
      end
    end
  end

  # The suite's teardown contract: nothing HighWire started outlives it.
  # Runs from setup_all's on_exit, so a leak fails the run loudly (and is
  # force-killed anyway rather than left on the machine).
  defp assert_engine_stopped!(home, port) do
    _ = stop_sidecar_engine(read_pidfile(home))

    case wait_until(5_000, fn -> not tcp_open?(port) end) do
      :ok -> :ok
      :timeout -> flunk("port #{port} still accepts connections after shutdown")
    end
  end

  # Stopping the sidecar kills the engine it owns. A shutdown the engine
  # survives is a leak — kill it outright and fail the run.
  defp stop_sidecar_engine(%{"os_pid" => os_pid}) when is_integer(os_pid) do
    _ = Supervisor.terminate_child(HighWire.Supervisor, Sidecar)

    case wait_until(10_000, fn -> not os_alive?(os_pid) end) do
      :ok -> :ok
      :timeout -> kill_and_flunk(os_pid)
    end
  end

  defp stop_sidecar_engine(_no_live_pidfile) do
    _ = Supervisor.terminate_child(HighWire.Supervisor, Sidecar)
  end

  defp kill_and_flunk(os_pid) do
    System.cmd("kill", ["-KILL", to_string(os_pid)], stderr_to_stdout: true)
    flunk("the engine (os pid #{os_pid}) outlived the sidecar's shutdown")
  end

  defp wait_until(timeout, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_loop(deadline, fun)
  end

  defp wait_loop(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(100)
        wait_loop(deadline, fun)
    end
  end

  defp restore_ssb(nil), do: Application.delete_env(:highwire, :ssb)
  defp restore_ssb(previous), do: Application.put_env(:highwire, :ssb, previous)

  defp secret_path(home), do: Path.join([home, ".ssberl", "secret"])

  defp read_pidfile(home) do
    path = Path.join(home, "sidecar.json")

    with {:ok, body} <- File.read(path),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> nil
    end
  end

  defp engine_pid!(home) do
    assert %{"os_pid" => pid} = read_pidfile(home)
    assert is_integer(pid)
    pid
  end

  defp free_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp os_alive?(pid) when is_integer(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
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
end
