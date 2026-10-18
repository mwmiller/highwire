defmodule HighWire.ContactsTest do
  use ExUnit.Case, async: false

  alias HighWire.Contacts
  alias HighWire.SSB.Profile

  defp ids(n), do: for(i <- 1..n, do: "@feed#{i}=.ed25519")

  defp start, do: start_supervised!({Contacts, name: :test_contacts})

  test "starts empty and never sits on a stale draw" do
    start()
    assert Contacts.get_contacts(:test_contacts) == []
  end

  test "draws at most seven distinct candidates" do
    start()
    candidates = ids(20)

    Contacts.cast_contacts(candidates, :test_contacts)
    drawn = Contacts.get_contacts(:test_contacts)

    assert length(drawn) == 7
    assert Enum.uniq(drawn) == drawn
    assert Enum.all?(drawn, &(&1 in candidates))
  end

  test "a list that already fits comes back whole" do
    start()
    candidates = ids(4)

    Contacts.cast_contacts(candidates, :test_contacts)

    assert Enum.sort(Contacts.get_contacts(:test_contacts)) == Enum.sort(candidates)
  end

  test "holds its draw until the candidate list changes" do
    start()
    candidates = ids(20)

    Contacts.cast_contacts(candidates, :test_contacts)
    first = Contacts.get_contacts(:test_contacts)

    # the same list offered again is not a new draw
    Contacts.cast_contacts(candidates, :test_contacts)
    assert Contacts.get_contacts(:test_contacts) == first

    # a changed follow list draws from the new candidates
    others = for i <- 21..40, do: "@feed#{i}=.ed25519"
    Contacts.cast_contacts(others, :test_contacts)
    redrawn = Contacts.get_contacts(:test_contacts)

    assert length(redrawn) == 7
    assert Enum.all?(redrawn, &(&1 in others))
  end

  test "orders the draw by display alias, not feed id" do
    start()
    zed = "@zzz=.ed25519"
    amy = "@yyy=.ed25519"

    Profile.put_all(%{zed => %{name: "Zed"}, amy => %{name: "Amy"}})

    Contacts.cast_contacts([zed, amy], :test_contacts)

    assert Contacts.get_contacts(:test_contacts) == [amy, zed]
  end
end
