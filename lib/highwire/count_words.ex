defmodule HighWire.CountWords do
  @moduledoc """
  Counts said in words.

  A number on the page asks the reader to weigh it, and past a handful
  the exact figure is not what they came for — they want to know whether
  a thing is small, busy or vast. These are the words people reach for
  when they do not have the figure to hand: a few, several, a dozen, a
  score, dozens, hundreds, thousands, millions. Each band is coarse on
  purpose; two counts that read the same are, for reading, the same.

  Precision is not banned, it is just not the default. A figure stays
  a figure where the number is the thing itself — bytes on disk,
  addresses to suppress, pieces on a board, a shelf of a dozen games
  you are working through — and in any list short enough to count at a
  glance. These words are for volume, where the exact figure asks the
  reader for arithmetic they never wanted to do.

  And sometimes the right answer is none at all: things being numerous
  does not make them interesting, so where the things are already on the
  screen and nothing hangs on the total, the count is simply left out.
  """

  @doc """
  The quantity in words, without a noun: `"no"`, `"a"`, `"a few"`,
  `"several"`, `"a dozen"`, `"about a dozen"`, `"a score of"`, `"dozens of"`,
  `"hundreds of"`, `"thousands of"`, `"tens of thousands of"`,
  `"hundreds of thousands of"`, `"millions of"`, `"billions of"`.

  The trailing "of" is there so a noun can follow directly; the bands
  with none read as a quantity on their own.

      iex> HighWire.CountWords.words(4)
      "several"

      iex> HighWire.CountWords.words(12)
      "a dozen"

      iex> HighWire.CountWords.words(120)
      "dozens of"
  """
  def words(count) when count <= 0, do: "no"
  def words(1), do: "a"
  def words(count) when count <= 3, do: "a few"
  def words(count) when count <= 9, do: "several"
  # Exactly a dozen needs no hedge; the band above it is the guess.
  def words(12), do: "a dozen"
  def words(count) when count <= 19, do: "about a dozen"
  def words(count) when count <= 29, do: "a score of"
  def words(count) when count <= 199, do: "dozens of"
  def words(count) when count <= 999, do: "hundreds of"
  def words(count) when count <= 9_999, do: "thousands of"
  def words(count) when count <= 99_999, do: "tens of thousands of"
  def words(count) when count <= 999_999, do: "hundreds of thousands of"
  def words(count) when count <= 999_999_999, do: "millions of"
  def words(_count), do: "billions of"

  @doc """
  The quantity with `more` after it, for a sentence that carries on:
  `"one more"`, `"a few more"`, `"several more"`, `"a dozen
  more"`, `"about a dozen more"`, `"a score more"`, `"dozens more"`,
  `"hundreds more"`.

  `words/1` answers how many, and its noun follows; this answers how many
  others, and no noun does. The larger bands say "of" because a noun comes
  next — "dozens of replies" — so that "of" is dropped here, where the
  next word is "more".

      iex> HighWire.CountWords.more(4)
      "several more"

      iex> HighWire.CountWords.more(59)
      "dozens more"
  """
  def more(count) do
    case words(count) do
      "a" -> "one more"
      quantity -> String.replace_suffix(quantity, " of", "") <> " more"
    end
  end

  @doc """
  The quantity with its noun, pluralised for the count. Pass the plural
  when the noun does not simply take an `s`.

      iex> HighWire.CountWords.phrase(0, "reply", "replies")
      "no replies"

      iex> HighWire.CountWords.phrase(1, "reply", "replies")
      "a reply"

      iex> HighWire.CountWords.phrase(2, "person", "people")
      "a few people"
  """
  def phrase(count, one, many \\ nil) do
    many = many || one <> "s"
    "#{words(count)} #{if count == 1, do: one, else: many}"
  end
end
