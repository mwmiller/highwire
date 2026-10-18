defmodule HighWireWeb.IdentityLiveTest do
  # Not async: the cases point :application_dir at a temp home.
  use HighWireWeb.ConnCase

  import Phoenix.LiveViewTest

  alias HighWire.Avatar, as: Ident
  alias HighWire.Blob
  alias HighWire.SSB.{Identities, Keys, Profile}

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
      {:ok, main} = Identities.create("Main")
      {:ok, bot} = Identities.create("Bot")

      {:ok, _view, html} = live(conn, "/identity")

      assert html =~ "Current identity"
      assert html =~ "Main"
      assert html =~ "Bot"

      # The rail avatar is the entry point: it links back here, and its
      # title pairs the name followers see with the local label in
      # parentheses after it. Nothing has resolved for this key yet, so
      # the name is the short id — what a feed with no profile shows.
      assert html =~ ~s(aria-label="Identity")
      assert html =~ ~s(href="/identity")
      assert html =~ "You are #{Ident.short_id(main)} (Main) — click to manage identities"

      # A row with nothing published resolves the same way: short id
      # first, the local label in parens after it.
      assert html =~ ~r/#{Regex.escape(Ident.short_id(bot))}\s*<span[^>]*>\(Bot\)/

      # The avatar sits beside the gear at the top right, not beside
      # the crab mark at the left.
      {crab, _} = :binary.match(html, ~s(aria-label="Timeline"))
      {avatar, _} = :binary.match(html, ~s(aria-label="Identity"))
      {gear, _} = :binary.match(html, ~s(aria-label="Settings"))
      assert crab < avatar and avatar < gear
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

      assert html =~
               "You are #{Ident.short_id(Identities.active_id())} (Main) — click to manage identities"

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

      assert html =~
               "You are #{Ident.short_id(Identities.active_id())} (Main) — click to manage identities"
    end

    test "switching rewrites the secret the engine authenticates with", %{conn: conn, home: home} do
      {:ok, _} = Identities.create("Main")
      {:ok, bot} = Identities.create("Bot")

      {:ok, view, _html} = live(conn, "/identity")
      html = render_click(view, "switch", %{"id" => bot})

      # Engine disabled: the secret write is the whole switch.
      assert html =~ "Now posting as Bot"
      assert html =~ "You are #{Ident.short_id(bot)} (Bot) — click to manage identities"
      assert Keys.load!(secret_path(home)).id == bot
      assert Identities.active_id() == bot
    end

    test "the rail and card show what followers see, label in parens after", %{conn: conn} do
      {:ok, id} = Identities.create("Main")
      ref = "&ohrb6WhNesxa/1Qu6mccRSZgjUKh5kF1tZ5aykPQDjo=.sha256"

      :ok = Profile.put_all(%{id => %{name: "dtBy", image: ref}})

      {:ok, _view, html} = live(conn, "/identity")

      # The title pairs the alias followers know with the local label…
      assert html =~ "You are dtBy (Main) — click to manage identities"
      # …and the card pairs them the same way: name, then parens.
      assert html =~ ~r/dtBy\s*<span[^>]*>\(Main\)/
      # The avatar is the feed's own image, never the identicon.
      assert html =~ Blob.url(ref)
      refute html =~ Ident.identicon_url(id)
    end

    test "an answer landing after mount fills in without a reload", %{conn: conn} do
      {:ok, id} = Identities.create("Main")

      {:ok, view, html} = live(conn, "/identity")
      refute html =~ "dtBy"

      :ok = Profile.put_all(%{id => %{name: "dtBy", image: nil}})

      # Transfers ride the same topic and carry nothing — the page
      # takes both messages without a hiccup.
      send(view.pid, {HighWire.Timeline, :transfer, %{}})
      send(view.pid, {HighWire.Timeline, :updated, %{}})

      html = render(view)
      assert html =~ "You are dtBy (Main) — click to manage identities"
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
