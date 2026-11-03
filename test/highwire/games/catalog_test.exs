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

  describe "the order" do
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

    # What this node holds is what the room can page through: a game that
    # moved long ago is still a game on this node, and its reader should be
    # able to reach it and see it counted.
    test "nothing falls out of the order, however long ago a game moved" do
      Enum.each(1..450, &touch(:chess, "g#{&1}"))

      assert Catalog.count() == 450
      assert Enum.take(Catalog.recent(1), 1) == [{:chess, "g450"}]
      assert List.last(Catalog.recent(450)) == {:chess, "g1"}
    end
  end

  describe "paging" do
    test "a page is a slice of the order, and paging back continues it" do
      Enum.each(1..10, &touch(:chess, "g#{&1}"))

      assert Catalog.recent(4) == for(n <- 10..7//-1, do: {:chess, "g#{n}"})
      assert Catalog.recent(4, 4) == for(n <- 6..3//-1, do: {:chess, "g#{n}"})
    end

    test "past the end is empty, not an error" do
      touch(:chess, "one")

      assert Catalog.recent(10, 5) == []
    end

    test "reads work before the catalog is running" do
      assert Catalog.recent(5) == []
    end
  end
end
