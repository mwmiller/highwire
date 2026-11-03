defmodule HighWire.Games.Filter do
  @moduledoc """
  Narrowing the room to the games worth reviewing.

  The room is a room: what is waiting on you, what there is to watch, and
  what is over. Reviewing is a different question — a hundred games of
  network history is not something anybody reads top to bottom, but "the
  long games between people I follow this year" is a set you can sit with.

  A filter is four facets, each one a narrow question about a game rather
  than a free-text search:

    * **who** — `:played`, `:followed`, `:strangers`, `:mine`
    * **length** — `:short` (under ten moves), `:medium` (ten to thirty-nine),
      `:long` (forty or more)
    * **age** — `:today`, `:week`, `:month`, `:year`
    * **kind** — `:chess`, `:backgammon`

  A facet left out, or set to `:any`, does not narrow. Facets combine: every
  one that asks for something must match.

  Grouping is the other half of review: the same set read by period, by
  result, or by the room's own sections, so a run of games can be read as
  a run rather than as a list.
  """

  alias HighWire.Games.Interest

  @hour 60 * 60 * 1000
  @day 24 * @hour
  @week 7 * @day
  @month 30 * @day
  @year 365 * @day

  # What a game in one band answers to when asked about a period: an hour ago
  # is today, and this week, and this month, and this year.
  @reaches %{
    today: [:today, :week, :month, :year],
    week: [:week, :month, :year],
    month: [:month, :year],
    year: [:year],
    older: [:older],
    unknown: [:unknown]
  }

  @facets [:who, :length, :age, :kind]

  @doc "The facet names, in the order the room shows them."
  @spec facets() :: [atom()]
  def facets, do: @facets

  @doc """
  The games that match every facet that asks for something, in the order
  they arrived (callers order them by interest afterwards).
  """
  @spec apply([map()], map(), map()) :: [map()]
  def apply(games, viewer, filters) when is_list(games) and is_map(filters) do
    Enum.filter(games, fn game ->
      match?(game, viewer, Map.get(filters, :who, :any)) and
        length?(game, Map.get(filters, :length, :any)) and
        age?(game, Map.get(filters, :age, :any)) and
        kind?(game, Map.get(filters, :kind, :any))
    end)
  end

  @doc """
  Which of the four facets this game falls in for this viewer:
  `%{who: atom, length: atom, age: atom, kind: atom}`.

  The room uses the same answers to narrow, so a card's badge and a filter
  cannot disagree about what a game is.
  """
  @spec facets_of(map(), map()) :: map()
  def facets_of(game, viewer) do
    %{
      who: who(game, viewer),
      length: length_band(game),
      age: age_band(game),
      kind: kind_of(game)
    }
  end

  @doc """
  The period a game's last move falls in, as the group titles read.

  Groups partition the room — one heading per game — so each is the stretch
  before the one above it, and says so. "This week" would name a stretch that
  includes today, which already has a heading of its own.
  """
  @spec period(map()) :: binary()
  def period(game) do
    case age_band(game) do
      :today -> "Today"
      :week -> "Earlier this week"
      :month -> "Earlier this month"
      :year -> "Earlier this year"
      :older -> "Older"
      _ -> "Undated"
    end
  end

  @doc "How a game ended, as the group titles read."
  @spec result(map()) :: binary()
  def result(%{status: :broken}), do: "Does not verify"
  def result(%{status: :withdrawn}), do: "Withdrawn"
  def result(%{status: status}) when status in [:playing, :opening], do: "Unfinished"
  def result(%{verdict: {word, _side}}), do: verdict_title(word)
  def result(%{verdict: word}) when word != nil, do: verdict_title(word)
  def result(%{winner: %{}}), do: "Decided"
  def result(_game), do: "Decided"

  defp verdict_title(word) do
    case to_string(word) do
      "checkmate" -> "Checkmate"
      "stalemate" -> "Draw"
      "draw" -> "Draw"
      _ -> "Decided"
    end
  end

  # -- facets ------------------------------------------------------------

  defp match?(_game, _viewer, :any), do: true
  defp match?(game, viewer, band), do: who(game, viewer) == band

  defp who(game, viewer) do
    players = Interest.players(game)
    self_id = Map.get(viewer, :self_id)
    followed = viewers_set(viewer, :follows)
    played = viewers_set(viewer, :played)

    cond do
      is_binary(self_id) and self_id in players -> :mine
      Enum.any?(players, &MapSet.member?(played, &1)) -> :played
      Enum.any?(players, &MapSet.member?(followed, &1)) -> :followed
      true -> :strangers
    end
  end

  defp length?(game, band), do: length?(game, band, length_band(game))

  defp length?(_game, :any, _actual), do: true
  defp length?(_game, :unknown, :unknown), do: true
  defp length?(_game, band, band), do: true
  defp length?(_game, _band, _actual), do: false

  defp length_band(game) do
    case plies(game) do
      0 -> :unknown
      plies when plies < 10 -> :short
      plies when plies < 40 -> :medium
      _ -> :long
    end
  end

  defp age?(game, band), do: age?(game, band, age_band(game))

  # A period is asked about a game as a stretch of time, not as a slot: a game
  # that moved an hour ago is a game from today, and also one from this week,
  # this month and this year. Asked "this week", a room that hid today's games
  # would be answering a question nobody asked.
  defp age?(_game, :any, _actual), do: true
  defp age?(_game, band, actual), do: band in Map.get(@reaches, actual, [])

  defp age_band(game) do
    case Map.get(game, :updated_at) do
      ts when is_integer(ts) and ts > 0 -> band(System.system_time(:millisecond) - ts)
      _ -> :unknown
    end
  end

  defp band(ms) when ms < @hour, do: :today
  defp band(ms) when ms < @day, do: :today
  defp band(ms) when ms < @week, do: :week
  defp band(ms) when ms < @month, do: :month
  defp band(ms) when ms < @year, do: :year
  defp band(_ms), do: :older

  defp kind?(game, band), do: kind?(game, band, kind_of(game))

  defp kind?(_game, :any, _actual), do: true
  defp kind?(_game, band, band), do: true
  defp kind?(_game, _band, _actual), do: false

  defp kind_of(%{kind: kind}), do: kind
  defp kind_of(_game), do: :unknown

  defp plies(%{kind: :chess, turn_count: plies}) when is_integer(plies), do: plies
  defp plies(%{history: history}) when is_list(history), do: length(history)
  defp plies(%{turn_count: turns}) when is_integer(turns), do: turns
  defp plies(_game), do: 0

  defp viewers_set(viewer, key) do
    case Map.get(viewer, key) do
      nil -> MapSet.new()
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
    end
  end
end
