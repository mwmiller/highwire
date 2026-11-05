defmodule HighWireWeb.IdentitiesControllerTest do
  # Not async: the cases point :application_dir at a temp home.
  use HighWireWeb.ConnCase

  alias HighWire.SSB.Identities

  setup %{conn: conn} do
    tmp =
      Path.join(System.tmp_dir!(), "hw-identities-json-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, tmp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :application_dir, previous),
        else: Application.delete_env(:highwire, :application_dir)

      File.rm_rf!(tmp)
    end)

    {:ok, conn: conn}
  end

  test "lists the identities the menu can switch to, active first", %{conn: conn} do
    {:ok, main} = Identities.create("Main")
    {:ok, bot} = Identities.create("Bot")
    :ok = Identities.disable(bot)

    conn = get(conn, "/identities.json")
    items = json_response(conn, 200)

    # The active identity carries its flag; a disabled one cannot be
    # switched to, so it is not in the menu at all.
    assert [%{"id" => ^main, "label" => "Main", "active" => true}] = items
  end

  test "says nothing about keys", %{conn: conn} do
    {:ok, _} = Identities.create("Main")

    body = conn |> get("/identities.json") |> response(200)

    refute body =~ "private"
    refute body =~ "public"
  end
end
