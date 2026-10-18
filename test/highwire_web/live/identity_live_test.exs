defmodule HighWireWeb.IdentityLiveTest do
  # Not async: the cases point :application_dir at a temp home.
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.SSB.{Identities, Keys}

  setup %{conn: conn} do
    tmp =
      Path.join(System.tmp_dir!(), "hw-identity-live-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, tmp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :application_dir, previous),
        else: Application.delete_env(:highwire, :application_dir)

      File.rm_rf!(tmp)
    end)

    {:ok, conn: conn, home: tmp}
  end

  defp secret_path(home), do: Path.join([home, ".ssberl", "secret"])

  describe "the identity page" do
    test "lists identities and links the rail avatar to itself", %{conn: conn} do
      {:ok, _} = Identities.create("Main")
      {:ok, _} = Identities.create("Bot")

      {:ok, _view, html} = live(conn, "/identity")

      assert html =~ "Current identity"
      assert html =~ "Main"
      assert html =~ "Bot"

      # The rail avatar is the entry point: it names the identity and
      # links back here.
      assert html =~ ~s(aria-label="Identity")
      assert html =~ ~s(href="/identity")
      assert html =~ "You are Main — click to manage identities"
    end

    test "with no identity at all, the page offers to make one", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/identity")

      assert html =~ "No identity yet"
      # No identity, no avatar link in the rail.
      refute html =~ ~s(aria-label="Identity")
    end

    test "creating the first identity makes it the active one", %{conn: conn, home: home} do
      {:ok, view, html} = live(conn, "/identity")
      assert html =~ "No identity yet"

      html =
        view
        |> form("form", %{label: "Main"})
        |> render_submit()

      assert html =~ "Main is your identity now"
      assert html =~ "You are Main — click to manage identities"
      assert [row] = Identities.list()
      assert row["active"]
      assert Keys.load!(secret_path(home)).id == row["id"]
    end

    test "later identities arrive enabled but inactive", %{conn: conn} do
      {:ok, _} = Identities.create("Main")
      {:ok, view, _html} = live(conn, "/identity")

      html =
        view
        |> form("form", %{label: "Bot"})
        |> render_submit()

      assert html =~ "Created Bot — switch to it when you want to post as it"
      assert html =~ "You are Main — click to manage identities"
    end

    test "switching rewrites the secret the engine authenticates with", %{conn: conn, home: home} do
      {:ok, _} = Identities.create("Main")
      {:ok, bot} = Identities.create("Bot")

      {:ok, view, _html} = live(conn, "/identity")
      html = render_click(view, "switch", %{"id" => bot})

      # Engine disabled: the secret write is the whole switch.
      assert html =~ "Now posting as Bot"
      assert html =~ "You are Bot — click to manage identities"
      assert Keys.load!(secret_path(home)).id == bot
      assert Identities.active_id() == bot
    end

    test "delete is two-stage, and only ever offered on disabled rows", %{conn: conn} do
      {:ok, main} = Identities.create("Main")
      {:ok, bot} = Identities.create("Bot")

      {:ok, view, html} = live(conn, "/identity")

      # Enabled rows have no Delete at all.
      refute html =~ "Delete"

      html = render_click(view, "disable", %{"id" => bot})
      assert html =~ "Disabled"
      assert html =~ "Delete"

      # The first click only asks.
      html = render_click(view, "delete", %{"id" => bot})
      assert html =~ "Permanently delete"
      assert html =~ "Delete forever"
      assert Enum.any?(Identities.list(), &(&1["id"] == bot))

      html = render_click(view, "delete-cancel", %{})
      refute html =~ "Delete forever"
      assert Enum.any?(Identities.list(), &(&1["id"] == bot))

      # The second click goes through; the active identity is untouched.
      _html = render_click(view, "delete", %{"id" => bot})
      html = render_click(view, "delete-confirm", %{"id" => bot})

      assert html =~ "Bot was deleted permanently"
      refute Enum.any?(Identities.list(), &(&1["id"] == bot))
      assert Identities.active_id() == main
    end

    test "the active row's Disable is present but inert", %{conn: conn} do
      {:ok, _} = Identities.create("Main")

      {:ok, _view, html} = live(conn, "/identity")

      assert html =~ "Switch to another identity first"
    end

    test "export reveals the ssb-keys file inline", %{conn: conn} do
      {:ok, id} = Identities.create("Main")

      {:ok, view, _html} = live(conn, "/identity")
      html = render_click(view, "export", %{"id" => id})

      assert html =~ "WARNING: Never show this to anyone."
      assert html =~ id
    end
  end
end
