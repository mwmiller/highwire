defmodule HighWireWeb.Components.HeartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias HighWireWeb.Components.Heart

  test "the unliked pill is an outline heart with a Like label" do
    html = render_component(&Heart.pill/1, key: "%k.sha256", liked: false)

    assert html =~ ~s(phx-click="like")
    assert html =~ ~s(phx-value-key="%k.sha256")
    assert html =~ ~s(aria-pressed="false")
    assert html =~ ~s(title="Like")
    assert html =~ ~s(fill="none")
  end

  test "the liked pill reads pressed with a filled heart" do
    html = render_component(&Heart.pill/1, key: "%k.sha256", liked: true)

    assert html =~ ~s(aria-pressed="true")
    assert html =~ ~s(title="Unlike")
    assert html =~ ~s(fill="currentColor")
    refute html =~ ~s(fill="none")
  end
end
