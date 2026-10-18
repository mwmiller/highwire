defmodule HighWire.SSB.Suggest do
  @moduledoc """
  "Whom to follow": feeds we do not follow, ranked by friend-of-friend
  endorsement from the store-wide contact graph.

  Discovery runs off the contact drain, not the timeline window. The
  contact graph can: a candidate is any feed someone we follow follows,
  scored by how many of the people we follow endorse it. That social
  proof is what makes a suggestion worth acting on, and it works against
  any engine. (The engine has no `stats.whoToFollow`: the call answers
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
  appear. Endorsements only count from feeds we follow. Sorted by
  endorsement desc, then total followers desc, then id for
  determinism; the final list is shuffled by default so the rail
  surfaces a different slice across regenerations.
  """
  @spec rank([map()], [String.t()], String.t() | nil, keyword()) :: [map()]
  def rank(contact_msgs, follows, self_id, opts \\ []) do
    endorsers_of_followed =
      follows
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()

    {endorsers, followers} = graph(contact_msgs)

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
    |> maybe_shuffle(opts)
    |> Enum.take(@limit)
    |> Enum.map(&Map.take(&1, ["id", "followers"]))
  end

  defp maybe_shuffle(list, opts) do
    if Keyword.get(opts, :shuffle, true) do
      Enum.shuffle(list)
    else
      list
    end
  end

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

  defp content(%{"value" => %{"content" => c}}) when is_map(c), do: c
  defp content(_msg), do: %{}
end
