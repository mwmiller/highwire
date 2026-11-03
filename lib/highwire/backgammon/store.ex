defmodule HighWire.Backgammon.Store do
  @moduledoc """
  The local record of every backgammon game this node has seen, kept in a
  DETS file.

  Two things make the store necessary rather than convenient. SSB has no
  query for "the messages of one game" — a reader would have to walk whole
  feeds — and the social timeline is the wrong place to answer "whose move
  is it". So every `backgammon/*` message that arrives is filed here, keyed
  by game, and the page reads the store rather than the feed.

  The fold runs on read: a game is a few hundred small maps, so folding is
  cheaper than keeping a derived cache in step with an append-only log. The
  store persists the *entries* — that is what makes a game replayable after
  a restart, and it is the part that cannot be recomputed from anything else.

  Nothing here decides whether a message is true. A row records what was
  published; the fold decides whether those entries make a legal game, and
  `error` on a snapshot is the fold saying they do not.
  """

  use GenServer

  require Logger

  alias HighWire.Backgammon.{Fold, Game, Reader}

  @table :highwire_backgammon
  @topic "backgammon"

  @doc "Start the store. `:path` overrides the DETS file (tests)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The PubSub topic the store announces changes on."
  def topic, do: @topic

  @doc """
  File an envelope. Callers that must not block (the timeline's live tail)
  use `observe/1`; everything that wants the answer uses `ingest/1`.
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

  @doc "Every game, newest activity first."
  @spec games() :: [map()]
  def games do
    @table
    |> :dets.match_object({{:game, :_}, :_})
    |> Enum.map(fn {_key, row} -> snapshot(row) end)
    |> Enum.reject(&(is_nil(&1.challenger) or is_nil(&1.accepter)))
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
      challenge_commit: row.challenge_commit,
      accept_commit: row.accept_commit
    }

    entries = Enum.group_by(row.entries, & &1.author, & &1.entry)
    entries = Map.new(entries, fn {player, list} -> {player, Enum.reject(list, &is_nil/1)} end)

    folded = Fold.fold_game(game, %{entries: entries, accept_reveal: row.accept_reveal})

    %{
      game_id: row.game_id,
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
    |> Map.merge(folded)
    |> Map.put(:status, status(folded, row))
  end

  defp status(%{phase: :finished, winner: %{player: player}}, _row) when is_binary(player),
    do: :finished

  defp status(%{error: error}, _row) when error != :none, do: :broken
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
        {:ok, %{path: path}}

      {:error, reason} ->
        Logger.error("backgammon store: cannot open #{inspect(path)}: #{inspect(reason)}")
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
    Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {:backgammon, game_id})
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
      challenge_key: nil,
      accept_key: nil,
      challenge_commit: nil,
      accept_commit: nil,
      accept_reveal: nil,
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
        challenge_commit: content["commit"],
        challenge: content
    }
    |> record(read)
  end

  defp put_message(row, %{type: "accept", author: author, content: content} = read) do
    row
    |> Map.merge(%{
      accepter: row.accepter || author,
      accept_key: read.key,
      accept_commit: content["commit"],
      accept_reveal: content["reveal"],
      accept: content
    })
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

  defp dets_path, do: Path.join([HighWire.home_dir(), ".ssberl", "backgammon.dets"])

  @doc false
  # Kept for the router's constraints and for tests that need a valid id.
  def valid_id?(id), do: Game.id?(id)
end
