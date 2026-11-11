defmodule HighWire.Chess.Legacy.Store do
  @moduledoc """
  The chess this node has seen from the network's own format, kept apart
  from its own games.

  Apart because they cannot mix: a `chess/*` row is ours to fold and to
  play, and a `chess_invite` row is a record of somebody else's game that
  arrived with its positions already written down. Filing them in one table
  would mean one table of two shapes, and a game whose moves nobody can
  continue.

  Rows are kept exactly as they arrived, keyed by the message key so a
  re-delivery is not a second move, and a game is folded on read — it is a
  few dozen maps, which is cheaper than keeping a board in step with an
  append-only log.
  """

  use GenServer

  require Logger

  alias HighWire.Chess.Legacy
  alias HighWire.Games.Catalog
  alias Phoenix.PubSub

  @table :highwire_chess_legacy
  @topic "chess_legacy"

  @doc "Start the store. `:path` overrides the DETS file (tests)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic the store announces changes on."
  def topic, do: @topic

  @doc "File an envelope without waiting for the write."
  @spec observe(map()) :: :ok
  def observe(msg) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:ingest, msg})
    end
  end

  @doc "File an envelope and wait for the write."
  @spec ingest(map()) :: {:ok, binary()} | :ignored | :seen
  def ingest(msg), do: GenServer.call(__MODULE__, {:ingest, msg}, 10_000)

  @doc "Every game this node has seen in this format, newest activity first."
  @spec games() :: [map()]
  def games do
    @table
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> Legacy.fold(row.rows) end)
    |> Enum.reject(&is_nil(&1.game_id))
    |> Enum.sort_by(& &1.updated_at, :desc)
  rescue
    ArgumentError -> []
  end

  @doc "One game's snapshot, or nil."
  @spec get(binary()) :: map() | nil
  def get(game_id) when is_binary(game_id) do
    case lookup(game_id) do
      nil -> nil
      row -> Legacy.fold(row.rows)
    end
  end

  @doc "Forget everything."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear, 5_000)

  # -- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    path =
      Keyword.get_lazy(opts, :path, fn ->
        Path.join(HighWire.home_dir(), ".ssberl/chess_legacy.dets")
      end)

    case :dets.open_file(@table, file: String.to_charlist(path), type: :set) do
      {:ok, @table} ->
        seed_catalog()
        {:ok, %{path: path}}

      {:error, reason} ->
        Logger.warning("chess legacy store: cannot open #{path}: #{inspect(reason)}")
        {:ok, %{path: nil}}
    end
  end

  @impl true
  def handle_cast({:ingest, msg}, state) do
    file(msg)
    {:noreply, state}
  end

  @impl true
  def handle_call({:ingest, msg}, _from, state), do: {:reply, file(msg), state}

  def handle_call(:clear, _from, state) do
    :dets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, %{path: nil}), do: :ok

  def terminate(_reason, _state) do
    :dets.close(@table)
    :ok
  end

  # A row is filed under its game, keyed by the message it came from: a
  # re-delivered message is the same row, not a second move.
  defp file(%{"key" => key, "value" => %{"author" => author, "content" => content} = value}) do
    with true <- Legacy.message?(content),
         game_id when is_binary(game_id) <- game_id(key, content),
         row when is_map(row) <-
           lookup(game_id) || %{game_id: game_id, rows: [], keys: MapSet.new()},
         false <- MapSet.member?(row.keys, key) do
      row = %{
        row
        | rows: [%{key: key, author: author, content: content, ts: value["timestamp"]} | row.rows],
          keys: MapSet.put(row.keys, key)
      }

      :dets.insert(@table, {{:game, game_id}, row})
      announce(game_id)
      {:ok, game_id}
    else
      true -> :ignored
      _ -> :seen
    end
  rescue
    ArgumentError -> :seen
  end

  defp file(_msg), do: :ignored

  defp game_id(key, content) do
    # Every message in a game names its root; the invite is its own root.
    # An accept published with neither cannot be placed in a game, so it is
    # dropped rather than filed as a game that is only an accept.
    case Legacy.canonical(content["type"]) do
      "chess_invite" -> Legacy.game_id(content["root"] || key)
      _ -> Legacy.game_id(content["root"])
    end
  end

  defp lookup(game_id) do
    case :dets.lookup(@table, {:game, game_id}) do
      [{_key, row}] -> row
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # The catalog is a cache of recency: a boot rebuilds it from the rows
  # already on disk, oldest first, so the newest game ends at the front.
  defp seed_catalog do
    @table
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> {updated_at(row.rows), row.game_id} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {_ts, game_id} -> Catalog.touch(:chess_legacy, game_id) end)
  rescue
    ArgumentError -> :ok
  end

  defp updated_at(rows) do
    rows
    |> Enum.map(&(&1.ts || 0))
    |> Enum.max(fn -> 0 end)
    |> trunc()
  end

  defp announce(game_id) do
    Catalog.touch(:chess_legacy, game_id)
    PubSub.broadcast(HighWire.PubSub, @topic, {:chess_legacy, game_id})
  rescue
    _ -> :ok
  end
end
