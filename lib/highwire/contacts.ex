defmodule HighWire.Contacts do
  @moduledoc """
  The collapsed rail's contacts: a stable random handful of the feeds we
  follow, held off the Timeline and the LiveView both.

  The rail used to be a sliding window over the alphabetized roll,
  stepped by a clock — faces drifted past whether or not anything had
  changed. This holds one draw instead: taken when the follow list
  changes (or when the process restarts), then returned unchanged on
  every read, so the rail holds still between contact edits. A draw is
  sorted by display alias for presentation, through the same read model
  every view resolves names with.
  """

  use GenServer

  alias HighWire.SSB.Profile

  @subset 7

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "How many contacts the collapsed rail shows."
  @spec subset_size() :: pos_integer()
  def subset_size, do: @subset

  @doc """
  The current draw, sorted by display alias. A missing process reads as
  an empty rail rather than taking the caller down with it.
  """
  @spec get_contacts(GenServer.server()) :: [String.t()]
  def get_contacts(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> []
      pid -> GenServer.call(pid, :contacts)
    end
  end

  @doc """
  Offer the current candidate list — the feeds we follow, self already
  excluded. A new draw is only taken when the list actually changes.
  """
  @spec cast_contacts([String.t()], GenServer.server()) :: :ok
  def cast_contacts(candidates, server \\ __MODULE__) do
    candidates = List.wrap(candidates)

    case GenServer.whereis(server) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:contacts, candidates})
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{all: nil, selected: []}}

  @impl true
  def handle_call(:contacts, _from, state) do
    {:reply, sort_by_alias(state.selected), state}
  end

  # Same follow list as last time — nothing has changed, so the draw
  # holds. Only a real edit redraws it.
  @impl true
  def handle_cast({:contacts, candidates}, %{all: candidates} = state) do
    {:noreply, state}
  end

  def handle_cast({:contacts, candidates}, state) do
    {:noreply, %{state | all: candidates, selected: draw(candidates)}}
  end

  # A fresh random handful, capped at @subset. A list that already fits
  # still comes back in a fresh order each draw, which is why the draw
  # happens once here and not on every read.
  defp draw(candidates) do
    candidates
    |> Enum.uniq()
    |> Enum.shuffle()
    |> Enum.take(@subset)
  end

  defp sort_by_alias(ids) do
    Enum.sort_by(ids, &{String.downcase(Profile.display_name(&1)), &1})
  end
end
