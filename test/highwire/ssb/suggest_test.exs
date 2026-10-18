defmodule HighWire.SSB.SuggestTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Suggest

  @me "@me=.ed25519"
  @a "@aaa=.ed25519"
  @b "@bbb=.ed25519"
  @c "@ccc=.ed25519"

  defp msg(key, author, opts \\ []) do
    content = Keyword.get(opts, :content, %{"type" => "post", "text" => "hi"})

    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end

  defp follow(from, to, following \\ true) do
    content = %{"type" => "contact", "contact" => to, "following" => following}
    msg("follow-#{from}-#{to}", from, content: content)
  end

  test "ranks unfollowed authors by activity, with distinct follower counts" do
    messages = [
      msg("k1", @a),
      msg("k2", @a),
      msg("k3", @a),
      msg("k4", @b),
      msg("k5", @c),
      msg("k6", @me)
    ]

    contact_msgs = [
      follow("@xxx=.ed25519", @a),
      follow("@yyy=.ed25519", @a),
      # A follow/unfollow/follow churn by the same feed is one follower.
      follow("@yyy=.ed25519", @a, false),
      follow("@yyy=.ed25519", @a),
      # `following: false` is an unfollow, not a follower.
      follow("@zzz=.ed25519", @c, false)
    ]

    # @me (self) and @b (followed) never appear; @a leads on activity
    # and carries two distinct followers; @c counts zero.
    assert Suggest.rank(messages, contact_msgs, [@me, @b], @me) == [
             %{"id" => @a, "activity" => 3, "followers" => 2},
             %{"id" => @c, "activity" => 1, "followers" => 0}
           ]
  end

  test "a message with a string content (undecrypted) still counts for activity" do
    messages = [msg("k1", @a, content: "%DLW...==")]

    assert [%{"id" => @a, "activity" => 1, "followers" => 0}] =
             Suggest.rank(messages, [], [], @me)
  end

  test "messages without a usable author or key never become rows" do
    messages = [
      %{"key" => "k1", "value" => %{"content" => %{}}},
      %{"value" => %{"author" => @a, "content" => %{}}},
      msg("k2", @a),
      msg("k2", @a)
    ]

    # The duplicate key collapses (the window overlaps streams); the
    # authorless message is dropped; the keyless one still counts its
    # author. Malformed input degrades, never crashes the rank.
    assert [%{"id" => @a, "activity" => 2, "followers" => 0}] =
             Suggest.rank(messages, [], [], @me)
  end

  test "ties break on followers, then id — deterministically" do
    messages = [msg("k1", @c), msg("k2", @a), msg("k3", @b)]

    contact_msgs = [follow("@xxx=.ed25519", @c)]

    # Same activity, @c wins on followers; the rest hold id order.
    assert [%{"id" => @c}, %{"id" => @a}, %{"id" => @b}] =
             Suggest.rank(messages, contact_msgs, [@me], @me)
             |> Enum.map(&Map.take(&1, ["id"]))
  end

  test "the list is capped so the rail stays a nudge" do
    messages =
      for i <- 1..9 do
        msg("k#{i}", "@f#{i}=.ed25519")
      end

    ranked = Suggest.rank(messages, [], [@me], @me)
    assert length(ranked) == 5
  end

  test "a store with nothing to suggest ranks nothing" do
    assert Suggest.rank([], [], [@me], @me) == []
  end
end
