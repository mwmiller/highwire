defmodule HighWire.Games.CatalogTest do
  use ExUnit.Case, async: false

  alias HighWire.Games.Catalog

  setup do
    Catalog.clear()
    :ok
  end

  # Touches are casts; a reader that wants its own writes waits for them.
  defp touch(kind, id) do
    Catalog.touch(kind, id)
    Catalog.flush()
  end

  test "the newest touch comes first" do
    touch(:chess, "one")
    touch(:chess, "two")

    assert Catalog.recent(10) == [{:chess, "two"}, {:chess, "one"}]
  end

  test "touching a game again moves it to the front without duplicating it" do
    touch(:chess, "one")
    touch(:chess, "two")
    touch(:chess, "one")

    assert Catalog.recent(10) == [{:chess, "one"}, {:chess, "two"}]
    assert Catalog.count() == 2
  end

  test "kinds are independent" do
    touch(:chess, "same")
    touch(:chess_legacy, "same")

    assert Catalog.recent(10) == [{:chess_legacy, "same"}, {:chess, "same"}]
  end

  test "a page is a window of the order, and paging back continues it" do
    Enum.each(1..10, &touch(:chess, "g#{&1}"))

    assert Catalog.recent(4) == for(n <- 10..7//-1, do: {:chess, "g#{n}"})
    assert Catalog.recent(4, 4) == for(n <- 6..3//-1, do: {:chess, "g#{n}"})
  end

  test "past the end is empty, not an error" do
    touch(:chess, "one")

    assert Catalog.recent(10, 5) == []
  end

  test "the window is bounded: the oldest fall out, the stores keep them" do
    Enum.each(1..450, &touch(:chess, "g#{&1}"))

    assert Catalog.count() == 400
    assert Enum.take(Catalog.recent(1), 1) == [{:chess, "g450"}]
    refute Enum.any?(Catalog.recent(400), &match?({:chess, "g1"}, &1))
  end

  test "reads work before the catalog is running" do
    assert Catalog.recent(5) == []
  end
end
