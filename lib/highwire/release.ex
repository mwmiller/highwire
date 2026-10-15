defmodule HighWire.Release do
  @moduledoc """
  Build-time steps for `mix release` (see `releases/0` in `mix.exs`).

  These run between `:assemble` and `Burrito.wrap/1`, while the release
  is still an ordinary directory tree, so anything they fix rides into
  the wrapped backend that ships.
  """

  @doc """
  Make every bundled `enacl_nif.so` self-contained, then hand the release
  back to the release pipeline.

  `enacl` reaches libsodium through a NIF, which is `dlopen`'d at
  runtime — so no packager ever sees it. linuxdeploy and Tauri trace the
  *shell's* link-time libraries, never a NIF loaded later, and the NIF is
  built against whatever libsodium the build host had: Ubuntu 22.04's
  `libsodium.so.23`, Homebrew's `libsodium.26.dylib`. Shipped as-is that
  bakes in the build host's library and dies wherever it differs —
  Arch/CachyOS ship `libsodium.so.26`, so the NIF can't find the
  `libsodium.so.23` it names — or is missing entirely (a Mac without
  Homebrew: the `/opt/homebrew/...` path is absolute).

  A release holds two copies, HighWire's own `enacl` (the SHS client that
  talks to the local engine) and the engine's, nested under `priv/erlbutt`.
  Both must load. Copy the exact library beside each NIF and repoint the
  NIF at its own directory — `$ORIGIN` (patchelf) on Linux, `@loader_path`
  (install_name_tool) on macOS — so it carries its libsodium with it.

  Best-effort: a missing tool or library only warns, so a source checkout
  still produces a (host-dependent) release instead of failing the build.
  Windows is out of scope here — its `sodium.dll` gap is handled
  separately.
  """
  @spec bundle_libsodium(%{path: Path.t()}) :: %{path: Path.t()}
  def bundle_libsodium(%{path: path} = rel) do
    path
    |> nif_paths()
    |> Enum.each(&bundle/1)

    rel
  end

  @doc """
  Every `enacl_nif.so` in an assembled release: HighWire's own and the
  engine's copy under `priv/erlbutt`.
  """
  @spec nif_paths(Path.t()) :: [Path.t()]
  def nif_paths(release_path) do
    Path.wildcard(Path.join(release_path, "lib/**/enacl_nif.so"))
  end

  defp bundle(nif) do
    with {:ok, lib} <- libsodium(nif),
         :ok <- place(lib, nif),
         :ok <- repoint(nif, lib) do
      IO.puts("release: bundled #{Path.basename(lib)} beside #{nif}")
    else
      {:error, reason} ->
        IO.puts(:stderr, "warning: release left libsodium unbundled for #{nif}: #{reason}")
    end
  end

  # -- finding the build host's libsodium ---------------------------------

  defp libsodium(nif) do
    case :os.type() do
      {:unix, :darwin} -> from_otool(nif)
      {:unix, _other} -> from_ldd(nif)
      os -> {:error, "unsupported platform #{inspect(os)}"}
    end
  end

  defp from_otool(nif) do
    with {:ok, out} <- run("otool", ["-L", nif]),
         [line | _] <- Enum.filter(String.split(out, "\n"), &String.contains?(&1, "libsodium")) do
      {:ok, line |> String.split() |> hd()}
    else
      {:error, _} = error -> error
      [] -> {:error, "otool listed no libsodium"}
    end
  end

  defp from_ldd(nif) do
    with {:ok, out} <- run("ldd", [nif]),
         [line | _] <- Enum.filter(String.split(out, "\n"), &String.contains?(&1, "libsodium")) do
      resolve_ldd(line)
    else
      {:error, _} = error -> error
      [] -> {:error, "ldd resolved no libsodium"}
    end
  end

  # `ldd` prints `=> not found` when it cannot resolve the library; that
  # must not read as a resolved path.
  defp resolve_ldd(line) do
    case String.split(line) do
      [_name, "=>", path | _] when path != "not" -> {:ok, path}
      _other -> {:error, "libsodium unresolved: #{String.trim(line)}"}
    end
  end

  defp run(cmd, args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "#{cmd} not found"}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {out, 0} -> {:ok, out}
          {out, code} -> {:error, "#{cmd} exited #{code}: #{String.trim(out)}"}
        end
    end
  end

  # -- making the NIF independent of the build host -----------------------

  defp place(lib, nif) do
    dest = Path.join(Path.dirname(nif), Path.basename(lib))

    cond do
      not absolute?(lib) -> :ok
      Path.expand(dest) == Path.expand(lib) -> :ok
      true -> copy(lib, dest)
    end
  end

  defp copy(lib, dest) do
    case File.cp(lib, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, "copy failed: #{:file.format_error(reason)}"}
    end
  end

  defp repoint(nif, lib) do
    cond do
      not absolute?(lib) ->
        :ok

      macos?() ->
        run_ok("install_name_tool", ["-change", lib, "@loader_path/#{Path.basename(lib)}", nif])

      true ->
        run_ok("patchelf", ["--set-rpath", "$ORIGIN", nif])
    end
  end

  # `run/2` reports the command's output; the caller only cares whether it
  # worked.
  defp run_ok(cmd, args) do
    case run(cmd, args) do
      {:ok, _out} -> :ok
      {:error, _} = error -> error
    end
  end

  # A relative reference means a previous run already repointed this NIF;
  # every step below is then a no-op.
  defp absolute?(path), do: String.starts_with?(path, "/")

  defp macos?, do: match?({:unix, :darwin}, :os.type())
end
