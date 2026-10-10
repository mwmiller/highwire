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

  test "the label tick re-renders so relative times keep aging", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    send(view.pid, :labels_tick)
    assert render(view) =~ "Timeline"

    state = :sys.get_state(view.pid)
    assert is_integer(state.socket.assigns.labels_tick)
  end

  test "about page still renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/about")
    assert html =~ "HighWire"
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
      # ...and the bare tally is gone.
      refute html =~ "❤ <span"
    end
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
