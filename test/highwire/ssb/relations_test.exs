defmodule HighWire.SSB.RelationsTest do
  # The table is shared with the running app, so a fixed feed id would let
  # one test's graph answer another's read.
  use ExUnit.Case, async: false

  alias HighWire.SSB.Relations

  setup do
    Relations.create()
    :ok
  end

  defp feed,
    do: "@" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false) <> "=.ed25519"

  defp contact(author, contact, fields, ts) do
    %{
      "key" => "%#{ts}.sha256",
      "value" => %{
        "author" => author,
        "timestamp" => ts,
        "content" => Map.merge(%{"type" => "contact", "contact" => contact}, fields)
      }
    }
  end

  describe "folding contact messages" do
    test "follows, unfollows and blocks land on the feed that published them" do
      author = feed()
      first = feed()
      second = feed()

      Relations.fold(contact(author, first, %{"following" => true}, 10))
      Relations.fold(contact(author, second, %{"following" => true}, 20))
      Relations.fold(contact(author, first, %{"following" => false}, 30))
      Relations.fold(contact(author, second, %{"following" => false, "blocking" => true}, 40))

      assert %{follows: [], blocked: [^second]} = Relations.of(author)

      # Someone else's graph is their own.
      assert %{follows: [], blocked: []} = Relations.of(first)
    end

    test "unblocking leaves the follow alone" do
      author = feed()
      peer = feed()

      Relations.fold(contact(author, peer, %{"following" => true}, 10))
      Relations.fold(contact(author, peer, %{"following" => false, "blocking" => true}, 20))
      Relations.fold(contact(author, peer, %{"blocking" => false}, 30))

      assert %{follows: [], blocked: []} = Relations.of(author)

      Relations.fold(contact(author, peer, %{"following" => true}, 40))
      assert %{follows: [^peer], blocked: []} = Relations.of(author)
    end
  end

  describe "incoming edges" do
    test "answers the feeds whose messages name this feed" do
      reader = feed()
      follower = feed()
      blocker = feed()

      Relations.fold(contact(follower, reader, %{"following" => true}, 10))
      Relations.fold(contact(blocker, reader, %{"blocking" => true}, 20))

      assert %{follows: [^follower], blocked: [^blocker]} = Relations.incoming(reader)
      assert %{follows: [], blocked: []} = Relations.incoming(follower)
    end
  end

  describe "standings" do
    test "names each two-sided state" do
      self_id = feed()
      mutual = feed()
      following = feed()
      followed_by = feed()
      blocked = feed()
      blocking = feed()
      stranger = feed()

      Relations.fold(contact(mutual, self_id, %{"following" => true}, 10))
      Relations.fold(contact(followed_by, self_id, %{"following" => true}, 20))
      Relations.fold(contact(blocking, self_id, %{"blocking" => true}, 30))

      opts = [self_id: self_id, follows: [mutual, following, blocked], blocked: [blocked]]

      assert Relations.state(self_id, self_id, opts[:follows], opts[:blocked]) == :self
      assert Relations.state(mutual, self_id, opts[:follows], opts[:blocked]) == :mutual
      assert Relations.state(following, self_id, opts[:follows], opts[:blocked]) == :following
      assert Relations.state(followed_by, self_id, opts[:follows], opts[:blocked]) == :followed_by
      assert Relations.state(blocked, self_id, opts[:follows], opts[:blocked]) == :blocked
      assert Relations.state(blocking, self_id, opts[:follows], opts[:blocked]) == :blocking
      assert Relations.state(stranger, self_id, opts[:follows], opts[:blocked]) == :reading
    end

    test "every combination of the four edges is representable" do
      self_id = feed()

      for follows? <- [false, true],
          blocks? <- [false, true],
          their_follows? <- [false, true],
          their_blocks? <- [false, true] do
        peer = feed()

        Relations.fold(
          contact(
            peer,
            self_id,
            %{"following" => their_follows?, "blocking" => their_blocks?},
            10
          )
        )

        [peer]
        |> Relations.standings(
          self_id: self_id,
          follows: if(follows?, do: [peer], else: []),
          blocked: if(blocks?, do: [peer], else: [])
        )
        |> Map.fetch!(peer)
        |> then(fn standing ->
          assert standing.follows? == follows?
          assert standing.blocked? == blocks?
          assert standing.follows_you? == their_follows?
          assert standing.blocks_you? == their_blocks?
        end)
      end
    end

    test "a block the reader holds outranks one held against them" do
      self_id = feed()
      peer = feed()

      Relations.fold(contact(peer, self_id, %{"blocking" => true}, 10))

      assert Relations.state(peer, self_id, [], [peer]) == :blocked
      assert Relations.state(peer, self_id, [peer], []) == :blocking
    end

    test "nothing known reads as the passive state" do
      assert Relations.state(feed(), feed(), [], []) == :reading
      assert Relations.state(nil, feed(), [], []) == :reading
    end
  end

  describe "edges" do
    test "lists the follow and block each pair's messages name" do
      author = feed()
      peer = feed()

      Relations.fold(contact(author, peer, %{"following" => true}, 10))
      Relations.fold(contact(author, peer, %{"blocking" => true}, 20))

      assert {author, peer, :follows} in Relations.edges()
      assert {author, peer, :blocks} in Relations.edges()
    end
  end

  describe "ordering" do
    test "an older message does not undo a newer one" do
      author = feed()
      peer = feed()

      Relations.fold(contact(author, peer, %{"following" => false}, 20))
      Relations.fold(contact(author, peer, %{"following" => true}, 10))

      assert %{follows: [], blocked: []} = Relations.of(author)
    end

    test "the lists read newest first" do
      author = feed()
      older = feed()
      newer = feed()

      Relations.fold(contact(author, older, %{"following" => true}, 10))
      Relations.fold(contact(author, newer, %{"following" => true}, 20))

      assert %{follows: [^newer, ^older]} = Relations.of(author)
    end
  end

  describe "input it cannot use" do
    test "a message that names no contact is ignored" do
      author = feed()

      Relations.fold(%{
        "value" => %{"author" => author, "timestamp" => 5, "content" => %{"type" => "contact"}}
      })

      Relations.fold(%{"value" => %{"author" => author, "content" => "ciphertext"}})
      Relations.fold(:not_a_message)

      assert %{follows: [], blocked: []} = Relations.of(author)
    end
  end
end
