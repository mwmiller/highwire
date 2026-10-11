defmodule HighWireWeb.Components.Mentions do
  @moduledoc """
  Shared @ / ~ mention candidates: filtering, scoring, and ranking for
  a typed query — used by the timeline composer and the thread reply
  box, which each bring their own id source and name lookup.
  """

  @doc """
  The top eight `{id, name}` candidates for `q` among `ids`, naming
  each through `name_of`. An empty query lists everything known;
  matches rank prefix → substring → id fragment, then by name.
  """
  @spec candidates(binary(), [binary()], (binary() -> binary())) :: [{binary(), binary()}]
  def candidates(q, ids, name_of)
      when is_binary(q) and is_list(ids) and is_function(name_of, 1) do
    query = String.downcase(q)

    ids
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
    |> Enum.uniq()
    |> Enum.map(&{&1, name_of.(&1)})
    |> Enum.map(fn {id, name} -> {id, name, score(name, id, query)} end)
    |> Enum.reject(fn {_id, _name, s} -> s == :miss end)
    |> Enum.sort_by(fn {id, name, s} -> {s, String.downcase(name), id} end)
    |> Enum.take(8)
    |> Enum.map(fn {id, name, _s} -> {id, name} end)
  end

  defp score(_name, _id, ""), do: 0

  defp score(name, id, query) do
    down_name = String.downcase(name)

    cond do
      String.starts_with?(down_name, query) -> 1
      String.contains?(down_name, query) -> 2
      String.contains?(String.downcase(id), query) -> 3
      true -> :miss
    end
  end
end
