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
  end
end
