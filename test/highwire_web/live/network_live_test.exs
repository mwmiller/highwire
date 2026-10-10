defmodule HighWireWeb.NetworkLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.SSB.Network
  alias HighWireWeb.NetworkLive

  setup do
    # A stale overrides file from another run would move the pressed
    # profile out from under these assertions.
    File.rm(Network.path())
    :ok
  end

  describe "nav badge" do
    test "links to the network page, not settings", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/network")

      # The badge is the general entry point; it used to point at
      # settings, which no longer holds any network controls.
      assert html =~ ~s(href="/network")
      assert html =~ ~s(aria-label="Network")
    end
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

  # The engine cannot run under test, so the report-present half of the
  # page is rendered directly: build the assigns a live session would
  # hold and call render/1. Same template, same helpers.
  describe "render with a live report" do
    test "shows connections, the address book, and recent dials" do
      html =
        render_with_report(%{
          "enabled" => true,
          "cap" => 8,
          "connections" => ["@alice.ed25519"],
          "lanCandidates" => 2,
          "autoconnectCandidates" => 5,
          "knownPeers" => [
            %{
              "address" => "net:192.168.1.10:8008~shs:bobkey",
              "source" => "pub",
              "autoconnect" => true
            },
            %{"address" => "net:10.0.0.2:8008~shs:carolkey", "autoconnect" => false}
          ],
          "dialTry" => [
            %{"addr" => "net:192.168.1.10:8008~shs:bobkey", "attempts" => 0, "lastTry" => 1},
            %{"addr" => "net:10.0.0.2:8008~shs:carolkey", "attempts" => 3, "lastTry" => 1}
          ]
        })

      # Dialer: on, with the off toggle offered.
      assert html =~ "auto-dial on"
      assert html =~ "Turn auto-dial off"
      assert html =~ "Dial now"
      refute html =~ ~r/<button[^>]*phx-click="dialer-toggle"[^>]*disabled/

      # Connections: one row, address shortened to the 9-char id form.
      assert html =~ "Connections · 1 / 8"
      assert html =~ "alice.ed2"

      # Known peers: host:port shown, full address in the title,
      # source and auto/manual badges.
      assert html =~ "Known peers · 2"
      assert html =~ "192.168.1.10:8008"
      assert html =~ ~s(title="net:192.168.1.10:8008~shs:bobkey")
      assert html =~ "pub"
      assert html =~ "auto"
      assert html =~ "manual"

      # Recent dials: ok vs failing counts.
      assert html =~ "Recent dials"
      assert html =~ "ok"
      assert html =~ "3 fails"
    end

    test "auto-dial off offers the on toggle" do
      html = render_with_report(%{"enabled" => false, "connections" => [], "dialTry" => []})

      assert html =~ "auto-dial off"
      assert html =~ "Turn auto-dial on"
    end

    test "known peers beyond the cap are truncated with a count line" do
      peers =
        for i <- 1..52 do
          %{"address" => "net:10.0.0.#{i}:8008~shs:key#{i}", "autoconnect" => true}
        end

      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => peers,
          "dialTry" => []
        })

      assert html =~ "Known peers · 52"
      assert html =~ "Showing first 50 of 52"
      # Row 51's address is not rendered.
      refute html =~ "10.0.0.51:8008"
      refute html =~ "10.0.0.52:8008"
    end

    test "empty sections say so" do
      html =
        render_with_report(%{
          "enabled" => true,
          "connections" => [],
          "knownPeers" => [],
          "dialTry" => []
        })

      assert html =~ "No peers connected."
      assert html =~ "The address book is empty"
      assert html =~ "Nothing dialed yet."
    end
  end

  # The assigns a connected session would hold, with only the report
  # varying per test.
  defp render_with_report(report) do
    assigns = %{
      __changed__: nil,
      page_title: "Network",
      status: :ok,
      profiles: %{},
      report: report,
      active: true,
      tick_timer: nil,
      network: :dev,
      net_status: :ready,
      switching: false,
      switch_notice: nil,
      polls: 0,
      dial_notice: nil,
      dialing: false,
      known_peers_cap: 50
    }

    NetworkLive.render(assigns) |> Phoenix.LiveViewTest.rendered_to_string()
  end
end
