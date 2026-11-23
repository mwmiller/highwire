defmodule HighWire.SSB.GraphTest do
  use ExUnit.Case, async: true

  # The graph module under test, aliased away from `Graph` so the
  # library's own reads in these assertions stay unambiguous.
  alias HighWire.SSB.Graph, as: Net

  @a "@a.ed25519"
  @b "@b.ed25519"
  @c "@c.ed25519"
  @d "@d.ed25519"

  defp graph do
    Net.from_edges([
      {@a, @b, :follows},
      {@c, @a, :follows},
      {@c, @b, :follows},
      {@d, @c, :follows}
    ])
  end

  describe "around/3" do
    test "keeps the feeds within each hop, edges and all" do
      one = Net.around(@a, 1, graph())
      assert Enum.sort(Graph.vertices(one)) == Enum.sort([@a, @b, @c])
      assert Enum.sort(edges(one)) == Enum.sort([{@a, @b}, {@c, @a}, {@c, @b}])

      two = Net.around(@a, 2, graph())
      assert Enum.sort(Graph.vertices(two)) == Enum.sort([@a, @b, @c, @d])
    end

    test "depth zero is the feed alone, and an unknown feed is no graph" do
      assert Graph.vertices(Net.around(@a, 0, graph())) == [@a]
      assert Graph.vertices(Net.around("@nobody.ed25519", 2, graph())) == []
    end
  end

  describe "path/3" do
    test "follows the published direction, and stops where it stops" do
      assert Net.path(@a, @b, graph()) == [@a, @b]
      assert Net.path(@c, @b, graph()) == [@c, @b]
      assert Net.path(@a, @c, graph()) == nil
      assert Net.path(@a, @d, graph()) == nil
    end

    test "an id the graph does not hold has no path" do
      assert Net.path("@nobody.ed25519", @b, graph()) == nil
    end
  end

  describe "per-feed reads" do
    test "followers and following are the two ends of the follows edges" do
      assert Net.followers(@b, graph()) |> Enum.sort() == [@a, @c]
      assert Net.following(@c, graph()) |> Enum.sort() == [@a, @b]
      assert Net.following(@b, graph()) == []
    end

    test "a pair naming both edges keeps both, each a label of its own" do
      graph = Net.from_edges([{@a, @b, :follows}, {@a, @b, :blocks}])

      assert Net.followers(@b, graph) == [@a]
      assert Net.blocked_by(@b, graph) == [@a]

      labels = Enum.map(Graph.edges(graph), &{&1.v1, &1.v2, &1.label})
      assert Enum.sort(labels) == [{@a, @b, :blocks}, {@a, @b, :follows}]
    end
  end

  describe "hubs/1" do
    test "ranks feeds by how many stored follows name them" do
      assert Net.hubs(graph: graph(), limit: 2) == [{@b, 2}, {@a, 1}]
    end
  end

  defp edges(graph), do: Enum.map(Graph.edges(graph), &{&1.v1, &1.v2})
end
