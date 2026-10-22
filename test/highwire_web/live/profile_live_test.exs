defmodule HighWireWeb.ProfileLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "profile renders and load-more with no engine is a no-op", %{conn: conn} do
    id = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, view, html} = live(conn, "/profile?id=" <> URI.encode_www_form(id))

    assert html =~ "Posts"
    # sidecar disabled under test: no more pages, nothing to load
    refute html =~ "profile-sentinel"

    assert render_hook(view, "load-more", %{}) =~ "Posts"
  end

  test "a page on the way says so, and lands where it was asked for", %{conn: conn} do
    id = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"

    msg = %{
      "key" => "%p1.sha256",
      "value" => %{
        "author" => id,
        "timestamp" => 1_700_000_000_000,
        "content" => %{"type" => "post", "text" => "the thing"}
      }
    }

    {:ok, view, _html} = live(conn, "/profile?id=" <> URI.encode_www_form(id))
    seed(view, %{id: id, messages: [msg], more: true, resume: "cursor-1"})

    # The sentinel asks for the next page, and the request is answered
    # by the line going up: the reader can see the page is on its way.
    html = element(view, "#profile-sentinel") |> render_hook("load-more", %{})
    assert html =~ "Loading more…"

    # Under test the store has nothing behind the cursor: the line
    # clears and the posts the reader had are still there.
    send(view.pid, {:load_more, id, "cursor-1"})
    html = render(view)
    refute html =~ "Loading more…"
    assert html =~ "the thing"

    # The profile moved on while the next page was out. The answer
    # belongs to where the reader was, so it clears its own line and
    # lands nothing on the feed now on screen.
    seed(view, %{id: "@someone=.ed25519", messages: [msg], more: true, resume: "cursor-2"})
    html = element(view, "#profile-sentinel") |> render_hook("load-more", %{})
    assert html =~ "Loading more…"

    seed(view, %{id: "@someone=.ed25519", messages: [msg], more: true, resume: "cursor-2"})
    send(view.pid, {:load_more, id, "cursor-1"})

    html = render(view)
    refute html =~ "Loading more…"
    assert html =~ "the thing"
  end

  test "profile without an id defaults to the signed-in feed", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/profile")
    # sidecar disabled under test: no signed-in feed resolves
    assert html =~ "No feed selected."
  end

  test "identity resolution falls back cleanly with no engine", %{conn: conn} do
    id = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, _view, html} = live(conn, "/profile?id=" <> URI.encode_www_form(id))

    # alias: no name resolves through the engine, so the heading falls
    # back to Patchwork's shortFeedId (id.slice(1, 10))
    assert html =~ ~r/<h1[^>]*>\s*vkdMlsuBg\s*<\/h1>/
    # the full id stays on the page for copy/paste
    assert html =~ id

    # avatar: no image resolves, so the tile falls back to the Excon
    # identicon keyed by the feed id — never a broken image
    assert html =~ "/identicon/" <> Base.encode16(id, case: :lower)

    assert html =~ "No posts yet."
    # engine off: no follow control is offered
    refute html =~ "toggle-follow"

    # the rail identity card carries the id a second time (header + rail)
    assert length(Regex.scan(~r/vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=/, html)) >= 2
  end

  test "a short dev-era handle renders whole, not stubbed", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/profile?id=" <> URI.encode_www_form("@dtBy.ed25519"))

    # Nine characters off a short handle just cuts the readable part
    # ("dtBy.ed25"); the stub is for full base64 feed ids only.
    assert html =~ ~r/<h1[^>]*>\s*dtBy\.ed25519\s*<\/h1>/
    refute html =~ "dtBy.ed25<"
  end

  test "the rail never sits empty without an id", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/profile")

    assert html =~ "Open a profile from the timeline"
  end

  test "profile posts open their thread like timeline posts", %{conn: conn} do
    id = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, view, _html} = live(conn, "/profile?id=" <> URI.encode_www_form(id))

    key = "fake-post-key"

    row = %{
      "key" => key,
      "value" => %{
        "content" => %{"type" => "post", "text" => "seedit"},
        "timestamp" => 1_700_000_000_000
      }
    }

    # Engine is off under test, so the profile mounts with no posts.
    # Seed one row straight into the assigns and record the old value in
    # __changed__ (LiveView's dirty map) so the next render computes a
    # diff for :messages instead of serving the cached tree.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns
      changed = Map.put(assigns.__changed__, :messages, assigns.messages)

      assigns =
        assigns
        |> Map.put(:messages, [row])
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    # Any message wakes the view so it computes that diff — the label
    # tick this replaced is gone; ages now refresh client-side from
    # the data-ts the row ships with.
    send(view.pid, :nudge)

    html = render(view)
    assert html =~ "phx-hook=\"OpenPost\""
    assert html =~ "data-key=\"fake-post-key\""
    assert html =~ "cursor-pointer"
    assert html =~ "seedit"
    assert html =~ ~s(data-ts="1700000000000")

    render_hook(view, "open-post", %{"key" => key})
    assert_redirect(view, "/post/" <> Base.url_encode64(key, padding: false))
  end

  test "the rail offers Follow and Block, and reflects the relationship", %{conn: conn} do
    me = "@me=.ed25519"
    peer = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, view, _html} = live(conn, "/profile?id=" <> URI.encode_www_form(peer))

    seed(view, status: :ok, self_id: me, follows: [me], blocked: [])
    html = render(view)

    assert html =~ "toggle-follow"
    assert html =~ "toggle-block"
    assert html =~ "Follow"
    # the label is exactly "Block" — no block is in force
    refute html =~ "Unblock"
    refute html =~ "Blocked"

    # a click publishes through the same chokepoint as follow (the engine
    # is off, so the publish refuses — the view must not come down with it)
    assert render_click(view, "toggle-block", %{"id" => peer}) =~ "toggle-block"

    seed(view, blocked: [peer])
    html = render(view)

    assert html =~ "Unblock"
    assert html =~ "Blocked"
    # a blocked feed is not offered the follow control at all
    refute html =~ "toggle-follow"
  end

  test "every publish control holds the press while the engine takes its time", %{conn: conn} do
    peer = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, view, _html} = live(conn, "/profile?id=" <> URI.encode_www_form(peer))

    seed(view, status: :ok, self_id: "@me=.ed25519", follows: [peer], blocked: [])

    # The engine can take seconds, and the reader has to see the press
    # was taken before the engine answers it: the control names the verb
    # in flight — the one it is undoing, since the label beside it
    # already reads "Following" — and goes dead under the finger.
    held = render_click(view, "toggle-follow", %{"id" => peer})

    assert held =~ "Unfollowing…"
    assert held =~ ~r/phx-click="toggle-follow"[^>]*disabled/

    held = render_click(view, "toggle-block", %{"id" => peer})

    assert held =~ "Blocking…"
    assert held =~ ~r/phx-click="toggle-block"[^>]*disabled/
  end

  test "a publish the engine refuses says so under the buttons", %{conn: conn} do
    peer = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, view, _html} = live(conn, "/profile?id=" <> URI.encode_www_form(peer))

    seed(view, status: :ok, self_id: "@me=.ed25519", follows: [], blocked: [])

    # The engine is off under test, so the publish comes back refused.
    # The refusal lands under the buttons and the press is let go, so a
    # click that did not take says so instead of reading as one that did
    # nothing at all.
    assert render_click(view, "toggle-follow", %{"id" => peer}) =~ "Following…"

    html = render(view)
    assert html =~ "Not connected yet. Try again in a moment."
    refute html =~ "Following…"

    assert render_click(view, "toggle-block", %{"id" => peer}) =~ "Blocking…"

    html = render(view)
    assert html =~ "Not connected yet. Try again in a moment."
    refute html =~ "Blocking…"
  end

  # Engine off under test, so relationship state is seeded straight into
  # the assigns; __changed__ records the old values so the next render
  # computes a diff instead of serving the cached tree.
  defp seed(view, overrides) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        Enum.reduce(overrides, assigns.__changed__, fn {key, _new}, acc ->
          Map.put(acc, key, Map.get(assigns, key))
        end)

      assigns =
        Enum.reduce(overrides, assigns, fn {key, value}, acc -> Map.put(acc, key, value) end)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    send(view.pid, :nudge)
    view
  end
end
