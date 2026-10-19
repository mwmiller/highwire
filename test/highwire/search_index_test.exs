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

  test "records are dated by the author's timestamp, not the receive time", %{key: key} do
    # A bulk import stamps thousands of messages with one received time;
    # the author's claimed time (value.timestamp) is what a reader sees.
    tag = "dated by authorship #{System.unique_integer([:positive])}"

    SearchIndex.ingest([
      %{
        "key" => key,
        "timestamp" => 1_700_000_000_000,
        "value" => %{
          "author" => "@alice.example",
          "timestamp" => 1_500_000_000_000,
          "content" => %{"text" => tag}
        }
      }
    ])

    :sys.get_state(SearchIndex)

    SearchIndex.search(tag, self())
    assert_receive {:search_results, ^tag, [hit]}, 2_000
    assert hit.ts == 1_500_000_000_000
  end

  test "status reports the index state the header chip consumes" do
    # The engine is disabled under test, so the index never dials.
    assert SearchIndex.status() == :disabled
  end

  describe "matching" do
    test "a query is a literal, never a pattern", %{key: key} do
      tag = "literal#{System.unique_integer([:positive])}"
      dotted = key <> "-dot"
      on_exit(fn -> :dets.delete(:highwire_search, dotted) end)

      SearchIndex.ingest([
        %{"key" => key, "author" => "@a", "text" => "#{tag} axbzz", "ts" => 1},
        %{"key" => dotted, "author" => "@a", "text" => "#{tag} a.bzz c++zz", "ts" => 2}
      ])

      :sys.get_state(SearchIndex)

      # `.` must not stand for `x`, and `++` must not read as repetition
      # (an unescaped `c++` would not even compile, answering nothing).
      for q <- ["a.b", "c++"] do
        SearchIndex.search(q, self())
        assert_receive {:search_results, ^q, hits}, 2_000
        assert Enum.any?(hits, &(&1.key == dotted)), "#{q} missed the literal post"
        refute Enum.any?(hits, &(&1.key == key)), "#{q} matched as a pattern"
      end
    end

    test "matching is caseless by Unicode rules", %{key: key} do
      SearchIndex.ingest([
        %{
          "key" => key,
          "author" => "@a",
          "text" => "CafÉ Ünïcode ΣΟΦΟΣ İstanbul",
          "ts" => 1
        }
      ])

      :sys.get_state(SearchIndex)

      # A plain `:caseless` match folds ASCII only and would miss the
      # first three; `σοφος` also survives the final-sigma rule.
      for q <- ["café", "ünïcode", "σοφος", "İstanbul"] do
        SearchIndex.search(q, self())
        assert_receive {:search_results, ^q, hits}, 2_000
        assert Enum.any?(hits, &(&1.key == key)), "#{q} missed the post"
      end
    end

    test "a text that is not valid UTF-8 is stored without text, not fatal", %{key: key} do
      tag = "guard#{System.unique_integer([:positive])}"

      SearchIndex.ingest([
        %{
          "key" => key,
          "author" => "@#{tag}",
          "text" => "#{tag} zebrabad" <> <<0xFF>>,
          "ts" => 1
        }
      ])

      :sys.get_state(SearchIndex)

      # `:re` raises on a subject that is not valid UTF-8; the query
      # answers anyway, and the row is still findable by its author.
      SearchIndex.search(tag, self())
      assert_receive {:search_results, ^tag, [hit]}, 2_000
      assert hit.key == key
      assert hit.text == nil

      # Unreadable bytes are not searchable text.
      SearchIndex.search("zebrabad", self())
      assert_receive {:search_results, "zebrabad", []}, 2_000
    end
  end

  describe "crawl robustness" do
    test "a message whose content is not a map is skipped, not fatal", %{key: key} do
      # get_in/2 raises on a boxed-string content; that would crash the
      # GenServer mid-crawl and the restart would re-crawl into the same
      # record forever.
      boom = key <> "-boxed"

      on_exit(fn ->
        :dets.delete(:highwire_search, boom)
        :dets.delete(:highwire_search, boom <> "2")
      end)

      SearchIndex.ingest([
        %{"key" => boom, "value" => "not-a-map", "timestamp" => 1},
        %{"key" => boom <> "2", "value" => %{"content" => "abc.box"}, "timestamp" => 2}
      ])

      :sys.get_state(SearchIndex)

      # The index survived and still serves the records around it.
      tag = "survived #{System.unique_integer([:positive])}"

      SearchIndex.ingest([%{"key" => key, "author" => "@a", "text" => tag, "ts" => 3}])
      :sys.get_state(SearchIndex)

      assert Process.alive?(Process.whereis(SearchIndex))
      SearchIndex.search(tag, self())
      assert_receive {:search_results, ^tag, [hit]}, 2_000
      assert hit.key == key
    end

    test "a broad query is capped at the newest 200, not every match", %{key: key} do
      tag = "captag#{System.unique_integer([:positive])}"

      items =
        for n <- 1..205 do
          %{"key" => "#{key}-#{n}", "author" => "@a", "text" => "#{tag} #{n}", "ts" => n}
        end

      SearchIndex.ingest(items)
      :sys.get_state(SearchIndex)

      on_exit(fn ->
        for n <- 1..205, do: :dets.delete(:highwire_search, "#{key}-#{n}")
      end)

      SearchIndex.search(tag, self())
      assert_receive {:search_results, ^tag, hits}, 5_000

      assert length(hits) == 200
      # Newest first, and the five oldest fall off the cap.
      assert hd(hits).key == "#{key}-205"
      assert Enum.all?(hits, &(&1.key != "#{key}-1"))
    end
  end

  describe "next_backlog_step/1 (what a finished backlog page means)" do
    test "a request that delivers nothing ends the crawl" do
      assert SearchIndex.next_backlog_step(%{
               page_count: 0,
               cursor: 10,
               page_start_cursor: 10
             }) == :live
    end

    test "a short page that moved the cursor keeps paging" do
      # The engine omits rows whose message it cannot hydrate, so a
      # limit-sized read can deliver fewer frames while more rows remain.
      # Treating that as exhaustion is what lost 88k rows once.
      assert SearchIndex.next_backlog_step(%{
               page_count: 4_902,
               cursor: 100,
               page_start_cursor: 50
             }) == {:page, 99}
    end

    test "resume reads one behind the cursor so same-millisecond siblings survive" do
      assert SearchIndex.next_backlog_step(%{
               page_count: 5_000,
               cursor: 100,
               page_start_cursor: 50
             }) == {:page, 99}
    end

    test "a page that moved nothing steps strictly past the millisecond wall" do
      # Re-reading behind a shared millisecond would serve the same page
      # forever; the strict read is the only way forward.
      assert SearchIndex.next_backlog_step(%{
               page_count: 5_000,
               cursor: 100,
               page_start_cursor: 100
             }) == {:page, 100}
    end
  end
end
