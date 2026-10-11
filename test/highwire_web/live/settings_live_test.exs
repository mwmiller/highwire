defmodule HighWireWeb.SettingsLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "settings page" do
    test "renders appearance and version", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Settings"
      assert html =~ "Appearance"
      assert html =~ "Colour scheme"
      assert html =~ "Font size"
      assert html =~ "Font family"
      assert html =~ ~r/HighWire v?\d+\.\d+\.\d+ · MIT/
    end

    test "the network switcher has moved to the network page", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      refute html =~ ~s(phx-click="switch_network")
      refute html =~ "Network set to:"
      refute html =~ "HighWire starts on Mainnet."
    end

    test "the rail jump-links every section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ ~s(href="#appearance")
      assert html =~ ~s(href="#notifications")
      assert html =~ ~s(href="#writing")
      assert html =~ ~s(href="#information")
    end
  end
end
