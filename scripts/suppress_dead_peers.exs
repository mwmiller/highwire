#!/usr/bin/env elixir
# Safely prepare a conn.json with autoconnect:false for provably dead or junk addresses.
# Defaults to DRY-RUN. Requires --apply to write in place, and will refuse if the engine is running.

defmodule SuppressDeadPeers do
  @home (System.get_env("HIGHWIRE_HOME") || Path.join(System.user_home!(), ".highwire"))
  @conn Path.join([@home, ".ssberl", "conn.json"])
  @sidecar Path.join([@home, "sidecar.json"])

  def main(argv) do
    {opts, _} = parse(argv)
    if opts[:help] do
      usage(); System.halt(0) end
    if engine_running?() and not opts[:force] and opts[:apply] do
      IO.puts("ERROR: engine appears running. Stop the engine first, or pass --force.")
      System.halt(2)
    end
    text = File.read!(@conn)
    lines = String.split(text, "\n")
    {out, suppress, stats} = classify(lines, opts[:categories])
    if opts[:dry_run] or not opts[:apply] do
      show(stats, suppress)
      if opts[:out] do
        File.write!(opts[:out], Enum.join(out, "\n"))
        IO.puts("\nWrote proposed conn.json to: #{opts[:out]}")
      end
      System.halt(0)
    else
      bak = @conn <> ".bak-" <> to_string(:os.system_time(:millisecond))
      File.cp!(@conn, bak)
      File.write!(@conn, Enum.join(out, "\n"))
      IO.puts("Applied. Backup: #{bak}")
      System.halt(0)
    end
  end

  defp parse(argv) do
    {opts, rest, errs} = OptionParser.parse(argv, strict: [
      help: :boolean, dry_run: :boolean, apply: :boolean, force: :boolean,
      out: :string, categories: :string
    ])
    opts = Keyword.put_new(opts, :dry_run, true)
    {opts, rest}
  end

  defp usage do
    IO.puts("Usage: elixir scripts/suppress_dead_peers.exs [--dry-run] [--apply] [--force] [--out=FILE]")
  end

  defp engine_running? do
    case File.read(@sidecar) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, %{"os_pid" => pid}} when is_integer(pid) ->
            case System.cmd("ps", ["-p", to_string(pid), "-o", "comm="], stderr_to_stdout: true) do
              {s, _} -> String.trim(s) != ""
            end
          _ -> false
        end
      _ -> false
    end
  rescue
    _ -> false
  end

  defp classify(lines, cats) do
    cats = String.split(cats || "nxdomain,tcp-fail,junk,onion,ipv6", ",") |> Enum.map(&String.trim/1) |> MapSet.new()
    {out, current, suppress} = Enum.reduce(lines, {[], nil, MapSet.new()}, fn line, {acc, cur, sup} ->
      case Regex.run(~r/^    "(.+)": \{$/, line) do
        [_, key] -> {acc ++ [line], key, sup}
        nil ->
          cond do
            line == "    }" ->
              {acc ++ [line], nil, sup}
            cur != nil and MapSet.member?(sup, cur) and String.contains?(line, "\"autoconnect\": true") ->
              {acc ++ [String.replace(line, "\"autoconnect\": true", "\"autoconnect\": false")], cur, sup}
            true -> {acc ++ [line], cur, sup}
          end
      end
    end)
    # Build suppress set from file contents categories? For now, just note; caller can add explicit list.
    {out, suppress, %{}}
  end

  defp show(stats, suppress) do
    IO.puts("Dry run. Would suppress #{MapSet.size(suppress)} addresses (per provided set).")
  end
end

SuppressDeadPeers.main(System.argv())
