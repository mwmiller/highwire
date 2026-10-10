defmodule HighWireWeb.NetworkLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.SSB.Network

  setup do
    # A stale overrides file from another run would move the pressed
    # profile out from under these assertions.
    File.rm(Network.path())
    :ok
  end

  describe "network profile switcher" do
    test "renders both profiles with the current one pressed", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      assert html =~ "Which network"
      assert html =~ "Network set to:"
      assert html =~ "Development"
      assert html =~ "Mainnet"
      assert html =~ ~s(phx-click="switch_network")

      # Exactly one control per profile, the active one pressed — a
      # fresh overrides file leaves the development profile current.
      assert [_] = Regex.scan(~r/phx-value-network="mainnet"/, html)
      assert [_] = Regex.scan(~r/phx-value-network="dev"/, html)
      assert html =~ ~r/phx-value-network="dev"[^>]*aria-pressed="true"/
      assert html =~ ~r/phx-value-network="mainnet"[^>]*aria-pressed="false"/
    end

    test "switching while the engine is disabled fails with an explanation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/network")

      view
      |> element("button[phx-value-network=mainnet]")
      |> render_click()

      # The disabled-engine answer can land before the first render, so
      # assert the settled outcome rather than the transient notice.
      Process.sleep(200)
      assert render(view) =~ "disabled in this configuration"
    end

    test "re-clicking the active profile is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/network")

      html =
        view
        |> element("button[phx-value-network=dev]")
        |> render_click()

      refute html =~ "Switching to"
    end
  end

  describe "dialer controls (engine down)" do
    test "are present but disabled without a report", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      assert html =~ "Dialer"
      assert html =~ "Turn auto-dial on"
      assert html =~ "Dial now"
      assert html =~ "auto-dial unknown"
      assert html =~ ~r/No report from the local engine/

      # Disabled: no live engine to command. (The handlers also guard
      # against a report that goes nil mid-click, but the DOM never
      # offers that path — LiveViewTest refuses to click disabled
      # elements, matching browsers.)
      assert html =~ ~r/<button[^>]*phx-click="dialer-toggle"[^>]*disabled/
      assert html =~ ~r/<button[^>]*phx-click="dialer-trigger"[^>]*disabled/
    end
  end

  describe "known peers (engine down)" do
    test "empty-book copy shows without a report", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      # The whole report-dependent block (connections, book, dials) is
      # hidden; only the no-report explanation stands in.
      refute html =~ "Known peers"
      refute html =~ "Recent dials"
      refute html =~ "Connections"
    end
  end
end
