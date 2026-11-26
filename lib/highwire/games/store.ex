defmodule HighWire.Games.Store do
  @moduledoc """
  The filing end shared by the game stores, and the contract a store fills in.

  A chess game and a backgammon game are filed the same way: every message in
  the game's namespace is read once, filed under the game it belongs to, and
  skipped when its key has already been seen; the row keeps the entries, and
  a snapshot folds them on read. Only the shapes differ — what a challenge
  and an accept carry, and what the fold needs beside the entries — so that
  is the seam: a store module names its game and its row's shape, and this
  module keeps the process, one GenServer per store, started under the
  store's own name.

  Nothing here decides whether a move is true. A row records what was
  published; the fold decides whether those entries make a legal game, and
  `:broken` on a snapshot is the fold saying they do not.

  A store `use`s this module for the process-side API (`start_link/1`,
  `ingest/1`, `observe/1`, `games/0`, `get/1`, `clear/0`, `valid_id?/1`) and
  implements the behaviour: which table, topic, file and modules belong to
  its game, and how one read and one snapshot are shaped.
  """

  use GenServer

  require Logger

  alias HighWire.Games.Catalog
  alias Phoenix.PubSub

  @doc "The DETS table, PubSub topic, file name and modules for one game."
  @callback kind() :: atom()
  @callback table() :: atom()
  @callback topic() :: String.t()
  @callback file() :: String.t()
  @callback game_module() :: module()
  @callback fold_module() :: module()
  @callback reader_module() :: module()

  @doc "A fresh row for a game id the store has not filed yet."
  @callback new_row(binary()) :: map()

  @doc "One read folded into its row."
  @callback put_message(map(), map()) :: map()

  @doc "The game map the fold reads."
  @callback snapshot_game(map()) :: map()

  @doc "Anything else the fold needs beside the entries."
  @callback fold_extras(map()) :: map()

  @doc "Game-specific fields carried on the snapshot."
  @callback snapshot_extras(map()) :: map()

  @doc "Whether a row appears in `games/0`."
  @callback listed?(map()) :: boolean()

  @doc "The snapshot's status, from the folded game and its row."
  @callback status(map(), map()) :: atom()

  defmacro __using__(_opts) do
    quote do
      alias HighWire.Games.Store

      @behaviour Store

      @doc "Start the store. `:path` overrides the DETS file (tests)."
      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []), do: Store.start_link(__MODULE__, opts)

      # The process is HighWire.Games.Store's, so the store module is a child
      # only by way of its own start_link — the same spec `use GenServer`
      # would write.
      @doc false
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 500
        }
      end

      @doc """
      File an envelope. Callers that must not block (the timeline's drain) use
      `observe/1`; everything that wants the answer uses `ingest/1`.
      """
      @spec ingest(map()) :: {:ok, binary()} | :ignored | :seen
      def ingest(msg), do: Store.ingest(__MODULE__, msg)

      @doc "File an envelope without waiting for the write."
      @spec observe(map()) :: :ok
      def observe(msg), do: Store.observe(__MODULE__, msg)

      @doc "Every game this store holds, newest activity first."
      @spec games() :: [map()]
      def games, do: Store.games(__MODULE__)

      @doc "One game's snapshot, or nil."
      @spec get(term()) :: map() | nil
      def get(game_id), do: Store.get(__MODULE__, game_id)

      @doc "Forget everything. Tests, and the settings page if it ever needs it."
      @spec clear() :: :ok
      def clear, do: Store.clear(__MODULE__)

      @doc false
      # Kept for the router's constraints and for tests that need a valid id.
      def valid_id?(id), do: Store.valid_id?(__MODULE__, id)
    end
  end

  @spec start_link(module(), keyword()) :: GenServer.on_start()
  def start_link(store, opts) do
    GenServer.start_link(__MODULE__, {store, opts}, name: store)
  end

  @spec ingest(module(), map()) :: {:ok, binary()} | :ignored | :seen
  def ingest(store, msg), do: GenServer.call(store, {:ingest, msg}, 10_000)

  @spec observe(module(), map()) :: :ok
  def observe(store, msg) do
    case Process.whereis(store) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:ingest, msg})
    end
  end

  @spec games(module()) :: [map()]
  def games(store) do
    store.table()
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> snapshot(store, row) end)
    |> Enum.filter(fn game -> store.listed?(game) end)
    |> Enum.sort_by(& &1.updated_at, :desc)
  rescue
    ArgumentError -> []
  end

  @spec get(module(), term()) :: map() | nil
  def get(store, game_id) when is_binary(game_id) do
    case lookup(store, game_id) do
      nil -> nil
      row -> snapshot(store, row)
    end
  end

  def get(_store, _game_id), do: nil

  @spec clear(module()) :: :ok
  def clear(store), do: GenServer.call(store, :clear, 5_000)

  @doc false
  def valid_id?(store, id) do
    game = store.game_module()
    game.id?(id)
  end

  # -- server ------------------------------------------------------------

  @impl true
  def init({store, opts}) do
    path = Keyword.get(opts, :path, dets_path(store))
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(store.table(), dets_options(path)) do
      {:ok, table} ->
        seed_catalog(store, table)
        {:ok, %{store: store, table: table, path: path}}

      {:error, reason} ->
        Logger.error("#{store.kind()} store: cannot open #{inspect(path)}: #{inspect(reason)}")
        {:ok, %{store: store, table: nil, path: path, disabled?: true}}
    end
  end

  @impl true
  def handle_cast({:ingest, msg}, state) do
    case file(state, msg) do
      {:ok, game_id} -> announce(state, game_id)
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:ingest, msg}, _from, state) do
    result = file(state, msg)
    if match?({:ok, _}, result), do: announce(state, elem(result, 1))
    {:reply, result, state}
  end

  def handle_call(:clear, _from, state) do
    if not Map.get(state, :disabled?, false), do: :dets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  # -- snapshot ----------------------------------------------------------

  defp snapshot(store, row) do
    entries = Enum.group_by(row.entries, & &1.author, & &1.entry)
    entries = Map.new(entries, fn {player, list} -> {player, Enum.reject(list, &is_nil/1)} end)

    fold = store.fold_module()

    folded =
      fold.fold_game(
        store.snapshot_game(row),
        Map.merge(%{entries: entries}, store.fold_extras(row))
      )

    %{
      game_id: row.game_id,
      kind: store.kind(),
      challenger: row.challenger,
      accepter: row.accepter,
      challenge_key: row.challenge_key,
      accept_key: row.accept_key,
      challenge_note: get_in(row, [:challenge, "note"]),
      accept_note: get_in(row, [:accept, "note"]),
      directed_to: get_in(row, [:challenge, "to"]),
      withdrawn?: row.withdrawn?,
      updated_at: row.updated_at,
      entries: length(row.entries)
    }
    |> Map.merge(store.snapshot_extras(row))
    |> Map.merge(folded)
    |> Map.put(:status, store.status(folded, row))
  end

  # -- filing ------------------------------------------------------------

  defp file(%{disabled?: true}, _msg), do: :ignored

  defp file(state, msg) do
    reader = state.store.reader_module()

    case reader.read(msg) do
      {:ok, read} -> apply_read(state, read)
      :error -> :ignored
    end
  end

  defp apply_read(state, read) do
    store = state.store
    row = lookup(store, read.game_id) || store.new_row(read.game_id)

    if Map.has_key?(row.keys, read.key || "") do
      :seen
    else
      row = row |> store.put_message(read) |> record(read) |> touch()

      case write(state, row) do
        :ok -> {:ok, read.game_id}
        _ -> :ignored
      end
    end
  end

  # An entry is kept even when it is not a foldable move — the key set is
  # what makes a re-delivery of the same message a no-op.
  defp record(row, read) do
    key = read.key || "#{read.author}:#{read.type}:#{length(row.entries)}"

    %{
      row
      | entries:
          if(read.entry,
            do: row.entries ++ [%{key: key, author: read.author, entry: read.entry}],
            else: row.entries
          ),
        keys: Map.put(row.keys, key, true)
    }
  end

  defp touch(row), do: %{row | updated_at: now()}

  defp now, do: System.system_time(:millisecond)

  defp write(%{disabled?: true}, _row), do: {:error, :disabled}

  defp write(state, row) do
    :dets.insert(state.table, {{:game, row.game_id}, row})
  rescue
    ArgumentError -> {:error, :disabled}
  end

  defp lookup(store, game_id) do
    case :dets.lookup(store.table(), {:game, game_id}) do
      [{_key, row}] -> row
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp announce(state, game_id) do
    store = state.store
    Catalog.touch(store.kind(), game_id)
    PubSub.broadcast(HighWire.PubSub, store.topic(), {store.kind(), game_id})
  end

  defp dets_options(path) do
    [
      {:file, String.to_charlist(path)},
      {:type, :set},
      {:keypos, 1},
      {:repair, true},
      {:access, :read_write}
    ]
  end

  defp dets_path(store), do: Path.join(HighWire.ssb_dir(), store.file())

  # The catalog is a cache of recency, so a boot rebuilds it from the rows
  # the store already holds: touching in age order leaves the newest game
  # at the front, which is where a room starts.
  defp seed_catalog(store, table) do
    table
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> {row.updated_at || 0, row.game_id} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {_ts, game_id} -> Catalog.touch(store.kind(), game_id) end)
  rescue
    ArgumentError -> :ok
  end
end
