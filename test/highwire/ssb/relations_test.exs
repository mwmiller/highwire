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
