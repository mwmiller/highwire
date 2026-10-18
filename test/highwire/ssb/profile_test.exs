defmodule HighWire.SSB.ProfileTest do
  use ExUnit.Case, async: true

  alias HighWire.Avatar, as: Ident
  alias HighWire.SSB.Profile

  describe "the read model" do
    test "stores what the engine answered and reads it back" do
      id = "@profile-case-#{:erlang.unique_integer([:positive])}.ed25519"

      assert Profile.get(id) == nil
      assert Profile.image(id) == nil

      :ok = Profile.put_all(%{id => %{name: "dtBy", image: "&img=.sha256"}})

      assert Profile.get(id) == %{name: "dtBy", image: "&img=.sha256"}
      assert Profile.image(id) == "&img=.sha256"
      assert Profile.display_name(id) == "dtBy"

      # take/1 answers for the ids it knows and drops the rest, so a
      # caller's profiles map never carries a nil entry.
      assert Profile.take([id, "@unresolved00.ed25519"]) == %{
               id => %{name: "dtBy", image: "&img=.sha256"}
             }
    end

    test "a later write merges over, and nothing else moves" do
      id = "@profile-merge-#{:erlang.unique_integer([:positive])}.ed25519"

      Profile.put_all(%{id => %{name: "one", image: "&first=.sha256"}})
      Profile.put_all(%{id => %{name: "two", image: nil}})

      assert Profile.get(id) == %{name: "two", image: nil}
      assert Profile.display_name(id) == "two"
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
