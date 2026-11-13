defmodule HighWireWeb.Components.NavTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias HighWireWeb.Components.Nav

  describe "the network mark" do
    test "the header icon counts live connections behind a live dot" do
      html = render_component(&Nav.rail/1, gossip: %{connected: 3, pulse: 2})

      assert html =~ "gossip-dot"
      assert html =~ "3 live"
    end

    test "a quiet rail shows the idle dot and no live peers" do
      html = render_component(&Nav.rail/1, [])

      refute html =~ "gossip-dot"
      assert html =~ "0 live"
    end
  end

  describe "network link" do
    test "the utility corner carries the way into the network page" do
      html = render_component(&Nav.rail/1, [])

      assert html =~ ~s(id="rail-network")
      assert html =~ ~s(href="/network")
      assert html =~ ~s(aria-label="Network")

      {header, _} = :binary.match(html, ~s(id="rail-header"))
      {utilities, _} = :binary.match(html, ~s(id="rail-utilities"))
      {network, _} = :binary.match(html, ~s(id="rail-network"))
      {settings, _} = :binary.match(html, ~s(aria-label="Settings"))
      {content, _} = :binary.match(html, ~s(id="rail-content"))

      # It belongs with the identity and settings controls, not with the
      # two destinations built from the logs.
      assert header < utilities and utilities < network and network < settings
      assert network < content
    end
  end

  describe "page history" do
    test "the rail opens with back and forward through the page history" do
      html = render_component(&Nav.rail/1, [])

      assert html =~ ~s(phx-hook="HistoryNav")
      assert html =~ ~s(data-history="back")
      assert html =~ ~s(data-history="forward")
      assert html =~ ~s(aria-label="Back")
      assert html =~ ~s(aria-label="Forward")

      # Both sit on the top line, ahead of the two log-backed page links.
      {back, _} = :binary.match(html, ~s(data-history="back"))
      {forward, _} = :binary.match(html, ~s(data-history="forward"))
      {crab, _} = :binary.match(html, ~s(aria-label="Timeline"))
      {table, _} = :binary.match(html, ~s(aria-label="Gameroom"))
      assert back < forward and forward < crab and crab < table
    end
  end
end
