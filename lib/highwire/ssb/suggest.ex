defmodule HighWire.SSB.Suggest do
  @moduledoc """
  "Who to follow": active feeds we do not follow, ranked by activity
  with follower counts.

  Computed from what the Timeline already has in hand — the window's
  messages for recent activity, the store-wide contact drain for the
  follower graph — so discovery works against any engine. (The engine
  has no `stats.whoToFollow`: the call answers "method not found",
  which is why the sidebar never filled in while the ranking lived
  behind that RPC.)

  Each row is a plain string-keyed map — `{id, activity, followers}` —
  the shape the sidebar renders: the id keys the avatar and profile
  link, activity is how many of the window's messages the feed wrote,
  followers is how many distinct feeds in the store follow it. Rows
  without a usable id are dropped so the sidebar never renders a dead
  link.
  """

  # A sidebar is a nudge, not a directory — a few rows below Contacts
  # (which caps at 8) fits the rail without pushing it off-screen.
  @limit 5

  @doc """
  Rank `messages` (the Timeline's window, raw as the engine sent them)
  into suggestion rows. `follows` and `self_id` never appear — you do
  not follow yourself. Deterministic: activity desc, then follower
  count, then id, so the list only moves when the data does.
  """
  @spec rank([map()], [map()], [String.t()], String.t() | nil) :: [map()]
  def rank(messages, contact_msgs, follows, self_id) do
    excluded =
      follows
      |> Enum.filter(&is_binary/1)
      |> MapSet.new()
      |> MapSet.put(self_id)

    followers = follower_counts(contact_msgs)

    messages
    |> Enum.uniq_by(& &1["key"])
    |> Enum.reduce(%{}, fn msg, acc ->
      case author(msg) do
        nil -> acc
        id -> Map.update(acc, id, 1, &(&1 + 1))
      end
    end)
    |> Map.reject(fn {id, _n} -> MapSet.member?(excluded, id) end)
    |> Enum.map(fn {id, activity} ->
      %{"id" => id, "activity" => activity, "followers" => Map.get(followers, id, 0)}
    end)
    |> Enum.sort_by(fn s -> {-s["activity"], -s["followers"], s["id"]} end)
    |> Enum.take(@limit)
  end

  # One follower per distinct feed that said `following: true` — a
  # follow/unfollow/follow churn must not count triple, and `false`
  # (or a missing field) is not a follow at all.
  defp follower_counts(contact_msgs) do
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
    |> Map.new(fn {id, set} -> {id, MapSet.size(set)} end)
  end

  defp author(%{"value" => %{"author" => id}}) when is_binary(id), do: id
  defp author(_msg), do: nil

  # Encrypted private messages keep their content as a string — they
  # still count for activity (author/1 above), never for follows.
  defp content(%{"value" => %{"content" => c}}) when is_map(c), do: c
  defp content(_msg), do: %{}
end
