defmodule HighWireWeb.IdentitiesController do
  @moduledoc """
  The identity list as data: `GET /identities.json`.

  The desktop shell's Go menu lists every identity this install can
  post as, and a native menu is built outside the page — so the shell
  asks here for the list whenever a page loads and rebuilds the menu's
  identity items when it changes. The browser-only app never calls it.

  Only what a menu needs leaves: the id, this install's label for it,
  and whether it is the one being posted as. Private key material is
  never in `Identities.list/0` to begin with, and disabled identities
  are left out because they cannot be switched to.
  """

  use HighWireWeb, :controller

  alias HighWire.SSB.Identities

  def index(conn, _params) do
    items =
      Identities.list()
      |> Enum.reject(& &1["disabled"])
      |> Enum.map(fn row ->
        %{id: row["id"], label: row["label"], active: row["active"] == true}
      end)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(items)
  end
end
