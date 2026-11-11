defmodule HighWire.Chess do
  @moduledoc """
  The chess namespace, in every format this node reads.

  Chess messages reach the network as `chess/<name>` (the current form),
  `chess_<name>` (the form the store has carried for years), or
  `ssb_chess_<name>` (the same four messages under the prefix one early
  client published). All of them name the same idea, so everything that
  asks "is this chess?" or "which store owns this?" goes through here and
  sees one answer.
  """

  alias HighWire.Chess.{Game, Legacy, Store}

  @doc """
  The canonical type for a raw chess message type, or nil for anything that
  is not chess.
  """
  @spec normalize_type(term()) :: String.t() | nil
  def normalize_type(type) when is_binary(type) do
    cond do
      type in Legacy.kinds() -> Legacy.canonical(type)
      name = Game.local_type(type) -> "chess_" <> name
      true -> nil
    end
  end

  def normalize_type(_), do: nil

  @doc "Whether a content map is a chess message in any format."
  @spec message?(term()) :: boolean()
  def message?(content), do: Game.message?(content) or Legacy.message?(content)

  @doc """
  File one envelope in the store that owns its format.

  The two stores hold different shapes — a `chess/*` row is ours to fold and
  play, a `chess_*` row is a record of somebody else's game — so the routing
  lives here rather than at each drain.
  """
  @spec observe(map()) :: :ok
  def observe(%{"value" => %{"content" => content}} = msg) when is_map(content) do
    cond do
      Legacy.message?(content) -> Legacy.Store.observe(msg)
      Game.message?(content) -> Store.observe(msg)
      true -> :ok
    end
  end

  def observe(_msg), do: :ok
end
