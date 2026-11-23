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

  Both directions are indexed: `of/1` answers whom a feed follows and
  blocks, `incoming/1` who follows and blocks it. The reader's standing
  with a face therefore costs one lookup rather than a scan of the whole
  graph, which is what lets every byline in a feed say what the person
  is to the reader.

  A read answers `%{follows: ids, blocked: ids}`, newest first. A feed
  whose contact messages the store has never carried reads as two empty
  lists: nothing is known about it, which is not the same as it
  following nobody.
  """

  @table __MODULE__
  @incoming HighWire.SSB.Relations.Incoming

  @type relations :: %{follows: [binary()], blocked: [binary()]}

  @typedoc """
  How the reader stands with one feed, as the four edges that can exist
  between two feeds, each independent of the others.

  The protocol keeps a follow and a block on the same pair apart, and
  either side may hold either edge, so the combinations do not all read
  as a way a person would behave — a feed can follow someone who blocks
  it, or block someone who follows it. Keeping the four bits rather than
  one word is what makes every one of those combinations representable.
  """
  @type standing :: %{
          self?: boolean(),
          follows?: boolean(),
          blocked?: boolean(),
          follows_you?: boolean(),
          blocks_you?: boolean()
        }

  @typedoc """
  The one-word reading of a `t:standing/0`, for surfaces that name the
  relationship rather than marking its edges. It is a summary, not the
  data: a feed that both follows the reader and blocks them reads as
  `:blocking` here, and `standings/2` keeps the follow.
  """
  @type state ::
          :self | :mutual | :following | :followed_by | :blocked | :blocking | :reading

  @doc """
  Create the tables when they are not up yet. The Timeline calls this from
  its init, so the writer owns them for the life of the process; reads
  against tables that are gone answer emptily.
  """
  @spec create() :: :ok
  def create do
    ensure_table(@table)
    ensure_table(@incoming)
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

        # The same row under both keys: one read walks the feed's own
        # edges, the other walks the edges aimed at it.
        true = :ets.insert(ensure_table(@table), {key, row})
        true = :ets.insert(ensure_table(@incoming), {{contact, author}, row})
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
  def of(id) when is_binary(id), do: read(@table, id)

  def of(_id), do: empty()

  @doc """
  The edges aimed at one feed: `%{follows: ids, blocked: ids}` for the
  feeds that follow and block it, each newest first. Empty when nothing
  is known.

  This is the other half of `of/1` — the reader's own list says what they
  published about someone, this says what that someone published about
  the reader — and together the two are what a standing is made of.
  """
  @spec incoming(binary() | nil) :: relations()
  def incoming(id) when is_binary(id), do: read(@incoming, id)

  def incoming(_id), do: empty()

  @doc """
  Every edge the store's contact messages name, as
  `{author, contact, :follows | :blocks}` — the shape
  `HighWire.SSB.Graph` builds its graph from.
  """
  @spec edges() :: [{binary(), binary(), :follows | :blocks}]
  def edges do
    @table
    |> :ets.tab2list()
    |> Enum.flat_map(&edge/1)
  rescue
    ArgumentError -> []
  end

  @doc """
  How the reader stands with each feed in `ids`, as `%{feed => state}`.

  The reader's own lists come from the caller: they are the payload's,
  which carry a press before the contact message does. The other side's
  is a point lookup per feed — the incoming table is keyed by the pair,
  so "does this feed follow the reader" is one lookup, not a walk of the
  reader's followers.

  Every bit is answered on its own: a follow and a block on the same
  pair are independent in the protocol and are reported independently
  here, however odd the combination reads.
  """
  @spec standings([binary()], keyword()) :: %{optional(binary()) => standing()}
  def standings(ids, opts) do
    self_id = Keyword.get(opts, :self_id)
    mine_follows = to_set(Keyword.get(opts, :follows))
    mine_blocked = to_set(Keyword.get(opts, :blocked))

    ids
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Map.new(fn id ->
      their = aimed_at_reader(self_id, id)

      {id,
       %{
         self?: id == self_id,
         follows?: MapSet.member?(mine_follows, id),
         blocked?: MapSet.member?(mine_blocked, id),
         follows_you?: their.follows?,
         blocks_you?: their.blocks?
       }}
    end)
  end

  @doc """
  `standings/2` with the reader's own edges read from the graph, for pages
  that carry no contact list of their own.
  """
  @spec standings_for([binary()], binary() | nil) :: %{optional(binary()) => standing()}
  def standings_for(ids, self_id) do
    mine = of(self_id)
    standings(ids, self_id: self_id, follows: mine.follows, blocked: mine.blocked)
  end

  @doc """
  The one-word reading of the reader's standing with one feed —
  `standings/2` for a single id, summarised. Surfaces that mark the
  edges themselves read `standings/2` directly, so no combination is
  lost to this summary.
  """
  @spec state(binary(), binary() | nil, [binary()], [binary()]) :: state()
  def state(id, self_id, follows, blocked) when is_binary(id) do
    [id]
    |> standings(self_id: self_id, follows: follows, blocked: blocked)
    |> Map.fetch!(id)
    |> summarise()
  end

  def state(_id, _self_id, _follows, _blocked), do: :reading

  # The summary a reader-facing label stands on: identity first, then a
  # block in either direction, then the follow edges. It names at most
  # one thing, which is why the marks read the bits instead.
  defp summarise(%{self?: true}), do: :self
  defp summarise(%{blocked?: true}), do: :blocked
  defp summarise(%{blocks_you?: true}), do: :blocking
  defp summarise(%{follows?: true, follows_you?: true}), do: :mutual
  defp summarise(%{follows?: true}), do: :following
  defp summarise(%{follows_you?: true}), do: :followed_by
  defp summarise(_standing), do: :reading

  # Both edges the feed published about the reader, each on its own: a
  # row naming a block may also name a follow, and the two do not cancel
  # in the store.
  defp aimed_at_reader(self_id, id) when is_binary(self_id) and is_binary(id) do
    case :ets.lookup(@incoming, {self_id, id}) do
      [{_key, row}] ->
        %{
          follows?: Map.get(row, :following) == true,
          blocks?: Map.get(row, :blocking) == true
        }

      [] ->
        %{follows?: false, blocks?: false}
    end
  rescue
    ArgumentError -> %{follows?: false, blocks?: false}
  end

  defp aimed_at_reader(_self_id, _id), do: %{follows?: false, blocks?: false}

  defp to_set(set) when is_struct(set, MapSet), do: set
  defp to_set(ids), do: ids |> List.wrap() |> MapSet.new()

  defp read(table, id) do
    case select_by_prefix(table, id) do
      [] -> empty()
      rows -> collect(rows)
    end
  rescue
    ArgumentError -> empty()
  end

  # Both tables are ordered sets keyed by the pair, so a bound first key
  # is a range scan rather than a walk of every row.
  defp select_by_prefix(table, id) do
    :ets.select(table, [{{{id, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
  end

  defp empty, do: %{follows: [], blocked: []}

  # A blocked pair is a block, whatever else its messages once said: the
  # two edges are independent in the protocol, but a feed this identity
  # has blocked is not one it follows however the older edits read.
  defp collect(rows) do
    {follows, blocked} =
      Enum.reduce(rows, {[], []}, fn
        {contact, %{blocking: true, blocking_ts: ts}}, {follows, blocked} ->
          {follows, [{ts, contact} | blocked]}

        {contact, %{following: true, following_ts: ts}}, {follows, blocked} ->
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

  defp edge({{author, contact}, row}) when is_binary(author) and is_binary(contact) do
    follows = if Map.get(row, :following) == true, do: [{author, contact, :follows}], else: []
    blocks = if Map.get(row, :blocking) == true, do: [{author, contact, :blocks}], else: []
    follows ++ blocks
  end

  defp edge(_row), do: []

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

  # Ordered sets: the pair is the key, and both reads are prefix scans of
  # one of them.
  defp ensure_table(table) do
    :ets.new(table, [
      :named_table,
      :ordered_set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    table
  rescue
    ArgumentError -> table
  end
end
