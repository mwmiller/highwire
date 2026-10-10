defmodule HighWireWeb.PostLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "unknown key renders the not-found message", %{conn: conn} do
    key = Base.url_encode64("%missing=.sha256", padding: false)
    {:ok, _view, html} = live(conn, "/post/" <> key)

    assert html =~ "not in the local store"
  end

  test "the label tick re-renders so relative times keep aging", %{conn: conn} do
    key = Base.url_encode64("%missing=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    send(view.pid, :labels_tick)
    assert render(view) =~ "not in the local store"

    state = :sys.get_state(view.pid)
    assert is_integer(state.socket.assigns.labels_tick)
  end
end
