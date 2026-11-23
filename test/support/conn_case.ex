defmodule HighWireWeb.ConnCase do
  @moduledoc """
  Test case template for tests exercising the web layer.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest

      import HighWireWeb.ConnCase

      @endpoint HighWireWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Point the app at an SSB home no engine of HighWire's runs in, for the
  length of the test — the page's view of an engine somebody else owns.
  Returns the empty directory; the config is restored and the directory
  removed on exit.
  """
  def external_engine_home do
    home = Path.join(System.tmp_dir!(), "hw-external-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)

    previous = Application.get_env(:highwire, :ssb_home)
    Application.put_env(:highwire, :ssb_home, home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :ssb_home, previous),
        else: Application.delete_env(:highwire, :ssb_home)

      File.rm_rf(home)
    end)

    home
  end
end
