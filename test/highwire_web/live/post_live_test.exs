defmodule HighWireWeb.PostLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias HighWireWeb.Components.Heart

  test "unknown key renders the not-found message", %{conn: conn} do
    key = Base.url_encode64("%missing=.sha256", padding: false)
    {:ok, _view, html} = live(conn, "/post/" <> key)

    assert html =~ "not in the local store"
    # the rail still carries its section, with an explanation instead
    # of an empty column
    assert html =~ "In this thread"
    assert html =~ "Nothing loaded"
    # and a way back — the content column's own control, which Escape
    # follows too (the rail row alone is a small target)
    assert html =~ ~s(id="post-back")
    assert html =~ "← Timeline"
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
    assert html =~ "not in the local store"
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
    # profile for the target was ever fetched
    assert html =~ "blocked Szilvia"
    assert html =~ "posted in #drama"
  end
end
