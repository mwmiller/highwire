defmodule HighWire.ThreadGraph do
  @moduledoc """
  The thread graph on disk: message key → the thread head it belongs to.

  The Timeline folds this map in memory; keeping it in DETS means a
  restart reads the chains back instead of walking them again, and a
  reply whose parent arrived before the restart still lands in its
  conversation even when that parent has aged out of the window.

  One writer, no second copy: the Timeline writes what a fold changed
  through this process, and reads the graph back when it starts. A
  missing or unreadable file reads as an empty graph, which is the safe
  answer for a cache. The DETS table is named for the process, so tests
  can run their own instance beside the application's.
  """

  use GenServer

  require Logger

  @doc "Start the graph. `:path` and `:name` override the file and process (tests)."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The whole graph, or an empty map when the graph is not running."
  @spec load(atom()) :: %{binary() => binary()}
  def load(server \\ __MODULE__) do
    if Process.whereis(server), do: GenServer.call(server, :load, 5_000), else: %{}
  end

  @doc "Add or replace entries."
  @spec put([{binary(), binary()}], atom()) :: :ok
  def put(entries, server \\ __MODULE__) do
    if Process.whereis(server), do: GenServer.call(server, {:put, entries}, 5_000), else: :ok
  end

  @doc "Replace the whole graph — used when the fold trims it to its cap."
  @spec rewrite(%{binary() => binary()}, atom()) :: :ok
  def rewrite(graph, server \\ __MODULE__) do
    if Process.whereis(server), do: GenServer.call(server, {:rewrite, graph}, 5_000), else: :ok
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, dets_path())
    table = Keyword.get(opts, :name, __MODULE__)

    state = %{table: table, path: path, open?: open?(path, table)}

    {:ok, state}
  end

  @impl true
  def handle_call(:load, _from, state), do: {:reply, read(state), state}

  def handle_call({:put, entries}, _from, state) do
    write(state, entries)
    {:reply, :ok, state}
  end

  def handle_call({:rewrite, graph}, _from, state) do
    rewrite_table(state, graph)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.open?, do: close(state.table)
    :ok
  end

  defp open?(path, table) do
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(table, [
           {:file, String.to_charlist(path)},
           {:type, :set},
           {:keypos, 1},
           {:repair, true},
           {:access, :read_write}
         ]) do
      {:ok, ^table} ->
        true

      {:error, reason} ->
        Logger.warning("thread graph: cannot open #{inspect(path)}: #{inspect(reason)}")
        false
    end
  rescue
    error ->
      Logger.warning("thread graph: cannot open #{inspect(path)}: #{Exception.message(error)}")
      false
  end

  defp read(%{open?: false}), do: %{}

  defp read(%{table: table}) do
    :dets.foldl(
      fn
        {key, root}, graph when is_binary(key) and is_binary(root) -> Map.put(graph, key, root)
        _entry, graph -> graph
      end,
      %{},
      table
    )
  rescue
    ArgumentError -> %{}
  end

  defp write(_state, []), do: :ok
  defp write(%{open?: false}, _entries), do: :ok

  defp write(%{table: table}, entries) do
    :dets.insert(table, entries)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp rewrite_table(%{open?: false}, _graph), do: :ok

  defp rewrite_table(%{table: table} = state, graph) do
    :dets.delete_all_objects(table)
    write(state, Map.to_list(graph))
  rescue
    ArgumentError -> :ok
  end

  defp close(table) do
    _ = :dets.close(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # HighWire's read models live in the app home (search.dets,
  # blob-index.dets); the engine's own files live under .ssberl.
  defp dets_path, do: Path.join(HighWire.home_dir(), "thread-graph.dets")
end
