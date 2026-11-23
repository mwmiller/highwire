defmodule HighWire.SSB.Graph do
  @moduledoc """
  The follow and block graph the store's contact messages describe, as a
  `Graph` — every feed a vertex, every follow and block a directed edge
  labelled `:follows` or `:blocks` — for exploring the network by hand.

  The graph is not a second copy of the data: `build/0` derives it from
  `HighWire.SSB.Relations`, whose tables keep each pair's newest state
  for the life of the node, so what is explored is the graph the store
  reads now. A pair whose messages name both edges carries both, one
  label each — the protocol keeps the edges independent — while the
  relation reads (`of/1`, `incoming/1`) answer with the block, because a
  feed this identity has blocked is not one it follows however the older
  edits read.

  `around/2` is an ego network — the edges reachable in either direction,
  which is how a feed sits among its neighbours rather than only along
  the reader's own follows. `path/3` follows edges in their published
  direction, so it answers who can see whom. `hubs/1`, `followers/1`,
  `following/1` and `blocked_by/1` are the ranked and per-feed reads.

  For an IEx session on a running node:

      graph = HighWire.SSB.Graph.build()
      HighWire.SSB.Graph.around(HighWire.Timeline.viewer().self_id, 2)
      HighWire.SSB.Graph.hubs(graph: graph, limit: 20)
  """

  alias HighWire.SSB.{Profile, Relations}

  @type edge :: {binary(), binary(), :follows | :blocks}

  @doc """
  The whole graph as the store's contact edges read now.
  """
  @spec build() :: Graph.t()
  def build, do: from_edges(Relations.edges())

  @doc """
  A graph from an explicit edge list — the same shape `Relations.edges/0`
  answers. Building from edges rather than the store is what makes a
  small graph (a test's, a saved sample) explorable on its own.
  """
  @spec from_edges([edge()]) :: Graph.t()
  def from_edges(edges) when is_list(edges) do
    Enum.reduce(edges, Graph.new(type: :directed), fn
      {from, to, kind}, graph when is_binary(from) and is_binary(to) ->
        graph
        |> Graph.add_vertex(from)
        |> Graph.add_vertex(to)
        |> Graph.add_edge(from, to, label: kind)

      _edge, graph ->
        graph
    end)
  end

  @doc """
  The ego network around `id`: every vertex within `depth` hops of it,
  following and blocking edges in either direction, with the edges among
  them kept.

  Depth 0 is the feed alone; a feed the graph does not hold reads as an
  empty graph.
  """
  @spec around(binary(), pos_integer() | 0, Graph.t()) :: Graph.t()
  def around(id, depth \\ 2, graph \\ build())

  def around(id, 0, graph) do
    if Graph.has_vertex?(graph, id), do: Graph.subgraph(graph, [id]), else: Graph.new()
  end

  def around(id, depth, graph) when is_integer(depth) and depth > 0 do
    if Graph.has_vertex?(graph, id) do
      Graph.subgraph(graph, reach(graph, MapSet.new([id]), [id], depth))
    else
      Graph.new(type: :directed)
    end
  end

  @doc """
  A shortest chain of follows and blocks from `from` to `to`, in the
  direction the edges were published, or nil when there is none — two
  feeds with no chain between them, or an id the graph does not hold.
  """
  @spec path(binary(), binary(), Graph.t()) :: [binary()] | nil
  def path(from, to, graph \\ build()) do
    if Graph.has_vertex?(graph, from) and Graph.has_vertex?(graph, to) do
      Graph.get_shortest_path(graph, from, to)
    end
  end

  @doc "The feeds that follow `id` — the `:follows` edges aimed at it."
  @spec followers(binary(), Graph.t()) :: [binary()]
  def followers(id, graph \\ build()), do: sources(graph, id, :follows)

  @doc "The feeds `id` follows."
  @spec following(binary(), Graph.t()) :: [binary()]
  def following(id, graph \\ build()), do: targets(graph, id, :follows)

  @doc "The feeds that block `id`."
  @spec blocked_by(binary(), Graph.t()) :: [binary()]
  def blocked_by(id, graph \\ build()), do: sources(graph, id, :blocks)

  @doc """
  The most-followed feeds, `[{feed, follower_count}]`, largest first. The
  count is of follows the store holds, not of the far side's claims: a
  hub here is a feed many of the stored contact messages name.
  """
  @spec hubs(keyword()) :: [{binary(), pos_integer()}]
  def hubs(opts \\ []) do
    graph = Keyword.get_lazy(opts, :graph, &build/0)
    limit = Keyword.get(opts, :limit, 10)

    graph
    |> Graph.edges()
    |> Enum.filter(&(&1.label == :follows))
    |> Enum.frequencies_by(& &1.v2)
    |> Enum.sort_by(fn {feed, count} -> {-count, feed} end)
    |> Enum.take(limit)
  end

  @doc """
  A feed's name as the app shows it — the alias the read model holds, or
  the key's short form.
  """
  @spec name(binary()) :: binary()
  def name(id) when is_binary(id), do: Profile.display_name(id)

  defp reach(_graph, seen, _frontier, 0), do: seen

  defp reach(graph, seen, frontier, depth) do
    next =
      frontier
      |> Enum.flat_map(&neighbours(graph, &1))
      |> MapSet.new()
      |> MapSet.difference(seen)
      |> MapSet.to_list()

    reach(graph, MapSet.union(seen, MapSet.new(next)), next, depth - 1)
  end

  defp neighbours(graph, id) do
    Graph.out_neighbors(graph, id) ++ Graph.in_neighbors(graph, id)
  end

  defp sources(graph, id, kind) do
    for %{v1: from, v2: ^id, label: ^kind} <- Graph.edges(graph), do: from
  end

  defp targets(graph, id, kind) do
    for %{v1: ^id, v2: to, label: ^kind} <- Graph.edges(graph), do: to
  end
end
