defmodule HighWireTest do
  use ExUnit.Case, async: true

  describe "version/0" do
    test "reads the app spec, not a hardcoded string" do
      # The spec's vsn comes from mix.exs; a release bump that forgets
      # a second copy used to leave the UI claiming 0.1.0 forever.
      assert HighWire.version() == to_string(Application.spec(:highwire, :vsn))
      assert HighWire.version() =~ ~r/\d+\.\d+\.\d+/
    end
  end

  describe "home_dir/0" do
    test "expands the configured application_dir" do
      assert HighWire.home_dir() ==
               :highwire
               |> Application.get_env(:application_dir)
               |> Path.expand()
    end
  end
end
