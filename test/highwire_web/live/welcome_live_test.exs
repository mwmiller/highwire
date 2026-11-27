defmodule HighWireWeb.WelcomeLiveTest do
  @moduledoc """
  The first-run welcome page: the gate that leads a fresh identity to
  it, the invite form, and the two ways off it — both of which retire
  the page for good.

  The test configuration runs no engine, so the page's own status line
  reads a service that is not answering; anything that would dial a pub
  is exercised through the message the page would have received.
  """

  use HighWireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HighWire.FirstRun
  alias HighWireWeb.WelcomeLive

  setup do
    # The test configuration turns the offer off so a booting sidecar
    # cannot greet other modules; this page's own tests turn it on.
    enabled = Application.get_env(:highwire, :first_run)
    Application.put_env(:highwire, :first_run, enabled: true)

    on_exit(fn ->
      if enabled,
        do: Application.put_env(:highwire, :first_run, enabled),
        else: Application.delete_env(:highwire, :first_run)

      File.rm(FirstRun.welcome_path())
      File.rm(FirstRun.welcomed_path())
    end)

    :ok
  end

  describe "the gate" do
    test "a fresh identity meets the welcome page before the feed" do
      FirstRun.mark()

      assert {:error, {:redirect, %{to: "/welcome"}}} = live(conn(), "/")
      assert {:error, {:redirect, %{to: "/welcome"}}} = live(conn(), "/network")
    end

    test "a retired page waves the app through" do
      FirstRun.dismiss()

      {:ok, _view, html} = live(conn(), "/")
      assert html =~ "Timeline"
    end

    test "an install already past it goes home from the page itself" do
      FirstRun.dismiss()

      assert {:error, {:redirect, %{to: "/"}}} = live(conn(), "/welcome")
    end
  end

  describe "the page" do
    test "names what a pub does and offers the invite form" do
      FirstRun.mark()

      {:ok, _view, html} = live(conn(), "/welcome")

      assert html =~ "Welcome to HighWire"
      assert html =~ "A pub carries"
      assert html =~ ~s(id="invite-code")
      assert html =~ ~s(phx-submit="join-pub")
      assert html =~ "host:port:@key.ed25519~seed"
      assert html =~ "Join pub"
      assert html =~ "Skip for now"
      assert html =~ "I have a peer address instead"
    end

    test "an empty field asks for a code rather than dialing" do
      FirstRun.mark()

      {:ok, view, _html} = live(conn(), "/welcome")

      view
      |> form("form[phx-submit=join-pub]", %{invite: "   "})
      |> render_submit()

      assert render(view) =~ "Paste an invite code to join a pub."
    end

    test "text that is not an invite says what one looks like" do
      FirstRun.mark()

      {:ok, view, _html} = live(conn(), "/welcome")

      view
      |> form("form[phx-submit=join-pub]", %{invite: "not-an-invite"})
      |> render_submit()

      assert render(view) =~ "That is not a valid invite code"
      assert render(view) =~ "host:port:@key.ed25519~seed"
    end

    test "a well-formed code waits for the service instead of reaching out" do
      FirstRun.mark()

      {:ok, view, _html} = live(conn(), "/welcome")

      view
      |> form("form[phx-submit=join-pub]", %{invite: invite_code()})
      |> render_submit()

      assert render(view) =~ "The local service is not answering yet"
      # The box keeps the code: it is worth retrying once the engine answers.
      assert render(view) =~ ~s(value="#{invite_code()}")
      assert FirstRun.pending?()
    end

    test "typing survives the status poll" do
      FirstRun.mark()

      {:ok, view, _html} = live(conn(), "/welcome")

      view
      |> form("form[phx-change=invite-type]", %{invite: "pub.example.org:8008:@key"})
      |> render_change()

      assert render(view) =~ ~s(value="pub.example.org:8008:@key")
    end

    test "skipping retires the page and goes to the feed" do
      FirstRun.mark()

      {:ok, view, _html} = live(conn(), "/welcome")
      render_click(view, "skip")

      refute FirstRun.pending?()
      assert_redirect(view, "/")
    end

    test "a peer address goes to the Network page and retires the page" do
      FirstRun.mark()

      {:ok, view, _html} = live(conn(), "/welcome")
      render_click(view, "skip-to-network")

      refute FirstRun.pending?()
      assert_redirect(view, "/network#add-a-peer")
    end
  end

  # The join runs in a Task in production; here the outcome arrives as
  # the message that Task would send, the same way the Network page's
  # wording is covered.
  describe "a joined pub" do
    test "names the pub, retires the page, and points at the feed" do
      FirstRun.mark()

      {:ok, socket} = WelcomeLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      {:noreply, socket} =
        WelcomeLive.handle_info(
          {:invite_result, {:ok, %{host: "pub.example.org", port: 8008}}},
          socket
        )

      assert socket.assigns.notice =~ "Joined pub.example.org:8008"
      assert socket.assigns.joined.host == "pub.example.org"
      refute socket.assigns.redeeming
      refute FirstRun.pending?()
    end

    test "a refused invite leaves the page waiting" do
      FirstRun.mark()

      {:ok, socket} = WelcomeLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      {:noreply, socket} =
        WelcomeLive.handle_info({:invite_result, {:error, {:refused, :expired}}}, socket)

      assert socket.assigns.notice =~ "refused the invite"
      assert FirstRun.pending?()
    end
  end

  defp conn, do: build_conn()

  defp invite_code do
    key = Base.encode64(:binary.copy(<<7>>, 32))
    seed = Base.encode64(:binary.copy(<<9>>, 32))
    "pub.example.org:8008:@#{key}.ed25519~#{seed}"
  end
end
