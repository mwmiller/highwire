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

    test "the combination lock presents the mainnet key beneath it", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ ~s(id="net-lock")
      assert html =~ ~s(data-combo="#{Network.id(:mainnet)}")
      assert html =~ "The combination"
      # The whole key prints at once, bright, right beneath the lock.
      assert html =~ Network.id(:mainnet)
      assert html =~ ~s(class="lock-combo )
      assert html =~ "the combination is the key itself"
      assert html =~ "type the whole key"
      # One box per key character, grouped in fours.
      assert 44 == length(Regex.scan(~r/class="lock-char"/, html))
      assert html =~ ~s(maxlength="1")
      assert html =~ ~s(aria-label="Key character 1 of 44")
      assert html =~ "Type or paste the whole mainnet key"
      assert html =~ "green characters agree,"
      assert html =~ "Click the shackle onto Mainnet"
      # Exactly one control per profile: the shackle and the plate — and
      # both live inside the lock, so the lock IS the network selector.
      assert [_] = Regex.scan(~r/phx-value-network="mainnet"/, html)
      assert [_] = Regex.scan(~r/phx-value-network="dev"/, html)
      assert html =~ ~r/id="net-lock".*phx-value-network="mainnet"/s
      assert html =~ ~r/id="net-lock".*phx-value-network="dev"/s
      assert html =~ "Locked: Development"
      # Ergonomics: live status line, hold-to-leave plate, click-to-fill
      # and copy affordances, and the narrow-screen single-key field.
      assert html =~ ~s(id="net-lock-status")
      assert html =~ ~s(data-leave="true")
      assert html =~ ~s(data-fill="true")
      assert html =~ ~s(data-copy="true")
      assert html =~ ~s(class="lock-key-field")
      assert html =~ ~s(maxlength="44")
      assert html =~ ~s(tabindex="-1")
    end
  end
end
