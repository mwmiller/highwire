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

  defp normalize(meta) do
    Enum.reduce(meta, %{}, fn
      {k, v}, acc when is_binary(k) and is_map(v) -> Map.put(acc, k, v)
      _, acc -> acc
    end)
  end
end
