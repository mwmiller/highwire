defmodule HighWire.Games.Id do
  @moduledoc """
  Game ids: 32 random bytes as 64 lowercase hex characters.

  Both games use this shape, so a gameroom URL does not say which game it
  points at, and the database never has to. The rules live here once
  because a game module that generated or accepted a different shape would
  be wrong in a way the other game's store would not notice.
  """

  @doc "A fresh game id."
  @spec new() :: binary()
  def new, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  @doc "Whether a term is a well-formed game id."
  @spec valid?(term()) :: boolean()
  def valid?(id) when is_binary(id) and byte_size(id) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(id, case: :lower))
  end

  def valid?(_), do: false
end
