defmodule HighWireWeb.LiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "landing view" do
    test "GET / renders HighWire", %{conn: conn} do
      conn = get(conn, "/about")
      assert html_response(conn, 200) =~ "HighWire"
    end

    test "live mount shows engine status", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/about")

      assert render(view) =~ "erlbutt"
      assert render(view) =~ HighWire.home_dir()

      assert view
             |> element("h1")
             |> render() =~ "HighWire"
    end
  end
end
