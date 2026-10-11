defmodule HighWireWeb.Components.TimeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HighWireWeb.Components.Time

  test "age ships the stamp the client ages the label from" do
    ts = 1_700_000_000_000
    html = render_component(&Time.age/1, ts: ts)

    assert html =~ ~s(data-ts="#{ts}")
    assert html =~ ~s(datetime="2023-11-14T22:13:20)
    assert html =~ Time.rel_time(ts)
  end

  test "a missing stamp renders never with nothing for the client to age" do
    for ts <- [nil, 0] do
      html = render_component(&Time.age/1, ts: ts)

      assert html =~ "never"
      refute html =~ "data-ts"
    end
  end
end
