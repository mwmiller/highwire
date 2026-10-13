defmodule HighWireWeb.DiagnosticsLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "diagnostics page" do
    test "renders the health report", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      assert html =~ "Diagnostics"
      assert html =~ "Engine views"
      assert html =~ "Local window"
      assert html =~ "Sidecar:"
    end

    test "the rail jump-links every section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      assert html =~ ~s(href="#engine")
      assert html =~ ~s(href="#window")
    end

    test "a down sidecar reports its state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/diagnostics")

      # No sidecar process in tests; the page must surface that, not hide it.
      assert html =~ "down"
    end
  end

  describe "Timeline.diagnose/0" do
    test "returns a structured report when the timeline is down" do
      report = HighWire.Timeline.diagnose()

      assert is_map(report)
      assert Map.has_key?(report, :sidecar)
      assert Map.has_key?(report, :window)
      assert Map.has_key?(report, :probes)
    end
  end
end
