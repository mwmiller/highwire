defmodule HighWire.SSB.PeerAddress do
  @moduledoc """
  Remembering a peer by its address — dialing somewhere already known.

  An address (`net:host:port~shs:key`) says where something lives, not
  who runs it or whether it will talk. That is enough to dial, and it
  is the weaker half of what a pub invite carries: an invite names an
  address *and* a one-time key the pub trusts, which is what makes the
  pub follow this identity back. Adding an address alone follows
  nothing. It writes the address into the connection book under the
  same `pub` record the gossip layer uses, so the dialer picks it up
  and keeps trying from then on, and leaves the social decision —
  whether to follow whoever answers — to the reader.

  The write goes out through the local engine's publish, the same
  chokepoint every other outbound message uses: this identity's feed
  records the address, and the engine's ingest of that message is what
  folds it into `conn.json`. Nothing is signed as anyone else, and no
  connection is opened as part of adding the address.
  """

  require Logger

  alias HighWire.SSB.Admin
  alias HighWire.Timeline

  @type t :: %{host: String.t(), port: pos_integer(), key: binary()}

  @typedoc "Why an address was refused, in the shape the UI words for a reader."
  @type error :: :bad_address | {:announce, term()}

  @doc """
  Parse a multiserver address into its parts, or
  `{:error, :bad_address}` for anything that is not one. Both the
  `net:host:port~shs:key` spelling the address book keys on and the
  bare `host:port~shs:key` are accepted, and the key decodes from
  base64 with or without padding, in the standard or URL-safe alphabet.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :bad_address}
  def parse(address) when is_binary(address) do
    trimmed = address |> String.trim() |> String.trim_leading("net:")

    with [addr_part, key_body] <- String.split(trimmed, "~", parts: 2),
         [host, port_str] <- split_host_port(addr_part),
         {port, ""} <- Integer.parse(String.trim(port_str)),
         true <- port >= 1 and port <= 65_535,
         true <- String.trim(host) != "",
         key_body = key_body |> String.trim() |> String.trim_leading("shs:"),
         {:ok, key} <- base64(key_body),
         true <- byte_size(key) == 32 do
      {:ok, %{host: String.trim(host), port: port, key: key}}
    else
      _ -> {:error, :bad_address}
    end
  end

  def parse(_address), do: {:error, :bad_address}

  # The port is whatever follows the final colon, so a host that itself
  # carries colons still leaves its port readable off the end.
  defp split_host_port(addr_part) do
    parts = String.split(addr_part, ":")

    if length(parts) >= 2 do
      {port, host_parts} = List.pop_at(parts, -1)
      [Enum.join(host_parts, ":"), port]
    else
      :error
    end
  end

  @doc """
  The multiserver address a parsed peer dials as — the same
  `net:host:port~shs:key` spelling the engine's address book keys on.
  """
  @spec address(t()) :: binary()
  def address(%{host: host, port: port, key: key}),
    do: "net:#{host}:#{port}~shs:#{Base.encode64(key)}"

  @doc """
  Record a peer's address on this identity's feed so the dialer keeps
  it, then kick a dial round.

  `:ok` once the announce lands. This does not follow the peer and does
  not open a session: it only says where to dial, so a later follow is
  a separate act taken against whoever answers.

  `opts` exist for tests: `:announce` overrides the engine publish step
  and `:trigger` the dialer kick, both receiving the parsed peer.
  """
  @spec add(t(), keyword()) :: :ok | {:error, error()}
  def add(%{} = peer, opts \\ []) do
    announce = Keyword.get(opts, :announce, &announce_via_engine/1)
    trigger = Keyword.get(opts, :trigger, &trigger_dialer/0)

    # The wrap lives here rather than in the default announce so every
    # announce answers in the one shape this function's spec promises.
    # The engine's publish answers `{:ok, key}` — the id of the message
    # it just wrote — as well as `:ok`, and both mean the address is on
    # the feed. Answering only for `:ok` sent every real add down the
    # error path, and raised before the dialer could be kicked: the
    # address was saved, then reported as a failure and left undialed.
    with :ok <- announce_status(announce.(peer)) do
      _ = trigger.()
      :ok
    end
  end

  defp announce_status(:ok), do: :ok
  defp announce_status({:ok, _message_id}), do: :ok
  defp announce_status({:error, reason}), do: {:error, {:announce, reason}}

  defp announce_via_engine(%{host: host, port: port, key: key}) do
    Logger.info("peer: remembering #{host}:#{port}")

    Timeline.announce_pub(host, port, display_id(key))
  end

  # Best effort: a failed kick leaves the address for the next pass,
  # which the announce has already queued it for.
  defp trigger_dialer do
    _ = Admin.dialer_trigger()
    :ok
  end

  # The address travels as the display form — "@<b64>.ed25519" — the
  # same shape conn.json and every published message use. The engine's
  # gossip layer strips the sigil and suffix on ingest, so either
  # spelling reaches the same conn.json entry.
  defp display_id(key), do: "@" <> Base.encode64(key) <> ".ed25519"

  defp base64(str) do
    str = String.trim(str)
    padded = str <> String.duplicate("=", rem(4 - rem(byte_size(str), 4), 4))

    case Base.decode64(padded) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.url_decode64(padded)
    end
  end
end
