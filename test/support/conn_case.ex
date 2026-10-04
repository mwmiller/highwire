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
end
