defmodule HighWire.SSB.Profile do
  @moduledoc """
  What followers see — each feed's display name and avatar image — as
  a small ETS read model beside the Timeline that resolves it.

  Every payload broadcast carries `%{id => %{name, image}}` for the
  feeds in that window, but a payload belongs to a moment: the next
  finalize evicts ids the window no longer covers, and the rail is a
  function component with no process to ask. So the Timeline shadows
  each payload here before it broadcasts, and entries only ever
  accumulate — the union of everything the engine has ever answered —
  which is the set the identity page needs to show its own feeds
  whether or not they still hold a window seat.

  A read degrades to nil: a feed the engine has never described has no
  entry, and `HighWire.Avatar.display_name/2` then falls back to the
  short id — what that feed shows its followers anyway.
  """

  alias HighWire.Avatar, as: Ident

  @table __MODULE__

  @type profile :: %{name: binary() | nil, image: binary() | nil}
  @type profiles :: %{optional(binary()) => profile()}

  @doc """
  Create the table when it is not up yet. The Timeline calls this from
  its init so the writer owns the table; writes also self-heal, so a
  read model whose table is gone rebuilds on the next payload.
  """
  @spec create() :: :ok
  def create do
    ensure_table()
    :ok
  end

  @doc """
  Store a payload's profiles (id → `%{name, image}`), merging over
  what is already known. Entries are never dropped — a later payload
  that no longer covers a feed must not take its name away from the
  pages still showing it.
  """
  @spec put_all(map()) :: :ok
  def put_all(profiles) when is_map(profiles) do
    entries =
      Enum.map(profiles, fn
        {id, profile} when is_map(profile) ->
          {id, %{name: Map.get(profile, :name), image: Map.get(profile, :image)}}

        {id, _other} ->
          {id, %{name: nil, image: nil}}
      end)

    true = :ets.insert(ensure_table(), entries)
    :ok
  end

  @doc "Record the blob revision avatar URLs cache-bust on."
  @spec put_rev(integer()) :: :ok
  def put_rev(rev) when is_integer(rev) do
    true = :ets.insert(ensure_table(), {:rev, rev})
    :ok
  end

  @doc "One feed's presentation — nil while nothing has resolved it."
  @spec get(binary()) :: profile() | nil
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, profile}] -> profile
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Presentations for the given ids, dropping the unresolved ones."
  @spec take([binary()]) :: profiles()
  def take(ids) when is_list(ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      case get(id) do
        nil -> acc
        profile -> Map.put(acc, id, profile)
      end
    end)
  end

  @doc """
  The name a feed goes by, through the one resolution every view
  shares (`HighWire.Avatar.display_name/2`): its alias when the store
  has one, the short id when it does not.
  """
  @spec display_name(binary()) :: binary()
  def display_name(id) when is_binary(id), do: Ident.display_name(id, %{id => get(id)})

  @doc "The feed's avatar image ref, or nil for the identicon."
  @spec image(binary()) :: binary() | nil
  def image(id) when is_binary(id), do: get(id)[:image]

  @doc "The blob revision for cache-busting avatar URLs, or nil."
  @spec rev() :: integer() | nil
  def rev do
    case :ets.lookup(@table, :rev) do
      [{:rev, rev}] -> rev
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp ensure_table do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    @table
  rescue
    ArgumentError -> @table
  end
end
