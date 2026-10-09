defmodule HighWireWeb.SettingsLiveTest do
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.SSB.Network

  setup do
    # A stale overrides file from another run would move the pressed
    # profile out from under these assertions.
    File.rm(Network.path())
    :ok
  end

  describe "network section" do
    test "renders both profiles and the engine status", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ "Network"
      assert html =~ "Network set to:"
      assert html =~ "Development"
      assert html =~ "Mainnet"
      assert html =~ "Engine:"
    end

    test "switching while the engine is disabled fails with an explanation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> element("button[phx-value-network=mainnet]")
      |> render_click()

      # The disabled-engine answer can land before the first render, so
      # assert the settled outcome rather than the transient notice.
      Process.sleep(200)
      assert render(view) =~ "disabled in this configuration"
    end

    test "re-clicking the active profile is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      html =
        view
        |> element("button[phx-value-network=dev]")
        |> render_click()

      refute html =~ "Switching to"
    end

    test "the selector is one button per profile", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      # Exactly one control per profile, the active one pressed — a
      # fresh overrides file leaves the development profile current.
      assert [_] = Regex.scan(~r/phx-value-network="mainnet"/, html)
      assert [_] = Regex.scan(~r/phx-value-network="dev"/, html)
      assert html =~ ~s(phx-click="switch_network")
      assert html =~ ~r/phx-value-network="dev"[^>]*aria-pressed="true"/
      assert html =~ ~r/phx-value-network="mainnet"[^>]*aria-pressed="false"/
      assert html =~ "HighWire starts on Mainnet."

      # The combination-lock artifice is gone.
      refute html =~ "net-lock"
      refute html =~ "lock-char"
      refute html =~ "shackle"
      refute html =~ "lock-key"
      refute html =~ "The combination"
      refute html =~ "Hold to snap shut"
    end
  end
end
