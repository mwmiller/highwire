defmodule HighWireWeb.Components.NavTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias HighWireWeb.Components.Nav

  describe "the gossip badge" do
    test "the rail badge counts live connections behind a live dot" do
      html = render_component(&Nav.rail/1, gossip: %{connected: 3, pulse: 2})

      assert html =~ "gossip-dot"
      assert html =~ "· 3"
    end

    test "a quiet rail shows the idle dot and no count" do
      html = render_component(&Nav.rail/1, [])

      refute html =~ "gossip-dot"
      refute html =~ "· "
    end
  end

  describe "network link" do
    test "the rail always carries the way into the network page" do
      html = render_component(&Nav.rail/1, [])

      assert html =~ ~s(id="rail-network")
      assert html =~ ~s(href="/network")
      assert html =~ ~s(aria-label="Network")
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

      # Both sit on the top line, ahead of the two page links.
      {back, _} = :binary.match(html, ~s(data-history="back"))
      {forward, _} = :binary.match(html, ~s(data-history="forward"))
      {crab, _} = :binary.match(html, ~s(aria-label="Timeline"))
      assert back < forward and forward < crab
    end
  end
end
