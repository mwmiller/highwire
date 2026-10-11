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

  test "the rail never sits empty without an id", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/profile")

    assert html =~ "Open a profile from the timeline"
  end

  test "the label tick re-renders so relative times keep aging", %{conn: conn} do
    id = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    {:ok, view, _html} = live(conn, "/profile?id=" <> URI.encode_www_form(id))

    send(view.pid, :labels_tick)
    assert render(view) =~ "Posts"

    state = :sys.get_state(view.pid)
    assert is_integer(state.socket.assigns.labels_tick)
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

    send(view.pid, :labels_tick)

    html = render(view)
    assert html =~ "phx-hook=\"OpenPost\""
    assert html =~ "data-key=\"fake-post-key\""
    assert html =~ "cursor-pointer"
    assert html =~ "seedit"

    render_hook(view, "open-post", %{"key" => key})
    assert_redirect(view, "/post/" <> Base.url_encode64(key, padding: false))
  end
end
