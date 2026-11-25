defmodule HighWire.CountWordsTest do
  use ExUnit.Case, async: true

  alias HighWire.CountWords

  describe "words/1" do
    test "small counts keep the words people use for them" do
      assert CountWords.words(0) == "no"
      assert CountWords.words(-3) == "no"
      assert CountWords.words(1) == "a"
      assert CountWords.words(2) == "a few"
      assert CountWords.words(9) == "several"
      assert CountWords.words(12) == "about a dozen"
      assert CountWords.words(20) == "a score of"
      assert CountWords.words(30) == "dozens of"
    end

    test "each larger band names a scale, not a figure" do
      assert CountWords.words(200) == "hundreds of"
      assert CountWords.words(1_000) == "thousands of"
      assert CountWords.words(10_000) == "tens of thousands of"
      assert CountWords.words(100_000) == "hundreds of thousands of"
      assert CountWords.words(1_000_000) == "millions of"
      assert CountWords.words(1_000_000_000) == "billions of"
    end

    test "neighbouring counts can read the same" do
      # The point of the bands: 99, 100 and 101 are all dozens.
      assert CountWords.words(99) == CountWords.words(101)
    end
  end

  describe "phrase/3" do
    test "pluralises the noun on the count" do
      assert CountWords.phrase(0, "blob") == "no blobs"
      assert CountWords.phrase(1, "blob") == "a blob"
      assert CountWords.phrase(4, "post") == "several posts"
    end

    test "takes an irregular plural" do
      assert CountWords.phrase(2, "person", "people") == "a few people"
      assert CountWords.phrase(40, "person", "people") == "dozens of people"
    end
  end
end
