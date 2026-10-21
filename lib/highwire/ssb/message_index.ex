defmodule HighWire.SSB.MessageIndex do
  @moduledoc """
  The store's honoured tombstones and edit targets, kept in a local
  DETS file and mirrored in ETS for reads.

  Two kinds of message change another message after the fact, and both
  arrive outside the per-feed windows the timeline renders from:

    * a **tombstone** (`{"type" => "delete", "dest" => key}`) asks its
      readers to drop a message. Only the message's own author can ask
      that — a delete from anyone else is not honoured — so the index
      keeps the author alongside the key to make that check possible.

    * an **edit** (`{"type" => "post-edit", "revisionRoot" => key}`)
      revises a post. Edits are already threaded in-window, but an edit
      of a post that has since aged out of the window has nothing to
      thread under; the index keeps the edit's target and that target's
      thread root so the row still lands in the right conversation.

  Both are keyed by the message they act on, so the render path asks one
  question per message it is about to show. The DETS file is the durable
  copy; reads come from an ETS mirror so a render never queues behind
  disk.

  The file also carries a received-time cursor per drain type, so the
  store is walked once — on the first run — and every pass afterwards
  resumes from the last message the index saw. That is what keeps a
  heartbeat from re-walking hundreds of thousands of messages to
  re-learn facts already on disk.
  """

  use GenServer

  require Logger

  @table :highwire_message_index
  @mirror :highwire_message_index_mirror

  @type feed_id :: binary()

  @doc "Start the index. `:path` overrides the DETS file (tests)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Records tombstones. Each entry is `{deleted_key, deleter_id}` — the
  author of the tombstone, kept so a delete from someone other than the
  message's author can be rejected when it is consulted.
  """
  @spec record_deletes([{binary(), feed_id()}]) :: :ok
  def record_deletes(entries), do: GenServer.call(__MODULE__, {:deletes, entries}, 5_000)

  @doc """
  Records edits. Each entry is `{edit_key, target_key, thread_root}`;
  `thread_root` is the conversation the target belongs to, resolved while
  the target is still in view.
  """
  @spec record_edits([{binary(), binary(), binary() | nil}]) :: :ok
  def record_edits(entries), do: GenServer.call(__MODULE__, {:edits, entries}, 5_000)

  @doc """
  The id of the author whose tombstone names `key`, or nil when `key`
  has no tombstone. The caller compares it to the message's own author:
  a tombstone only counts against a message its author wrote.
  """
  @spec deleted_by(binary()) :: feed_id() | nil
  def deleted_by(key) do
    case lookup({:deleted, key}) do
      {:deleted, author} -> author
      _ -> nil
    end
  end

  @doc "The conversation an edit of `key` belongs to, or nil when unknown."
  @spec edit_thread_root(binary()) :: binary() | nil
  def edit_thread_root(key) do
    case lookup({:edit, key}) do
      {:edit, root} -> root
      _ -> nil
    end
  end

  @doc """
  The received-time cursor for a drain `type` (`"delete"`/`"post-edit"`):
  the highest envelope timestamp the index has recorded, or nil when it
  has recorded none.

  The drain passes it as `gt` on the next open, so the engine's snapshot
  carries only what arrived since — the whole store is walked once, on
  the first pass, and every restart afterwards resumes from here.
  """
  @spec cursor(binary()) :: integer() | nil
  def cursor(type) do
    case lookup({:cursor, type}) do
      {:cursor, ts} when is_integer(ts) -> ts
      _ -> nil
    end
  end

  @doc """
  Advances the cursor for `type` to `ts`, if `ts` is newer than what is
  recorded. The drains call this with the received time of every item
  they fold, so a restart resumes from the last message seen.
  """
  @spec advance_cursor(binary(), integer()) :: :ok
  def advance_cursor(type, ts) when is_binary(type) and is_integer(ts) do
    GenServer.call(__MODULE__, {:cursor, type, ts}, 5_000)
  end

  def advance_cursor(_type, _ts), do: :ok

  @doc false
  def clear do
    GenServer.call(__MODULE__, :clear, 5_000)
  end

  # Reads go to the ETS mirror; a miss (or the index not running) reads
  # as "nothing known", which is the safe default for every caller.
  defp lookup(key) do
    case :ets.lookup(@mirror, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, dets_path())
    File.mkdir_p!(Path.dirname(path))

    :ets.new(@mirror, [:named_table, :set, :protected, read_concurrency: true])

    case :dets.open_file(@table, [
           {:file, String.to_charlist(path)},
           {:type, :set},
           {:keypos, 1},
           {:repair, true},
           {:access, :read_write}
         ]) do
      {:ok, @table} ->
        seed_mirror()
        {:ok, %{path: path}}

      {:error, reason} ->
        Logger.error("message index: cannot open #{inspect(path)}: #{inspect(reason)}")
        {:ok, %{path: path, disabled?: true}}
    end
  end

  @impl true
  def handle_call({:deletes, entries}, _from, state) do
    entries = Enum.filter(entries, fn {k, a} -> is_binary(k) and is_binary(a) end)
    write(state, Enum.map(entries, fn {k, a} -> {{:deleted, k}, {:deleted, a}} end))
    {:reply, :ok, state}
  end

  def handle_call({:edits, entries}, _from, state) do
    rows =
      entries
      |> Enum.filter(fn {edit, target, _root} -> is_binary(edit) and is_binary(target) end)
      |> Enum.map(fn {_edit, target, root} -> {{:edit, target}, {:edit, root}} end)

    write(state, rows)
    {:reply, :ok, state}
  end

  def handle_call({:cursor, type, ts}, _from, state) do
    row = {{:cursor, type}, {:cursor, ts}}

    case lookup({:cursor, type}) do
      {:cursor, current} when is_integer(current) and current >= ts ->
        :ok

      _ ->
        write(state, [row])
    end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@mirror)
    if not Map.get(state, :disabled?, false), do: :dets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  defp write(%{disabled?: true}, _rows), do: :ok

  defp write(_state, []), do: :ok

  defp write(_state, rows) do
    :ets.insert(@mirror, rows)
    :dets.insert(@table, rows)
    :ok
  end

  defp seed_mirror do
    :dets.foldl(
      fn {key, value}, _ ->
        :ets.insert(@mirror, {key, value})
        :ok
      end,
      :ok,
      @table
    )
  end

  defp dets_path, do: Path.join([HighWire.home_dir(), ".ssberl", "message-index.dets"])

  # -- message shapes ----------------------------------------------------

  @doc """
  The tombstone a message carries: `{deleted_key, deleter_id}`, or nil
  when the message is not a tombstone. `dest` may name a message; a feed
  id or a blank is not one this index honours.
  """
  @spec tombstone(map()) :: {binary(), feed_id()} | nil
  def tombstone(msg) do
    content = content_of(msg)
    dest = content["dest"]
    author = value_of(msg)["author"]

    if content["type"] == "delete" and is_binary(dest) and is_binary(author) and msg_key?(dest) do
      {dest, author}
    end
  end

  @doc """
  The edit a message carries: `{edit_key, target_key}`, or nil when the
  message is not an edit. `revisionRoot` is the protocol's own pointer;
  `revisionBranch`, `root`, and `branch` cover clients that set only one.
  """
  @spec edit(map()) :: {binary(), binary()} | nil
  def edit(msg) do
    content = content_of(msg)
    edit_key = msg["key"]

    if content["type"] == "post-edit" and is_binary(edit_key) do
      target =
        [content["revisionRoot"], content["revisionBranch"], content["root"], content["branch"]]
        |> Enum.find(&msg_key?/1)

      if target, do: {edit_key, target}
    end
  end

  defp content_of(%{"value" => %{"content" => c}}) when is_map(c), do: c
  defp content_of(_), do: %{}

  @doc """
  Whether an item from a live `messagesByType` stream is the `{sync: true}`
  sentinel that closes the backlog — not a message, and not something to
  fold. Every other shape the drains should see is a message.
  """
  @spec sentinel?(term()) :: boolean()
  def sentinel?(%{"sync" => true}), do: true
  def sentinel?(_), do: false

  defp value_of(%{"value" => v}) when is_map(v), do: v
  defp value_of(_), do: %{}

  defp msg_key?(<<"%", _::binary>> = id), do: String.ends_with?(id, ".sha256")
  defp msg_key?(_), do: false
end
