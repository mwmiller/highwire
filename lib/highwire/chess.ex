defmodule HighWire.Chess do
  @moduledoc """
  The chess namespace, in both formats this node reads.

  Chess messages reach the network as either `chess/<name>` (the current
  form) or `chess_<name>` (the form older clients published). Both name the
  same message, so everything that asks "is this chess?" or "which drain does
  this belong to?" goes through here and sees one answer.
  """

  alias HighWire.Chess.{Game, Legacy}

  @doc """
  The canonical type for a raw chess message type, or nil for anything that
  is not chess.
  """
  @spec normalize_type(term()) :: String.t() | nil
  def normalize_type(type) when is_binary(type) do
    cond do
      type in Legacy.types() -> type
      name = Game.local_type(type) -> "chess_" <> name
      true -> nil
    end
  end

  def normalize_type(_), do: nil

  @doc "Whether a content map is a chess message in either format."
  @spec message?(term()) :: boolean()
  def message?(content), do: Game.message?(content) or Legacy.message?(content)
end
