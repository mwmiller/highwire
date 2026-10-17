# Safe, headless twin of the Network page's "Preview suppression" control.
#
# The classification and the file edit both live in
# HighWire.SSB.ConnSuppress, so the CLI and the UI agree on what a dead
# and junk address is. Run it without booting the app, so no engine is
# spawned or attached:
#
#     mix run --no-start scripts/suppress_dead_peers.exs -- [--apply] [--force]
#
# It reads the engine's conn.json plus HighWire's dial cache (peers_meta.json)
# and marks loopback/RFC1918/.onion/IPv6-literal/wrong-port/non-net addresses,
# and any address the dialer has failed repeatedly with no handshake ever
# recorded, with autoconnect: false. conn.json is the only durable opt-out the
# dialer honours; the change is re-read on the engine's next start.
#
# Defaults to a dry run. --apply writes in place (keeping a timestamped backup)
# and refuses while the engine appears to be running, unless --force is given;
# a running engine holds the book in memory and would overwrite the file.

defmodule SuppressDeadPeers do
  alias HighWire.PeersMeta
  alias HighWire.SSB.ConnSuppress

  @home (System.get_env("HIGHWIRE_HOME") || Path.join(System.user_home!(), ".highwire"))
  @sidecar Path.join([@home, "sidecar.json"])

  def main(argv) do
    {opts, _rest, _invalid} =
      OptionParser.parse(argv, strict: [help: :boolean, apply: :boolean, force: :boolean])

    cond do
      opts[:help] ->
        usage()

      not File.exists?(ConnSuppress.path()) ->
        IO.puts("No address book at #{ConnSuppress.path()} — is the engine installed?")
        System.halt(1)

      opts[:apply] == true and engine_running?() and opts[:force] != true ->
        IO.puts("ERROR: the engine appears to be running. Stop it first, or pass --force.")
        IO.puts("(A running engine holds conn.json in memory and would overwrite the file.)")
        System.halt(2)

      true ->
        run(opts)
    end
  end

  defp run(opts) do
    {addrs, counts} = ConnSuppress.classify(ConnSuppress.book_peers(), PeersMeta.load())

    IO.puts("Address book: #{counts[:book] || 0} entries")
    IO.puts("Would suppress #{length(addrs)}:")

    for {key, label} <- [
          loopback: "loopback",
          rfc1918: "private",
          onion: "onion",
          ipv6: "IPv6 literal",
          scheme: "wrong scheme",
          port: "bad port",
          unparseable: "unparseable",
          no_reply: "no reply"
        ],
        (n = counts[key] || 0) > 0 do
      IO.puts("  #{n} #{label}")
    end

    if opts[:apply] do
      case ConnSuppress.apply(addrs) do
        {:ok, changed, backup} ->
          IO.puts("\nApplied. #{changed} entr#{if changed == 1, do: "y", else: "ies"} changed.")
          IO.puts("Backup: #{backup}")
          IO.puts("Restart the engine to pick it up.")

        {:error, reason} ->
          IO.puts("\nFailed: #{inspect(reason)}")
          System.halt(1)
      end
    else
      IO.puts("\nDry run. Pass --apply to write conn.json (backup kept).")
    end
  end

  defp usage do
    IO.puts("""
    Usage: mix run --no-start scripts/suppress_dead_peers.exs -- [--apply] [--force]

      (no flags)  dry run: classify and print what would be suppressed
      --apply     write autoconnect: false into conn.json, keeping a backup
      --force     apply even if the engine looks like it is running
    """)
  end

  defp engine_running? do
    with {:ok, bin} <- File.read(@sidecar),
         {:ok, %{"os_pid" => pid}} when is_integer(pid) <- Jason.decode(bin),
         {out, _} <- System.cmd("ps", ["-p", to_string(pid), "-o", "comm="], stderr_to_stdout: true) do
      String.trim(out) != ""
    else
      _ -> false
    end
  rescue
    _ -> false
  end
end

SuppressDeadPeers.main(System.argv())
