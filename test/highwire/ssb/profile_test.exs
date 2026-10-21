defmodule HighWire.SSB.ProfileTest do
  use ExUnit.Case, async: true

  alias HighWire.Avatar, as: Ident
  alias HighWire.SSB.Profile

  describe "the read model" do
    test "stores the payload's image, and takes the name from an about" do
      id = "@profile-case-#{:erlang.unique_integer([:positive])}.ed25519"

      assert Profile.get(id) == nil
      assert Profile.image(id) == nil

      :ok = Profile.put_all(%{id => %{name: "dtBy", image: "&img=.sha256"}})

      # The engine's name is not the feed's own word for itself, so the
      # payload writes only the image.
      assert Profile.get(id) == %{name: nil, image: "&img=.sha256", description: nil}
      assert Profile.image(id) == "&img=.sha256"
      assert Profile.display_name(id) == Ident.short_id(id)

      :ok = Profile.put_about(id, %{"name" => "dtBy"})
      assert Profile.display_name(id) == "dtBy"

      # take/1 answers for the ids it knows and drops the rest, so a
      # caller's profiles map never carries a nil entry.
      assert Profile.take([id, "@unresolved00.ed25519"]) == %{
               id => %{name: "dtBy", image: "&img=.sha256", description: nil}
             }
    end

    test "a later payload replaces the image and leaves the about's name alone" do
      id = "@profile-merge-#{:erlang.unique_integer([:positive])}.ed25519"

      Profile.put_all(%{id => %{name: "engine one", image: "&first=.sha256"}})
      Profile.put_about(id, %{"name" => "own name"})

      Profile.put_all(%{id => %{name: "engine two", image: "&second=.sha256"}})

      assert Profile.get(id) == %{name: "own name", image: "&second=.sha256", description: nil}
      assert Profile.display_name(id) == "own name"

      # A present nil image still wins: the feed's avatar went away.
      Profile.put_all(%{id => %{name: "engine three", image: nil}})
      assert Profile.get(id) == %{name: "own name", image: nil, description: nil}
    end

    test "an about message owns the name and folds in the bio" do
      id = "@profile-about-#{:erlang.unique_integer([:positive])}.ed25519"

      Profile.put_all(%{id => %{image: "&img=.sha256"}})
      :ok = Profile.put_about(id, %{"name" => "after", "description" => "nasty, brutish, short"})

      assert Profile.get(id) == %{
               name: "after",
               image: "&img=.sha256",
               description: "nasty, brutish, short"
             }

      # An about that carries only a bio leaves the name alone.
      :ok = Profile.put_about(id, %{"description" => "still short"})

      assert Profile.get(id) == %{
               name: "after",
               image: "&img=.sha256",
               description: "still short"
             }

      # A newer about that does carry a name revises it.
      :ok = Profile.put_about(id, %{"name" => "afterwards"})
      assert Profile.display_name(id) == "afterwards"
    end

    test "with_names lays the about's name over a payload's image map" do
      named = "@profile-named-#{:erlang.unique_integer([:positive])}.ed25519"
      unnamed = "@profile-unnamed-#{:erlang.unique_integer([:positive])}.ed25519"

      :ok = Profile.put_about(named, %{"name" => "Own Name"})

      payload = %{
        named => %{name: "Third party's label", image: "&a=.sha256"},
        unnamed => %{name: "Another label", image: "&b=.sha256"}
      }

      assert Profile.with_names(payload) == %{
               named => %{name: "Own Name", image: "&a=.sha256"},
               unnamed => %{name: nil, image: "&b=.sha256"}
             }
    end

    test "an about names a feed no payload has described yet" do
      id = "@profile-about-new-#{:erlang.unique_integer([:positive])}.ed25519"

      :ok = Profile.put_about(id, %{"name" => "fresh", "description" => "hi"})

      assert Profile.get(id) == %{name: "fresh", image: nil, description: "hi"}
      assert Profile.display_name(id) == "fresh"
    end

    test "an unresolved feed shows the short id — what its followers see" do
      id = "@stranger00.ed25519"

      assert Profile.take([id]) == %{}
      assert Profile.image(id) == nil
      assert Profile.display_name(id) == Ident.short_id(id)
    end

    test "the blob revision rides alongside for avatar cache busting" do
      previous = Profile.rev()
      on_exit(fn -> if is_integer(previous), do: Profile.put_rev(previous) end)

      :ok = Profile.put_rev(7)
      assert Profile.rev() == 7
    end
  end
end
