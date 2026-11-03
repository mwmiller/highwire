defmodule HighWire.Chess.Store do
  @moduledoc """
  The local record of every chess game this node has seen, kept in a DETS
  file of its own.

  Separate from the backgammon store for one reason: the two games have
  nothing in common to file. A backgammon row carries commitments, reveals
  and a chain position; a chess row carries a colour choice and moves. One
  table would be a table of two shapes.

  The fold runs on read, as it does for backgammon: a game is a short list of
  moves, so folding is cheaper than keeping a derived board in step with an
  append-only log, and the entries are what cannot be recomputed.

  Nothing here decides whether a move is true. A row records what was
  published; the fold decides whether those moves make a legal game, and
  `:broken` on a snapshot is the fold saying they do not.
  """

  use GenServer

  require Logger

  alias HighWire.Chess.{Fold, Game, Reader}

  @table :highwire_chess
  @topic "chess"

  @doc "Start the store. `:path` overrides the DETS file (tests)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic the store announces changes on."
  def topic, do: @topic

  @doc """
  File an envelope. Callers that must not block (the timeline's drain) use
  `observe/1`; everything that wants the answer uses `ingest/1`.
  """
  @spec ingest(map()) :: {:ok, binary()} | :ignored | :seen
  def ingest(msg), do: GenServer.call(__MODULE__, {:ingest, msg}, 10_000)

  @doc "File an envelope without waiting for the write."
  @spec observe(map()) :: :ok
  def observe(msg) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:ingest, msg})
    end
  end

  @doc "Every game with a challenger, newest activity first."
  @spec games() :: [map()]
  def games do
    @table
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> snapshot(row) end)
    |> Enum.reject(&is_nil(&1.challenger))
    |> Enum.sort_by(& &1.updated_at, :desc)
  rescue
    ArgumentError -> []
  end

  @doc "One game's snapshot, or nil."
  @spec get(binary()) :: map() | nil
  def get(game_id) when is_binary(game_id) do
    case lookup(game_id) do
      nil -> nil
      row -> snapshot(row)
    end
  end

  @doc "Forget everything. Tests, and the settings page if it ever needs it."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear, 5_000)

  @doc false
  # Kept for the router's constraints and for tests that need a valid id.
  def valid_id?(id), do: Game.id?(id)

  defp lookup(game_id) do
    case :dets.lookup(@table, {:game, game_id}) do
      [{_key, row}] -> row
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp snapshot(row) do
    game = %{
      challenger: row.challenger,
      accepter: row.accepter,
      game_id: row.game_id,
      challenger_color: row.challenger_color
    }

    entries = Enum.group_by(row.entries, & &1.author, & &1.entry)
    entries = Map.new(entries, fn {player, list} -> {player, Enum.reject(list, &is_nil/1)} end)

    folded = Fold.fold_game(game, %{entries: entries})

    %{
      game_id: row.game_id,
      kind: :chess,
      challenger: row.challenger,
      accepter: row.accepter,
      challenger_color: row.challenger_color,
      challenge_key: row.challenge_key,
      accept_key: row.accept_key,
      challenge_note: get_in(row, [:challenge, "note"]),
      accept_note: get_in(row, [:accept, "note"]),
      directed_to: get_in(row, [:challenge, "to"]),
      withdrawn?: row.withdrawn?,
      updated_at: row.updated_at,
      entries: length(row.entries)
    }
    |> Map.merge(folded)
    |> Map.put(:status, status(folded, row))
  end

  defp status(%{error: error}, _row) when error != :none, do: :broken
  defp status(%{phase: :finished}, _row), do: :finished
  defp status(_folded, %{withdrawn?: true}), do: :withdrawn
  defp status(%{phase: :opening}, _row), do: :opening
  defp status(_folded, _row), do: :playing

  # -- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, dets_path())
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, [
           {:file, String.to_charlist(path)},
           {:type, :set},
           {:keypos, 1},
           {:repair, true},
           {:access, :read_write}
         ]) do
      {:ok, @table} ->
        seed_catalog()
        {:ok, %{path: path}}

      {:error, reason} ->
        Logger.error("chess store: cannot open #{inspect(path)}: #{inspect(reason)}")
        {:ok, %{path: path, disabled?: true}}
    end
  end

  @impl true
  def handle_cast({:ingest, msg}, state) do
    case file(msg, state) do
      {:ok, game_id} -> announce(game_id)
      _ -> :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:ingest, msg}, _from, state) do
    result = file(msg, state)
    if match?({:ok, _}, result), do: announce(elem(result, 1))
    {:reply, result, state}
  end

  def handle_call(:clear, _from, state) do
    if not Map.get(state, :disabled?, false), do: :dets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp announce(game_id) do
    HighWire.Games.Catalog.touch(:chess, game_id)
    Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {:chess, game_id})
  end

  # -- filing ------------------------------------------------------------

  defp file(msg, state) do
    case Reader.read(msg) do
      {:ok, read} -> apply_read(read, state)
      :error -> :ignored
    end
  end

  defp apply_read(read, state) do
    row = lookup(read.game_id) || new_row(read.game_id)

    if Map.has_key?(row.keys, read.key || "") do
      :seen
    else
      row = row |> put_message(read) |> touch()

      case write(state, row) do
        :ok -> {:ok, read.game_id}
        _ -> :ignored
      end
    end
  end

  defp new_row(game_id) do
    %{
      game_id: game_id,
      challenger: nil,
      accepter: nil,
      challenger_color: nil,
      challenge_key: nil,
      accept_key: nil,
      challenge: nil,
      accept: nil,
      entries: [],
      keys: %{},
      withdrawn?: false,
      created_at: now(),
      updated_at: now()
    }
  end

  defp put_message(row, %{type: "challenge", author: author, content: content} = read) do
    %{
      row
      | challenger: row.challenger || author,
        challenge_key: read.key,
        challenger_color: content["color"] || "white",
        challenge: content
    }
    |> record(read)
  end

  defp put_message(row, %{type: "accept", author: author, content: content} = read) do
    row
    |> Map.merge(%{accepter: row.accepter || author, accept_key: read.key, accept: content})
    |> record(read)
  end

  defp put_message(row, %{type: "withdraw", author: author} = read) do
    row
    |> Map.put(:withdrawn?, row.challenger == author)
    |> record(read)
  end

  defp put_message(row, read), do: record(row, read)

  # An entry is kept even when it is not a foldable move — the key set is what
  # makes a re-delivery of the same message a no-op.
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

  defp write(_state, row) do
    :dets.insert(@table, {{:game, row.game_id}, row})
  rescue
    ArgumentError -> {:error, :disabled}
  end

  defp dets_path, do: Path.join([HighWire.home_dir(), ".ssberl", "chess.dets"])

  # The catalog is a cache of recency, so a boot rebuilds it from the rows
  # the store already holds: touching in age order leaves the newest game
  # at the front, which is where a room starts.
  defp seed_catalog do
    @table
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> {row.updated_at || 0, row.game_id} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {_ts, game_id} -> HighWire.Games.Catalog.touch(:chess, game_id) end)
  rescue
    ArgumentError -> :ok
  end
end
