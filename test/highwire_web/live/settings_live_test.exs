defmodule HighWireWeb.SettingsLiveTest do
  # Not async: the identity cases point :application_dir at a temp home.
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.SSB.Identities

  setup %{conn: conn} do
    tmp =
      Path.join(System.tmp_dir!(), "hw-settings-live-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, tmp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :application_dir, previous),
        else: Application.delete_env(:highwire, :application_dir)

      File.rm_rf!(tmp)
    end)

    {:ok, conn: conn}
  end

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

    test "switches identity in place", %{conn: conn} do
      {:ok, _main} = Identities.create("Main")
      {:ok, bot} = Identities.create("Bot")

      {:ok, view, html} = live(conn, "/settings")

      # The active identity is the card; the other one is the button.
      assert html =~ "Posting as"
      assert html =~ ~s(phx-value-id="#{bot}")

      html = render_click(view, "switch", %{"id" => bot})

      # Engine disabled: the secret write is the whole switch.
      assert html =~ "Now posting as Bot"
      assert Identities.active_id() == bot
      # The card and the button swap around.
      refute html =~ ~s(phx-value-id="#{bot}")
    end

    test "the rail jump-links every section", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings")

      assert html =~ ~s(href="#identity")
      assert html =~ ~s(href="#appearance")
      assert html =~ ~s(href="#notifications")
      assert html =~ ~s(href="#writing")
      assert html =~ ~s(href="#information")
    end
  end
end
