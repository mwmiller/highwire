defmodule HighWireWeb.PostLiveTest do
  use HighWireWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "unknown key renders the not-found message", %{conn: conn} do
    key = Base.url_encode64("%missing=.sha256", padding: false)
    {:ok, _view, html} = live(conn, "/post/" <> key)

    assert html =~ "not in the local store"
    # the rail still carries its section, with an explanation instead
    # of an empty column
    assert html =~ "In this thread"
    assert html =~ "Nothing loaded"
    # and a way back — the thread page has no content header, so the
    # rail carries the explicit nav row
    assert html =~ ~s(title="Back to the timeline")
  end

  test "the reply box opens the mention popup", %{conn: conn} do
    alice = "@vkdMlsuBgzzo5eLS3LZLdqnBpZ26OauJOMIq9gQ2E7E=.ed25519"
    key = Base.url_encode64("%reply-mentions=.sha256", padding: false)
    {:ok, view, _html} = live(conn, "/post/" <> key)

    root = %{
      "key" => "%reply-mentions=.sha256",
      "value" => %{
        "author" => alice,
        "timestamp" => 1_700_000_000_000,
        "content" => %{"type" => "post", "text" => "seedit"}
      }
    }

    # Engine is off under test, so the thread mounts empty and the
    # reply form stays hidden. Seed the root and a named profile
    # straight into the assigns, recording their old values in
    # __changed__ so the next render computes a diff instead of
    # serving the cached tree.
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      assigns = socket.assigns

      changed =
        assigns.__changed__
        |> Map.put(:root, assigns.root)
        |> Map.put(:profiles, assigns.profiles)
        |> Map.put(:not_found, assigns.not_found)

      assigns =
        assigns
        |> Map.put(:root, root)
        |> Map.put(:profiles, %{alice => %{name: "Alice Smith", image: nil}})
        |> Map.put(:not_found, false)
        |> Map.put(:__changed__, changed)

      %{state | socket: %{socket | assigns: assigns}}
    end)

    # any message wakes the view so it computes that diff
    send(view.pid, :nudge)

    html = render(view)
    assert html =~ ~s(id="reply-body")
    assert html =~ ~s(phx-hook="Mentions")
    assert html =~ ~s(data-draft-event="reply-draft")

    html = render_click(view, "mention-query", %{"q" => "ali"})
    assert html =~ ~s(id="mention-list")
    assert html =~ "Alice Smith"
    assert html =~ ~s(data-id=") <> alice

    # no match retires the popup rather than rendering an empty box
    html = render_click(view, "mention-query", %{"q" => "zzzz"})
    refute html =~ ~s(id="mention-list")

    html = render_click(view, "mention-close", %{})
    refute html =~ ~s(id="mention-list")
  end
end
