defmodule HighWireWeb.PostLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "unknown key renders the not-found message", %{conn: conn} do
    key = Base.url_encode64("%missing=.sha256", padding: false)
    {:ok, _view, html} = live(conn, "/post/" <> key)

    assert html =~ "not in the local store"
    # the rail still carries its section, with an explanation instead
    # of an empty column
    assert html =~ "In this thread"
    assert html =~ "Nothing loaded"
  end
end
