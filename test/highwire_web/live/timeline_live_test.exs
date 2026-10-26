defmodule HighWireWeb.TimelineLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "timeline renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Timeline"
    # sidecar disabled under test
    assert html =~ "Publishing is turned off"
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
    assert html =~ "Offline"
    assert html =~ ~s(href="/network")
  end

  test "the header shows the search index status", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    # engine disabled under test — same contract as the network chip:
    # the indicator renders its state rather than hiding. It is a dot
    # beside the search box, so the state rides on data-status (and the
    # tooltip), not on label text.
    assert html =~ ~s(id="search-index-status")
    assert html =~ ~s(data-status="disabled")
  end

  test "the crawling index tooltip separates thousands instead of eating a digit", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # The count the header reported as "6000,000": the pattern captured
    # the lookahead's triplet in \1 and replaced the digit it meant to
    # keep, so no count of 1,000 or more came out right.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns
      changed = Map.put(assigns.__changed__, :index_status, true)
      assigns = %{assigns | index_status: {:crawling, 60_000}, __changed__: changed}
      %{state | socket: %{socket | assigns: assigns}}
    end)

    # A message wakes the view so it renders the change (and the barrier
    # puts the diff in the test client's mailbox before it is asked).
    send(view.pid, :nudge)
    :sys.get_state(view.pid)
    html = render(view)

    assert html =~ "60,000 messages so far"
    refute html =~ "6000,000"
  end

  test "the contacts rail never sits empty", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "No contacts yet"
  end

  test "the rail shows Whom to follow when a payload carries suggestions", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    # the section keeps its heading when there is nothing to offer yet
    assert html =~ "Whom to follow"
    assert html =~ "Friend-of-friend suggestions will appear here"

    row = %{"id" => "@stranger=.ed25519", "followers" => 2}
    html = notify(view, %{feed_payload([]) | suggestions: [row]})

    assert html =~ "Whom to follow"
    refute html =~ "No suggestions yet"
    # followers ride on hover; the row itself carries no numbers
    assert html =~ "2 followers"
    # With no profile loaded the name falls back to the shortened id,
    # and the row still links to the full one.
    assert html =~ ~s(href="/profile?id=%40stranger%3D.ed25519")
  end

  test "the rail offers another set", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    # Present whether or not a set is loaded yet — an empty rail can
    # still ask for one.
    assert html =~ "Show another set"

    # The ranking runs off-process, so there is no round trip for the
    # press to wait in: it is answered by taking the hold, and the
    # button stays down until an answer lands.
    html = element(view, ~s(button[phx-click="refresh-suggestions"])) |> render_click()
    assert html =~ "Finding…"
    assert html =~ ~r/phx-click="refresh-suggestions"[^>]*disabled/

    # A second press in the meantime has the same ranking to do again,
    # so the handler holds the door shut as well as the button does.
    html = render_click(view, "refresh-suggestions", %{})
    assert html =~ "Finding…"

    # The answer comes back over the next payload: the set is on the
    # rail and the button is available again.
    row = %{"id" => "@stranger=.ed25519", "followers" => 2}
    html = notify(view, %{feed_payload([]) | suggestions: [row]})

    assert html =~ "Show another set"
    refute html =~ "Finding…"
    assert html =~ "2 followers"
  end

  test "a set that never comes back lets go of the button", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    html = element(view, ~s(button[phx-click="refresh-suggestions"])) |> render_click()
    assert html =~ "Finding…"

    # The ranking went quiet: the hold ends of its own accord, so the
    # rail is never left with a button that cannot be pressed.
    send(view.pid, :suggestions_hold_over)
    _ = render_click(view, "expand", %{"key" => "__notify__"})

    html = render(view)
    assert html =~ "Show another set"
    refute html =~ "Finding…"
  end

  test "the header Profile link opens your own profile page", %{conn: conn} do
    me = "@me=.ed25519"

    {:ok, view, html} = live(conn, "/")
    # No identity known yet — the link has nothing to point at.
    refute html =~ "Your profile"

    html = notify(view, feed_payload([], self_id: me))
    assert html =~ ~s(title="Your profile")
    assert html =~ ~s(href="/profile?id=#{URI.encode_www_form(me)}")
    # The tab button is gone; the header offers navigation, not a feed view.
    refute html =~ ~s(phx-value-v="profile")
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

    assert html =~ "Publishing is turned off in this configuration."
  end

  test "a publish is held down while the engine takes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    notify(view, feed_payload([], self_id: "@me=.ed25519"))
    render_change(view, "compose-draft", %{"body" => "hello world"})

    # The press is answered by the button taking the hold: the post is
    # on its way, and a second press in the meantime is a duplicate
    # rather than a second post.
    html = view |> form("#compose", %{"body" => "hello world"}) |> render_submit()

    assert html =~ ~r/disabled=""\s*>\s*Publishing…/

    # The engine is off under test, so the publish refuses: the box
    # keeps what was written, the reason is said, and the button is
    # back in reach for a retry.
    html = render(view)
    assert html =~ "Not connected yet. Try again in a moment."
    assert html =~ "hello world"
    refute html =~ ~r/disabled=""\s*>\s*Publishing…/
  end

  describe "private composer" do
    # Stand up the Private tab with a follow to address, since the
    # engine is off under test and the sidebar would be empty.
    defp private_view(conn, contacts \\ ["@peer=.ed25519"]) do
      {:ok, view, _html} = live(conn, "/")
      render_click(view, "view", %{"v" => "private"})

      :sys.replace_state(view.pid, fn state ->
        socket = state.socket
        assigns = socket.assigns

        changed =
          assigns.__changed__
          |> Map.put(:all_contacts, assigns.all_contacts)
          |> Map.put(:self_id, assigns.self_id)
          |> Map.put(:status, assigns.status)

        assigns =
          assigns
          |> Map.put(:all_contacts, contacts)
          |> Map.put(:self_id, "@me=.ed25519")
          |> Map.put(:status, :ok)
          |> Map.put(:__changed__, changed)

        %{state | socket: %{socket | assigns: assigns}}
      end)

      send(view.pid, :nudge)
      :sys.get_state(view.pid)
      view
    end

    test "the composer appears on the Private tab with a recipient list", %{conn: conn} do
      view = private_view(conn)
      html = render(view)

      assert html =~ ~s(id="compose")
      assert html =~ "Private thread. Choose who can read it."
      assert html =~ ~s(name="recipients[]")
      assert html =~ ~s(value="@peer=.ed25519")
    end

    test "a private post without a recipient is refused locally", %{conn: conn} do
      view = private_view(conn)

      html =
        view
        |> form("#compose", %{"body" => "just me"})
        |> render_submit()

      assert html =~ "Choose at least one recipient."
    end

    test "a recipient selection survives a draft keystroke", %{conn: conn} do
      view = private_view(conn)

      html =
        render_change(view, "compose-draft", %{
          "body" => "half",
          "recipients" => ["@peer=.ed25519"]
        })

      assert html =~ "half"
      assert html =~ ~s(value="@peer=.ed25519" checked)
    end

    test "the composer is hidden on the Public tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      assert render(view) =~ ~s(id="compose")
      refute render(view) =~ "Private thread. Choose who can read it."
    end
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

    test "search does not crash on the Private tab", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%root-secret.sha256", "@alice:.ed25519", now, %{
          "type" => "post",
          "text" => "secret words"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      _html = notify(view, feed_payload(msgs, self_id: "@me:.ed25519"))

      _html = render_click(view, "view", %{"v" => "private"})

      # search_rows filters the window through in_scope?, which had no
      # :private clause — any query on this tab raised a
      # FunctionClauseError and took the view down with it.
      html = render_click(view, "search", %{"q" => "secret"})
      assert is_binary(html)
    end

    test "blocks land as their own rows beside follows and unfollows", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%follow-dave.sha256", "@alice:.ed25519", now - 2_000, %{
          "type" => "contact",
          "contact" => "@dave:.ed25519",
          "following" => true
        }),
        ssb_msg("%block-eve.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "contact",
          "contact" => "@eve:.ed25519",
          "blocking" => true
        }),
        ssb_msg("%unfollow-frank.sha256", "@alice:.ed25519", now - 500, %{
          "type" => "contact",
          "contact" => "@frank:.ed25519",
          "following" => false
        }),
        ssb_msg("%unblock-hank.sha256", "@alice:.ed25519", now - 250, %{
          "type" => "contact",
          "contact" => "@hank:.ed25519",
          "blocking" => false
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      # each direction is named, not lumped under "followed"
      assert html =~ "followed"
      assert html =~ "blocked"
      assert html =~ "unfollowed"
      assert html =~ "unblocked"

      dave = URI.encode_www_form("@dave:.ed25519")
      eve = URI.encode_www_form("@eve:.ed25519")
      frank = URI.encode_www_form("@frank:.ed25519")
      hank = URI.encode_www_form("@hank:.ed25519")

      assert html =~ dave
      assert html =~ eve
      assert html =~ frank
      assert html =~ hank

      # one row per direction, newest activity first
      assert pos(html, hank) < pos(html, frank)
      assert pos(html, frank) < pos(html, eve)
      assert pos(html, eve) < pos(html, dave)
    end

    test "a cooled-off spate keeps its own line beside the live one", %{conn: conn} do
      now = 1_700_000_000_000

      msgs = [
        ssb_msg("%block-old.sha256", "@alice:.ed25519", now - :timer.hours(48), %{
          "type" => "contact",
          "contact" => "@eve:.ed25519",
          "blocking" => true
        }),
        ssb_msg("%block-new.sha256", "@alice:.ed25519", now - 1_000, %{
          "type" => "contact",
          "contact" => "@frank:.ed25519",
          "blocking" => true
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      eve = URI.encode_www_form("@eve:.ed25519")
      frank = URI.encode_www_form("@frank:.ed25519")

      # two lines, not one row re-counting the older spate — the live
      # spate is anchored at the newest edit and the cooled-off one keeps
      # its own anchor, so the row dedupe must not collapse them
      assert count(html, "blocked") == 2
      assert html =~ eve
      assert html =~ frank
      assert pos(html, frank) < pos(html, eve)
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

    test "every liker links to their profile, with none folded into a +N", %{conn: conn} do
      now = 1_700_000_000_000
      likers = for i <- 1..6, do: "@liker#{i}=.ed25519"

      votes =
        likers
        |> Enum.with_index(1)
        |> Enum.map(fn {id, i} ->
          ssb_msg("%vote-#{i}.sha256", id, now - i * 1_000, %{
            "type" => "vote",
            "vote" => %{"link" => "%root-six.sha256", "value" => 1, "expression" => "like"}
          })
        end)

      msgs =
        [
          ssb_msg("%root-six.sha256", "@alice:.ed25519", now - 9_000, %{
            "type" => "post",
            "text" => "the thing"
          })
        ] ++ votes

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      # Six voters, six faces, six ways to their profile: the list is
      # the count, so the fifth and sixth are not cut off behind a "+N".
      for id <- likers do
        assert html =~ ~s(href="/profile?id=#{URI.encode_www_form(id)}")
      end

      refute html =~ ~s(text-faint">+2</span>)
    end

    test "a row's face opens that person's profile, like every other face", %{conn: conn} do
      now = 1_700_000_000_000
      alice = "@alice:.ed25519"

      msgs = [
        ssb_msg("%face-row.sha256", alice, now - 1_000, %{
          "type" => "post",
          "text" => "hello"
        })
      ]

      payload =
        feed_payload(msgs)
        |> Map.put(:profiles, %{alice => %{name: "Alice", image: nil}})

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, payload)

      href = ~s(href="/profile?id=#{URI.encode_www_form(alice)}")

      # The tile and the byline are two ways to the same page — and the
      # tile carries the name itself, so it says who it is on its own.
      assert html =~ ~s(aria-label="Alice")
      assert count(html, href) == 2
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

      # The press fills the heart at once and holds the pill down: the
      # reader's own like is shown before the engine has answered, and a
      # second press in the meantime is a duplicate.
      held = element(view, ~s(button[aria-label="Like"])) |> render_click()

      assert held =~ ~s(aria-pressed="true")
      assert held =~ ~r/phx-click="like"[^>]*disabled/

      # The engine is off under test, so the publish refuses: the
      # optimistic fill must not linger on a row the store never saw,
      # and the reader is told what happened rather than left to notice
      # the heart empty again.
      html = render(view)
      refute html =~ ~s(aria-pressed="true")
      assert html =~ "That like didn&#39;t go through"
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
          "type" => "secret-thing"
        })
      ]

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      assert html =~ "sent a secret thing message"
    end

    test "a run of unknown messages reads as one row, not an expandable stack", %{conn: conn} do
      now = 1_700_000_000_000

      msgs =
        for {key, type, ago} <- [
              {"%mc1.sha256", "movieclub/new", 3_000},
              {"%mc2.sha256", "movieclub/review", 2_000},
              {"%mc3.sha256", "movieclub/new", 1_000}
            ] do
          ssb_msg(key, "@alice:.ed25519", now - ago, %{
            "type" => type,
            "title" => "film"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload(msgs))

      # One line for the burst, anchored on the newest message: the
      # family was repeated, and the sub-type is nothing to a reader who
      # does not implement the protocol.
      assert count(html, "sent some movieclub messages") == 1
      refute html =~ "movieclub new"
      refute html =~ "movieclub review"
      refute html =~ "+2 more"
      refute html =~ "show less"
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

    test "the rail asks Timeline to profile suggestion rows no payload carried", %{conn: conn} do
      id = "@railsuggest=.ed25519"

      {:ok, view, _html} = live(conn, "/")
      # What a freshly drawn set looks like: the rows arrive, and the
      # profiles map — built from window participants and follows —
      # carries nothing for them.
      notify(view, feed_payload([], suggestions: [%{"id" => id, "followers" => 7}]))

      # Asked for on render, not on the next finalize: the feed id of a
      # suggestion is neither followed nor in the window, so without
      # this it would wait out the 13s heartbeat on its identicon.
      wants = :sys.get_state(HighWire.Timeline).profile_wants
      assert MapSet.member?(wants, id)
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

    # The query is still out. Nothing is known yet, so the view says so
    # rather than presenting "no matches" as an answer.
    assert html =~ "Searching…"
    refute html =~ "Nothing matches"

    html = wait_for_search_answer(view)
    assert html =~ "Nothing matches"
    refute html =~ "the main topic"
  end

  test "a search says it is searching until the index answers", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    notify(view, feed_payload([]))

    html = render_change(view, "search", %{"q" => "zzznope"})
    assert html =~ "Searching…"
    refute html =~ "Nothing matches"

    # The test store answers empty, and only then is that claim honest.
    html = wait_for_search_answer(view)
    refute html =~ "Searching…"
    assert html =~ "Nothing matches"
  end

  test "hits from an earlier query stay up while a new one is asked", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    notify(view, feed_payload([]))
    render_change(view, "search", %{"q" => "needle"})
    Process.sleep(50)

    send(
      view.pid,
      {:search_results, "needle",
       [%{key: "%h.sha256", author: "@alice.ed25519", text: "a needle", ts: 1_700_000_000_000}]}
    )

    assert render(view) =~ "1 match"

    # While the new query is out, its predecessor's hits stay on screen
    # — still the best answer the view has — under the searching line.
    html = render_change(view, "search", %{"q" => "haystack"})
    assert html =~ ~s(id="search-results")
    assert html =~ "1 match"
    assert html =~ "Searching…"

    # The new query's answer replaces them, so stale hits never outlive
    # the query that superseded them.
    send(view.pid, {:search_results, "haystack", []})
    html = render(view)
    refute html =~ ~s(id="search-results")
    assert html =~ "Nothing matches"
  end

  test "one query runs at a time — a typed-over query waits for the answer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    notify(view, feed_payload([]))

    # Stand in the state a kicked query leaves behind: one query out,
    # nothing answered. No real query has been asked in this test, so
    # only the messages sent below can answer anything.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        Map.merge(assigns.__changed__, %{q: true, search_q_kicked: true, search_state: true})

      assigns = %{
        assigns
        | q: "two",
          search_q_kicked: "one",
          search_state: :pending,
          __changed__: changed
      }

      %{state | socket: %{socket | assigns: assigns}}
    end)

    # Typed while the first query is out: registered, but not asked —
    # the kick belongs to the answer still in flight.
    render_change(view, "search", %{"q" => "three"})
    assert kicked_query(view) == "one"

    # The answer to the first query is stale for what is on screen, and
    # asks for that instead — once.
    send(view.pid, {:search_results, "one", []})
    assert kicked_query(view) == "three"

    # A straggling answer for the old query asks nothing a second time.
    send(view.pid, {:search_results, "one", []})
    assert kicked_query(view) == "three"

    # And the answer for what is on screen lands it.
    send(view.pid, {:search_results, "three", []})
    html = render(view)
    refute html =~ "Searching…"
    assert html =~ "Nothing matches"
  end

  test "a search the index cannot answer does not claim there are no matches", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    notify(view, feed_payload([]))

    # Wait the real answer out first, so nothing else is in flight and
    # the state below stands still.
    render_change(view, "search", %{"q" => "needle"})
    assert wait_for_search_answer(view) =~ "Nothing matches"

    # The state a query that could not be started leaves behind, which is
    # the one case where no answer is coming at all.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns
      changed = Map.put(assigns.__changed__, :search_state, true)
      assigns = %{assigns | search_state: :stalled, __changed__: changed}
      %{state | socket: %{socket | assigns: assigns}}
    end)

    # A message wakes the view so it renders the change (and the barrier
    # puts the diff in the test client's mailbox before it is asked).
    send(view.pid, :nudge)
    :sys.get_state(view.pid)
    html = render(view)
    assert html =~ "Some results may be missing"
    refute html =~ "Nothing matches"
  end

  test "store hits are the results — no separate framing, no contradiction", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_change(view, "search", %{"q" => "needle"})

    # The index's own (empty) answer lands first; stand in the hits after.
    Process.sleep(50)

    send(
      view.pid,
      {:search_results, "needle",
       [
         %{
           key: "%needle-hit.sha256",
           author: "@alice.ed25519",
           text: "a needle in the haystack",
           ts: 1_700_000_000_000
         }
       ]}
    )

    html = render(view)

    assert html =~ ~s(id="search-results")
    assert html =~ "1 match"
    assert html =~ "in the haystack"
    # and nothing contradicts it or treats it as a side-channel
    refute html =~ "Nothing matches"
    refute html =~ "whole store"
  end

  test "the composer steps aside while search results are up", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ ~s(id="compose")

    html = render_change(view, "search", %{"q" => "ugly"})
    refute html =~ ~s(id="compose")

    html = render_change(view, "search", %{"q" => ""})
    assert html =~ ~s(id="compose")
  end

  test "store snippets are a three-line window centred on the query", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_change(view, "search", %{"q" => "needle"})
    Process.sleep(50)

    # match deep in a long body, with distinctive runs on either side
    long =
      String.duplicate("X", 500) <>
        " needle appears deep in this body " <> String.duplicate("Y", 500)

    send(
      view.pid,
      {:search_results, "needle",
       [%{key: "%long-hit.sha256", author: "@alice.ed25519", text: long, ts: 1_700_000_000_000}]}
    )

    html = render(view)

    assert html =~ "needle appears deep in this body"
    # the passage continues either side of the window, with ellipses
    assert html =~ "…"
    # and the window is bounded: neither unbroken run appears at full length
    refute html =~ String.duplicate("X", 130)
    refute html =~ String.duplicate("Y", 130)
  end

  test "store snippets open and close on whole words", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    render_change(view, "search", %{"q" => "needle"})
    Process.sleep(50)

    # the cut lands mid-word on both sides: 140 is inside "alpha", 340 is
    # inside "omega" — the snippet must still carry both words whole
    long = String.duplicate("alpha ", 40) <> "needle" <> String.duplicate(" omega", 40)

    send(
      view.pid,
      {:search_results, "needle",
       [%{key: "%word-hit.sha256", author: "@alice.ed25519", text: long, ts: 1_700_000_000_000}]}
    )

    html = render(view)

    assert html =~ "…alpha alpha"
    assert html =~ "omega…"
    refute html =~ "…lpha"
    refute html =~ "omeg…"
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

    test "each reply preview opens the reply it previews", %{conn: conn} do
      base = 1_700_000_000_000

      root =
        ssb_msg("%root-a.sha256", "@alice.ed25519", base - 10_000, %{
          "type" => "post",
          "text" => "the thread"
        })

      one =
        ssb_msg("%reply-one.sha256", "@bob.ed25519", base - 5_000, %{
          "type" => "post",
          "text" => "the first answer",
          "root" => "%root-a.sha256"
        })

      two =
        ssb_msg("%reply-two.sha256", "@carol.ed25519", base, %{
          "type" => "post",
          "text" => "the second answer",
          "root" => "%root-a.sha256"
        })

      {:ok, view, _html} = live(conn, "/")
      html = notify(view, feed_payload([root, one, two]))

      one_path = "/post/" <> Base.url_encode64("%reply-one.sha256", padding: false)
      two_path = "/post/" <> Base.url_encode64("%reply-two.sha256", padding: false)
      head_path = "/post/" <> Base.url_encode64("%root-a.sha256", padding: false)

      # A preview is a reply in its own right, so it carries the path of
      # that reply: the reader clicks the answer they want to read, and
      # the post view opens on it.
      assert html =~ ~s(href="#{one_path}")
      assert html =~ ~s(href="#{two_path}")
      # and not the thread's head, which the row itself opens
      refute html =~ ~s(href="#{head_path}")
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
      # survive, `more` still stands, the sentinel stays — and the failure
      # says so with a manual way past it — so the feed keeps its way into
      # the past instead of quietly declaring itself finished for good.
      assert html =~ "deeper 1"
      assert html =~ "feed-sentinel"
      assert html =~ "feed-page-error"
      assert html =~ "Older posts did not load."
      assert html =~ "feed-load-more"
      assert html =~ "Try again"
      refute html =~ "feed-end"
    end

    test "a first page that never comes back is recognized, not read as the end", %{conn: conn} do
      now = 1_700_000_000_000

      msgs =
        for i <- 1..3 do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - i * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      notify(view, feed_payload(msgs))

      # The engine never answers the fill: this was the packaged app's
      # report — window rows on screen, then a false "End of feed." while
      # history still stood unasked. Now it reads as the failure it is,
      # with the manual load beside it.
      send(view.pid, {:page_failed, :public, nil})
      html = render(view)
      assert html =~ "words 1"
      assert html =~ "feed-page-error"
      assert html =~ "Older posts did not load."
      assert html =~ "feed-load-more"
      refute html =~ "feed-end"

      # The backoff's own retry asks again: the shell never loaded, so
      # the ask must not be dropped as "nothing outstanding" — the
      # failure line stays either way, which is what a drop would erase.
      send(view.pid, {:retry_page, :public, nil})
      html = render(view)
      assert html =~ "feed-page-error"
      refute html =~ "feed-end"
    end

    test "the manual load stands whenever there is more to ask for", %{conn: conn} do
      now = 1_700_000_000_000

      msgs =
        for i <- 1..3 do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - i * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")
      notify(view, feed_payload(msgs))

      page = %{rows: HighWire.Timeline.build_feed(msgs, nil, %{}), resume: 42, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render(view)

      # A browser push that never reached the server leaves no failure
      # signal at all — so the manual way past is on screen regardless,
      # and a stale retry from the superseded first page cannot hang a
      # failure line under a feed that is paging fine.
      assert html =~ "feed-load-more"
      assert html =~ "Load more"
      refute html =~ "feed-page-error"

      html = render_click(view, "load-more", %{})
      assert html =~ "Loading more…"
      refute html =~ "feed-end"
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

    test "the manual load reads from its own state" do
      label = &HighWireWeb.TimelineLive.load_more_label/2

      # A press holds the control while its answer is on the way, a
      # failure asks again, and otherwise the load is just offered.
      assert label.(true, true) == "Loading…"
      assert label.(true, false) == "Loading…"
      assert label.(false, true) == "Try again"
      assert label.(false, false) == "Load more"
    end

    test "the fill behind the window does not flash the loading bar", %{conn: conn} do
      now = 1_700_000_000_000

      msgs =
        for i <- 1..8 do
          ssb_msg("%root-#{i}.sha256", "@bob:.ed25519", now - i * 1_000, %{
            "type" => "post",
            "text" => "words #{i}"
          })
        end

      {:ok, view, _html} = live(conn, "/")

      # An updated payload turns the feed on and kicks its own first page
      # with a nil resume. That fill is a background top-up behind rows
      # the window already painted, so it must not read as "loading more"
      # over a feed the reader is reading.
      notify(view, feed_payload(msgs))
      html = render(view)
      assert html =~ "words 1"
      refute html =~ "feed-loading"

      # A page past the first is the reader's own scroll into the past, and
      # that one does say so.
      page = %{rows: HighWire.Timeline.build_feed(msgs, nil, %{}), resume: 42, more: true}
      send(view.pid, {:page_loaded, :public, nil, page})
      html = render_click(view, "load-more", %{})
      assert html =~ "Loading more…"
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

  # A store query runs in its own task, so the answer lands a tick after
  # the change that asked for it. Wait the view out of its searching
  # state rather than sleeping a fixed span.
  defp wait_for_search_answer(view, tries \\ 100) do
    html = render(view)

    if tries > 0 and html =~ "Searching…" do
      Process.sleep(10)
      wait_for_search_answer(view, tries - 1)
    else
      html
    end
  end

  # The query last handed to the index — the coalescing invariant reads
  # straight off it: while an answer is out, the marker does not move.
  defp kicked_query(view) do
    :sys.get_state(view.pid).socket.assigns.search_q_kicked
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
