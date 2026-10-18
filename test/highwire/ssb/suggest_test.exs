defmodule HighWire.SSB.SuggestTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Suggest

  @me "@me=.ed25519"
  @a "@aaa=.ed25519"
  @b "@bbb=.ed25519"
  @c "@ccc=.ed25519"
  @stranger "@stranger=.ed25519"

  defp msg(key, author, opts) do
    content = Keyword.get(opts, :content, %{"type" => "post", "text" => "hi"})

    %{"key" => key, "value" => %{"author" => author, "content" => content}}
  end

  defp follow(from, to, following \\ true) do
    content = %{"type" => "contact", "contact" => to, "following" => following}
    msg("follow-#{from}-#{to}", from, content: content)
  end

  test "ranks friend-of-friend candidates by endorsement from the follows" do
    contact_msgs = [
      # Two feeds we follow both endorse @a; only one endorses @b; @c is
      # endorsed only by a stranger, so it never qualifies.
      follow(@a, @c),
      follow("@xxx=.ed25519", @a),
      follow("@yyy=.ed25519", @a),
      follow("@yyy=.ed25519", @b),
      follow(@stranger, @c)
    ]

    assert Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519", "@yyy=.ed25519"], @me, nil,
             shuffle: false
           ) == [
             %{"id" => @a, "followers" => 2},
             %{"id" => @b, "followers" => 1}
           ]
  end

  test "followed feeds and self are never suggested" do
    contact_msgs = [
      # @a endorses @b (which we follow) and @me (self); neither surfaces.
      follow(@a, @b),
      follow(@a, @me)
    ]

    assert Suggest.rank(contact_msgs, [@me, @a, @b], @me, nil) == []
  end

  test "a follow/unfollow/follow churn is one endorser" do
    contact_msgs = [
      follow("@xxx=.ed25519", @a),
      follow("@xxx=.ed25519", @a, false),
      follow("@xxx=.ed25519", @a)
    ]

    assert [%{"id" => @a, "followers" => 1}] =
             Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil)
  end

  test "an unfollow (following: false) is not an endorsement" do
    contact_msgs = [follow("@xxx=.ed25519", @a, false)]

    assert Suggest.rank(contact_msgs, [@me], @me, nil) == []
  end

  test "endorsement outranks raw follower count" do
    contact_msgs = [
      # @a: endorsed by two feeds we follow, one follower each way.
      follow("@xxx=.ed25519", @a),
      follow("@yyy=.ed25519", @a),
      # @b: endorsed by one feed we follow, but followed by a crowd of
      # strangers — popularity without a personal link ranks lower.
      follow("@zzz=.ed25519", @b),
      follow("@s1=.ed25519", @b),
      follow("@s2=.ed25519", @b),
      follow("@s3=.ed25519", @b)
    ]

    follows = [@me, "@xxx=.ed25519", "@yyy=.ed25519", "@zzz=.ed25519"]

    assert [%{"id" => @a}, %{"id" => @b}] =
             Suggest.rank(contact_msgs, follows, @me, nil, shuffle: false)
             |> Enum.map(&Map.take(&1, ["id"]))
  end

  test "ties break on followers, then id — deterministically" do
    contact_msgs = [
      follow("@xxx=.ed25519", @a),
      follow("@xxx=.ed25519", @b),
      follow("@xxx=.ed25519", @c),
      follow("@yyy=.ed25519", @c)
    ]

    # Equal endorsement; @c leads on followers, the rest hold id order.
    assert [%{"id" => @c}, %{"id" => @a}, %{"id" => @b}] =
             Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519", "@yyy=.ed25519"], @me, nil,
               shuffle: false
             )
             |> Enum.map(&Map.take(&1, ["id"]))
  end

  test "encrypted contact rows (string content) never become endorsements" do
    contact_msgs = [
      msg("enc", "@xxx=.ed25519", content: "%DLW...=="),
      follow("@xxx=.ed25519", @a)
    ]

    # The undecryptable row is ignored; the real follow still endorses @a.
    assert [%{"id" => @a, "followers" => 1}] =
             Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil)
  end

  test "contact rows without a usable author or contact are dropped" do
    contact_msgs = [
      %{"key" => "k1", "value" => %{"content" => %{"following" => true, "contact" => @a}}},
      %{"value" => %{"author" => "@xxx=.ed25519", "content" => %{"following" => true}}},
      follow("@xxx=.ed25519", @a)
    ]

    # Malformed input degrades, never crashes the rank: @a's one valid
    # endorsement stands.
    assert [%{"id" => @a, "followers" => 1}] =
             Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil)
  end

  test "the list is capped so the rail stays a nudge" do
    contact_msgs =
      for i <- 1..9 do
        follow("@xxx=.ed25519", "@f#{i}=.ed25519")
      end

    ranked = Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil)
    assert length(ranked) == 5
  end

  test "sets/5 draws two sets off a single graph pass" do
    contact_msgs =
      for i <- 1..9 do
        follow("@xxx=.ed25519", "@f#{i}=.ed25519")
      end

    {rows1, rows2} = Suggest.sets(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil)

    # Both sets are renderable rail rows drawn from the candidates.
    for rows <- [rows1, rows2] do
      assert length(rows) == 5
      assert Enum.all?(rows, &(Map.has_key?(&1, "id") and Map.has_key?(&1, "followers")))
      assert Enum.uniq_by(rows, & &1["id"]) |> length() == 5
    end

    # The draw is the only difference: unshuffled, both sets are the
    # same deterministic ranking rank/5 returns.
    {ranked1, ranked2} =
      Suggest.sets(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil, shuffle: false)

    assert ranked1 == ranked2
    assert ranked1 == Suggest.rank(contact_msgs, [@me, "@xxx=.ed25519"], @me, nil, shuffle: false)
  end

  test "a store with nothing to suggest ranks nothing" do
    assert Suggest.rank([], [@me], @me, nil) == []
  end

  test "candidates the store holds no about for are not suggested" do
    contact_msgs = [
      follow("@xxx=.ed25519", @a),
      follow("@xxx=.ed25519", @b)
    ]

    follows = [@me, "@xxx=.ed25519"]

    # The store knows an about for @b only — @a never gets named, so it
    # never gets a row.
    assert [%{"id" => @b, "followers" => 1}] =
             Suggest.rank(contact_msgs, follows, @me, MapSet.new([@b]))

    # nil is the deliberate "no filter" (tests, and any caller that
    # wants the raw ranking).
    assert [%{"id" => @a}, %{"id" => @b}] =
             Suggest.rank(contact_msgs, follows, @me, nil, shuffle: false)
             |> Enum.map(&Map.take(&1, ["id"]))

    # An empty set — Timeline's state until the about pass has landed —
    # filters everything out: a blank rail, never bare short ids.
    assert Suggest.rank(contact_msgs, follows, @me, MapSet.new()) == []

    # Sets draw from the same narrowed pool.
    {rows1, rows2} = Suggest.sets(contact_msgs, follows, @me, MapSet.new([@a]))

    for rows <- [rows1, rows2] do
      assert Enum.map(rows, & &1["id"]) == [@a]
    end
  end
end
