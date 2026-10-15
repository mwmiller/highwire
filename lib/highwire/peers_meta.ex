defmodule HighWire.PeersMeta do
  @moduledoc """
  Auxiliary peer metadata cache stored locally under HighWire.home_dir().

  This is strictly for UI hints (recency, usefulness signals). It must
  never override authoritative data from the engine/store. Treat it as
  a best-effort cache that can be pruned over time.
  """

  @path "peers_meta.json"

  def path do
    Path.join([HighWire.home_dir(), @path])
  end

  def load do
    case File.read(path()) do
      {:ok, bin} ->
        case Jason.decode(bin) do
          {:ok, %{} = map} -> normalize(map)
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  def save(%{} = meta) do
    tmp = path() <> ".tmp"
    dir = Path.dirname(path())

    with :ok <- File.mkdir_p(dir),
         {:ok, bin} <- Jason.encode(meta, pretty: false),
         :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, path()) do
      :ok
    else
      _ -> :error
    end
  end

  def get(meta, id) when is_binary(id) do
    case Map.get(meta, id) do
      nil -> %{}
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  def update(meta, id, fun) when is_binary(id) and is_function(fun, 1) do
    existing = get(meta, id)

    case fun.(existing) do
      %{} = next when next != existing -> Map.put(meta, id, next)
      _ -> meta
    end
  end

  @doc """
  A network report assembled from the cache alone — the shape
  `HighWire.Timeline.network/0` hands the view, with every engine-side
  fact absent rather than guessed: no connections (a live session is
  something only the engine can attest to), no dial ledger, no cap.

  Keyed peers become address-book rows. Feed-id entries describe
  connection recency, which says nothing about an address, so they are
  left out: the constellation's book ring wants addresses, and inventing
  one for a feed id would draw a peer the engine never named.

  This is what the constellation opens with when the engine is down, so
  a cache from a working session still shows the peers we last knew
  instead of an empty sky. The engine's report supersedes it on the next
  poll that answers.
  """
  @spec seed_report(map() | term()) :: map()
  def seed_report(%{} = meta) do
    %{
      "connections" => [],
      "knownPeers" => seeded_peers(meta),
      "dialTry" => [],
      "seeded" => true
    }
  end

  def seed_report(_meta), do: seed_report(%{})

  defp seeded_peers(meta) do
    meta
    |> Enum.filter(fn {key, value} -> is_binary(key) and is_map(value) end)
    |> Enum.map(fn {key, value} -> seeded_peer(key, value) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn peer -> -(peer["last_seen_at"] || 0) end)
  end

  # A cache entry may key on either an address or a feed id. Only an
  # address names a peer the constellation can place, so the rest are
  # skipped rather than shoehorned into a row.
  defp seeded_peer(<<"net:", _::binary>> = address, value) do
    peer = %{"address" => address}

    peer = if source = value["source"], do: Map.put(peer, "source", source), else: peer
    peer = if seen = value["last_seen_at"], do: Map.put(peer, "last_seen_at", seen), else: peer

    if peer["source"] || peer["last_seen_at"] do
      peer
    else
      nil
    end
  end

  defp seeded_peer(_key, _value), do: nil

  defp normalize(meta) do
    Enum.reduce(meta, %{}, fn
      {k, v}, acc when is_binary(k) and is_map(v) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
