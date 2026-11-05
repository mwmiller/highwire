defmodule HighWire.Backgammon.Game do
  @moduledoc """
  The wire messages a backgammon game publishes, and the identity helpers
  around them.

  Every message is an ordinary public message in the author's feed, in the
  `backgammon/*` namespace. The author is the player, so no message carries a
  `player` field; a game is a thread, so everything after the challenge
  carries `root` — the key of the challenge message.

  `game_id` is 32 random bytes as 64 lowercase hex characters, which keeps it
  safe in a URL and readable in a store dump.

  Reveals are hex in the wire format and binaries inside a fold. Each
  roll/turn carries the pair `r_cur`/`r_next`: the half that mixes into this
  roll and the freshly announced half for the next one.
  """

  alias HighWire.Games.Id

  @version 1
  @names ~w(challenge accept roll turn resign withdraw)

  @type role :: String.t()

  @doc "Protocol version, carried as `v` on every message."
  def version, do: @version

  @doc "Every message name in the namespace."
  def names, do: @names

  @doc "The full content type for a message name."
  def type(name) when name in @names, do: "backgammon/" <> name

  @doc "The message name for a content type, or nil when it is not ours."
  def local_type("backgammon/" <> name) when name in @names, do: name
  def local_type(_), do: nil

  @doc "Whether a content map is a backgammon message."
  def message?(content) when is_map(content), do: local_type(content["type"]) != nil
  def message?(_), do: false

  @doc "A fresh game id: 32 random bytes as 64 lowercase hex characters."
  def new_id, do: Id.new()

  @doc "Whether a binary is a well-formed game id."
  def id?(id), do: Id.valid?(id)

  @doc "Hex-encode 32 bytes."
  def hex(bin) when is_binary(bin), do: Base.encode16(bin, case: :lower)

  @doc "Decode a 32-byte hex value."
  def unhex32(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bin} when byte_size(bin) == 32 -> {:ok, bin}
      _ -> :error
    end
  end

  def unhex32(_), do: :error

  @doc """
  A challenge. `role` is `"challenger"` for the opening message; `commit` is
  hex. `:to` names a feed for a directed challenge and is omitted for an open
  one.
  """
  def challenge(game_id, commit, opts \\ []) do
    base(%{
      "type" => type("challenge"),
      "game_id" => game_id,
      "role" => "challenger",
      "commit" => commit,
      "to" => opts[:to],
      "note" => opts[:note]
    })
  end

  @doc "An accept. Carries the accepter's commitment and first reveal."
  def accept(game_id, root, commit, reveal, opts \\ []) do
    base(%{
      "type" => type("accept"),
      "game_id" => game_id,
      "root" => root,
      "role" => "accepter",
      "commit" => commit,
      "reveal" => reveal,
      "note" => opts[:note]
    })
  end

  @doc "An opening roll for `round`."
  def roll(game_id, root, round, r_cur, r_next, reveals, opts \\ []) do
    base(%{
      "type" => type("roll"),
      "game_id" => game_id,
      "root" => root,
      "round" => round,
      "r_cur" => r_cur,
      "r_next" => r_next,
      "reveals" => reveals,
      "note" => opts[:note]
    })
  end

  @doc """
  A turn: the roll as played, and the reveal pair that proves it. `pair` is
  `{r_cur, r_next}`.
  """
  def turn(game_id, root, turn, roll, moves, {r_cur, r_next}, reveals, opts \\ []) do
    base(%{
      "type" => type("turn"),
      "game_id" => game_id,
      "root" => root,
      "turn" => turn,
      "roll" => roll,
      "moves" => moves,
      "r_cur" => r_cur,
      "r_next" => r_next,
      "reveals" => reveals,
      "note" => opts[:note]
    })
  end

  @doc """
  A resignation by the player whose move it is.

  `player` is the resigning side. `turn` is carried as an option because the
  wire format decides it from the game's turn count, not from a separate
  argument.
  """
  def resign(game_id, root, player, opts \\ []) do
    base(%{
      "type" => type("resign"),
      "game_id" => game_id,
      "root" => root,
      "player" => player,
      "turn" => opts[:turn],
      "note" => opts[:note]
    })
  end

  @doc "A challenger withdrawing before anyone accepts."
  def withdraw(game_id, root) do
    base(%{"type" => type("withdraw"), "game_id" => game_id, "root" => root})
  end

  @doc """
  A stable wire key for a backgammon message, used when a write is filed
  locally without posting a timeline message. It is deterministic from the
  message shape, so the same logical write always lands on the same store
  row.
  """
  def key_for(%{"type" => type, "game_id" => game_id, "root" => root})
      when is_binary(type) and is_binary(game_id) and is_binary(root) do
    "backgammon:" <> type <> ":" <> game_id <> ":" <> root
  end

  def key_for(%{"type" => type, "game_id" => game_id, "round" => round})
      when is_binary(type) and is_binary(game_id) do
    "backgammon:" <> type <> ":" <> game_id <> ":" <> to_string(round)
  end

  def key_for(%{"type" => type, "game_id" => game_id})
      when is_binary(type) and is_binary(game_id) do
    "backgammon:" <> type <> ":" <> game_id
  end

  def key_for(_content), do: "backgammon:unknown"

  @doc "The roll as the notation writes it."
  def roll_string(a, b) when a in 1..6 and b in 1..6, do: "#{a}-#{b}"

  @doc "Parse `\"3-5\"` into `{3, 5}`, or `:error`."
  def parse_roll(string) when is_binary(string) do
    with [a, b] <- String.split(string, "-"),
         {a, ""} <- Integer.parse(a),
         {b, ""} <- Integer.parse(b),
         true <- a in 1..6 and b in 1..6 do
      {a, b}
    else
      _ -> :error
    end
  end

  def parse_roll(_), do: :error

  # Version on every message, and no nil-valued keys: a message is what a
  # reader sees, so absent fields are absent rather than null.
  defp base(fields) do
    fields
    |> Map.put("v", @version)
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
