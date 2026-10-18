defmodule HighWire.Suggester do
  @moduledoc """
  Owns the \"Whom to follow\" ranking, its disk cache, and the cache's
  lifecycle — kept entirely off the Timeline process.

  Timeline hands over input snapshots (`contact_msgs`, `follows`,
  `self_id`) when the store-wide contact graph refills or the follow
  list changes. Ranking runs in a supervised background task (a
  full pass over the contact graph is far too heavy to run on the feed's
  process), and that task writes the persisted cache before reporting
  back — so disk I/O never sits on any hot path either.

  Rows are cached until the inputs change. Following a suggested feed
  changes the follow list, which is exactly the event that regenerates
  the list. The cached rows are loaded at startup, so the rail shows
  last-known suggestions while the first ranking runs.

  To provide variety without delaying the UI, each regeneration produces
  two candidate sets: the first is served immediately, the second is
  kept in reserve and served on the next explicit refresh.
  """

  use GenServer
  require Logger

  alias HighWire.SSB.Suggest

  @cache "suggestions.json"

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
  Hand over an input snapshot (`contact_msgs`, `follows`, `self_id`).
  A ranking runs only when the snapshot differs from the one
  already ranked (or in flight).
  """
  @spec cast_inputs([map()], [String.t()], String.t() | nil, GenServer.server()) :: :ok
  def cast_inputs(contact_msgs, follows, self_id, server \\ __MODULE__) do
    inputs = {List.wrap(contact_msgs), List.wrap(follows), self_id}

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
       next_rows: [],
       cache_path: cache,
       ranked: nil,
       pending: nil,
       task_ref: nil,
       wants_refresh: false
     }}
  end

  @impl true
  def handle_call(:get_suggestions, _from, state) do
    {:reply, state.rows, %{state | rows: state.next_rows, next_rows: []}}
  end

  @impl true
  def handle_cast({:inputs, inputs}, state) do
    {:noreply, maybe_rank(%{state | pending: inputs, wants_refresh: false})}
  end

  @impl true
  def handle_cast(:refresh, state) do
    if state.task_ref do
      {:noreply, %{state | wants_refresh: true}}
    else
      {:noreply, maybe_rank(%{state | pending: state.ranked, wants_refresh: true})}
    end
  end

  @impl true
  def handle_info({ref, {rows1, rows2}}, %{task_ref: ref} = state)
      when is_list(rows1) and is_list(rows2) do
    Process.demonitor(ref, [:flush])
    cache = state.cache_path
    save_cache(cache, rows1)

    rows_now = if state.rows == [], do: rows1, else: state.rows
    next_now = if state.rows == [], do: rows2, else: rows1

    new_state =
      %{state | task_ref: nil, rows: rows_now, next_rows: next_now, wants_refresh: false}
      |> maybe_rank()

    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.debug("suggester: ranking failed: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil, wants_refresh: false} |> maybe_rank()}
  end

  defp maybe_rank(%{task_ref: ref} = state) when is_reference(ref), do: state
  defp maybe_rank(%{pending: nil} = state), do: state

  defp maybe_rank(%{pending: inputs, ranked: inputs, wants_refresh: false} = state),
    do: %{state | pending: nil}

  defp maybe_rank(%{pending: {contact_msgs, follows, self_id} = inputs} = state) do
    task =
      Task.Supervisor.async_nolink(HighWire.TaskSupervisor, fn ->
        rows1 = Suggest.rank(contact_msgs, follows, self_id, shuffle: true)
        rows2 = Suggest.rank(contact_msgs, follows, self_id, shuffle: true)
        {rows1, rows2}
      end)

    %{state | pending: nil, ranked: inputs, task_ref: task.ref, wants_refresh: false}
  end

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
