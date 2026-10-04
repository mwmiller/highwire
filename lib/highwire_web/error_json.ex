defmodule HighWireWeb.ErrorJSON do
  @moduledoc false
  use HighWireWeb, :html

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
