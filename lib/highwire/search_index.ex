defmodule HighWire.SearchIndex do
  @moduledoc """
  Durable background index of post content + metadata (author, text).
  Uses DETS for inter-session durability and lower RAM pressure.

  The backlog is crawled with `messagesByType "post"` paged on `gt` +
  `limit`, keyed on the engine's *received* time (the envelope's
  top-level `timestamp`). One request serves at most `@page` rows and
  `gt` compares strictly (`ts > gt`), so:

    * the engine omits rows whose message it cannot hydrate, so a
      delivered page shorter than `limit` does not prove the backlog is
      exhausted — only a request that delivers nothing does;
    * `gt` resumes one *below* the cursor — received timestamps are not
      unique, and a strict `>` at the boundary would silently skip the
      message's same-millisecond siblings (the primary key absorbs the
      overlap);
    * only then does the live tail open. The live stream's backlog
      snapshot is limit-capped too, so paging must finish before the
      tail opens or rows beyond the cap are lost forever.

  Queries run in a task under the app's TaskSupervisor and read DETS
  directly (`:dets.foldl`), so a search never queues behind crawl items
  in this process's mailbox. Records are inserted into DETS as they
  arrive — no staging batch — so a query task always sees them.

  Records carry the text twice: the original (for the snippet the feed
  shows) and a downcased copy the query matches against, plus the same
  pair for the author. Folding the table once per query to downcase
  every text is by far the most expensive part of a search — measured at
  ~1.8s for the text and ~0.8s for the authors over a 263k-record index,
  *independent of how many rows match*, so even a query with no hits
  paid it. Normalising at ingest moves that cost to a one-off per
  record; a query then only compares bytes. The fold keeps just the
  newest `@max_hits` in a bounded set rather than collecting every match
  and sorting it after (measured ~2.6s against ~10s for "the", with the
  identical top `@max_hits`).
  """

  use GenServer
  require Logger

  alias HighWire.SSB.{Client, Keys, Sidecar}

  @table :highwire_search
  @status :highwire_search_status

  # 3 — records carry their pre-normalised text/author alongside the
  # original. A version mismatch clears the table so the next boot
  # rebuilds it in the new shape; until then collect/3 still normalises
  # the older 4-tuple records on the fly, so a live session's search
  # keeps working across the reload.
  @version 3
  @max_hits 200
  @page 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  The index's current state, for the header indicator:

    * `:connecting`    — dialling the engine (or between retries)
    * `{:crawling, n}` — backlog paging; `n` posts indexed this session
    * `:live`          — backlog done, live tail attached (up to date)
    * `:reconnecting`  — stream dropped; resumes from the checkpoint
    * `:disabled`      — engine off in config
    * `:unavailable`   — the DETS table could not be opened

  Read from an ETS snapshot rather than by calling the GenServer: during
  a backlog flood the mailbox holds thousands of crawl items and a call
  would wait behind all of them.
  """
  def status do
    case :ets.lookup(@status, :status) do
      [{:status, status}] -> status
      [] -> :connecting
    end
  rescue
    _ -> :connecting
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
  # items in the index's mailbox. A closed table (open failed) answers
  # no matches rather than crashing the task, which would leave the
  # LiveView waiting on results forever.
  defp query(ql) do
    qd = String.downcase(ql)

    :dets.foldl(&collect(&1, &2, qd), :gb_sets.empty(), @table)
    |> :gb_sets.to_list()
    |> Enum.reverse()
    |> Enum.map(fn {ts, key, author, text} ->
      %{key: key, author: author, text: text, ts: ts}
    end)
  rescue
    e ->
      Logger.warning("[search_index] query #{inspect(ql)} failed: #{Exception.message(e)}")
      []
  catch
    kind, reason ->
      Logger.warning("[search_index] query #{inspect(ql)} failed: #{inspect({kind, reason})}")
      []
  end

  # Records written since @version 3 carry their normalised text and
  # author; the match is a plain byte search against them.
  defp collect({key, author, text, ts, text_lc, author_lc}, acc, qd) do
    t = if is_binary(text_lc), do: text_lc, else: ""
    a = if is_binary(author_lc), do: author_lc, else: ""

    if :binary.match(t, qd) != :nomatch or :binary.match(a, qd) != :nomatch do
      cap_hits(:gb_sets.add_element({ts, key, author, text}, acc))
    else
      acc
    end
  end

  # A record indexed before @version 3 has no normalised copy. Rather
  # than miss it, normalise it here; the next boot's rebuild replaces
  # every such record, so this path is only the transition.
  defp collect({key, author, text, ts}, acc, qd) do
    collect({key, author, text, ts, normalize(text), normalize(author)}, acc, qd)
  end

  defp collect(_record, acc, _qd), do: acc

  # The fold visits the table in key order, so nothing bounds it: keep
  # only the newest @max_hits. The tuple sorts by ts first (then the
  # unique key), so dropping the smallest reproduces "sort by ts
  # descending, take @max_hits" exactly — verified against the old shape
  # on the live index.
  defp cap_hits(set) do
    if :gb_sets.size(set) > @max_hits do
      {_oldest, set} = :gb_sets.take_smallest(set)
      set
    else
      set
    end
  end

  # Downcasing is not the query's job once the record is written. A
  # record whose text is not valid UTF-8 (or not a binary at all) must
  # not take the index down while crawling, so fall back to the raw
  # bytes rather than raising.
  defp normalize(s) when is_binary(s) do
    String.downcase(s)
  rescue
    _ -> s
  end

  defp normalize(_), do: ""

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

  # The status snapshot lives in its own ETS table (created once per
  # incarnation, owner-only writes) so the LiveView header can poll it
  # without queuing behind the crawl's mailbox.
  defp ensure_status_table do
    case :ets.whereis(@status) do
      :undefined -> :ets.new(@status, [:named_table, :protected, read_concurrency: true])
      _tid -> :ok
    end
  end

  defp put_status(status) do
    :ets.insert(@status, {:status, status})
    :ok
  rescue
    _ -> :ok
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
    # A dead engine must surface as a reconnect, not as a supervisor
    # restart of the index: the client is linked to us.
    Process.flag(:trap_exit, true)

    path = Keyword.get(opts, :path, dets_path())
    enabled? = Keyword.get(opts, :enabled?, Sidecar.enabled?())

    # Our own supervisor/owner: with trap_exit on, its exit signal
    # arrives as a message and must stop us, not be dropped. Ancestors
    # record a registered supervisor by name, so resolve that to the
    # pid its exit signal will come from.
    parent =
      case Process.get(:"$ancestors") do
        [p | _] when is_pid(p) -> p
        [name | _] when is_atom(name) -> Process.whereis(name)
        _ -> nil
      end

    base = %{
      path: path,
      enabled?: enabled?,
      parent: parent,
      cursor: 0,
      indexed: 0,
      client: nil,
      ref: nil,
      phase: :idle,
      page_count: 0,
      page_start_cursor: 0
    }

    ensure_status_table()

    case open_dets(path) do
      :ok ->
        {v, cursor} = read_meta()

        cursor =
          if v != @version do
            Logger.info("[search_index] version mismatch (#{v}!=#{@version}), clearing")
            :dets.delete_all_objects(@table)
            write_meta(0)
            0
          else
            cursor
          end

        put_status(if enabled?, do: :connecting, else: :disabled)
        {:ok, %{base | cursor: cursor}, {:continue, :maybe_connect}}

      {:error, reason} ->
        Logger.error("[search_index] failed to open dets #{inspect(path)}: #{inspect(reason)}")
        put_status(:unavailable)
        {:ok, %{base | enabled?: false}}
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

  # `gt` in the engine is strict (`ts > gt`): resuming at the cursor
  # itself would skip any rows sharing the last message's millisecond.
  # Resume one behind and let the primary key absorb the overlap.
  defp resume_gt(cursor), do: cursor - 1

  defp open_backlog(client, gt) do
    case Client.stream(client, ["messagesByType"], [
           %{"type" => "post", "limit" => @page, "gt" => gt}
         ]) do
      {:ok, ref} -> ref
      {:error, _} -> nil
    end
  catch
    _, _ -> nil
  end

  defp open_live(client, gt) do
    case Client.stream(client, ["messagesByType"], [
           %{"type" => "post", "limit" => @page, "gt" => gt, "live" => true}
         ]) do
      {:ok, ref} -> ref
      {:error, _} -> nil
    end
  catch
    _, _ -> nil
  end

  defp stop_client(%{client: nil} = state), do: %{state | ref: nil, phase: :idle}

  defp stop_client(%{client: pid} = state) do
    try do
      # Bounded, unlike Client.stop/1's :infinity: a wedged client must
      # not hang a reconnect (or terminate/2) forever. A late exit from
      # a stop that timed out lands in the catch-all below.
      GenServer.stop(pid, :normal, 5_000)
    catch
      _, _ -> :ok
    end

    %{state | client: nil, ref: nil, phase: :idle}
  end

  defp put_item(state, key, author, text, shown_ts, received_ts) do
    ts_int = if is_number(received_ts), do: trunc(received_ts), else: 0
    cursor = if ts_int > state.cursor, do: ts_int, else: state.cursor
    shown = if is_number(shown_ts), do: trunc(shown_ts), else: ts_int

    :dets.insert(@table, {key, author, text, shown, normalize(text), normalize(author)})
    state = %{state | cursor: cursor, indexed: state.indexed + 1}
    maybe_write_meta(state)
    state
  end

  # `get_in/2` raises when an intermediate value is not a map — a message
  # whose content is a boxed string, say. That would take the index down
  # mid-crawl and the restart would re-crawl into the same record
  # forever, so an unreadable field is simply nothing to index.
  defp field(value, path) do
    Enum.reduce_while(path, value, fn key, acc ->
      case acc do
        %{} = map -> {:cont, Map.get(map, key)}
        _ -> {:halt, nil}
      end
    end)
  end

  # The envelope's timestamp is when the engine *received* the message — a
  # bulk import stamps thousands with the same instant — so a result list
  # dated by it reads as one day repeated. What a reader means by "when was
  # this posted" is the author's claimed time in `value.timestamp`; it only
  # falls back to the received time when the message carries none. The
  # cursor still follows the received time: that is the only order the
  # engine pages in.
  defp authored_ts(v) do
    case v do
      %{"timestamp" => t} when is_number(t) -> t
      _ -> nil
    end
  end

  # The cursor rides along with every live-tail item (rare — cheap) and
  # every 1000th backlog item. A crash re-pages at most that far, and
  # re-paging is idempotent thanks to the primary key. The same
  # checkpoints refresh the indicator's running count.
  defp maybe_write_meta(%{phase: :live, cursor: cursor}), do: write_meta(cursor)

  defp maybe_write_meta(%{indexed: n, cursor: cursor} = state)
       when is_integer(n) and rem(n, 1000) == 0 do
    write_meta(cursor)
    put_status({:crawling, state.indexed})
  end

  defp maybe_write_meta(_state), do: :ok

  @impl true
  def handle_cast({:ingest, items}, state) do
    state =
      Enum.reduce(items, state, fn
        %{"key" => k, "value" => v, "timestamp" => ts}, st ->
          author = field(v, ["author"])
          text = field(v, ["content", "text"])
          put_item(st, k, author, text, authored_ts(v) || ts, ts)

        %{"key" => k, "author" => a, "text" => t, "ts" => ts}, st ->
          put_item(st, k, a, t, ts, ts)

        _, st ->
          st
      end)

    write_meta(state.cursor)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, %{enabled?: true} = state) do
    state = stop_client(state)

    case start_client() do
      nil ->
        Logger.warning("[search_index] could not start SSB client; retrying in 2s")
        put_status(:connecting)
        Process.send_after(self(), :connect, 2_000)
        {:noreply, state}

      client ->
        case open_backlog(client, resume_gt(state.cursor)) do
          nil ->
            Logger.warning("[search_index] could not open backlog stream; retrying in 2s")
            put_status(:connecting)
            Process.send_after(self(), :connect, 2_000)
            {:noreply, stop_client(%{state | client: client})}

          ref ->
            {:noreply, begin_stream(%{state | client: client}, ref, :backlog)}
        end
    end
  end

  def handle_info(:connect, %{enabled?: false} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({Client, ref, {:item, item}}, %{ref: ref} = state) do
    state = %{state | page_count: state.page_count + 1}

    state =
      case item do
        %{"key" => k, "value" => v, "timestamp" => ts} ->
          author = field(v, ["author"])
          text = field(v, ["content", "text"])
          put_item(state, k, author, text, authored_ts(v) || ts, ts)

        # A live stream parks a {sync: true} sentinel between its
        # backlog snapshot and the tail; it carries no message.
        _ ->
          state
      end

    {:noreply, state}
  end

  def handle_info({Client, ref, :done}, %{ref: ref, phase: :backlog, client: client} = state) do
    case next_backlog_step(state) do
      :live ->
        # An empty page: the backlog is exhausted. Checkpoint, then tail.
        write_meta(state.cursor)
        open_live_stream(state)

      {:page, gt} ->
        case open_backlog(client, gt) do
          nil -> reconnect_soon(state, 5_000)
          ref2 -> {:noreply, begin_stream(state, ref2, :backlog)}
        end
    end
  end

  # The live tail ends with the stream (engine restart, socket loss).
  # Caught up is not forever — re-dial on a slow cadence; the reconnect
  # pages from the stored cursor, so nothing between then and now is
  # lost.
  def handle_info({Client, ref, :done}, %{ref: ref} = state) do
    write_meta(state.cursor)
    reconnect_soon(stop_client(state), 60_000)
  end

  def handle_info({Client, ref, {:error, e}}, %{ref: ref} = state) do
    Logger.warning("[search_index] stream error: #{inspect(e)}; retrying backlog in 5s")
    write_meta(state.cursor)
    reconnect_soon(stop_client(state), 5_000)
  end

  # The supervisor/owner is stopping us: trap_exit turned its exit
  # signal into a message, and ignoring it would burn the whole
  # shutdown timeout and get us brutally killed without terminate/2.
  def handle_info({:EXIT, parent, reason}, %{parent: parent} = state) when is_pid(parent) do
    {:stop, reason, state}
  end

  # The client is linked to us; with trap_exit on, a dead engine lands
  # here instead of taking the index down with it.
  def handle_info({:EXIT, pid, reason}, %{client: pid} = state) do
    Logger.warning("[search_index] client exited: #{inspect(reason)}; reconnecting in 5s")
    put_status(:reconnecting)
    Process.send_after(self(), :connect, 5_000)
    {:noreply, %{state | client: nil, ref: nil, phase: :idle}}
  end

  # Stale messages from a stream we have already swapped out (or any
  # other stray send): the ref no longer matches, so they are dropped.
  def handle_info(_msg, state), do: {:noreply, state}

  # What a finished backlog page means. The delivered count cannot stand
  # in for "the engine had nothing more": rows whose message cannot be
  # hydrated are omitted (not sent as nulls), so a limit-sized read can
  # deliver fewer frames than it served. A short page is therefore not
  # proof of exhaustion — only an empty one is.
  @doc false
  def next_backlog_step(%{page_count: 0}), do: :live

  def next_backlog_step(%{cursor: cursor, page_start_cursor: start}) when cursor > start,
    do: {:page, cursor - 1}

  # Rows arrived but none moved the cursor: a wall of rows sharing one
  # received millisecond. Re-reading behind it would serve the same page
  # forever, so step strictly past the wall. (A single millisecond
  # holding more than a page of posts — far beyond anything this store
  # has — would lose its overflow here; the strict read is the only way
  # forward.)
  def next_backlog_step(%{cursor: cursor}), do: {:page, cursor}

  # Opening a stream is the one signal we have for where the crawl
  # stands: backlog open → counting, live open → caught up.
  defp begin_stream(state, ref, phase) do
    state = %{state | ref: ref, phase: phase, page_count: 0, page_start_cursor: state.cursor}
    put_status(if phase == :live, do: :live, else: {:crawling, state.indexed})
    state
  end

  defp open_live_stream(%{client: client} = state) do
    case open_live(client, resume_gt(state.cursor)) do
      nil -> reconnect_soon(state, 5_000)
      ref -> {:noreply, begin_stream(state, ref, :live)}
    end
  end

  defp reconnect_soon(state, ms) do
    put_status(:reconnecting)
    Process.send_after(self(), :connect, ms)
    {:noreply, %{state | ref: nil, phase: :idle}}
  end

  @impl true
  def handle_continue(:maybe_connect, %{enabled?: true} = state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_continue(:maybe_connect, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    write_meta(state.cursor)
    stop_client(state)
    :dets.close(@table)
    :ok
  rescue
    _ -> :ok
  end
end
