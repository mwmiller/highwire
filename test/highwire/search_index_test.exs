defmodule HighWire.SearchIndexTest do
  use ExUnit.Case, async: false

  alias HighWire.SearchIndex

  setup do
    key =
      "%search-index-test." <> Integer.to_string(System.unique_integer([:positive])) <> ".sha256"

    on_exit(fn -> :dets.delete(:highwire_search, key) end)
    [key: key]
  end

  test "ingested posts are searchable by content and author", %{key: key} do
    SearchIndex.ingest([
      %{
        "key" => key,
        "author" => "@alice.example",
        "text" => "Observing Zebrafish behaviour in the lab",
        "ts" => 1_700_000_000_000
      }
    ])

    # The cast must land before the query task folds the table.
    :sys.get_state(SearchIndex)

    SearchIndex.search("zebrafish", self())
    assert_receive {:search_results, "zebrafish", hits}, 2_000
    assert Enum.any?(hits, &(&1.key == key))

    SearchIndex.search("ALICE.EXAMPLE", self())
    assert_receive {:search_results, "ALICE.EXAMPLE", hits2}, 2_000
    assert Enum.any?(hits2, &(&1.key == key))
  end

  test "an empty query answers immediately with no hits" do
    SearchIndex.search("", self())
    assert_received {:search_results, "", []}
  end

  test "a query with no matches answers with an empty list" do
    :sys.get_state(SearchIndex)

    SearchIndex.search("zzz-no-such-post-zzz", self())
    assert_receive {:search_results, "zzz-no-such-post-zzz", []}, 2_000
  end
end
