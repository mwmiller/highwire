defmodule HighWire.Chess.Game do
  @moduledoc """
  The wire messages a chess game publishes, and the identity helpers around
  them.

  Every message is an ordinary public message in the author's feed, in the
  `chess/*` namespace. The author is the player, so no message carries a
  `player` field; a game is a thread, so everything after the challenge
  carries `root` — the key of the challenge message.

  Chess hides nothing, so there is no commitment and no reveal: each move is
  its own proof, because replaying it either lands on a legal position or it
  does not. That is the whole difference from backgammon's protocol, and it
  is why a chess game needs no chain.

  A move goes on the wire as coordinates (`"e2e4"`, `"e7e8q"`) and a `ply`
  counting up from 1, so two nodes fold the same sequence regardless of the
  order the messages arrive in.
  """

  alias HighWire.Games.Id

  @version 1
  @names ~w(challenge accept move resign withdraw)

  @doc "Protocol version, carried as `v` on every message."
  def version, do: @version

  @doc "Every message name in the namespace."
  def names, do: @names

  @doc "The full content type for a message name."
  def type(name) when name in @names, do: "chess/" <> name

  @doc "The message name for a content type, or nil when it is not ours."
  def local_type("chess/" <> name) when name in @names, do: name
  def local_type(_), do: nil

  @doc "Whether a content map is a chess message."
  def message?(content) when is_map(content), do: local_type(content["type"]) != nil
  def message?(_), do: false

  @doc """
  A fresh game id, the same shape a backgammon game uses, so a gameroom URL
  and its route constraint do not care which game it points at.
  """
  def new_id, do: Id.new()

  @doc "Whether a binary is a well-formed game id."
  def id?(id), do: Id.valid?(id)

  @doc """
  A challenge. `color` is the side the challenger takes — `"white"` or
  `"black"` — so a player can open as either. `:to` names a feed for a
  directed challenge and is omitted for an open one.
  """
  def challenge(game_id, color, opts \\ []) do
    base(%{
      "type" => type("challenge"),
      "game_id" => game_id,
      "role" => "challenger",
      "color" => color,
      "to" => opts[:to],
      "note" => opts[:note]
    })
  end

  @doc "An accept. The accepter takes the side the challenger left."
  def accept(game_id, root, opts \\ []) do
    base(%{
      "type" => type("accept"),
      "game_id" => game_id,
      "root" => root,
      "role" => "accepter",
      "note" => opts[:note]
    })
  end

  @doc "A move in coordinates, at `ply` counting up from 1."
  def move(game_id, root, ply, uci, opts \\ []) do
    base(%{
      "type" => type("move"),
      "game_id" => game_id,
      "root" => root,
      "ply" => ply,
      "uci" => uci,
      "note" => opts[:note]
    })
  end

  @doc "A resignation by the player whose move it is."
  def resign(game_id, root, ply, opts \\ []) do
    base(%{
      "type" => type("resign"),
      "game_id" => game_id,
      "root" => root,
      "ply" => ply,
      "note" => opts[:note]
    })
  end

  @doc "A challenger withdrawing before anyone accepts."
  def withdraw(game_id, root) do
    base(%{"type" => type("withdraw"), "game_id" => game_id, "root" => root})
  end

  # Version on every message, and no nil-valued keys: a message is what a
  # reader sees, so absent fields are absent rather than null.
  defp base(fields) do
    fields
    |> Map.put("v", @version)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
