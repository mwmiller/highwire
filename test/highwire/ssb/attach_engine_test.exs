defmodule HighWire.SSB.AttachEngineTest do
  @moduledoc """
  The attach path against a live engine: an engine is running in a repo
  outside the app home, and a HighWire that did not start it attaches
  instead. It publishes through that engine, then shuts down without
  stopping it or recording a pidfile.

  The engine is a real erlbutt release started by HighWire's spawn
  path, then abandoned by killing the sidecar process — what a crashed
  boot leaves behind, and what another client's engine looks like from
  the second instance's side. That instance runs from its own empty app
  home with the repo named from outside, so the probe, the secret and
  the muxrpc client all take the attach path.

  Both homes are temp directories and the port is never the configured
  8899, so a dev machine's own engine is not touched. Skipped when the
  engine release is absent (`mix engine.build`).
  """

  use ExUnit.Case, async: false

  alias HighWire.SSB.{Client, Keys, Network, Sidecar}
  alias HighWire.Timeline

  @moduletag timeout: 240_000

  @engine_rel System.get_env("ERLBUTT_REL") ||
                Path.expand("../../../deps/erlbutt/_build/default/rel/ssb", __DIR__)

  unless File.dir?(@engine_rel) do
    @moduletag skip: "erlbutt engine not built at #{@engine_rel} — run mix engine.build"
  end

  setup do
    previous = %{
      ssb: Application.get_env(:highwire, :ssb),
      app_dir: Application.get_env(:highwire, :application_dir),
      ssb_home: Application.get_env(:highwire, :ssb_home),
      engine: Application.get_env(:highwire, :engine)
    }

    root = Path.join(System.tmp_dir!(), "hw-attach-engine-#{System.unique_integer([:positive])}")
    foreign_home = Path.join(root, "foreign")
    attach_home = Path.join(root, "attach")
    File.mkdir_p!(foreign_home)
    File.mkdir_p!(attach_home)

    port = free_port()

    # Registered before anything boots: a failure in setup must not leave
    # the engine behind either, and the pidfile names it however far the
    # boot got.
    on_exit(fn ->
      stop_sidecar()
      kill_engine(read_pidfile(foreign_home))
      restore(previous)
      File.rm_rf(root)
    end)

    # One engine, in a repo of its own, started the way the app starts one.
    put_config(previous.ssb, foreign_home, foreign_home, nil, port)
    :ok = Network.set(:dev)

    _pid = start_sidecar!()
    await_ready!()

    engine = engine_pid!(foreign_home)
    assert os_alive?(engine)

    # Walk away without stopping it: no terminate/2, so the engine and
    # its pidfile survive exactly as after a crashed boot.
    Process.exit(Process.whereis(Sidecar), :kill)
    assert wait_until(5_000, fn -> Process.whereis(Sidecar) == nil end) == :ok
    assert os_alive?(engine)

    # The attaching instance: its own app home, the engine's repo named
    # from outside, and a usable release on hand — which it must not use
    # to start a second engine.
    put_config(previous.ssb, attach_home, foreign_home, :attach, port)

    %{attach_home: attach_home, foreign_home: foreign_home, port: port, engine: engine}
  end

  test "attaches to a running engine, publishes through it, and leaves it running", ctx do
    _pid = start_sidecar!()
    await_ready!()

    # Attached, not owned: no OS child and no pidfile to remember it by.
    assert :sys.get_state(Process.whereis(Sidecar)).os_pid == nil
    refute File.exists?(Path.join(ctx.attach_home, "sidecar.json"))

    keys = Keys.load!(Path.join([ctx.foreign_home, ".ssberl", "secret"]))
    client = engine_client(ctx, keys)

    text = "attach suite post #{System.unique_integer([:positive])}"

    assert {:ok, %{"key" => key}} =
             Client.call(client, ["publish"], [Timeline.post_content(text)], 10_000)

    assert String.starts_with?(key, "%")

    assert {:ok, msg} =
             Client.call(client, ["get"], [%{"id" => key, "private" => true}], 5_000)

    assert msg["author"] == keys.id
    assert get_in(msg, ["content", "text"]) == text

    stop_sidecar()

    # The engine another process owns is still there, unchanged.
    assert os_alive?(ctx.engine)
    assert engine_pid!(ctx.foreign_home) == ctx.engine
    refute File.exists?(Path.join(ctx.attach_home, "sidecar.json"))
  end

  # -- helpers ------------------------------------------------------------

  # Point the app at one home, one engine config, one port. `engine` is
  # the explicit HIGHWIRE_ENGINE choice, nil for the default rule.
  defp put_config(base, home, ssb_home, engine, port) do
    Application.put_env(:highwire, :application_dir, home)
    Application.put_env(:highwire, :ssb_home, ssb_home)

    if engine,
      do: Application.put_env(:highwire, :engine, engine),
      else: Application.delete_env(:highwire, :engine)

    Application.put_env(
      :highwire,
      :ssb,
      Keyword.merge(base || [],
        enabled: true,
        port: port,
        erlbutt_rel: @engine_rel,
        net_id: Network.id(:dev)
      )
    )
  end

  defp start_sidecar!(attempts \\ 50) do
    case Supervisor.start_child(HighWire.Supervisor, Sidecar.child_spec([])) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, _pid}} when attempts > 0 ->
        stop_sidecar()
        start_sidecar!(attempts - 1)

      {:error, :already_present} when attempts > 0 ->
        _ = Supervisor.delete_child(HighWire.Supervisor, Sidecar)
        start_sidecar!(attempts - 1)

      other ->
        flunk("could not start the sidecar: #{inspect(other)}")
    end
  end

  defp stop_sidecar do
    _ = Supervisor.terminate_child(HighWire.Supervisor, Sidecar)
    wait_until(5_000, fn -> Process.whereis(Sidecar) == nil end)
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

  defp await_ready!(timeout \\ 60_000) do
    case wait_until(timeout, fn -> Sidecar.status() == :ready end) do
      :ok ->
        :ok

      :timeout ->
        flunk("""
        the engine never reached :ready (last status: #{inspect(Sidecar.status())}); \
        the logs are under #{HighWire.home_dir()}
        """)
    end
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

  defp engine_pid!(home) do
    assert %{"os_pid" => pid} = read_pidfile(home)
    assert is_integer(pid)
    pid
  end

  defp read_pidfile(home) do
    with {:ok, body} <- File.read(Path.join(home, "sidecar.json")),
         {:ok, json} <- Jason.decode(body) do
      json
    else
      _ -> nil
    end
  end

  defp kill_engine(%{"os_pid" => pid}) when is_integer(pid) do
    System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
  end

  defp kill_engine(_none), do: :ok

  defp os_alive?(pid) when is_integer(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end

  defp free_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp restore(previous) do
    for {key, value} <- [
          application_dir: previous.app_dir,
          ssb_home: previous.ssb_home,
          engine: previous.engine,
          ssb: previous.ssb
        ] do
      restore_key(key, value)
    end
  end

  defp restore_key(key, nil), do: Application.delete_env(:highwire, key)
  defp restore_key(key, value), do: Application.put_env(:highwire, key, value)
end
