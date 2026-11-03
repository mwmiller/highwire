defmodule HighWire.Games.Catalog do
  @moduledoc """
  Which games have moved recently, in the order they moved.

  The stores are append-only: a game is filed once and then gains moves
  forever, and the number of games only grows. A room that answers "what is
  there" by folding every game is therefore a room that gets slower every
  day, and one that renders what it found is a page that gets longer
  forever.

  So the room asks this instead — an ordered list of every game the stores
  have filed, newest touch first. Every touch moves a game to the front, and
  a game stays in the list for as long as its store keeps it: what the room
  pages through is what this node holds, not a recent sample of it.

  Reads come from ETS directly, because the pages ask constantly and the
  answer is a handful of rows. The process owns the table and keeps the
  sequence numbers; nothing else is stored here.
  """

  use GenServer

  @table :highwire_games_catalog

  @doc "Start the catalog."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Record that a game changed, moving it to the front of the window.

  Called by the stores as they file a row, so it is a cast: filing a
  message must not wait on the room.
  """
  @spec touch(atom(), binary()) :: :ok
  def touch(kind, game_id) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:touch, kind, game_id})
    end
  end

  @doc """
  The games this node holds, newest touch first, as `{kind, game_id}`.

  `offset` pages back through them; past the end is an empty list.
  """
  @spec recent(pos_integer(), non_neg_integer()) :: [{atom(), binary()}]
  def recent(limit, offset \\ 0) when is_integer(limit) and limit > 0 do
    table = :ets.whereis(@table)

    if table == :undefined do
      []
    else
      walk(:ets.last(table), table, limit, offset, 0, [])
    end
  rescue
    ArgumentError -> []
  end

  @doc "How many games the room can page through."
  @spec count() :: non_neg_integer()
  def count do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  @doc """
  Wait until every touch already cast has been applied.

  The room does not need this — it re-reads on the stores' broadcasts — but
  a caller that wants to read what it just wrote does.
  """
  @spec flush() :: :ok
  def flush do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :flush, 5_000)
    end
  end

  @doc false
  def clear do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :clear, 5_000)
    end
  end

  # -- server ------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:ordered_set, :named_table, :protected, read_concurrency: true])
    {:ok, %{table: table, seq: 0, index: %{}}}
  end

  @impl true
  def handle_cast({:touch, kind, game_id}, state) do
    {:noreply, put(state, kind, game_id)}
  end

  @impl true
  def handle_call(:flush, _from, state), do: {:reply, :ok, state}

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | seq: 0, index: %{}}}
  end

  # A touch is a move to the front: the old entry goes, a new sequence
  # number arrives, and the order is the sequence.
  defp put(state, kind, game_id) do
    key = {kind, game_id}
    state = if state.index[key], do: drop(state, key), else: state
    seq = state.seq + 1

    :ets.insert(@table, {seq, kind, game_id})

    %{state | seq: seq, index: Map.put(state.index, key, seq)}
  end

  defp drop(state, key) do
    case state.index[key] do
      nil ->
        state

      seq ->
        :ets.delete(@table, seq)
        %{state | index: Map.delete(state.index, key)}
    end
  end

  # Walk the sequence backwards — newest first — skipping `offset` rows
  # and keeping `limit`, so a page costs its own size and not the window's.
  defp walk(:"$end_of_table", _table, _limit, _offset, _taken, acc), do: Enum.reverse(acc)

  defp walk(seq, table, limit, offset, taken, acc) do
    next = :ets.prev(table, seq)

    cond do
      offset > 0 ->
        walk(next, table, limit, offset - 1, taken, acc)

      taken >= limit ->
        Enum.reverse(acc)

      true ->
        case :ets.lookup(table, seq) do
          [{_seq, kind, game_id}] ->
            walk(next, table, limit, 0, taken + 1, [{kind, game_id} | acc])

          [] ->
            walk(next, table, limit, 0, taken, acc)
        end
    end
  end
end
