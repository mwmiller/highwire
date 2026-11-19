defmodule HighWire.BlobIndex do
  @moduledoc """
  A durable index of the engine's blob store.

  The store is content-addressed files, tens of thousands of them, and
  answering "what is in it" by opening every file per page load is a
  full sweep every time. This index crawls the store once, in small
  throttled chunks — a couple of hundred files, a short pause, repeat —
  and keeps the result in DETS so a restart starts from what was already
  learned. Files are content-addressed and never rewritten, so a sweep
  only has to look at names it has not seen.

  What each blob is comes from its first bytes; the post that carried it
  — its key, author and opening words — comes from the search index,
  read once per sweep. Reads are served from `:persistent_term`, so a
  page is a lookup rather than work.
  """

  use GenServer
  require Logger

  alias HighWire.{Blob, SearchIndex}

  @table :highwire_blob_index

  # Reading a header is an open and a read per blob; a few readers and a
  # short pause turn the first sweep from a minute into a handful of
  # seconds, and a restart only has new names to look at anyway.
  @chunk 500
  @pause 25
  @workers 4
  @rescan 10 * 60 * 1000

  @ref ~r/&[A-Za-z0-9+\/]{43}={0,2}\.sha256/
  @image ~r/!\[[^\]]*\]\([^)]*\)/
  @link ~r/\[([^\]]*)\]\([^)]*\)/
  @fence ~r/~{3,}/

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Make sure the indexer is running. It is a supervised child in a normal
  boot; a hot-reloaded dev app has the module without the process, and
  the page's first visit is the natural moment to start it.
  """
  def ensure_started do
    if Process.whereis(__MODULE__) do
      :ok
    else
      case Supervisor.start_child(HighWire.Supervisor, {__MODULE__, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        {:error, :already_present} -> Supervisor.restart_child(HighWire.Supervisor, __MODULE__)
        {:error, _reason} -> :ok
      end
    end
  end

  @doc "Every indexed blob, newest arrival first."
  def rows, do: get(:rows, [])

  @doc """
  Blob ref → the post that carried it: `%{key, author, text, ts}`, where
  `text` is the post's opening words with the markdown and refs taken
  out, so a row can say what the blob is rather than only its digest.
  """
  def parents, do: get(:parents, %{})

  @doc "How many blobs there are, overall and by kind."
  def counts, do: get(:counts, %{all: 0, image: 0, audio: 0, video: 0, file: 0})

  @doc "`:ready`, or `:indexing` while the first sweep is still running."
  def status, do: get(:status, :indexing)

  defp get(key, default) do
    :persistent_term.get({__MODULE__, key}, default)
  rescue
    _ -> default
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    rows = load()
    publish(rows)
    if rows == [], do: put(:status, :indexing)
    Process.send_after(self(), :sweep, 1_000)

    {:ok, %{rows: rows, sweeping: false}}
  end

  @impl true
  def handle_info(:sweep, %{sweeping: false} = state) do
    parent = self()
    Task.start(fn -> send(parent, {:swept, sweep(state.rows)}) end)
    {:noreply, %{state | sweeping: true}}
  end

  def handle_info(:sweep, state), do: {:noreply, state}

  def handle_info({:swept, rows}, state) do
    publish(rows)
    broadcast()
    Process.send_after(self(), :sweep, @rescan)
    {:noreply, %{state | rows: rows, sweeping: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp broadcast do
    Phoenix.PubSub.broadcast(HighWire.PubSub, topic(), :updated)
  rescue
    _ -> :ok
  end

  @doc "Pages subscribe here to redraw when a sweep finishes."
  def topic, do: "blobs:index"

  # -- the sweep ---------------------------------------------------------

  defp sweep(known) do
    paths = Blob.store_root() |> Path.join("*/*") |> Path.wildcard()
    live = paths |> Enum.map(&hex_of/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
    known_hex = MapSet.new(known, & &1.hex)

    new_rows =
      paths
      |> Enum.flat_map(&fresh(&1, known_hex))
      |> Enum.chunk_every(@chunk)
      |> Enum.reduce([], fn chunk, acc ->
        rows =
          chunk
          |> Task.async_stream(fn {hex, path} -> row(hex, path) end,
            max_concurrency: @workers,
            ordered: false,
            timeout: 10_000
          )
          |> Enum.flat_map(fn
            {:ok, rows} -> rows
            _skipped -> []
          end)

        :dets.insert(@table, Enum.map(rows, &row_record/1))
        Process.sleep(@pause)
        [rows | acc]
      end)
      |> Enum.reverse()
      |> List.flatten()

    # A blob's file never changes, but it can go; a row whose bytes are no
    # longer on disk is not something the list should offer.
    rows = Enum.filter(known ++ new_rows, &MapSet.member?(live, &1.hex))
    :dets.sync(@table)

    # The parent map is the one expensive read (the whole search index),
    # so it is only rebuilt when the store gained something to place — or
    # when the rows it holds predate what a row now says about its post.
    if new_rows != [] or known == [] or parents_stale?(), do: put_parents(parent_map())
    put_status(:ready)
    rows
  rescue
    e ->
      Logger.warning("blob index sweep failed: #{Exception.message(e)}")
      known
  end

  # A store file the sweep has not seen yet, as the pair its row wants;
  # anything already known, or not a store file at all, adds nothing.
  defp fresh(path, known_hex) do
    hex = hex_of(path)

    if is_nil(hex) or MapSet.member?(known_hex, hex), do: [], else: [{hex, path}]
  end

  # One store file → one row. The store name is the digest in minimal
  # hex, so the ref pads the dropped leading zeros back on.
  defp row(hex, path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        [
          %{
            hex: hex,
            ref: Blob.ref_from_hex(hex),
            kind: Blob.file_kind(path),
            size: size,
            mtime: mtime
          }
        ]

      _ ->
        []
    end
  end

  defp hex_of(path) do
    name = Path.basename(Path.dirname(path)) <> Path.basename(path)

    if name != "" and String.match?(name, ~r/\A[0-9A-Fa-f]+\z/) do
      hex = name |> String.pad_leading(64, "0") |> String.downcase()
      if byte_size(hex) == 64, do: hex
    end
  end

  defp row_record(row), do: {row.hex, row.ref, row.kind, row.size, row.mtime}

  # Which post carried which blob: the search index read once per sweep,
  # newest post kept when several point at the same bytes. The author and
  # the post's words ride along, because a digest alone says nothing about
  # what the blob is or where it came from.
  defp parent_map do
    SearchIndex.fold_posts(%{}, fn {key, author, text, ts}, acc ->
      case text do
        body when is_binary(body) ->
          entry = {key, author, excerpt(body), ts}

          body
          |> then(&Regex.scan(@ref, &1))
          |> List.flatten()
          |> Enum.reduce(acc, &put_ref(&1, entry, &2))

        _no_text ->
          acc
      end
    end)
    |> Map.new(fn {ref, {key, author, excerpt, ts}} ->
      {ref, %{key: key, author: author, text: excerpt, ts: ts}}
    end)
  end

  # One post's claim on one blob: the newest post wins when several
  # point at the same bytes.
  defp put_ref(ref, {_key, _author, _excerpt, ts} = entry, acc) do
    case acc do
      %{^ref => {_, _, _, seen}} when seen >= ts -> acc
      _ -> Map.put(acc, ref, entry)
    end
  end

  # The post's opening words as a reader would say them: the pictures it
  # carries are dropped along with their refs (the row is already about a
  # blob — repeating the opaque key is what this replaces), and the run of
  # whitespace markdown leaves behind becomes one space.
  defp excerpt(text) do
    text
    |> String.replace(@image, " ")
    |> String.replace(@ref, " ")
    |> String.replace(@link, "\\1")
    |> String.replace(@fence, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, 160)
  end

  # A map of bare post keys is what a sweep wrote before rows carried
  # their post's author and words; the store has not changed, so the map
  # is simply read again.
  defp parents_stale? do
    parents()
    |> Map.values()
    |> Enum.any?(&(not is_map(&1)))
  end

  # -- storage -----------------------------------------------------------

  defp load do
    case open() do
      :ok ->
        :dets.foldl(
          fn {hex, ref, kind, size, mtime}, acc ->
            [%{hex: hex, ref: ref, kind: kind, size: size, mtime: mtime} | acc]
          end,
          [],
          @table
        )

      {:error, reason} ->
        Logger.warning("blob index could not open its table: #{inspect(reason)}")
        []
    end
  end

  defp open do
    case :dets.open_file(@table, [
           {:file, String.to_charlist(dets_path())},
           {:type, :set},
           {:keypos, 1},
           {:repair, true},
           {:access, :read_write}
         ]) do
      {:ok, @table} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dets_path, do: Path.join(HighWire.home_dir(), "blob-index.dets")

  defp publish(rows) do
    rows = Enum.sort_by(rows, & &1.mtime, :desc)
    put(:rows, rows)
    put(:counts, counts_of(rows))
    put(:status, :ready)
  end

  defp counts_of(rows) do
    base = %{all: length(rows), image: 0, audio: 0, video: 0, file: 0}

    Enum.reduce(rows, base, fn row, acc ->
      Map.update!(acc, row.kind, &(&1 + 1))
    end)
  end

  defp put(key, value), do: :persistent_term.put({__MODULE__, key}, value)

  defp put_parents(parents), do: put(:parents, parents)

  defp put_status(:ready), do: put(:status, :ready)
end
