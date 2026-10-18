defmodule HighWire.Suggester do
  @moduledoc """
  Owns the \"Who to follow\" ranking, its disk cache, and the cache's
  lifecycle — kept entirely off the Timeline process.

  Timeline hands over input snapshots (`window`, `contact_msgs`,
  `follows`, `self_id`) when the store-wide contact graph refills or the
  follow list changes. Ranking runs in a supervised background task (a
  full pass over the contact graph is far too heavy to run on the feed's
  process), and that task writes the persisted cache before reporting
  back — so disk I/O never sits on any hot path either.

  Rows are cached until the inputs change. Following a suggested feed
  changes the follow list, which is exactly the event that regenerates
  the list. The cached rows are loaded at startup, so the rail shows
  last-known suggestions while the first ranking runs.
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
    # A missing Suggester must never take the feed down with it — an
    # empty rail is the worst case.
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :get_suggestions)
    end
  end

  @doc """
  Hand over an input snapshot (`window`, `contact_msgs`, `follows`,
  `self_id`). A ranking runs only when the snapshot differs from the one
  already ranked (or in flight).
  """
  @spec cast_inputs([map()], [map()], [String.t()], String.t() | nil, GenServer.server()) :: :ok
  def cast_inputs(window, contact_msgs, follows, self_id, server \\ __MODULE__) do
    inputs = {List.wrap(window), List.wrap(contact_msgs), List.wrap(follows), self_id}

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
       cache_path: cache,
       ranked: nil,
       pending: nil,
       task_ref: nil
     }}
  end

  @impl true
  def handle_call(:get_suggestions, _from, state), do: {:reply, state.rows, state}

  @impl true
  def handle_cast({:inputs, inputs}, state) do
    {:noreply, maybe_rank(%{state | pending: inputs})}
  end

  # The ranking task finished; it has already written the disk cache.
  @impl true
  def handle_info({ref, rows}, %{task_ref: ref} = state) when is_list(rows) do
    Process.demonitor(ref, [:flush])
    {:noreply, maybe_rank(%{state | rows: rows, task_ref: nil})}
  end

  # The ranking task died (crash or kill): keep the rows we have and let
  # the next input change retry.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Logger.debug("suggester: ranking failed: #{inspect(reason)}")
    {:noreply, %{state | task_ref: nil}}
  end

  defp maybe_rank(%{task_ref: ref} = state) when is_reference(ref), do: state
  defp maybe_rank(%{pending: nil} = state), do: state

  # Identical to what is already ranked — nothing to do.
  defp maybe_rank(%{pending: inputs, ranked: inputs} = state), do: %{state | pending: nil}

  defp maybe_rank(%{pending: {window, contact_msgs, follows, self_id} = inputs} = state) do
    cache = state.cache_path

    task =
      Task.Supervisor.async_nolink(HighWire.TaskSupervisor, fn ->
        rows = Suggest.rank(window, contact_msgs, follows, self_id)
        save_cache(cache, rows)
        rows
      end)

    %{state | pending: nil, ranked: inputs, task_ref: task.ref}
  end

  defp load_cache(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, rows} when is_list(rows) <- Jason.decode(bin) do
      Enum.filter(rows, &match?(%{"id" => id} when is_binary(id), &1))
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
