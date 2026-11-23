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
    all_rows()
    |> Enum.map(fn {_key, row} -> Legacy.fold(row.rows) end)
    |> Enum.reject(&is_nil(&1.game_id))
    |> Enum.sort_by(& &1.updated_at, :desc)
  end

  @doc "One game's snapshot, or nil."
  @spec get(binary()) :: map() | nil
  def get(game_id) when is_binary(game_id) do
    case lookup(game_id) do
      row when is_map(row) -> Legacy.fold(row.rows)
      _ -> nil
    end
  end

  @doc "Forget everything."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear, 5_000)

  # -- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, dets_path())

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
         game_id when is_binary(game_id) <- game_id(key, content) do
      add_row(game_id, key, author, content, value["timestamp"])
    else
      _ -> :ignored
    end
  end

  defp file(_msg), do: :ignored

  defp add_row(game_id, key, author, content, ts) do
    case lookup(game_id) do
      {:unreadable, reason} ->
        dropped(reason)

      row ->
        row = row || %{game_id: game_id, rows: [], keys: MapSet.new()}

        if MapSet.member?(row.keys, key) do
          :seen
        else
          row = %{
            row
            | rows: [%{key: key, author: author, content: content, ts: ts} | row.rows],
              keys: MapSet.put(row.keys, key)
          }

          :dets.insert(@table, {{:game, game_id}, row})
          announce(game_id)
          {:ok, game_id}
        end
    end
  rescue
    ArgumentError -> dropped(:closed)
  end

  defp game_id(key, content) do
    # Every message in a game names its root; the invite is its own root.
    # An accept published with neither cannot be placed in a game, so it is
    # dropped rather than filed as a game that is only an accept.
    case Legacy.canonical(content["type"]) do
      "chess_invite" -> Legacy.game_id(content["root"] || key)
      _ -> Legacy.game_id(content["root"])
    end
  end

  # A table that cannot answer is not the same as one without the game.
  # Only an empty answer means the game is new; anything else leaves the
  # row unknown, so nothing is filed rather than written where it cannot
  # be read back.
  defp lookup(game_id) do
    case :dets.lookup(@table, {:game, game_id}) do
      [{_key, row}] -> row
      [] -> nil
      {:error, reason} -> {:unreadable, reason}
    end
  rescue
    ArgumentError -> {:unreadable, :closed}
  end

  # A table that cannot answer fails every lookup, and a boot replays a whole
  # backlog, so the run gets one warning, with the reason. Only the store's own
  # process files rows, so the flag in its dictionary lasts exactly one run.
  defp dropped(reason) do
    unless Process.get(:warned_unreadable) do
      Process.put(:warned_unreadable, true)
      Logger.warning("chess legacy store: cannot file a row: #{inspect(reason)}")
    end

    :ignored
  end

  # A damaged or closed table raises rather than answering; it holds no rows
  # this node can read.
  defp all_rows do
    :dets.match_object(@table, {{:game, :_}, :_})
  rescue
    ArgumentError -> []
  end

  defp dets_path, do: Path.join(HighWire.ssb_dir(), "chess_legacy.dets")

  # The catalog is a cache of recency: a boot rebuilds it from the rows
  # already on disk, oldest first, so the newest game ends at the front.
  defp seed_catalog do
    all_rows()
    |> Enum.map(fn {_key, row} -> {updated_at(row.rows), row.game_id} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {_ts, game_id} -> Catalog.touch(:chess_legacy, game_id) end)
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
  end
end
