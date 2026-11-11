defmodule HighWire.SSB.Relations do
  @moduledoc """
  Whom each feed follows and blocks, as its own messages name it — held
  in ETS beside the Timeline so a profile can show the identity it is
  about, not only the reader's list.

  The Timeline's store-wide contact pass already reads every contact
  message in the store; it leaves the newest state of each pair here as
  it goes. One row per (author, contact) carries the two edges its
  messages have named, each with the timestamp that named it, so an
  older edit replayed by a later pass cannot overwrite a newer one.

  A read answers `%{follows: ids, blocked: ids}`, newest first. A feed
  whose contact messages the store has never carried reads as two empty
  lists: nothing is known about it, which is not the same as it
  following nobody.
  """

  @table __MODULE__

  @type relations :: %{follows: [binary()], blocked: [binary()]}

  @doc """
  Create the table when it is not up yet. The Timeline calls this from
  its init, so the writer owns the table for the life of the process;
  reads against a table that is gone answer emptily.
  """
  @spec create() :: :ok
  def create do
    ensure_table()
    :ok
  end

  @doc """
  Fold one contact message into its author's graph. Only the edges the
  message names move — an unfollow leaves the block alone, an unblock
  leaves the follow alone — and an edge older than the one already held
  is ignored.
  """
  @spec fold(map()) :: :ok
  def fold(%{"value" => %{"author" => author, "content" => content}} = msg)
      when is_binary(author) and is_map(content) do
    case content["contact"] do
      contact when is_binary(contact) ->
        ts = timestamp(msg)
        key = {author, contact}

        row =
          key
          |> row()
          |> named(:following, content["following"], ts)
          |> named(:blocking, content["blocking"], ts)

        true = :ets.insert(ensure_table(), {key, row})
        :ok

      _ ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  def fold(_msg), do: :ok

  @doc """
  The graph one feed's own messages name: `%{follows: ids, blocked: ids}`,
  each newest first.
  """
  @spec of(binary()) :: relations()
  def of(id) when is_binary(id) do
    @table
    |> :ets.match_object({{id, :_}, :_})
    |> collect()
  rescue
    ArgumentError -> empty()
  end

  def of(_id), do: empty()

  defp empty, do: %{follows: [], blocked: []}

  # A blocked pair is a block, whatever else its messages once said: the
  # two edges are independent in the protocol, but a feed this identity
  # has blocked is not one it follows however the older edits read.
  defp collect(rows) do
    {follows, blocked} =
      Enum.reduce(rows, {[], []}, fn
        {{_author, contact}, %{blocking: true, blocking_ts: ts}}, {follows, blocked} ->
          {follows, [{ts, contact} | blocked]}

        {{_author, contact}, %{following: true, following_ts: ts}}, {follows, blocked} ->
          {[{ts, contact} | follows], blocked}

        _row, acc ->
          acc
      end)

    %{follows: newest(follows), blocked: newest(blocked)}
  end

  defp newest(rows) do
    rows
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.map(&elem(&1, 1))
    |> Enum.uniq()
  end

  defp row(key) do
    case :ets.lookup(@table, key) do
      [{^key, row}] when is_map(row) -> normalize(row)
      _ -> new_row()
    end
  rescue
    ArgumentError -> new_row()
  end

  defp new_row, do: %{following: nil, following_ts: 0, blocking: nil, blocking_ts: 0}

  defp normalize(row) do
    %{
      following: Map.get(row, :following),
      following_ts: Map.get(row, :following_ts, 0),
      blocking: Map.get(row, :blocking),
      blocking_ts: Map.get(row, :blocking_ts, 0)
    }
  end

  # An edge a message does not carry stays as it is; one it carries takes
  # the message's timestamp, unless the edge already holds a newer one.
  defp named(row, _field, value, _ts) when not is_boolean(value), do: row

  defp named(row, field, value, ts) do
    if Map.get(row, :"#{field}_ts", 0) > ts do
      row
    else
      row
      |> Map.put(field, value)
      |> Map.put(:"#{field}_ts", ts)
    end
  end

  defp timestamp(%{"value" => %{"timestamp" => ts}}) when is_number(ts), do: round(ts)
  defp timestamp(_msg), do: 0

  defp ensure_table do
    :ets.new(@table, [:named_table, :public, read_concurrency: true, write_concurrency: true])
    @table
  rescue
    ArgumentError -> @table
  end
end
