defmodule HighWire.Backgammon.NotationTest do
  use ExUnit.Case, async: true

  alias HighWire.Backgammon.Notation

  doctest Notation

  describe "move/2" do
    test "renders point to point" do
      assert Notation.move(24, 18) == "24/18"
      assert Notation.move(13, 8) == "13/8"
      assert Notation.move(1, 1) == "1/1"
    end

    test "renders bar entry" do
      assert Notation.move(:bar, 20) == "bar/20"
      assert Notation.move(:bar, 24) == "bar/24"
    end

    test "renders bear off" do
      assert Notation.move(6, :off) == "6/off"
      assert Notation.move(1, :off) == "1/off"
    end

    test "renders bar to off" do
      assert Notation.move(:bar, :off) == "bar/off"
    end
  end

  describe "turn/1" do
    test "renders multiple moves space-separated" do
      assert Notation.turn([{13, 8}, {13, 8}]) == "13/8 13/8"
    end

    test "renders a single move" do
      assert Notation.turn([{6, :off}]) == "6/off"
    end

    test "handles mixed tuple and string moves" do
      assert Notation.turn([{24, 18}, "6/off"]) == "24/18 6/off"
    end

    test "empty turn renders empty string" do
      assert Notation.turn([]) == ""
    end
  end

  describe "point_name/1" do
    test "names numbered points" do
      assert Notation.point_name(13) == "13-point"
      assert Notation.point_name(24) == "24-point"
      assert Notation.point_name(1) == "1-point"
    end

    test "names bar and off" do
      assert Notation.point_name(:bar) == "bar"
      assert Notation.point_name(:off) == "off the board"
    end
  end
end
