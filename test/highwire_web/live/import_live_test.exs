defmodule HighWireWeb.ImportLiveTest do
  @moduledoc """
  The import gate: every face of `/import`, the route gate that waves
  app pages into it, and the accept/decline/fail flows against a fake
  sidecar registered under the real name (the test configuration runs
  no engine, so the name is free).
  """

  use HighWireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HighWireWeb.ImportLive

  # A sidecar-shaped GenServer: answers the four calls ImportLive makes,
  # and walks its own state the way the real one does so the page's
  # refresh-after-each-button flow is exercised end to end.
  defmodule FakeSidecar do
    @moduledoc false
    use GenServer, restart: :temporary

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: HighWire.SSB.Sidecar)

    @impl true
    def init(opts), do: {:ok, Map.new(opts)}

    @impl true
    def handle_call(:status, _from, state), do: {:reply, state.status, state}

    def handle_call(:import_info, _from, state), do: {:reply, Map.get(state, :info, %{}), state}

    def handle_call(:accept_import, _from, state) do
      if state[:on_accept] == :fail do
        info = state |> Map.get(:info, %{}) |> Map.put(:error, "converter missing")
        {:reply, {:error, :converter_missing}, %{state | status: :import_failed, info: info}}
      else
        info =
          state
          |> Map.get(:info, %{})
          |> Map.put(:started_at, System.system_time(:second))
          |> Map.put(:dots, 1)

        {:reply, :ok, %{state | status: :importing, info: info}}
      end
    end

    def handle_call(:decline_import, _from, state) do
      {:reply, :ok, %{state | status: :starting}}
    end
  end

  @consent_info %{
    id: "@publ1c.ed25519",
    log_size: 4_194_304,
    blobs: true,
    log_path: nil
  }

  # -- render-only faces --------------------------------------------------

  describe "faces" do
    test "consent names the account, the size, and the choice" do
      html = render_face(:import_pending, @consent_info)

      assert html =~ "Bring your old feed along"
      assert html =~ "@publ1c.ed25519"
      assert html =~ "4.0 MB of messages"
      assert html =~ "present — they come too"
      assert html =~ "Quit the old client before importing"
      assert html =~ "Import it"
      assert html =~ "Start fresh"
      refute html =~ "identity only"
    end

    test "consent without a log admits it is identity only" do
      html = render_face(:import_pending, %{id: "@publ1c.ed25519"})

      assert html =~ "identity only — no history log found"
      assert html =~ "none found"
    end

    test "progress counts down from dots until the converter reports" do
      html = render_face(:importing, %{started_at: System.system_time(:second), dots: 3})

      assert html =~ "Converting your history"
      assert html =~ "≈ 10,000 messages"
      refute html =~ "Import it"
    end

    test "progress prefers the converter's own counts" do
      html =
        render_face(:importing, %{
          started_at: System.system_time(:second),
          dots: 3,
          counts: %{feeds: 1_234, messages: 98_765}
        })

      assert html =~ "98,765 messages"
      assert html =~ "1,234"
      refute html =~ "≈ 10,000"
    end

    test "failure shows the converter's words and both ways out" do
      html = render_face(:import_failed, %{error: "converter missing", tail: "HW_SIDECAR..."})

      assert html =~ "The import stopped"
      assert html =~ "converter missing"
      assert html =~ "Try again"
      assert html =~ "Start fresh"
    end

    test "failure without an explanation says so" do
      html = render_face(:import_failed, %{})

      assert html =~ "The importer failed without saying why."
    end

    test "an engine-less configuration gets its own panel" do
      html = render_face(:disabled, %{})

      assert html =~ "Nothing to import into"
      refute html =~ "Import it"
    end
  end

  # -- the gate -----------------------------------------------------------

  describe "route gate" do
    test "an unanswered offer halts the app routes into /import" do
      start_supervised!({FakeSidecar, status: :import_pending, info: @consent_info})

      assert {:error, {:redirect, %{to: "/import"}}} = live(conn(), "/")
      assert {:error, {:redirect, %{to: "/import"}}} = live(conn(), "/settings")
    end

    test "an in-flight import gates the same way" do
      start_supervised!({FakeSidecar, status: :importing, info: %{}})

      assert {:error, {:redirect, %{to: "/import"}}} = live(conn(), "/")
    end

    test "with the import over the gate waves the page through" do
      start_supervised!({FakeSidecar, status: :ready, info: %{}})

      {:ok, _view, html} = live(conn(), "/")
      assert html =~ "Timeline"
    end
  end

  # -- live flows ---------------------------------------------------------

  describe "flows" do
    test "consent → accept flips to the progress face" do
      start_supervised!({FakeSidecar, status: :import_pending, info: @consent_info})

      {:ok, view, _html} = live(conn(), "/import")
      render_click(view, "accept")

      assert_poll(view, "Converting your history")
      refute render(view) =~ "Import it"
    end

    test "consent → decline drops the offer and routes home" do
      start_supervised!({FakeSidecar, status: :import_pending, info: @consent_info})

      {:ok, view, _html} = live(conn(), "/import")
      render_click(view, "decline")

      assert_redirect(view, "/", 2_000)
    end

    test "a failed accept lands on the failure face" do
      start_supervised!(
        {FakeSidecar, status: :import_pending, info: @consent_info, on_accept: :fail}
      )

      {:ok, view, _html} = live(conn(), "/import")
      render_click(view, "accept")

      assert_poll(view, "The import stopped")
      assert render(view) =~ "converter missing"
      assert render(view) =~ "Try again"
    end

    test "the offer is not waiting when the import is already over" do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn(), "/import")
    end
  end

  # -- helpers ------------------------------------------------------------

  # Render one face without a session: the page reads the sidecar only
  # through refresh/3, which mount calls — the assigns below are exactly
  # what it would assign.
  defp render_face(mode, info) do
    assigns = %{
      __changed__: nil,
      page_title: "Import",
      mode: mode,
      info: info
    }

    ImportLive.render(assigns) |> Phoenix.LiveViewTest.rendered_to_string()
  end

  # The accept path answers through a Task; poll briefly for its refresh.
  defp assert_poll(view, needle, tries \\ 40) do
    html = render(view)

    cond do
      html =~ needle ->
        html

      tries == 0 ->
        flunk("timed out waiting for #{inspect(needle)} in:\n#{html}")

      true ->
        Process.sleep(25)
        assert_poll(view, needle, tries - 1)
    end
  end

  defp conn, do: build_conn()
end
