defmodule HighWire.SSB.AttachOnlyTest do
  @moduledoc """
  An SSB home named from outside belongs to the engine that already
  writes it. The sidecar boots attached-only there: it seeds no
  `overrides.cfg`, starts no engine, records no pidfile, takes no
  ownership of a pidfile it finds, and offers no first-run import.

  Both homes are temp directories — the app's and the external one — so
  the engine's repo is empty before the boot and can be compared whole
  afterwards. A future change that quietly seeds, writes or spawns on
  that repo fails here instead of on someone's live store.
  """

  use ExUnit.Case, async: false

  alias HighWire.SSB.{Identities, Import, Network, Sidecar}

  setup do
    root = Path.join(System.tmp_dir!(), "hw-attach-#{System.unique_integer([:positive])}")
    app_home = Path.join(root, "app")
    ssb_home = Path.join(root, "engine")
    js_home = Path.join(root, "js-store")

    File.mkdir_p!(app_home)
    File.mkdir_p!(ssb_home)

    # A real JS store is waiting: spawn mode would offer to import it, so
    # attach-only skipping the offer is a decision here, not an accident
    # of there being nothing to offer.
    write_secret!(Path.join(js_home, "secret"))

    previous_ssb = Application.get_env(:highwire, :ssb)

    previous =
      for key <- [:application_dir, :ssb_home, :engine] do
        {key, Application.get_env(:highwire, key)}
      end

    on_exit(fn ->
      stop_sidecar()

      for {key, value} <- previous, do: restore(key, value)
      restore(:ssb, previous_ssb)

      File.rm_rf(root)
    end)

    port = free_port()

    Application.put_env(:highwire, :application_dir, app_home)
    Application.put_env(:highwire, :ssb_home, ssb_home)
    Application.put_env(:highwire, :engine, :attach)

    Application.put_env(
      :highwire,
      :ssb,
      Keyword.merge(previous_ssb || [],
        enabled: true,
        port: port,
        erlbutt_rel: "/nonexistent",
        js_home: js_home
      )
    )

    %{app_home: app_home, ssb_home: ssb_home, port: port}
  end

  test "booting against an external home writes nothing and offers no import", ctx do
    pid = start_sidecar!()
    assert :sys.get_state(pid).spawn == false, "the sidecar did not take the attach-only path"

    # attempts > 0 means the probe ran and found no engine to dial — the
    # attach-only answer — rather than the boot never getting that far.
    assert await(fn -> :sys.get_state(pid).attempts > 0 end, 10_000) == :ok

    assert Sidecar.status() == :starting

    # Nothing of HighWire's lands in the engine's repo: no seeded
    # overrides file, no conn.json, no `.ssberl`, no secret, no import log.
    assert tree(ctx.ssb_home) == []
    refute File.exists?(Network.path())
    refute File.exists?(Import.marker_path())
  end

  test "a pidfile engine is not claimed, stopped or cleaned up", ctx do
    decoy = sleep_process()

    pidfile = Path.join(ctx.app_home, "sidecar.json")
    body = Jason.encode!(%{"port" => ctx.port, "os_pid" => decoy})
    File.write!(pidfile, body)

    pid = start_sidecar!()
    assert await(fn -> :sys.get_state(pid).attempts > 0 end, 10_000) == :ok

    # The recorded engine is not this VM's to own: no os_pid is adopted,
    # so a shutdown signals nothing and the pidfile is left as it was
    # written by whoever did own that engine.
    assert :sys.get_state(pid).os_pid == nil

    stop_sidecar()

    assert os_alive?(decoy), "a recorded engine was stopped by the attach-only sidecar"
    assert File.read!(pidfile) == body, "the pidfile highwire did not write was rewritten"
    assert tree(ctx.ssb_home) == []
  end

  # `Identities.ensure_boot/0` restores a vanished secret from the active
  # registry row, which is a write into the repo. Here the registry has an
  # active identity and the external home has no secret yet, so that branch
  # is the one the boot reaches — and it must not put the key there.
  test "an active registry row restores no secret into the external home", ctx do
    id = seed_identity!(ctx.app_home)

    assert Identities.active_id() == id
    refute File.exists?(Path.join([ctx.ssb_home, ".ssberl", "secret"]))

    pid = start_sidecar!()
    assert await(fn -> :sys.get_state(pid).attempts > 0 end, 10_000) == :ok

    assert tree(ctx.ssb_home) == []
    assert Identities.active_id() == id
  end

  test "the actions that stop or rewrite the engine are refused", ctx do
    # Each of these stops the engine and rewrites its repo when HighWire
    # owns the engine; on this home they answer without touching it.
    assert {:error, :engine_not_owned} = Sidecar.switch_network(:mainnet)
    assert {:error, :engine_not_owned} = Sidecar.switch_identity("@nobody.ed25519")

    assert {:error, :engine_not_owned} =
             Sidecar.apply_conn_suppression(["net:127.0.0.1:8020~shs:key"])

    assert tree(ctx.ssb_home) == []
  end

  # -- helpers ------------------------------------------------------------

  # Start the sidecar under the app supervisor, where the rest of the app
  # already looks for it. A leftover from an earlier run is cleared first.
  defp start_sidecar!(attempts \\ 20) do
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
    await(fn -> Process.whereis(Sidecar) == nil end, 5_000)
  end

  defp await(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        Process.sleep(50)
        do_await(fun, deadline)
    end
  end

  # Everything under `dir`, recursively, so a comparison covers dotfiles
  # and directories: an empty external home stays byte-for-byte empty.
  defp tree(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &entry_tree(dir, &1))
      _ -> []
    end
  end

  defp entry_tree(dir, entry) do
    path = Path.join(dir, entry)
    if File.dir?(path), do: [path | tree(path)], else: [path]
  end

  # A stand-in for the engine already running on the external home: a real
  # live pid a wrongly-owning sidecar would signal on shutdown.
  defp sleep_process do
    {out, 0} = System.cmd("sh", ["-c", "sleep 60 >/dev/null 2>&1 & echo $!"])
    pid = out |> String.trim() |> String.to_integer()

    on_exit(fn -> System.cmd("kill", ["-KILL", to_string(pid)], stderr_to_stdout: true) end)

    pid
  end

  defp os_alive?(pid) when is_integer(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", to_string(pid)], stderr_to_stdout: true))
  end

  # A registry row as the app writes it, with the active pointer set: the
  # install believes it posts as this key, and no secret exists anywhere
  # except the registry's own copy.
  defp seed_identity!(app_home) do
    keys = keypair()

    row = %{
      "id" => keys.id,
      "label" => "Main",
      "created_at" => 0,
      "disabled" => false,
      "public" => keys.public,
      "private" => keys.private
    }

    File.write!(
      Path.join(app_home, "identities.json"),
      Jason.encode!(%{"active" => keys.id, "identities" => [row]})
    )

    keys.id
  end

  defp write_secret!(path) do
    keys = keypair()

    body =
      Jason.encode!(%{
        "curve" => "ed25519",
        "public" => keys.public,
        "private" => keys.private,
        "id" => keys.id
      })

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body <> "\n")
  end

  defp keypair do
    %{public: public, secret: private} = :enacl.sign_keypair()

    %{
      id: "@" <> Base.encode64(public) <> ".ed25519",
      public: Base.encode64(public) <> ".ed25519",
      private: Base.encode64(private) <> ".ed25519"
    }
  end

  defp free_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp restore(key, nil), do: Application.delete_env(:highwire, key)
  defp restore(key, value), do: Application.put_env(:highwire, key, value)
end
