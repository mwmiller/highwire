defmodule HighWireWeb.TimelineLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "timeline renders and handles the menu bridge event", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Timeline"
    # sidecar disabled under test
    assert html =~ "SSB engine disabled"

    render_hook(view, "menu", %{})
    render_hook(view, "window-resize", %{})
  end

  test "tab activity events toggle timeline polling", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")

    assert html =~ "Timeline"

    assert render_hook(view, "tab-inactive", %{}) =~ "Timeline"
    assert render_hook(view, "tab-active", %{}) =~ "Timeline"
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
end
