defmodule HighWireWeb.PostLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HighWireWeb.Components.Heart

  test "unknown key renders the not-found message", %{conn: conn} do
    key = Base.url_encode64("%missing=.sha256", padding: false)
    {:ok, _view, html} = live(conn, "/post/" <> key)

    # the copy is escaped in the markup, as all text is
    assert html =~ "That message hasn&#39;t arrived yet."
    # the rail still carries its section, with an explanation instead
    # of an empty column
    assert html =~ "In this thread"
    assert html =~ "Nothing loaded"
    # and a way back — the content column's own control, which Escape
    # follows too (the rail row alone is a small target)
    assert html =~ ~s(id="post-back")
    assert html =~ "← Timeline"
  end

  test "a transient fetch failure does not blank the thread on screen", %{conn: conn} do
    key = Base.url_encode64("%transient=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    root = %{
      "key" => "%transient=.sha256",
      "value" => %{
        "author" => "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519",
        "timestamp" => 1_700_000_000_000,
        "content" => %{"type" => "post", "text" => "seedkeep"}
      }
    }

    # Stand up the state a loaded thread has: a root on screen.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        assigns.__changed__
        |> Map.put(:root, assigns.root)
        |> Map.put(:not_found, assigns.not_found)

      assigns =
        assigns
        |> Map.put(:root, root)
        |> Map.put(:not_found, false)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :nudge)
    assert render(view) =~ "seedkeep"

    # A broadcast re-reads the thread. With the engine off Timeline.post/1
    # answers nil — the same nil a timed-out fetch gives — and that must
    # not tell the reader the post is gone.
    send(view.pid, {HighWire.Timeline, :updated, %{}})
    :sys.get_state(view.pid)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.root == root
    refute assigns.not_found
    assert render(view) =~ "seedkeep"
  end

  test "the reply box opens the mention popup", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%reply-mentions=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    root = %{
      "key" => "%reply-mentions=.sha256",
      "value" => %{
        "author" => alice,
        "timestamp" => 1_700_000_000_000,
        "content" => %{"type" => "post", "text" => "seedit"}
      }
    }

    # Engine is off under test, so the thread mounts empty and the
    # reply form stays hidden. Seed the root and a named profile
    # straight into the assigns, recording their old values in
    # __changed__ so the next render computes a diff instead of
    # serving the cached tree.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        assigns.__changed__
        |> Map.put(:root, assigns.root)
        |> Map.put(:profiles, assigns.profiles)
        |> Map.put(:not_found, assigns.not_found)

      assigns =
        assigns
        |> Map.put(:root, root)
        |> Map.put(:profiles, %{alice => %{name: "Alice Smith", image: nil}})
        |> Map.put(:not_found, false)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    # any message wakes the view so it computes that diff
    send(view.pid, :nudge)

    html = render(view)
    assert html =~ ~s(id="reply-body")
    assert html =~ ~s(phx-hook="Mentions")
    assert html =~ ~s(data-draft-event="reply-draft")

    html = render_click(view, "mention-query", %{"q" => "ali"})
    assert html =~ ~s(id="mention-list")
    assert html =~ "Alice Smith"
    assert html =~ ~s(data-id=") <> alice

    # no match retires the popup rather than rendering an empty box
    html = render_click(view, "mention-query", %{"q" => "zzzz"})
    refute html =~ ~s(id="mention-list")

    html = render_click(view, "mention-close", %{})
    refute html =~ ~s(id="mention-list")
  end

  test "profile fill-ins survive a payload that no longer carries them", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%profile-keep=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    root = %{
      "key" => "%profile-keep=.sha256",
      "value" => %{
        "author" => alice,
        "timestamp" => 1_700_000_000_000,
        "content" => %{"type" => "post", "text" => "keep me"}
      }
    }

    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        assigns.__changed__
        |> Map.put(:root, assigns.root)
        |> Map.put(:profiles, assigns.profiles)
        |> Map.put(:not_found, assigns.not_found)

      assigns =
        assigns
        |> Map.put(:root, root)
        |> Map.put(:profiles, %{alice => %{name: "Alice Smith", image: nil}})
        |> Map.put(:not_found, false)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :nudge)
    assert render(view) =~ "Alice Smith"

    # A finalize evicts profile ids outside its window from the payload —
    # here the payload's profiles map comes back empty (and the snapshot
    # it re-reads carries nothing either, engine off under test). The
    # avatar it already showed must not flicker back to an identicon.
    send(view.pid, {HighWire.Timeline, :updated, %{profiles: %{}}})
    _ = render(view)

    assigns = :sys.get_state(view.pid).socket.assigns
    assert assigns.profiles == %{alice => %{name: "Alice Smith", image: nil}}
  end

  test "Heart.toggle flips the like state locally" do
    assigns = %{my_likes: [], like_counts: %{}, likes_by: %{}, self_id: "@me=.ed25519"}
    key = "%k=.sha256"

    on = Heart.toggle(assigns, key)
    assert on[:my_likes] == [key]
    assert on[:like_counts] == %{key => 1}
    assert on[:likes_by] == %{key => ["@me=.ed25519"]}

    off = Heart.toggle(Map.merge(assigns, Map.new(on)), key)
    assert off[:my_likes] == []
    assert off[:like_counts] == %{}
    assert off[:likes_by] == %{}
  end

  test "a refused like leaves no phantom heart behind", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%like-root=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    root = %{
      "key" => "%like-root=.sha256",
      "value" => %{
        "author" => alice,
        "timestamp" => 1_700_000_000_000,
        "content" => %{"type" => "post", "text" => "the thing"}
      }
    }

    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        assigns.__changed__
        |> Map.put(:root, assigns.root)
        |> Map.put(:not_found, assigns.not_found)

      assigns =
        assigns
        |> Map.put(:root, root)
        |> Map.put(:not_found, false)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :nudge)
    html = render(view)
    assert html =~ ~s(aria-label="Like")

    # the engine is off under test, so the publish refuses: the
    # optimistic fill must revert to the re-read thread instead of
    # lingering as a heart that never happened
    html = element(view, ~s(button[aria-label="Like"])) |> render_click()
    refute html =~ ~s(aria-pressed="true")

    # That re-read finds nothing in the engine-off test store; a nil
    # fetch must not blank a thread already on screen, so the reader
    # keeps the post they were reading and only the heart reverts.
    assert html =~ "the thing"
    refute html =~ "not in the local store"
  end

  test "a message with no text renders a sentence describing it", %{conn: conn} do
    jeremy = "@0W1ekqmNIN4e1IsAWBM1Kft6w5w86BMUdPO2M0SO83I=.ed25519"
    silvia = "@SS47qSh5M6HsOZOAGzeQDG0s0G1dXbSzLsQWML7Cfzo=.ed25519"
    key = Base.url_encode64("%block-thread=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    # The root is a contact edit — no body text at all — with a reply
    # that is a textless post carrying only a channel.
    root = %{
      "key" => "%block-thread=.sha256",
      "value" => %{
        "author" => jeremy,
        "timestamp" => 1_700_000_000_000,
        "content" => %{
          "type" => "contact",
          "contact" => silvia,
          "blocking" => true,
          "about" => %{"name" => "Szilvia"}
        }
      }
    }

    reply = %{
      "key" => "%channel-reply=.sha256",
      "value" => %{
        "author" => jeremy,
        "timestamp" => 1_700_000_060_000,
        "content" => %{"type" => "post", "channel" => "drama"}
      }
    }

    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        assigns.__changed__
        |> Map.put(:root, assigns.root)
        |> Map.put(:replies, assigns.replies)
        |> Map.put(:not_found, assigns.not_found)

      assigns =
        assigns
        |> Map.put(:root, root)
        |> Map.put(:replies, [reply])
        |> Map.put(:not_found, false)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :nudge)
    html = render(view)

    # the name rides the contact edit itself, so it shows even though no
    # profile for the target was ever fetched — on a chip that links to
    # that feed's profile, with its own avatar, so the reader can look
    # them over and block them for themselves
    assert html =~ "blocked"
    assert html =~ "Szilvia"
    assert html =~ "/profile?id=" <> URI.encode_www_form(silvia)
    assert html =~ "/identicon/" <> Base.encode16(silvia, case: :lower)

    # the chip carries the avatar component's own div, so the sentence
    # must not be a <p>: the HTML parser closes a p at the div and the
    # avatar and name fall out of the sentence in the browser
    refute html =~ ~s(<p class="text-sm italic text-sub)

    # the reply is a textless post, so it describes itself too
    assert html =~ "posted in #drama"
  end

  test "the rail opens on the thread; the way back is the control beside the post",
       %{conn: conn} do
    key = Base.url_encode64("%rail=.sha256", padding: false)
    {:ok, _view, html} = live(conn, "/post/" <> key)

    assert html =~ "In this thread"

    # A Timeline row of its own sat above the thread here: a second way
    # back, on top of the app icon in the top bar. Two links to the
    # timeline are left and not a third — the icon and the content
    # column's control — and the rail opens where the timeline's first
    # label opens.
    assert html =~ ~s(id="post-back")
    assert length(:binary.matches(html, ~s(href="/"))) == 2
  end

  test "every message on the page has a place of its own", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%anchors=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    seed_thread(
      view,
      msg(alice, "%anchors=.sha256", "the post"),
      [msg(alice, "%anchor-reply=.sha256", "the answer")]
    )

    html = render(view)

    # The anchor is the message key as url-safe base64 — the encoding
    # the route takes — because raw ids carry "/" and "=" and belong in
    # neither a DOM id nor a path segment.
    assert html =~ ~s(id=") <> dom_id("%anchors=.sha256") <> ~s(")
    assert html =~ ~s(id=") <> dom_id("%anchor-reply=.sha256") <> ~s(")
  end

  test "the message the feed opened is the one brought into view", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%land-on=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    seed_thread(
      view,
      msg(alice, "%land-on=.sha256", "the post"),
      [
        msg(alice, "%land-reply-one=.sha256", "the answer", 1_700_000_060_000),
        msg(alice, "%land-reply-two=.sha256", "the other answer", 1_700_000_120_000)
      ],
      focus_key: "%land-reply-one=.sha256"
    )

    html = render(view)

    # The hook that brings a message into view rides that message and no
    # other, so the browser scrolls to the one the reader clicked — not
    # to the head of the thread it belongs to.
    assert html =~ ~r/id="#{dom_id("%land-reply-one=.sha256")}"[^>]*phx-hook="LandOn"/
    refute html =~ ~r/id="#{dom_id("%land-reply-two=.sha256")}"[^>]*phx-hook/
    refute html =~ ~r/id="#{dom_id("%land-on=.sha256")}"[^>]*phx-hook/
  end

  test "a page opened at the thread head brings nothing into view", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%head-on=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    # The root opens at the top, where every post has always opened:
    # nothing is dragged into view for a reader who has not asked.
    seed_thread(
      view,
      msg(alice, "%head-on=.sha256", "the post"),
      [msg(alice, "%head-reply=.sha256", "the answer")],
      focus_key: nil
    )

    refute render(view) =~ ~s(phx-hook="LandOn")
  end

  # Engine off under test, so a thread mounts empty and no focus
  # resolves. These tests are about what the page does with a thread it
  # already has, so they seed root, replies and focus straight into the
  # assigns, recording their old values in __changed__ so the next
  # render computes a diff instead of serving the cached tree.
  defp seed_thread(view, root, replies, extra \\ []) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns
      values = [root: root, replies: replies, not_found: false] ++ extra

      changed =
        Enum.reduce(values, assigns.__changed__, fn {key, _value}, acc ->
          Map.put(acc, key, Map.get(assigns, key))
        end)

      assigns =
        values
        |> Enum.reduce(assigns, fn {key, value}, acc -> Map.put(acc, key, value) end)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :nudge)
    view
  end

  defp msg(author, key, text, at \\ 1_700_000_000_000) do
    %{
      "key" => key,
      "value" => %{
        "author" => author,
        "timestamp" => at,
        "content" => %{"type" => "post", "text" => text}
      }
    }
  end

  defp dom_id(key), do: "msg-" <> Base.url_encode64(key, padding: false)
end
