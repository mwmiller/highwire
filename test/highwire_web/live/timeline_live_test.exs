defmodule HighWireWeb.TimelineLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "timeline renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Timeline"
    # sidecar disabled under test
    assert html =~ "SSB engine disabled"
    # the feed scroller carries the scroll-position hook, so returning
    # from a post lands where the reader left off
    assert html =~ ~s(id="feed-scroller" phx-hook="FeedScroll")
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

  test "the rail shows Whom to follow when a payload carries suggestions", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    # the section keeps its heading when there is nothing to offer yet
    assert html =~ "Whom to follow"
    assert html =~ "No suggestions yet"

    row = %{"id" => "@stranger=.ed25519", "activity" => 3, "followers" => 2}
    html = notify(view, %{feed_payload([]) | suggestions: [row]})

    assert html =~ "Whom to follow"
    refute html =~ "No suggestions yet"
    assert html =~ "2 followers · 3 messages"
    # With no profile loaded the name falls back to the shortened id,
    # and the row still links to the full one.
    assert html =~ ~s(href="/profile?id=%40stranger%3D.ed25519")
  end

  test "the contacts rail caps the list and offers to expand it", %{conn: conn} do
    follows = for i <- 1..20, do: "@contact#{i}:.ed25519"
    # the draw HighWire.Contacts would hold for this list: seven of the twenty
    contacts = Enum.take(follows, 7)

    {:ok, view, _html} = live(conn, "/")
    html = notify(view, feed_payload([], follows: follows, contacts: contacts))

    # The collapsed rail shows the draw; the rest wait behind the toggle.
    assert html =~ "Show all 20"
    assert count_visible_contacts(html, follows) == 7

    html = render_click(view, "toggle-contacts", %{})
    assert html =~ "contact20"
    assert html =~ "Show fewer"
    assert count_visible_contacts(html, follows) == 20

    html = render_click(view, "toggle-contacts", %{})
    assert html =~ "Show all 20"
    assert count_visible_contacts(html, follows) == 7
  end

  test "the collapsed rail holds its draw across payloads", %{conn: conn} do
    follows = for i <- 1..20, do: "@contact#{i}:.ed25519"
    contacts = Enum.take(follows, 7)

    {:ok, view, _html} = live(conn, "/")
    html = notify(view, feed_payload([], follows: follows, contacts: contacts))
    window = visible_contacts(html, follows)
    assert length(window) == 7

    # Payloads arrive on every broadcast; the draw is unchanged, so the
    # rail must not reshuffle out from under the reader.
    same = notify(view, feed_payload([], follows: follows, contacts: contacts))
    assert visible_contacts(same, follows) == window
  end

  test "the rail follows a redrawn contact list", %{conn: conn} do
    follows = for i <- 1..20, do: "@contact#{i}:.ed25519"

    {:ok, view, _html} = live(conn, "/")
    html = notify(view, feed_payload([], follows: follows, contacts: Enum.take(follows, 7)))
    assert visible_contacts(html, follows) == Enum.take(follows, 7)

    # The follow list changed, so HighWire.Contacts drew a fresh handful.
    redrawn = Enum.take(Enum.drop(follows, 7), 7)
    html = notify(view, feed_payload([], follows: follows, contacts: redrawn))
    assert visible_contacts(html, follows) == redrawn
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
      html = notify(view, feed_payload(msgs))
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
      html = notify(view, feed_payload(msgs, self_id: me))
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

      html = notify(view, feed_payload(first))
      assert html =~ bob
      assert count(html, "followed") == 1

      html = notify(view, feed_payload(second))
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
        feed_payload(msgs)
        |> Map.put(:profiles, %{liker => %{name: "Dana", image: nil}})

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, payload)

      # the liker is named on their avatar...
      assert html =~ "Dana"
      # ...and the like control is one obvious pill with a pressed state.
      assert html =~ ~s(phx-click="like")
      assert html =~ "aria-pressed="
    end

    test "a refused like on the feed falls back to the last payload", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%root-unliked.sha256", "@alice:.ed25519", now - 5_000, %{
          "type" => "post",
          "text" => "the thing"
        })
      ]

      payload = feed_payload(msgs, self_id: "@me=.ed25519")

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, payload)
      assert html =~ ~s(aria-label="Like")

      # the engine is off under test, so the publish refuses: the
      # optimistic fill must not linger on a row the store never saw
      html = element(view, ~s(button[aria-label="Like"])) |> render_click()
      refute html =~ ~s(aria-pressed="true")
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
      html = notify(view, feed_payload(msgs))

      assert html =~ "subscribed to #core"
      # a leading # is not doubled when the message already carries one
      assert html =~ "unsubscribed from #rant"
      refute html =~ "sent a channel message"
      # a toggle that names no channel still reads as a toggle
      assert html =~ "toggled a channel subscription"
    end

    test "about updates name the profile they touch", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%about-alice.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "about",
          "about" => "@alice:.ed25519",
          "name" => "Alice"
        }),
        ssb_msg("%about-bob.sha256", "@alice:.ed25519", now - 500, %{
          "type" => "about",
          "about" => "@bob:.ed25519",
          "description" => "Bob's bio"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      # No profiles are loaded in this payload, so the target resolves to
      # its short id — the label still names the profile it touched,
      # which is the point.
      alice = HighWire.Avatar.short_id("@alice:.ed25519")
      bob = HighWire.Avatar.short_id("@bob:.ed25519")

      assert html =~ "set #{alice}"
      assert html =~ "display name"
      assert html =~ "wrote #{bob}"
      assert html =~ "bio"
      refute html =~ "sent a about"

      # The author's name is the row's only affordance and links to their
      # profile. Both messages here are authored by @alice; the about
      # *subject* (@bob) is named in the sentence but is not the link.
      assert html =~ ~s(href="/profile?id=#{URI.encode_www_form("@alice:.ed25519")}")
      refute html =~ ~s(href="/profile?id=#{URI.encode_www_form("@bob:.ed25519")}")
    end

    test "a post body clamps to four lines and carries an expand toggle", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%long-post.sha256", "@alice:.ed25519", now, %{
          "type" => "post",
          "text" => "a long post body"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      # The body renders clamped and the toggle ships hidden: whether a
      # body actually overflows depends on width and markdown, so the
      # ClampRows hook measures and reveals it — the server never decides.
      assert html =~ "line-clamp-4"
      assert html =~ "data-clamp-toggle"
      assert html =~ ~s(phx-value-key="%long-post.sha256")
      assert html =~ "show more"

      html = render_click(view, "expand", %{"key" => "%long-post.sha256"})

      # Expanded: the clamp is gone and the toggle now offers to collapse.
      refute html =~ "line-clamp-4"
      assert html =~ ~s(data-expanded="true")
      assert html =~ "show less"
    end

    test "pub, room alias and post-edit rows read as sentences, not protocol types", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%pub-freesocial.sha256", "@alice:.ed25519", now - 3_000, %{
          "type" => "pub",
          "address" => %{"host" => "pub.freesocial.co", "port" => 8008}
        }),
        ssb_msg("%alias-linuxuser.sha256", "@alice:.ed25519", now - 2_000, %{
          "type" => "room/alias",
          "alias" => "linuxuser",
          "room" => "@room=.ed25519"
        }),
        ssb_msg("%edit-root.sha256", "@alice:.ed25519", now - 1_500, %{
          "type" => "post",
          "text" => "the original post"
        }),
        ssb_msg("%edit-rev.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%edit-root.sha256",
          "text" => "the revised post"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      assert html =~ "announced the pub pub.freesocial.co"
      assert html =~ "registered the alias linuxuser"

      # The post-edit revises a post in the window, so it collapses onto
      # that post's row: the row carries the newest text rather than a
      # bare "edited their post" line pointing nowhere.
      assert html =~ "the revised post"
      refute html =~ "the original post"

      refute html =~ "sent a pub message"
      refute html =~ "sent a room/alias message"
      refute html =~ "sent a post-edit message"
    end

    test "an unknown protocol type still reads as a phrase, not a slug", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%weird.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "secret/thing"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      assert html =~ "sent a secret thing message"
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
      notify(view, feed_payload(msgs))

      # The request lands on the supervised Timeline as a parked want —
      # the same path cursor-page rows use once the engine is up.
      wants = :sys.get_state(HighWire.Timeline).profile_wants
      assert MapSet.member?(wants, author)
    end

    test "an edited post is marked edited", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%ed-root.sha256", "@alice:.ed25519", now - 2_000, %{
          "type" => "post",
          "text" => "first draft"
        }),
        ssb_msg("%ed-rev.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%ed-root.sha256",
          "text" => "final draft"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      # The row shows the revision's text and admits it was revised.
      assert html =~ "final draft"
      refute html =~ "first draft"
      assert html =~ "edited"
      refute html =~ "edited by"
    end

    test "a post revised by several feeds names them", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%multi-root.sha256", "@alice:.ed25519", now - 3_000, %{
          "type" => "post",
          "text" => "v1"
        }),
        ssb_msg("%multi-e1.sha256", "@alice:.ed25519", now - 2_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%multi-root.sha256",
          "text" => "v2"
        }),
        ssb_msg("%multi-e2.sha256", "@bob:.ed25519", now - 1_000, %{
          "type" => "post-edit",
          "revisionRoot" => "%multi-root.sha256",
          "text" => "v3"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      alice = HighWire.Avatar.short_id("@alice:.ed25519")
      bob = HighWire.Avatar.short_id("@bob:.ed25519")

      assert html =~ "v3"
      assert html =~ "edited by #{bob}, #{alice}"
    end
  end

  describe "composer mentions" do
    test "the popup suggests follows and profiles, and closes cleanly", %{conn: conn} do
      alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"

      {:ok, view, html} = live(conn, "/")
      assert html =~ "phx-hook=\"Mentions\""

      payload =
        feed_payload([])
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
    assert notify(view, feed_payload([alice])) =~ "gossip-arrived"

    # The same wave again: nothing new, and the glow retires.
    refute notify(view, feed_payload([alice])) =~ "gossip-arrived"

    # Replication brings a newer post: only that wave lights up.
    assert notify(view, feed_payload([bob, alice])) =~ "gossip-arrived"
  end

  test "rows are named after their message, not their position", %{conn: conn} do
    now = 1_700_000_000_000
    token = fn key -> Base.url_encode64(key, padding: false) end

    older =
      ssb_msg("%older-a.sha256", "@alice.ed25519", now - 50_000, %{
        "type" => "post",
        "text" => "older words"
      })

    newer =
      ssb_msg("%newer-b.sha256", "@bob.ed25519", now - 1_000, %{
        "type" => "post",
        "text" => "newer words"
      })

    {:ok, view, _html} = live(conn, "/")
    html = notify(view, feed_payload([older, newer]))

    id_a = "row-" <> token.("%older-a.sha256")
    id_b = "row-" <> token.("%newer-b.sha256")

    assert html =~ ~s(id="#{id_a}")
    assert html =~ ~s(id="#{id_b}")
    # the article inside the row carries the same token, not the index
    assert html =~ ~s(id="post-#{token.("%older-a.sha256")}")
    assert pos(html, id_b) < pos(html, id_a)

    # A newer post lands on top. Both rows shift down a place — the
    # position changes, the identity is the message, so the id must not.
    newest =
      ssb_msg("%newest-c.sha256", "@carol.ed25519", now, %{
        "type" => "post",
        "text" => "brand new words"
      })

    html = notify(view, feed_payload([newest, older, newer]))

    assert html =~ ~s(id="#{id_a}")
    assert html =~ ~s(id="#{id_b}")
    assert pos(html, "row-" <> token.("%newest-c.sha256")) < pos(html, id_b)
    assert pos(html, id_b) < pos(html, id_a)
  end

  test "the rail badge counts gossip connections", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    refute html =~ "· 3"

    send(view.pid, {HighWire.Timeline, :gossip, %{connected: 3}})

    assert render(view) =~ "· 3"
  end

  test "network activity lights the header indicator and then retires", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # Timeline is one shared process, so pin the window rather than
    # assuming a fresh one — any earlier test may have just bumped it.
    quiet = %{last_net_at: 1, last_gossip_at: nil, active?: false}
    send(view.pid, {HighWire.Timeline, :transfer, quiet})
    refute render(view) =~ ~s(id="transfer-activity")

    send(view.pid, {HighWire.Timeline, :transfer, %{quiet | active?: true}})
    assert render(view) =~ ~s(id="transfer-activity")

    send(view.pid, :transfer_clear)
    refute render(view) =~ ~s(id="transfer-activity")
  end

  test "search reaches replies, not just rendered roots", %{conn: conn} do
    now = System.system_time(:millisecond)

    root =
      ssb_msg("%root-x.sha256", "@alice.ed25519", now - 1_000, %{
        "type" => "post",
        "text" => "the main topic"
      })

    reply =
      ssb_msg("%reply-x.sha256", "@bob.ed25519", now, %{
        "type" => "post",
        "text" => "obscure side point",
        "root" => "%root-x.sha256"
      })

    {:ok, view, _html} = live(conn, "/")
    notify(view, feed_payload([root, reply]))

    # The reply's text appears in no rendered root — only the window's
    # flat message list carries it — yet searching it surfaces the row.
    html = render_change(view, "search", %{"q" => "obscure"})
    assert html =~ "the main topic"

    html = render_change(view, "search", %{"q" => "main topic"})
    assert html =~ "the main topic"

    html = render_change(view, "search", %{"q" => "zzznope"})
    assert html =~ "Nothing matches"
    refute html =~ "the main topic"
  end

  describe "feed coherence" do
    test "a reply bumps an already-shown thread to the top", %{conn: conn} do
      base = 1_700_000_000_000

      root_a =
        ssb_msg("%root-a.sha256", "@alice.ed25519", base - 5_000, %{
          "type" => "post",
          "text" => "thread A"
        })

      root_b =
        ssb_msg("%root-b.sha256", "@bob.ed25519", base - 1_000, %{
          "type" => "post",
          "text" => "thread B"
        })

      {:ok, view, _html} = live(conn, "/")

      html = notify(view, feed_payload([root_a, root_b]))
      assert pos(html, "thread B") < pos(html, "thread A")

      # A reply to the older thread lands in the window: it must overtake
      # B, not stay frozen at its original position.
      reply_a =
        ssb_msg("%reply-a.sha256", "@carol.ed25519", base, %{
          "type" => "post",
          "text" => "bumping reply",
          "root" => "%root-a.sha256"
        })

      html = notify(view, feed_payload([reply_a, root_a, root_b]))
      assert pos(html, "thread A") < pos(html, "thread B")
    end

    test "a reply aging out of the window never sinks a loaded thread", %{conn: conn} do
      base = 1_700_000_000_000

      root_a =
        ssb_msg("%root-a.sha256", "@alice.ed25519", base - 5_000, %{
          "type" => "post",
          "text" => "thread A"
        })

      reply_a =
        ssb_msg("%reply-a.sha256", "@carol.ed25519", base, %{
          "type" => "post",
          "text" => "hot reply",
          "root" => "%root-a.sha256"
        })

      root_b =
        ssb_msg("%root-b.sha256", "@bob.ed25519", base - 1_000, %{
          "type" => "post",
          "text" => "thread B"
        })

      {:ok, view, _html} = live(conn, "/")

      html = notify(view, feed_payload([reply_a, root_a, root_b]))
      assert pos(html, "thread A") < pos(html, "thread B")

      # The window slid: A's reply aged out, so the fresh row's activity
      # dropped back to the root's time. The already-earned position
      # stays — the merge is raise-only.
      html = notify(view, feed_payload([root_a, root_b]))
      assert pos(html, "thread A") < pos(html, "thread B")
    end

    test "a bumped thread keeps its reply previews after the bump", %{conn: conn} do
      base = 1_700_000_000_000

      root =
        ssb_msg("%root-a.sha256", "@alice.ed25519", base - 10_000, %{
          "type" => "post",
          "text" => "the thread"
        })

      reply =
        ssb_msg("%reply-a.sha256", "@bob.ed25519", base, %{
          "type" => "post",
          "text" => "the bumping reply",
          "root" => "%root-a.sha256"
        })

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload([reply, root]))
      assert html =~ "the bumping reply"

      # A later heartbeat without the reply in the slice must not lose
      # the preview the bump earned.
      html = notify(view, feed_payload([root]))
      assert html =~ "the bumping reply"
    end

    test "the window's rows are capped so first paint isn't a wall of rows", %{conn: conn} do
      now = 1_700_000_000_000

      # More standalone roots than the tab cap; `words 1` is oldest.
      msgs =
        for i <- 1..(HighWireWeb.TimelineLive.max_tab_rows() + 40) do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - (200 - i) * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      capped = HighWireWeb.TimelineLive.max_tab_rows()
      assert count(html, "id=\"post-") == capped

      # The newest (highest-activity) rows survive the cap...
      assert html =~ "words #{capped + 40}"
      assert html =~ "words #{capped + 39}"
      # ...and the oldest were dropped, not all rendered.
      refute html =~ "words 1#{~s(</p>)}"
    end

    test "rows paged in past the window survive the cap", %{conn: conn} do
      now = 1_700_000_000_000
      capped = HighWireWeb.TimelineLive.max_tab_rows()

      # A window with more roots than the tab cap: first paint paints
      # exactly `capped` of them, the newest.
      msgs =
        for i <- 1..(capped + 40) do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - (200 - i) * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))
      assert count(html, "id=\"post-") == capped

      # The next cursor page is older than everything the window
      # carried, which is the whole point of scrolling for it.
      older =
        for i <- 1..5 do
          ssb_msg("%old-#{i}.sha256", "@carol:.ed25519", now - (1_000 + i) * 1_000, %{
            "type" => "post",
            "text" => "deeper #{i}"
          })
        end

      page = %{rows: HighWire.Timeline.build_feed(older, nil, %{}), resume: 42, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render(view)

      assert html =~ "deeper 1"
      assert count(html, "id=\"post-") == capped + 5

      # A later heartbeat (same window) must not re-trim what the reader
      # paged in — the cap has to be idempotent, or the feed slides back
      # up on every broadcast.
      html = notify(view, feed_payload(msgs))
      assert html =~ "deeper 1"
      assert count(html, "id=\"post-") == capped + 5

      # And a second page keeps going deeper, beyond anything the window
      # could reach.
      deeper =
        for i <- 1..5 do
          ssb_msg("%deeper-#{i}.sha256", "@carol:.ed25519", now - (2_000 + i) * 1_000, %{
            "type" => "post",
            "text" => "ancient #{i}"
          })
        end

      page = %{rows: HighWire.Timeline.build_feed(deeper, nil, %{}), resume: 84, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render(view)

      assert html =~ "ancient 5"
      assert count(html, "id=\"post-") == capped + 10
    end

    test "a page the engine failed to return does not end the feed", %{conn: conn} do
      now = 1_700_000_000_000
      capped = HighWireWeb.TimelineLive.max_tab_rows()

      msgs =
        for i <- 1..(capped + 5) do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - (200 - i) * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      notify(view, feed_payload(msgs))

      # One page arrives, then the request for the next never comes back.
      older =
        for i <- 1..3 do
          ssb_msg("%old-#{i}.sha256", "@carol:.ed25519", now - (1_000 + i) * 1_000, %{
            "type" => "post",
            "text" => "deeper #{i}"
          })
        end

      page = %{rows: HighWire.Timeline.build_feed(older, nil, %{}), resume: 42, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render(view)
      assert html =~ "deeper 1"
      assert html =~ "feed-sentinel"

      send(view.pid, {:page_failed, :public, 42})
      html = render(view)

      # A failed load is not an empty last page. The rows already paged in
      # survive, `more` still stands, and the sentinel stays — so the feed
      # keeps its way into the past instead of quietly declaring itself
      # finished for good.
      assert html =~ "deeper 1"
      assert html =~ "feed-sentinel"
    end

    test "a failed page retries on a capped exponential backoff" do
      delay = &HighWireWeb.TimelineLive.page_retry_delay/1

      assert delay.(0) == 1_000
      assert delay.(1) == 2_000
      assert delay.(2) == 4_000
      # The cap keeps a long outage from stretching the retries without
      # bound.
      assert delay.(10) == 30_000
      assert delay.(50) == 30_000
    end

    test "a page in flight tells the reader it is loading more", %{conn: conn} do
      now = 1_700_000_000_000

      msgs =
        for i <- 1..8 do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - i * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      notify(view, feed_payload(msgs))

      # With nothing outstanding the tail is silent.
      page = %{rows: HighWire.Timeline.build_feed(msgs, nil, %{}), resume: 42, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render(view)
      assert html =~ "feed-sentinel"
      refute html =~ "feed-loading"

      # Ask for the next page: the request is in flight, and says so.
      html = render_click(view, "load-more", %{})
      assert html =~ "feed-loading"
      assert html =~ "Loading more…"

      # It clears when the answer lands.
      send(view.pid, {:page_loaded, :public, 42, %{rows: [], resume: nil, more: false}})
      html = render(view)
      refute html =~ "feed-loading"
    end

    test "the feed says when it has run out, and stays quiet while searching", %{conn: conn} do
      now = 1_700_000_000_000

      msgs =
        for i <- 1..8 do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - i * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      notify(view, feed_payload(msgs))

      # More history below the fold: a sentinel, and no claim of an end.
      page = %{rows: HighWire.Timeline.build_feed(msgs, nil, %{}), resume: 42, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render(view)
      assert html =~ "feed-sentinel"
      refute html =~ "feed-end"

      # The next page reports nothing further back — that is the end.
      send(view.pid, {:page_loaded, :public, 42, %{rows: [], resume: nil, more: false}})
      html = render(view)
      refute html =~ "feed-sentinel"
      assert html =~ "End of feed."

      # A search is over matches, not over depth: the footer must not
      # read as "no more results" underneath the matches.
      html = render_click(view, "search", %{"q" => "words"})
      assert html =~ "words 1"
      refute html =~ "feed-end"
    end

    test "an empty feed does not claim to have reached the end", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload([]))

      refute html =~ "feed-end"
      assert html =~ "No messages yet."
    end
  end

  defp ssb_msg(key, author, ts, content) do
    %{"key" => key, "value" => %{"author" => author, "timestamp" => ts, "content" => content}}
  end

  # Mirrors the payload's search projection: only key, author and the
  # post text's type/root survive the wire — plus the few extra fields
  # each event type's sentence is built from. Search reads nothing else.
  defp slim(msg) do
    c = msg["value"]["content"]
    base = ["type", "text", "root"]

    fields =
      case c do
        %{"type" => type} when is_binary(type) ->
          Map.get(HighWire.Timeline.event_projection_fields(), type, [])

        _ ->
          []
      end

    %{
      "key" => msg["key"],
      "value" => %{
        "author" => msg["value"]["author"],
        "content" => Map.take(c, base ++ fields)
      }
    }
  end

  # A Timeline payload as finalize/1 broadcasts it — the window rows come
  # straight from the same builder the engine uses.
  defp feed_payload(msgs, opts \\ []) do
    self_id = Keyword.get(opts, :self_id)
    follows = Keyword.get(opts, :follows, [])
    suggestions = Keyword.get(opts, :suggestions, [])
    contacts = Keyword.get(opts, :contacts, [])
    likes = HighWire.Timeline.likes_state(msgs)
    counts = HighWire.Timeline.like_counts(likes)

    %{
      feed: HighWire.Timeline.build_feed(msgs, self_id, counts),
      messages: Enum.map(msgs, &slim/1),
      reply_counts: %{},
      like_counts: counts,
      likes_by: HighWire.Timeline.like_authors(likes),
      my_likes: HighWire.Timeline.my_likes(likes, self_id),
      index: Map.new(msgs, fn m -> {m["key"], m["value"]["author"]} end),
      follows: follows,
      self_id: self_id,
      profiles: %{},
      suggestions: suggestions,
      contacts: contacts
    }
  end

  defp notify(view, payload) do
    send(view.pid, {HighWire.Timeline, :updated, payload})
    # The send is async, so render/1 would return the pre-payload rows.
    # "expand" with a no-op key is a synchronous no-op that still forces
    # LiveView to drain the mailbox (and process the payload) first.
    _ = render_click(view, "expand", %{"key" => "__notify__"})
    render(view)
  end

  defp pos(html, needle) do
    case :binary.match(html, needle) do
      {idx, _} -> idx
      :nomatch -> flunk("expected #{inspect(needle)} in the feed HTML")
    end
  end

  defp count(html, needle) do
    html
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
  end

  # How many of the known follow ids actually appear in the rendered
  # HTML. The rail links each visible contact to its profile, and these
  # test ids are unique strings that appear nowhere else, so a simple
  # containment check counts the visible rows without depending on which
  # random handful the rail picked.
  # The rail renders each contact by its short id (Ident.short_id/1), so
  # containment has to look for that, not the full feed id.
  defp count_visible_contacts(html, follows) do
    Enum.count(follows, fn id -> String.contains?(html, HighWire.Avatar.short_id(id)) end)
  end

  # Which of the known follow ids appear, in the given order — enough to
  # tell whether the collapsed window held or moved between renders.
  defp visible_contacts(html, follows) do
    Enum.filter(follows, &String.contains?(html, HighWire.Avatar.short_id(&1)))
  end
end
