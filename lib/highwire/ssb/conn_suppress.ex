defmodule HighWire.SSB.ConnSuppress do
  @moduledoc """
  Marks addresses the engine should stop dialing, by setting
  `autoconnect: false` on them in `.ssberl/conn.json`.

  This is the one durable opt-out the dialer honours: `conn_db`'s
  `remember/3` merges an incoming pub's fields over the stored map, and
  `autoconnect` is never among them, so a `false` survives every future
  re-announcement. `known_candidates/0` in erlbutt only collects
  entries whose `autoconnect` is `true`, so a suppressed address is
  never dialed again.

  The dialer reads the book out of memory and there is no reload RPC,
  so a change only takes effect after the engine restarts.
  `HighWire.SSB.Sidecar.apply_conn_suppression/1` stops the engine,
  calls `apply/1`, and starts it again.

  Addresses are classified from two signals the Network page already
  holds:

    * the address string itself — loopback, RFC1918, `.onion` hosts,
      IPv6 literals, a non-`net:` scheme, or a port outside 1..65535
      can never be dialed from here;
    * the per-address dial cache (`dial_attempts`, `dial_ok_at`) the
      timeline keeps from the engine's ledger — an address with a
      couple of consecutive failures and no handshake ever recorded.

  A loopback or private address may be a deliberate LAN peer somewhere
  else, so the classification is a preview the user confirms, never
  something applied on its own.
  """

  @path ".ssberl/conn.json"

  @no_reply_min_attempts 2

  @doc "The engine's address book."
  @spec path() :: Path.t()
  def path, do: Path.join(HighWire.home_dir(), @path)

  @doc """
  Read the address book straight off disk as `known_peers`-shaped maps
  (`%{"address" => ..., "autoconnect" => ...}`). The Network page
  classifies the report the engine hands it; a caller with no engine —
  the CLI wrapper, or a preview while the engine is down — reads the
  file instead, so both paths agree on what the book holds.
  """
  @spec book_peers() :: [map()]
  def book_peers do
    case File.read(path()) do
      {:ok, text} ->
        {acc, current, ac} =
          text
          |> String.split("\n")
          |> Enum.reduce({[], nil, true}, &book_line/2)

        acc |> flush(current, ac) |> Enum.reverse()

      _ ->
        []
    end
  end

  # A line naming an address opens an entry; a line carrying
  # autoconnect decides its fate; a line closing the entry flushes it.
  # "false" wins when a file contradicts itself.
  defp book_line(line, {acc, current, ac}) do
    case Regex.run(~r/^    "(.+)": \{$/, line) do
      [_, key] -> {flush(acc, current, ac), key, true}
      nil -> book_state(line, acc, current, ac)
    end
  end

  defp book_state("    }", acc, current, ac), do: {flush(acc, current, ac), nil, true}

  defp book_state(line, acc, current, ac) do
    cond do
      String.contains?(line, "\"autoconnect\": false") -> {acc, current, false}
      String.contains?(line, "\"autoconnect\": true") -> {acc, current, true}
      true -> {acc, current, ac}
    end
  end

  defp flush(acc, nil, _autoconnect), do: acc
  defp flush(acc, key, autoconnect), do: [%{"address" => key, "autoconnect" => autoconnect} | acc]

  @doc """
  Classify every address in `known_peers` (the report's `knownPeers`)
  against `peer_meta` (the dial cache). Returns
  `{suppress, counts}` — the addresses to suppress, and how many fell
  into each category, for a preview line.
  """
  @spec classify(list(), map()) :: {list(String.t()), %{atom() => integer()}}
  def classify(known_peers, peer_meta) when is_list(known_peers) and is_map(peer_meta) do
    suppress =
      known_peers
      |> Enum.filter(&(&1["autoconnect"] != false))
      |> Enum.map(fn
        %{"address" => addr} when is_binary(addr) -> addr
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(fn addr ->
        dial_ok = HighWire.PeersMeta.get(peer_meta, addr)["dial_ok_at"] || 0

        dial_ok <= 0 and
          (unreachable?(addr) or no_reply?(HighWire.PeersMeta.get(peer_meta, addr)))
      end)

    {suppress, counts(Enum.map(known_peers, &address_of/1), suppress)}
  end

  def classify(_known_peers, _peer_meta), do: {[], %{}}

  @doc """
  Flip `autoconnect` to `false` for `addrs` in `conn.json`, keeping a
  timestamped backup. Only the selected entries' lines change, so the
  diff is one word per address; the engine reformats the file the next
  time it saves. Returns `{:ok, changed, backup_path}`.
  """
  @spec apply(list(String.t())) :: {:ok, integer(), Path.t()} | {:error, term()}
  def apply(addrs) when is_list(addrs) do
    set = MapSet.new(addrs)
    file = path()

    with {:ok, text} <- File.read(file),
         {:ok, backup} <- write_backup(file, text) do
      {out, changed} = suppress_lines(String.split(text, "\n"), set)

      with :ok <- File.write(file, Enum.join(out, "\n")) do
        {:ok, changed, backup}
      end
    end
  rescue
    e -> {:error, e}
  end

  defp write_backup(file, text) do
    backup = file <> ".bak-" <> to_string(System.system_time(:second))

    case File.write(backup, text) do
      :ok -> {:ok, backup}
      {:error, reason} -> {:error, {:backup_failed, reason}}
    end
  end

  # Every "autoconnect": true belonging to a listed address is
  # rewritten; every other line passes through untouched, so the
  # file's own formatting and field order survive the rewrite.
  defp suppress_lines(lines, set) do
    {out, {_current, changed}} =
      Enum.map_reduce(lines, {nil, 0}, fn line, {current, changed} ->
        case Regex.run(~r/^    "(.+)": \{$/, line) do
          [_, key] -> {line, {key, changed}}
          nil -> suppress_line(line, current, changed, set)
        end
      end)

    {out, changed}
  end

  defp suppress_line(line, current, changed, set) do
    cond do
      line == "    }" ->
        {line, {nil, changed}}

      current != nil and MapSet.member?(set, current) and
          String.contains?(line, "\"autoconnect\": true") ->
        {String.replace(line, "\"autoconnect\": true", "\"autoconnect\": false"),
         {current, changed + 1}}

      true ->
        {line, {current, changed}}
    end
  end

  # -- classification ----------------------------------------------------

  defp address_of(%{"address" => addr}) when is_binary(addr), do: addr
  defp address_of(_), do: nil

  # An address the dialer can never reach from here, whatever the
  # ledger says.
  defp unreachable?(addr) do
    case host_port(addr) do
      {host, port} ->
        loopback?(host) or private?(host) or onion?(host) or ipv6?(host) or
          not (is_integer(port) and port in 1..65_535)

      # A non-`net:` scheme (or anything else without a host:port) is
      # not something this dialer can use.
      :error ->
        true
    end
  end

  defp no_reply?(meta) when is_map(meta) do
    is_integer(meta["dial_attempts"]) and meta["dial_attempts"] >= @no_reply_min_attempts and
      (meta["dial_ok_at"] || 0) == 0
  end

  defp counts(all, suppress) do
    suppress
    |> Enum.group_by(&category/1)
    |> Map.new(fn {cat, addrs} -> {cat, length(addrs)} end)
    |> Map.put(:total, length(suppress))
    |> Map.put(:book, all |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length())
  end

  defp category(addr) do
    cond do
      loopback_addr?(addr) ->
        :loopback

      bad_scheme?(addr) ->
        :scheme

      true ->
        case host_port(addr) do
          {host, port} -> classify_host_port(host, port)
          :error -> :unparseable
        end
    end
  end

  # The host decides first, whatever scheme wraps it:
  # "net:localhost:8008~shs:KEY" and "ws://localhost:8999~shs:KEY" are
  # both loopback, and loopback is the truer label — a scheme that also
  # happens to be wrong says less than a host that can never answer
  # from here under any scheme.
  defp loopback_addr?(addr) when is_binary(addr) do
    hostport =
      addr
      |> String.split("://", parts: 2)
      |> List.last()
      |> String.replace_prefix("net:", "")
      |> String.split("~", parts: 2)
      |> hd()

    case String.split(hostport, ":") do
      [_only] -> false
      parts -> parts |> Enum.drop(-1) |> Enum.join(":") |> loopback?()
    end
  end

  defp loopback_addr?(_addr), do: false

  defp classify_host_port(host, port) do
    cond do
      private?(host) -> :rfc1918
      onion?(host) -> :onion
      ipv6?(host) -> :ipv6
      not (is_integer(port) and port in 1..65_535) -> :port
      true -> :no_reply
    end
  end

  # "net:host:port~shs:KEY" → {host, port}. The host may itself contain
  # colons (an IPv6 literal), so split the port off the right.
  defp host_port("net:" <> rest) do
    case String.split(rest, "~", parts: 2) do
      [hostport, _key] ->
        case String.split(hostport, ":") do
          [_only] ->
            :error

          parts ->
            {port, _} = List.pop_at(parts, -1)
            {Enum.join(Enum.drop(parts, -1), ":"), Integer.parse(port) |> elem_or_nil()}
        end

      _ ->
        :error
    end
  end

  defp host_port(_addr), do: :error

  defp elem_or_nil({int, ""}) when is_integer(int), do: int
  defp elem_or_nil(_), do: nil

  defp loopback?(host) when is_binary(host),
    do: host in ["localhost", "::1"] or String.starts_with?(host, "127.")

  defp loopback?(_), do: false

  defp private?(host) when is_binary(host) do
    String.starts_with?(host, "10.") or String.starts_with?(host, "192.168.") or
      match?({172, b, _, _} when b >= 16 and b <= 31, ipv4(host))
  end

  defp private?(_), do: false

  defp ipv4(host) do
    case String.split(host, ".") do
      [a, b, c, d] ->
        with {a, ""} <- Integer.parse(a),
             {b, ""} <- Integer.parse(b),
             {c, ""} <- Integer.parse(c),
             {d, ""} <- Integer.parse(d) do
          {a, b, c, d}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp onion?(host) when is_binary(host), do: String.ends_with?(host, ".onion")
  defp onion?(_), do: false

  defp ipv6?(host) when is_binary(host), do: String.contains?(host, ":")
  defp ipv6?(_), do: false

  defp bad_scheme?(addr), do: not String.starts_with?(addr, "net:")
end
