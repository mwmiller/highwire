defmodule HighWireWeb.TimelineLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "timeline renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Timeline"
    # sidecar disabled under test
    assert html =~ "SSB engine disabled"
  end

  test "tab activity events toggle timeline polling", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Timeline"

    assert render_hook(view, "tab-inactive", %{}) =~ "Timeline"
    assert render_hook(view, "tab-active", %{}) =~ "Timeline"
  end

  test "about page still renders, with the shared left rail", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/about")
    assert html =~ "HighWire"
    assert html =~ ~s(title="Settings")
  end

  test "the network chip is always in the header and links to the dialing page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # engine disabled under test — the chip still renders, with
    # status-appropriate copy instead of vanishing
    assert html =~ "Engine off"
    assert html =~ ~s(href="/network")
  end

  test "the contacts rail never sits empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "No contacts yet"
  end

  test "reply snippets render markdown as its text, not its source" do
    msg = %{
      "value" => %{"content" => %{"text" => "**loud** take\n> quoted [link](http://x.test)"}}
    }

    preview = HighWireWeb.TimelineLive.snippet(msg, %{rev: 0})

    refute preview =~ "**"
    refute preview =~ "]("
    assert preview =~ "loud take"
    assert preview =~ "quoted link"
  end

  test "composer renders on the Public tab and tracks drafts", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ ~s(id="compose")
    assert html =~ "Write a post…"
    assert html =~ "Publish"

    html = render_change(view, "compose-draft", %{"body" => "half a thought"})
    assert html =~ "half a thought"
  end

  test "blank publish is rejected locally", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> form("#compose", %{"body" => "   "})
      |> render_submit()

    assert html =~ "Nothing to publish."
  end

  test "publishing with the engine disabled reports it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html =
      view
      |> form("#compose", %{"body" => "hello world"})
      |> render_submit()

    assert html =~ "SSB engine disabled in this configuration."
  end

  describe "event rows from the engine window" do
    test "follow events land on the Public tab in chronological context", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%root-old.sha256", "@bob:.ed25519", now - 60_000, %{
          "type" => "post",
          "text" => "oldest words"
        }),
        ssb_msg("%follow-dave.sha256", "@alice:.ed25519", now - 2_000, %{
          "type" => "contact",
          "contact" => "@dave:.ed25519"
        }),
        ssb_msg("%root-new.sha256", "@carol:.ed25519", now - 500, %{
          "type" => "post",
          "text" => "newest words"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs, now: now))
      dave = URI.encode_www_form("@dave:.ed25519")

      assert html =~ "followed"
      assert pos(html, "newest words") < pos(html, dave)
      assert pos(html, dave) < pos(html, "oldest words")
    end

    test "events stay on Public — other tabs keep the thread-only scope", %{conn: conn} do
      now = 1_700_000_000_000
      me = "@me:.ed25519"

      msgs = [
        ssb_msg("%root-mine.sha256", me, now - 5_000, %{
          "type" => "post",
          "text" => "my own words"
        }),
        ssb_msg("%follow-dave.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "contact",
          "contact" => "@dave:.ed25519"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs, now: now, self_id: me))
      dave = URI.encode_www_form("@dave:.ed25519")

      assert html =~ "my own words"
      assert html =~ dave

      html = render_click(view, "view", %{"v" => "participating"})
      assert html =~ "my own words"
      refute html =~ dave
    end

    test "a newer follow replaces the loaded follow row for that author", %{conn: conn} do
      now = 1_700_000_000_000

      first = [
        ssb_msg("%follow-bob.sha256", "@alice:.ed25519", now - 5_000, %{
          "type" => "contact",
          "contact" => "@bob:.ed25519"
        })
      ]

      second = [
        ssb_msg("%follow-carol.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "contact",
          "contact" => "@carol:.ed25519"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      bob = URI.encode_www_form("@bob:.ed25519")
      carol = URI.encode_www_form("@carol:.ed25519")

      html = notify(view, feed_payload(first, now: now))
      assert html =~ bob
      assert count(html, "followed") == 1

      html = notify(view, feed_payload(second, now: now))
      refute html =~ bob
      assert html =~ carol
      assert count(html, "followed") == 1
    end

    test "posts show who liked them instead of a count", %{conn: conn} do
      now = 1_700_000_000_000
      liker = "@dana:.ed25519"

      msgs = [
        ssb_msg("%root-liked.sha256", "@alice:.ed25519", now - 5_000, %{
          "type" => "post",
          "text" => "the thing"
        }),
        ssb_msg("%vote-dana.sha256", liker, now - 1_000, %{
          "type" => "vote",
          "vote" => %{"link" => "%root-liked.sha256", "value" => 1, "expression" => "like"}
        })
      ]

      payload =
        feed_payload(msgs, now: now)
        |> Map.put(:profiles, %{liker => %{name: "Dana", image: nil}})

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, payload)

      # the liker is named on their avatar...
      assert html =~ "Dana"
      # ...and the like control is one obvious pill with a pressed state.
      assert html =~ ~s(phx-click="like")
      assert html =~ "aria-pressed="
    end

    test "channel subscriptions say which channel and which way", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%sub-core.sha256", "@alice:.ed25519", now - 2_000, %{
          "type" => "channel",
          "channel" => "core",
          "subscribed" => true
        }),
        ssb_msg("%unsub-rant.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "channel",
          "channel" => "#rant",
          "subscribed" => false
        }),
        ssb_msg("%sub-nochannel.sha256", "@alice:.ed25519", now - 500, %{
          "type" => "channel",
          "subscribed" => true
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs, now: now))

      assert html =~ "subscribed to #core"
      # a leading # is not doubled when the message already carries one
      assert html =~ "unsubscribed from #rant"
      refute html =~ "sent a channel message"
      # a toggle that names no channel still reads as a toggle
      assert html =~ "toggled a channel subscription"
    end

    test "about updates read as profile updates", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%about-alice.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "about",
          "name" => "Alice"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs, now: now))

      assert html =~ "updated their profile"
      refute html =~ "sent a about"
    end

    test "rendered rows ask Timeline to profile authors no payload carried", %{conn: conn} do
      now = 1_700_000_000_000
      author = "@pagedauthor=.ed25519"

      msgs = [
        ssb_msg("%root-paged.sha256", author, now - 1_000, %{
          "type" => "post",
          "text" => "from an older page"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      # The payload carries no profiles map entry for the author.
      notify(view, feed_payload(msgs, now: now))

      # The request lands on the supervised Timeline as a parked want —
      # the same path cursor-page rows use once the engine is up.
      wants = :sys.get_state(HighWire.Timeline).profile_wants
      assert MapSet.member?(wants, author)
    end
  end

  describe "composer mentions" do
    test "the popup suggests follows and profiles, and closes cleanly", %{conn: conn} do
      now = 1_700_000_000_000
      alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"

      {:ok, view, html} = live(conn, "/")
      assert html =~ "phx-hook=\"Mentions\""

      payload =
        feed_payload([], now: now)
        |> Map.put(:follows, [alice])
        |> Map.put(:profiles, %{alice => %{name: "Alice Smith", image: nil}})

      notify(view, payload)

      # a typed prefix matches on display name...
      html = render_click(view, "mention-query", %{"q" => "ali"})
      assert html =~ "id=\"mention-list\""
      assert html =~ "Alice Smith"
      assert html =~ "data-id=\"" <> alice <> "\""

      # ...a bare sigil lists everyone known...
      html = render_click(view, "mention-query", %{"q" => ""})
      assert html =~ "Alice Smith"

      # ...an id fragment matches too (typing a short id)...
      html = render_click(view, "mention-query", %{"q" => "vkdmlsu"})
      assert html =~ "Alice Smith"

      # ...and no match retires the popup rather than rendering an
      # empty box.
      html = render_click(view, "mention-query", %{"q" => "zzzz"})
      refute html =~ "id=\"mention-list\""

      html = render_click(view, "mention-close", %{})
      refute html =~ "id=\"mention-list\""
    end
  end

  test "a replication wave lights the new rows, once", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    now = System.system_time(:millisecond)
    alice = ssb_msg("%a.alice", "@alice.ed25519", now, %{"type" => "post", "text" => "first"})
    bob = ssb_msg("%b.bob", "@bob.ed25519", now + 1, %{"type" => "post", "text" => "second"})

    # Empty store — the first real payload is all arrival.
    assert notify(view, feed_payload([alice], now: now)) =~ "gossip-arrived"

    # The same wave again: nothing new, and the glow retires.
    refute notify(view, feed_payload([alice], now: now)) =~ "gossip-arrived"

    # Replication brings a newer post: only that wave lights up.
    assert notify(view, feed_payload([bob, alice], now: now)) =~ "gossip-arrived"
  end

  test "the rail badge counts gossip connections", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute html =~ "· 3"

    send(view.pid, {HighWire.Timeline, :gossip, %{connected: 3}})

    assert render(view) =~ "· 3"
  end

  defp ssb_msg(key, author, ts, content) do
    %{"key" => key, "value" => %{"author" => author, "timestamp" => ts, "content" => content}}
  end

  # A Timeline payload as finalize/1 broadcasts it — the window rows come
  # straight from the same builder the engine uses.
  defp feed_payload(msgs, opts) do
    now = Keyword.fetch!(opts, :now)
    self_id = Keyword.get(opts, :self_id)
    likes = HighWire.Timeline.likes_state(msgs)
    counts = HighWire.Timeline.like_counts(likes)

    %{
      feed: HighWire.Timeline.build_feed(msgs, self_id, counts, now),
      messages: [],
      reply_counts: %{},
      like_counts: counts,
      likes_by: HighWire.Timeline.like_authors(likes),
      my_likes: HighWire.Timeline.my_likes(likes, self_id),
      index: %{},
      follows: [],
      self_id: self_id,
      profiles: %{},
      suggestions: []
    }
  end

  defp notify(view, payload) do
    send(view.pid, {HighWire.Timeline, :updated, payload})
    render(view)
  end

  defp pos(html, needle) do
    case :binary.match(html, needle) do
      {idx, _} -> idx
      :nomatch -> flunk("expected #{inspect(needle)} in the feed HTML")
    end
  end

  defp count(html, needle) do
    html |> String.split(needle) |> length() |> Kernel.-(1)
  end
end
