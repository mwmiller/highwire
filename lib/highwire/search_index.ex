defmodule HighWire.SearchIndex do
  @moduledoc """
  Durable background index of post content + metadata (author, text).
  Uses DETS for inter-session durability and lower RAM pressure.
  """

  use GenServer
  require Logger

  alias HighWire.SSB.{Client, Keys, Sidecar}

  @table :highwire_search
  @version 1
  @page 5_000
  @batch 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Search whole-store index for q (async). Sends {:search_results, q, hits} to owner."
  def search(q, owner) when is_binary(q) and is_pid(owner) do
    ql = String.trim(q)

    if ql == "" do
      send(owner, {:search_results, "", []})
      :ok
    else
      Task.Supervisor.start_child(HighWire.TaskSupervisor, fn ->
        send(owner, {:search_results, ql, query(ql)})
      end)

      :ok
    end
  end

  # Runs in a query task, never in the GenServer — a DETS fold over the
  # whole table is seconds of disk I/O and must not queue behind crawl
  # items in the index's mailbox.
  defp query(ql) do
    qd = String.downcase(ql)

    :dets.foldl(&collect(&1, &2, qd), [], @table)
    |> Enum.sort_by(& &1.ts, :desc)
    |> Enum.take(200)
  end

  defp collect({key, author, text, ts}, acc, qd)
       when is_binary(text) or is_binary(author) do
    t = if is_binary(text), do: String.downcase(text), else: ""
    a = if is_binary(author), do: String.downcase(author), else: ""

    if String.contains?(t, qd) or String.contains?(a, qd) do
      [%{key: key, author: author, text: text, ts: ts} | acc]
    else
      acc
    end
  end

  defp collect(_record, acc, _qd), do: acc

  @doc "Ingest a list of post maps (for tests/live tail)."
  def ingest(items) when is_list(items) do
    GenServer.cast(__MODULE__, {:ingest, items})
  end

  defp dets_path do
    Path.join(HighWire.home_dir(), "search.dets")
  end

  defp read_meta do
    case :dets.lookup(@table, :meta) do
      [{:meta, v, cursor}] when is_integer(v) and (is_integer(cursor) or cursor == nil) ->
        {v, cursor || 0}

      _ ->
        {nil, 0}
    end
  end

  defp write_meta(cursor) do
    :dets.insert(@table, {:meta, @version, cursor})
  end

  defp open_dets(path) do
    case :dets.open_file(@table, [
           {:file, String.to_charlist(path)},
           {:type, :set},
           {:keypos, 1},
           {:repair, true},
           {:access, :read_write}
         ]) do
      {:ok, @table} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, dets_path())
    enabled? = Keyword.get(opts, :enabled?, Sidecar.enabled?())

    case open_dets(path) do
      :ok ->
        {v, cursor} = read_meta()

        if v != @version do
          Logger.info("[search_index] version mismatch (#{v}!=#{@version}), clearing")
          :dets.delete_all_objects(@table)
          write_meta(0)

          {:ok, %{path: path, cursor: 0, enabled?: enabled?, batching: [], count: 0},
           {:continue, :maybe_connect}}
        else
          {:ok, %{path: path, cursor: cursor, enabled?: enabled?, batching: [], count: 0},
           {:continue, :maybe_connect}}
        end

      {:error, reason} ->
        Logger.error("[search_index] failed to open dets #{inspect(path)}: #{inspect(reason)}")
        {:ok, %{path: path, cursor: 0, enabled?: false, batching: [], count: 0}}
    end
  end

  defp start_client do
    secret = Path.join([HighWire.home_dir(), ".ssberl", "secret"])

    if File.exists?(secret) do
      keys = Keys.load!(secret)

      case Client.start_link(
             port: Sidecar.port(),
             remote_pk: keys.public,
             net_id: Base.decode64!(Sidecar.net_id()),
             keys: keys
           ) do
        {:ok, pid} -> pid
        {:error, _} -> nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp open_backlog(client, gt) do
    Client.stream(
      client,
      ["messagesByType", "post"],
      %{"limit" => @page, "gt" => gt}
    )
  end

  defp open_live(client, gt) do
    Client.stream(
      client,
      ["messagesByType", "post"],
      %{"limit" => @page, "gt" => gt, "live" => true}
    )
  end

  defp flush_batch(state) do
    if state.batching != [] do
      :dets.insert(@table, Enum.reverse(state.batching))
    end

    %{state | batching: [], count: 0}
  end

  defp put_item(state, key, author, text, ts) do
    ts_int = if is_integer(ts), do: ts, else: 0
    cursor = if ts_int > state.cursor, do: ts_int, else: state.cursor
    rec = {key, author, text, ts_int}
    batching = [rec | state.batching]
    count = state.count + 1

    state =
      if count >= @batch do
        :dets.insert(@table, Enum.reverse(batching))
        %{state | batching: [], count: 0, cursor: cursor}
      else
        %{state | batching: batching, count: count, cursor: cursor}
      end

    write_meta(state.cursor)
    state
  end

  @impl true
  def handle_cast({:ingest, items}, state) do
    state =
      Enum.reduce(items, state, fn
        %{"key" => k, "value" => v, "timestamp" => ts}, st ->
          author = get_in(v, ["author"])
          text = get_in(v, ["content", "text"])
          put_item(st, k, author, text, ts)

        %{"key" => k, "author" => a, "text" => t, "ts" => ts}, st ->
          put_item(st, k, a, t, ts)

        _, st ->
          st
      end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, %{enabled?: true} = state) do
    case start_client() do
      nil ->
        Logger.warning("[search_index] could not start SSB client; retrying in 2s")
        Process.send_after(self(), :connect, 2_000)
        {:noreply, state}

      client ->
        ref = open_backlog(client, state.cursor)
        {:noreply, %{state | client: client, ref: ref, phase: :backlog}}
    end
  end

  def handle_info(:connect, %{enabled?: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:ssb, ref, {:item, item}}, %{ref: ref} = state) do
    state =
      case item do
        %{"key" => k, "value" => v, "timestamp" => ts} ->
          author = get_in(v, ["author"])
          text = get_in(v, ["content", "text"])
          put_item(state, k, author, text, ts)

        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({:ssb, ref, :done}, %{ref: ref, phase: :backlog, client: client} = state) do
    state = flush_batch(state)
    write_meta(state.cursor)
    ref2 = open_live(client, state.cursor)
    {:noreply, %{state | ref: ref2, phase: :live}}
  end

  def handle_info({:ssb, ref, :done}, %{ref: ref, phase: :live} = state) do
    state = flush_batch(state)
    write_meta(state.cursor)
    {:noreply, %{state | ref: nil, phase: :caught_up}}
  end

  def handle_info({:ssb, ref, {:error, e}}, %{ref: ref} = state) do
    Logger.warning("[search_index] stream error: #{inspect(e)}; retrying backlog in 5s")
    state = flush_batch(state)
    Process.send_after(self(), :connect, 5_000)
    {:noreply, %{state | ref: nil, client: nil}}
  end

  @impl true
  def handle_continue(:maybe_connect, %{enabled?: true} = state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_continue(:maybe_connect, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    flush_batch(state)
    write_meta(state.cursor)
    :ok
  end
end
