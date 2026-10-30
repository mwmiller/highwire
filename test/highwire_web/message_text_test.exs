defmodule HighWireWeb.MessageTextTest do
  use ExUnit.Case, async: true

  alias HighWireWeb.MessageText

  defp msg(content), do: %{"key" => "%m.sha256", "value" => %{"content" => content}}

  defp contact(id, flags), do: msg(Map.merge(%{"type" => "contact", "contact" => id}, flags))

  describe "contact edits" do
    test "each direction is named — an unblock is not a follow" do
      dave = "@dave.ed25519"

      assert MessageText.describe(contact(dave, %{"following" => true})) == "followed dave.ed25"

      assert MessageText.describe(contact(dave, %{"following" => false})) ==
               "unfollowed dave.ed25"

      assert MessageText.describe(contact(dave, %{"blocking" => true})) == "blocked dave.ed25"
      assert MessageText.describe(contact(dave, %{"blocking" => false})) == "unblocked dave.ed25"

      # a block that also retracts the follow is still a block: the block
      # is the relationship that matters
      assert MessageText.describe(contact(dave, %{"blocking" => true, "following" => false})) ==
               "blocked dave.ed25"
    end

    test "the name the edit carries wins over a profile lookup" do
      silvia = "@silvia.ed25519"

      sentence =
        MessageText.describe(
          contact(silvia, %{"blocking" => true, "about" => %{"name" => "Szilvia"}})
        )

      assert sentence == "blocked Szilvia"

      # the edit named a feed the profile store has never heard of, and
      # that is still a usable sentence
      assert MessageText.describe(contact(silvia, %{"blocking" => true})) == "blocked silvia.ed"
    end

    test "an edit with no direction at all falls back to the generic phrase" do
      # an about-only contact message (some clients share aliases this
      # way) is not a follow, but there is no direction to name
      assert MessageText.describe(contact("@dave.ed25519", %{"about" => %{"name" => "Dave"}})) ==
               "edited their contact list for Dave"
    end

    test "contact_edit/1 splits the edit for views that can link the target" do
      silvia = "@silvia.ed25519"

      assert MessageText.contact_edit(
               contact(silvia, %{"blocking" => true, "about" => %{"name" => "Szilvia"}})
             ) == {"blocked", silvia, "Szilvia"}

      assert MessageText.contact_edit(contact(silvia, %{"blocking" => false})) ==
               {"unblocked", silvia, nil}

      refute MessageText.contact_edit(msg(%{"type" => "post", "text" => "hi"}))
    end
  end

  describe "other payloads" do
    test "a textless post names the channel it landed in" do
      assert MessageText.describe(msg(%{"type" => "post", "channel" => "drama"})) ==
               "posted in #drama"
    end

    test "a message with no content at all reads as private" do
      assert MessageText.describe(%{"key" => "%m.sha256", "value" => %{}}) ==
               "sent a private message"
    end

    test "labelled_type?/1 separates named sentences from the generic fallback" do
      assert MessageText.labelled_type?("pub")
      assert MessageText.labelled_type?("room/alias")
      assert MessageText.labelled_type?("channel")
      refute MessageText.labelled_type?("movieclub/new")
      refute MessageText.labelled_type?(nil)
    end

    test "the family is what a sentence names, not the sub-type" do
      # A reader who does not implement the protocol has no use for the
      # difference between adding a film and reviewing one.
      assert MessageText.describe(msg(%{"type" => "movieclub/new"})) ==
               "sent a movieclub message"

      assert MessageText.describe(msg(%{"type" => "movieclub/review"})) ==
               "sent a movieclub message"

      # a type with no family of its own reads as it always has
      assert MessageText.describe(msg(%{"type" => "secret-thing"})) ==
               "sent a secret thing message"
    end

    test "the article follows how the family sounds, not just its letter" do
      assert MessageText.describe(msg(%{"type" => "issue"})) == "sent an issue message"
      assert MessageText.describe(msg(%{"type" => "event"})) == "sent an event message"

      # a vowel letter that opens on a consonant sound keeps "a"
      assert MessageText.describe(msg(%{"type" => "user"})) == "sent a user message"
      assert MessageText.describe(msg(%{"type" => "unique-poll"})) == "sent a unique poll message"

      # and a consonant letter that is silent takes "an"
      assert MessageText.describe(msg(%{"type" => "hourly-report"})) ==
               "sent an hourly report message"
    end

    test "describe_spate/1 says the family repeated, without a count" do
      assert MessageText.describe_spate(msg(%{"type" => "movieclub/new"})) ==
               "sent some movieclub messages"

      assert MessageText.describe_spate(msg(%{"type" => "movieclub/review"})) ==
               "sent some movieclub messages"
    end
  end
end
