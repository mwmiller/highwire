defmodule HighWire.ThreadGraphTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias HighWire.ThreadGraph

  setup %{test: test} do
    name = :"thread_graph_#{test}"

    path =
      Path.join(HighWire.home_dir(), "thread-graph-#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(path) end)

    {:ok, name: name, path: path}
  end

  test "the graph survives a restart", %{name: name, path: path} do
    start(name, path)

    :ok =
      ThreadGraph.put(
        [{"%a=.sha256", "%r=.sha256"}, {"%r=.sha256", "%r=.sha256"}],
        name
      )

    stop(name)
    start(name, path)

    assert ThreadGraph.load(name) == %{
             "%a=.sha256" => "%r=.sha256",
             "%r=.sha256" => "%r=.sha256"
           }
  end

  test "a graph that is not running reads empty and accepts writes" do
    name = :thread_graph_absent

    assert ThreadGraph.load(name) == %{}
    assert ThreadGraph.put([{"%a=.sha256", "%r=.sha256"}], name) == :ok
  end

  test "rewrite replaces everything the file held", %{name: name, path: path} do
    start(name, path)

    :ok =
      ThreadGraph.put(
        [{"%a=.sha256", "%r=.sha256"}, {"%b=.sha256", "%r=.sha256"}],
        name
      )

    :ok = ThreadGraph.rewrite(%{"%b=.sha256" => "%r=.sha256"}, name)

    assert ThreadGraph.load(name) == %{"%b=.sha256" => "%r=.sha256"}
  end

  defp start(name, path) do
    spec = Supervisor.child_spec({ThreadGraph, name: name, path: path}, id: name)
    start_supervised!(spec)
  end

  defp stop(name), do: stop_supervised!(name)
end
