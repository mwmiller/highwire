defmodule HighWireWeb.LiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "landing view" do
    test "GET / renders HighWire", %{conn: conn} do
      conn = get(conn, "/")
      assert html_response(conn, 200) =~ "HighWire"
    end

    test "live mount shows engine status and swallows menu events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert render(view) =~ "erlbutt"
      assert render(view) =~ HighWire.home_dir()

      assert view
             |> element("h1")
             |> render() =~ "HighWire"

      assert render_hook(view, "menu", %{"view" => "dashboard"}) =~ "HighWire"
      assert render_hook(view, "window-resize", %{"width" => 800, "height" => 600}) =~ "HighWire"
    end
  end
end
