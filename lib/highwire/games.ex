defmodule HighWire.Games do
  @moduledoc """
  A game read from whichever store holds it.

  A game id is derived from its challenge, so the id says nothing about which
  game it is: a page that has only the id asks every store, and the one that
  answers wins. Callers that already know the kind read that store directly.
  """

  alias HighWire.Backgammon
  alias HighWire.Chess

  @doc """
  The snapshot of the game with `game_id`, or nil when no store holds it.
  """
  @spec get(term()) :: map() | nil
  def get(game_id) when is_binary(game_id) do
    Chess.Store.get(game_id) || Chess.Legacy.Store.get(game_id) || Backgammon.Store.get(game_id)
  end

  def get(_game_id), do: nil
end
