defmodule Mix.Tasks.Engine.Build do
  @shortdoc "Builds the erlbutt engine release from the locked git dep"

  # The dep name in mix.exs; the path under deps/ follows from it.
  @dep :erlbutt
  @profile "default"

  @moduledoc """
  Builds the erlbutt SSB engine into a relx release the sidecar can spawn.

  The engine is fetched by `mix deps.get` into `deps/#{@dep}` at the
  revision pinned in `mix.lock` (branch-tracking in mix.exs, so
  `mix deps.update #{@dep}` moves the pin). This task compiles it with
  the vendored rebar3 and assembles the release:

      mix engine.build          # dev profile -> deps/#{@dep}/_build/default/rel/ssb
      mix engine.build prod     # prod profile -> deps/#{@dep}/_build/prod/rel/ssb

  The release directory is removed first: relx leaves stale
  `lib/<app>-<oldversion>` directories behind on a version bump, and
  the sidecar's `-pa` flags glob every `lib/*/ebin`, so a stale
  directory shadows the freshly built beams.
  """

  use Mix.Task

  @requirements ["app.config"]

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args, strict: [profile: :string])

    profile = Keyword.get(opts, :profile, @profile)
    dep = Path.join(Mix.Project.deps_path(), to_string(@dep))

    unless File.dir?(dep) do
      Mix.raise("#{@dep} dep not found at #{dep} — run `mix deps.get` first")
    end

    rel = Path.join([dep, "_build", profile, "rel", "ssb"])
    File.rm_rf!(rel)

    rebar_args =
      case profile do
        "default" -> ["release"]
        "prod" -> ["as", "prod", "release"]
        other -> Mix.raise("unknown profile #{inspect(other)} (expected default or prod)")
      end

    Mix.shell().info("Building #{@dep} engine (#{profile} profile) in #{dep}…")

    case System.cmd(Path.join(dep, "rebar3"), rebar_args,
           cd: dep,
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line),
           env: sodium_env()
         ) do
      {_stream, 0} ->
        Mix.shell().info("Engine release ready: #{rel}")

      {_stream, status} ->
        Mix.raise("rebar3 exited with status #{status} while building the #{@dep} engine")
    end
  end

  # enacl's NIFs need libsodium headers/lib on the compiler's search
  # path. On macOS Homebrew installs them outside clang's defaults —
  # the release workflow prepends the same flags for CI. Prepend (do
  # not replace) so an existing CFLAGS/LDFLAGS, e.g. the LLVM paths
  # mise/Homebrew export here, survive alongside libsodium.
  defp sodium_env do
    case brew_prefix() do
      nil ->
        []

      prefix ->
        [
          {"CFLAGS", "-I#{prefix}/include #{System.get_env("CFLAGS") || ""}"},
          {"LDFLAGS", "-L#{prefix}/lib #{System.get_env("LDFLAGS") || ""}"}
        ]
    end
  end

  defp brew_prefix do
    case System.find_executable("brew") do
      nil -> nil
      brew -> brew_prefix(brew)
    end
  end

  defp brew_prefix(brew) do
    case System.cmd(brew, ["--prefix", "libsodium"], stderr_to_stdout: true) do
      {prefix, 0} ->
        prefix = String.trim(prefix)
        if File.exists?(Path.join(prefix, "include/sodium.h")), do: prefix

      _ ->
        nil
    end
  end
end
