defmodule HighWire.SSB.Suggest do
  @moduledoc """
  "Whom to follow": feeds we do not follow, ranked by friend-of-friend
  endorsement from the store-wide contact graph.

  Discovery runs off the contact drain, not the timeline window. The
  window only holds messages from feeds already followed (plus self),
  so ranking window authors and then excluding follows leaves an empty
  pool by construction — it can never surface anyone new. The contact
  graph can: a candidate is any feed someone we follow follows, scored
  by how many of the people we follow endorse it. That social proof is
  what makes a suggestion worth acting on, and it works against any
  engine. (The engine has no `stats.whoToFollow`: the call answers
  "method not found", so ranking lives here against the drain.)

  Each row is a plain string-keyed map — `{id, followers}` — the shape
  the sidebar renders: the id keys the avatar and profile link,
  followers is how many distinct feeds in the store follow it. Rows
  without a usable id are dropped so the sidebar never renders a dead
  link.
  """

  # A sidebar is a nudge, not a directory — a few rows below Contacts
  # (which caps at 8) fits the rail without pushing it off-screen.
  @limit 5

  @doc """
  Rank the store's contact graph into suggestion rows.

  Candidates are feeds we do not follow, endorsed by at least one feed
  we do follow (friend-of-friend); self and already-followed feeds never
  appear. Endorsements only count from feeds we follow — an endorsement
  from ourselves, or from an inbound follower we do not follow, is not a
  reason to follow someone. Sorted by endorsement (how many of the feeds
  we follow follow it) desc, then total followers desc, then id, so the
  list only moves when the data does.
  """
  @spec rank([map()], [String.t()], String.t() | nil) :: [map()]
  def rank(contact_msgs, follows, self_id) do
    # The set of feeds whose endorsements carry weight: the ones we
    # follow. Self is deliberately left out of it.
    endorsers_of_followed =
      follows
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    {endorsers, followers} = graph(contact_msgs)

    # An endorsement only counts when it comes from a feed we follow —
    # a crowd of strangers vouching for a feed carries no weight here —
    # so a candidate qualifies on the strength of those endorsements
    # alone, never on the size of its total follower set. Candidates we
    # already follow (and self) are dropped outright.
    endorsers
    |> Map.reject(fn {id, _} -> id == self_id or MapSet.member?(endorsers_of_followed, id) end)
    |> Enum.map(fn {id, set} ->
      endorsement = Enum.count(set, &MapSet.member?(endorsers_of_followed, &1))

      %{
        "id" => id,
        "endorsement" => endorsement,
        "followers" => Map.get(followers, id, 0)
      }
    end)
    |> Enum.filter(fn s -> s["endorsement"] > 0 end)
    |> Enum.sort_by(fn s -> {-s["endorsement"], -s["followers"], s["id"]} end)
    |> Enum.map(&Map.take(&1, ["id", "followers"]))
    |> Enum.take(@limit)
  end

  # One follower per distinct feed that said `following: true` — a
  # follow/unfollow/follow churn must not count triple, and `false` (or
  # a missing field) is not a follow at all. `endorsers` maps each
  # contact to the set of feeds following it; `followers` is that set's
  # size — the store-wide follower count.
  defp graph(contact_msgs) do
    g =
      contact_msgs
      |> Enum.reduce(%{}, fn msg, acc ->
        c = content(msg)

        with true <- c["following"] == true,
             from when is_binary(from) <- author(msg),
             to when is_binary(to) <- c["contact"] do
          Map.update(acc, to, MapSet.new([from]), &MapSet.put(&1, from))
        else
          _ -> acc
        end
      end)

    {g, Map.new(g, fn {id, set} -> {id, MapSet.size(set)} end)}
  end

  defp author(%{"value" => %{"author" => id}}) when is_binary(id), do: id
  defp author(_msg), do: nil

  # Encrypted private messages keep their content as a string, so a row
  # of that shape can never read as a follow.
  defp content(%{"value" => %{"content" => c}}) when is_map(c), do: c
  defp content(_msg), do: %{}
end
