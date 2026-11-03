defmodule HighWire.Backgammon.Chain do
  @moduledoc """
  Provably-fair reveal chain for HighWire backgammon.

  Each player holds a deterministic chain of 32-byte values:

      chain[0]   = SHA-256(seed)
      chain[i+1] = SHA-256(chain[i])

  where the seed is derived from the player's identity secret, so the whole
  chain can be **recovered from the logs alone** (fresh device, lost local
  state):

      seed = HMAC-SHA256(identity_secret, "highwire/backgammon/v1/seed:" <> game_id <> ":" <> role)

  The **commitment** is `SHA-256(chain[-1])` — the hash of the last value —
  published when the game begins so the player cannot change their chain
  after seeing the opponent's play.

  Reveals walk the chain **in reverse order**: the first reveal is the last
  element, `chain[-1]`, then `chain[-2]`, and so on. Because each value is a
  one-way preimage of the previous, publishing an early reveal never leaks
  the later ones.

  Reveals are verified incrementally:

      verify_first(revealed, commitment)   # SHA-256(revealed) == commitment
      verify_next(revealed, prior_reveal)  # derive(revealed) == prior_reveal

  The dice for a turn come from two freshly-revealed halves (one per player):

      dice = SHA-256(mover_half <> opponent_half)

  ## Why SHA-256 and not a password KDF

  The binding here rests on collision and preimage resistance, not on KDF
  cost: a player who deviates has to find a preimage after committing. The
  inputs are 32 bytes derived from an ed25519 secret, so there is no
  low-entropy password to stretch and no dictionary to slow down. A memory
  hard KDF would buy nothing and would cost every verifier — and every
  third-party client — a dependency that browsers do not ship.

  ## Chain spec

  The one variable constant is the chain length, kept in a map so a challenge
  stays self-describing:

      %{"length" => 1024}

  Two links are spent per turn, so a game has 512 turns of headroom — more
  than any real game consumes.
  """

  @length 1024
  @seed_label "highwire/backgammon/v1/seed"

  @doc "The standard chain spec."
  @spec spec() :: map()
  def spec, do: %{"length" => @length}

  @doc "Derive the next chain value from a previous one."
  @spec derive(binary(), map()) :: binary()
  def derive(prev, _spec \\ spec()) when is_binary(prev) and byte_size(prev) == 32 do
    :crypto.hash(:sha256, prev)
  end

  @doc """
  Derive the recoverable chain seed for a game from an identity secret.

  `role` is `"challenger"` or `"accepter"`. The derivation is deterministic,
  so a player on a fresh device can regenerate the exact chain they committed
  to using only the game id and their role from the log.
  """
  @spec seed_for(binary(), String.t(), String.t(), map()) :: binary()
  def seed_for(identity_secret, game_id, role, _spec \\ spec())
      when is_binary(identity_secret) and is_binary(game_id) and is_binary(role) do
    :crypto.mac(:hmac, :sha256, identity_secret, @seed_label <> ":" <> game_id <> ":" <> role)
  end

  @doc """
  Generate a chain of `spec["length"]` values from a seed.

  Returns 32-byte binaries ordered from the seed onward. The first element is
  `derive(seed)`, not the seed itself — the seed never leaves the node.
  """
  @spec generate(binary(), map()) :: [binary()]
  def generate(seed, spec \\ spec()) when is_binary(seed) do
    first = derive(seed, spec)

    Enum.reduce(2..spec["length"]//1, [first], fn _, [next | _] = acc ->
      [derive(next, spec) | acc]
    end)
    |> Enum.reverse()
  end

  @doc """
  Compute the commitment for a chain: `SHA-256` of its last element.

  Pass the full chain (list of 32-byte binaries) or just the last element.
  """
  @spec commit([binary()] | binary()) :: binary()
  def commit(chain) when is_list(chain), do: chain |> List.last() |> commit()

  def commit(value) when is_binary(value) and byte_size(value) == 32 do
    :crypto.hash(:sha256, value)
  end

  @doc """
  Derive dice from both players' revealed chain values.

  `my_value` is the mover's freshly revealed half, `opp_value` the opponent's
  most recently published one. Deterministic and order-sensitive, so both
  players and any verifier recompute the same roll.
  """
  @spec dice(binary(), binary(), pos_integer()) :: [pos_integer()]
  def dice(my_value, opp_value, count \\ 2)
      when is_binary(my_value) and byte_size(my_value) == 32 and
             is_binary(opp_value) and byte_size(opp_value) == 32 and
             is_integer(count) and count >= 1 do
    extract_dice([], %{hash_next: my_value <> opp_value, found: [], needed: count})
  end

  @doc false
  def extract_dice(_hash, %{needed: 0, found: f}), do: Enum.reverse(f)

  def extract_dice([], %{hash_next: hn} = acc) do
    hash = :crypto.hash(:sha256, hn)
    extract_dice(:binary.bin_to_list(hash), %{acc | hash_next: hash})
  end

  # Rejection sampling: 0..251 divides evenly into six faces, so 252..255 are
  # dropped rather than folded in with a bias.
  def extract_dice([byte | rest], acc) when byte >= 252, do: extract_dice(rest, acc)

  def extract_dice([byte | rest], %{needed: n, found: f} = acc) do
    extract_dice(rest, %{acc | found: [rem(byte, 6) + 1 | f], needed: n - 1})
  end

  @doc """
  The next reveal pair for a player, indexed from how much entropy is left.

  `remaining` counts untouched reveals (from the chain length; the accepter
  starts one lower because their accept reveal consumes `chain[-1]`).
  Returns `{r_cur, r_next}`. Acting requires `remaining >= 2`; `0` means the
  chain is spent.
  """
  @spec reveal_pair([binary()], integer(), map() | nil) :: {binary(), binary()}
  def reveal_pair(chain, remaining, spec \\ nil)
      when is_list(chain) and is_integer(remaining) and remaining >= 2 do
    len = if is_map(spec), do: spec["length"], else: length(chain)
    [r_cur, r_next | _] = Enum.drop(Enum.reverse(chain), len - remaining)
    {r_cur, r_next}
  end

  @doc "Verify the first reveal of a chain against its commitment."
  @spec verify_first(binary(), binary()) :: :ok | {:error, String.t()}
  def verify_first(revealed, commitment)
      when is_binary(revealed) and byte_size(revealed) == 32 and
             is_binary(commitment) and byte_size(commitment) == 32 do
    if commit(revealed) == commitment do
      :ok
    else
      {:error, "reveal does not match commitment"}
    end
  end

  @doc "Verify a reveal extends the chain backward from the previous one."
  @spec verify_next(binary(), binary(), map()) :: :ok | {:error, String.t()}
  def verify_next(revealed, prior_reveal, spec \\ spec())
      when is_binary(revealed) and byte_size(revealed) == 32 and
             is_binary(prior_reveal) and byte_size(prior_reveal) == 32 do
    if derive(revealed, spec) == prior_reveal do
      :ok
    else
      {:error, "reveal does not extend the chain"}
    end
  end
end
