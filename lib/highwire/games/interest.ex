defmodule HighWire.Games.Interest do
  @moduledoc """
  How much a game is worth this reader's time.

  A room ordered by "most recently touched" answers what changed, which is
  not the same question as what to watch. A stranger's abandoned three-move
  game and one between two people you follow sit next to each other, and the
  reader has to open both to find out which.

  So a game is scored for the identity looking at it, from what this node
  already knows:

    * **who is playing.** A game with someone you follow, or someone you
      have played, is about a person rather than two short ids.
    * **whether they have a face.** A feed with a name or a picture is
      legible at a glance; one without is a string.
    * **what the game is.** A checkmate is a game; an abandoned opening, or
      one whose log does not verify, is a row.
    * **how much of it there is.** Long games repay a look; two-ply ones do
      not.
    * **when it happened.** Everything here decays — a game from this
      afternoon is news, last month's is an archive.

  The score and the reasons behind it are returned together, because a
  ranking a reader cannot explain to themselves is a ranking they will not
  trust. Every signal is cheap: the profile read model, the viewer's follow
  list, and the games themselves.
  """

  alias HighWire.SSB.Profile

  # What each signal is worth. Lopsided on purpose: who is playing decides
  # the order between two games, and everything else decides the order among
  # strangers.
  @played 30
  @follow 14
  @named 4
  @faceless 3
  @live 12
  @checkmate 10
  @decided 6
  @draw 4
  @opening 2
  @broken 8
  @stale 3

  # Ages are measured from the game's last move.
  @hour 60 * 60 * 1000
  @day 24 * @hour
  @week 7 * @day
  @month 30 * @day
  @year 365 * @day

  @doc """
  Score one game for one viewer.

  `viewer` is `%{self_id, follows, played}`: the identity reading the room,
  the feeds it follows, and the feeds it has a game against. `follows` and
  `played` may be lists or `MapSet`s. Returns `%{score: number, reasons:
  [binary]}` with the reasons ordered by what they are worth.
  """
  @spec score(map(), map()) :: %{score: number(), reasons: [binary()]}
  def score(game, viewer) do
    follows = set(Map.get(viewer, :follows))
    played = set(Map.get(viewer, :played))
    players = players(game)

    relationship = relationship(players, follows, played)
    faces = faces(players)
    standing = standing(game)
    shape = shape(game)
    age = age(game)

    %{
      score: relationship.score + faces + standing + shape + age,
      reasons: relationship.reasons
    }
  end

  @doc """
  Games in the order this viewer should look at them, each carrying its
  `:interest` as scored above.

  Ties break on recency, then on id, so the order is the same on every
  render rather than reshuffling under the reader between updates.
  """
  @spec rank([map()], map()) :: [map()]
  def rank(games, viewer) do
    games
    |> Enum.map(&Map.put(&1, :interest, score(&1, viewer)))
    |> Enum.sort_by(&{-&1.interest.score, -(Map.get(&1, :updated_at) || 0), &1.game_id})
  end

  @doc """
  The feeds playing a game, whichever way it names them: chess keeps a
  challenger and an accepter, backgammon and the network's format keep white
  and black. Both are read, because a game from the network has both pairs.
  """
  @spec players(map()) :: [binary()]
  def players(game) do
    game
    |> Map.take([:challenger, :accepter, :white, :black])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp relationship(players, follows, played) do
    played_by = Enum.filter(players, &MapSet.member?(played, &1))
    followed = Enum.filter(players, &MapSet.member?(follows, &1))

    cond do
      played_by != [] and followed != [] ->
        %{score: @played + @follow, reasons: ["you have played them", "you follow them"]}

      played_by != [] ->
        %{score: @played, reasons: ["you have played them"]}

      followed != [] ->
        %{score: @follow, reasons: ["you follow them"]}

      true ->
        %{score: 0, reasons: []}
    end
  end

  # A player with a name or a picture is someone; without either they are a
  # short id, and two short ids playing each other is the least legible row
  # the room can show.
  defp faces(players) do
    Enum.reduce(players, 0, fn id, acc ->
      case Profile.get(id) do
        %{name: name} when is_binary(name) and name != "" -> acc + @named
        %{image: image} when is_binary(image) and image != "" -> acc + @named
        _ -> acc - @faceless
      end
    end)
  end

  # In flight is only worth something while it is in flight: a game the
  # network left mid-move five years ago still folds to `:playing`, and
  # calling that live is how an archive of them ends up above this
  # afternoon's game.
  defp standing(%{status: :playing} = game) do
    if fresh?(game, @day), do: @live, else: 0
  end

  # The network's format carries the verdict as `{kind, side}`; this node's
  # own games carry a winner instead, and the fold's error as `:broken`.
  defp standing(%{verdict: verdict}) when verdict != nil do
    case verdict_word(verdict) do
      "checkmate" -> @checkmate
      "stalemate" -> @draw
      "draw" -> @draw
      nil -> 0
      _ -> @decided
    end
  end

  defp standing(%{status: :finished, winner: winner}) when is_map(winner), do: @decided
  defp standing(%{status: :finished}), do: @decided
  defp standing(%{status: :opening}), do: @opening
  defp standing(%{status: :withdrawn}), do: 0
  # A game whose log does not verify is worth less than one that does: the
  # board on the card is the fold's best guess, not the game.
  defp standing(%{status: :broken}), do: -@broken
  defp standing(_game), do: 0

  defp verdict_word({word, _side}), do: verdict_word(word)
  defp verdict_word(word) when is_atom(word), do: Atom.to_string(word)
  defp verdict_word(word) when is_binary(word), do: word
  defp verdict_word(_verdict), do: nil

  # A game with nothing played yet is a picture of the opening position, and
  # one with forty moves is something to step through.
  defp shape(game), do: min(plies(game), 40) * 0.25

  defp plies(%{kind: :chess, turn_count: plies}) when is_integer(plies), do: plies
  defp plies(%{history: history}) when is_list(history), do: length(history)
  defp plies(_game), do: 0

  defp age(game) do
    case Map.get(game, :updated_at) do
      ts when is_integer(ts) and ts > 0 -> decay(System.system_time(:millisecond) - ts)
      _ -> 0
    end
  end

  defp decay(ms) when ms < @hour, do: 12
  defp decay(ms) when ms < @day, do: 8
  defp decay(ms) when ms < @week, do: 4
  defp decay(ms) when ms < @month, do: 1
  defp decay(ms) when ms < @year, do: 0
  defp decay(_ms), do: -@stale

  defp fresh?(game, within) do
    case Map.get(game, :updated_at) do
      ts when is_integer(ts) and ts > 0 -> System.system_time(:millisecond) - ts < within
      _ -> false
    end
  end

  defp set(nil), do: MapSet.new()
  defp set(%MapSet{} = set), do: set
  defp set(list) when is_list(list), do: MapSet.new(list)
end
