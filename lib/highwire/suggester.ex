defmodule HighWire.Suggester do
  @moduledoc """
  Owns the "Whom to follow" ranking, its disk cache, and the cache's
  lifecycle — kept entirely off the Timeline process.

  Timeline hands over input snapshots (`contact_msgs`, `follows`,
  `self_id`, `about_ids`) when the store-wide contact graph refills, the
  follow list changes, or the about pass completes. `about_ids` is the
  set of feeds the store holds an `about` message for (nil until the
  first pass completes) — the ranking drops candidates outside it, since
  a feed the store cannot speak for would render as a bare short id.
  Ranking runs in a supervised background task (a
  full pass over the contact graph is far too heavy to run on the feed's
  process), and that task writes the persisted cache before reporting
  back — so disk I/O never sits on any hot path either.

  Rows are cached until the inputs change. Following a suggested feed
  changes the follow list, which is exactly the event that regenerates
  the list. The cached rows are loaded at startup, so the rail shows
  last-known suggestions while the first ranking runs.

  Variety comes from a prefetched queue: each ranking produces two
  sets. A changed input graph displays the first immediately and holds
  the second in `ready`; `refresh/1` displays the next ready set
  synchronously and, when the queue runs dry, kicks a background
  ranking whose first set is displayed on completion — so a refresh
  returns what exists now and pays for the next one off-process.
  `get_suggestions/1` is a pure read: sets never rotate without a
  refresh.
  """

  use GenServer
  require Logger

  alias HighWire.SSB.Suggest

  @cache "suggestions.json"
  # One reserve set to serve the next refresh, one behind it. Every
  # ranking that needs no serve appends two more, so without a bound
  # `ready` grows for as long as the app runs.
  @max_ready 2
  # A failed ranking with a refresh still owed is retried, but only
  # after a pause: a ranker that dies on this input would otherwise be
  # respawned in a hot loop.
  @retry_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The current suggestion rows — a cheap read for rendering."
  @spec get_suggestions(GenServer.server()) :: [map()]
  def get_suggestions(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :get_suggestions)
    end
  end

  @doc "Request a fresh shuffle of suggestions using the current inputs."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :refresh)
    end
  end

  @doc """
  Hand over an input snapshot (`contact_msgs`, `follows`, `self_id`,
  `about_ids`). A ranking runs only when the snapshot differs from the
  one already ranked (or in flight).
  """
  @spec cast_inputs([map()], [String.t()], String.t() | nil, MapSet.t() | nil, GenServer.server()) ::
          :ok
  def cast_inputs(contact_msgs, follows, self_id, about_ids, server \\ __MODULE__) do
    inputs = {List.wrap(contact_msgs), List.wrap(follows), self_id, about_ids}

    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:inputs, inputs})
    end
  end

  @doc "The default cache file, under the app home directory."
  @spec cache_path() :: String.t()
  def cache_path, do: Path.join(HighWire.home_dir(), @cache)

  @impl true
  def init(opts) do
    cache = Keyword.get(opts, :cache_path, cache_path())

    {:ok,
     %{
       rows: load_cache(cache),
       ready: [],
       cache_path: cache,
       retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
       ranked: nil,
       pending: nil,
       task_ref: nil,
       task_serve: false,
       wants_serve: false
     }}
  end

  @impl true
  def handle_call(:get_suggestions, _from, state) do
    {:reply, state.rows, state}
  end

  @impl true
  def handle_cast({:inputs, inputs}, state) do
    {:noreply, maybe_rank(%{state | pending: inputs})}
  end

  @impl true
  def handle_cast(:refresh, state) do
    case state.ready do
      [set | rest] ->
        # The reserve exists for exactly this: swap it in without
        # waiting on any task, and start a background ranking so the
        # next refresh has a fresh pair to draw from.
        state = %{state | rows: set, ready: rest}
        {:noreply, refill(state)}

      [] ->
        if state.task_ref do
          # A ranking is already in flight — it becomes the set this
          # refresh is owed when it lands.
          {:noreply, %{state | wants_serve: true}}
        else
          {:noreply, rank_now(state, state.ranked)}
        end
    end
  end

  @impl true
  def handle_info({ref, {rows1, rows2}}, %{task_ref: ref} = state)
      when is_list(rows1) and is_list(rows2) do
    Process.demonitor(ref, [:flush])

    # A serving ranking displays its first set and holds the second in
    # reserve; a refill only grows the reserve — the rail keeps what a
    # refresh already put in front of the user.
    {rows, ready} =
      if state.task_serve or state.wants_serve do
        {rows1, cap_ready(state.ready ++ [rows2])}
      else
        {state.rows, cap_ready(state.ready ++ [rows1, rows2])}
      end

    save_cache(state.cache_path, rows)

    state = %{
      state
      | task_ref: nil,
        task_serve: false,
        wants_serve: false,
        rows: rows,
        ready: ready
    }

    {:noreply, maybe_rank(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.debug("suggester: ranking failed: #{inspect(reason)}")

    # wants_serve survives: a refresh clicked during the failed task is
    # still owed a set, and the next ranking that runs is asked to
    # display it. New inputs only arrive by cast, though, so with none
    # coming the owed click would wait forever — schedule the ranking
    # it asked for instead of relying on the next snapshot.
    if state.wants_serve do
      Process.send_after(self(), :retry_serve, Map.get(state, :retry_ms, @retry_ms))
    end

    {:noreply, maybe_rank(%{state | task_ref: nil, task_serve: false})}
  end

  # The ranked inputs are non-nil whenever a task existed, so this
  # cannot start a ranking blind; it stands down if anything else has
  # started one since (task_ref set) or the debt was cleared.
  def handle_info(:retry_serve, %{wants_serve: true, task_ref: nil} = state) do
    {:noreply, rank_now(state, state.ranked)}
  end

  def handle_info(:retry_serve, state), do: {:noreply, state}

  # A pending snapshot is only ever set while a task is running (the
  # casts serialize here), so draining it at completion picks up the
  # newest inputs; a completed ranking always displays changed inputs.
  defp maybe_rank(%{task_ref: ref} = state) when is_reference(ref), do: state
  defp maybe_rank(%{pending: nil} = state), do: state
  defp maybe_rank(%{pending: inputs, ranked: inputs} = state), do: %{state | pending: nil}
  defp maybe_rank(%{pending: inputs} = state), do: rank_now(%{state | pending: nil}, inputs)

  # A refresh consumes the head of the reserve; anything that lands
  # afterwards appends to the tail. Keep only the newest few, or the
  # queue outlives every consumer of it.
  defp cap_ready(ready), do: Enum.take(ready, -@max_ready)

  defp refill(%{task_ref: nil, ranked: inputs} = state), do: rank(state, inputs, serve: false)
  defp refill(state), do: state

  defp rank_now(
         %{task_ref: nil} = state,
         {_contact_msgs, _follows, _self_id, _about_ids} = inputs
       ) do
    rank(state, inputs, serve: true)
  end

  defp rank_now(state, _inputs), do: state

  defp rank(%{task_ref: nil} = state, {contact_msgs, follows, self_id, about_ids} = inputs, opts)
       when is_list(contact_msgs) and is_list(follows) do
    task =
      Task.Supervisor.async_nolink(HighWire.TaskSupervisor, fn ->
        Suggest.sets(contact_msgs, follows, self_id, about_ids, shuffle: true)
      end)

    %{state | task_ref: task.ref, task_serve: Keyword.fetch!(opts, :serve), ranked: inputs}
  end

  # Nothing ranked yet (boot before the first snapshot) or a task is
  # already in flight — either way there is nothing to start.
  defp rank(state, _inputs, _opts), do: state

  defp load_cache(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, rows} when is_list(rows) <- Jason.decode(bin) do
      rows
      |> Enum.map(fn
        %{"id" => id} = row when is_binary(id) ->
          %{"id" => id, "followers" => Map.get(row, "followers", 0)}

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp save_cache(path, rows) do
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, bin} <- Jason.encode(rows),
         :ok <- File.write(tmp, bin),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      err -> Logger.debug("suggester: cache write failed: #{inspect(err)}")
    end
  end
end
