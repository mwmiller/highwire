defmodule HighWireWeb.Components.NavTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias HighWireWeb.Components.Nav

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
