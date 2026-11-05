defmodule HighWire.Backgammon.Log do
  @moduledoc """
  The writes a backgammon game makes: open one, accept one, roll the opening
  dice, play a turn, resign, or withdraw an unanswered challenge.

  Every write is an ordinary public message in the `backgammon/*` namespace,
  published to the player's own feed, so a game needs no server, no room and
  no arbiter: the opponent reads it the way they read anything else, and both
  feeds together are the game.

  The message is filed into the local store as soon as the engine hands back
  its key, because the player's next page reads the game straight away. The
  drain's later delivery of the same envelope is a no-op — the store keys on
  the message, so the second copy is recognised and folds nothing twice.

  Nothing here stores a reveal chain. A chain is derived from the player's
  identity secret, the game id and their role, so a game carries on from a
  device that never held it: that is what the commitment was for. What the
  writer needs from the fold is how much entropy is left and the opponent's
  most recently published half, since a turn's dice are the two halves.

  A turn is checked before it goes out — the roll is recomputed from the two
  halves, and the play must be legal and maximal — so this client cannot
  publish a turn the fold would reject. A game that disagrees can only be the
  other player's doing, which is what the fold's `:broken` is for.
  """

  alias HighWire.Backgammon.{Chain, Engine, Game, Notation, Store}
  alias HighWire.SSB.Identities
  alias HighWire.Timeline

  @type move :: {term(), term()}

  @doc """
  Open a game: write a challenge and return its id and the key that later
  moves answer to.

  Options: `:to` (a feed to challenge directly), `:note`, `:game_id` (tests),
  and the test seams `:publish`, `:author` and `:secret`.

  This writes the local store copy first. If there is `:commentary` content,
  it is posted to the timeline as a backgammon chat message, otherwise the
  game quiet write is silent and the returned key is throwaway.
  """
  @spec open(keyword()) :: {:ok, binary(), binary()} | {:error, term()}
  def open(opts \\ []) do
    game_id = Keyword.get(opts, :game_id) || Game.new_id()

    with {:ok, chain} <- chain(game_id, "challenger", opts) do
      content =
        Game.challenge(game_id, Game.hex(Chain.commit(chain)),
          to: opts[:to],
          note: opts[:note]
        )

      with {:ok, key} <- publish_and_file(content, opts), do: {:ok, game_id, key}
    end
  end

  defp publish_and_file(content, opts) do
    with {:ok, key} <- publish(content, opts) do
      file(key, content, opts)
      {:ok, key}
    end
  end

  defp publish(content, opts) do
    publisher = Keyword.get(opts, :publish) || default_publisher()
    publisher.(content)
  end

  @doc """
  Accept a challenge: the accepter takes the side the challenger left, and
  their first reveal is the one the commitment was made to.
  """
  @spec accept(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def accept(game, opts \\ []) do
    with :ok <- can_accept(game, me(opts)),
         {:ok, chain} <- chain(game.game_id, "accepter", opts) do
      content =
        Game.accept(
          game.game_id,
          game.challenge_key,
          Game.hex(Chain.commit(chain)),
          Game.hex(List.last(chain)),
          note: opts[:note]
        )

      publish_and_file(content, opts)
    end
  end

  @doc """
  Roll the opening dice.

  Both players roll, challenger first, until one die is higher; each roll
  spends two links of the roller's chain, and a tie rolls the next round.
  """
  @spec roll(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def roll(game, opts \\ []) do
    with {:ok, me} <- player(game, me(opts)),
         :ok <- turn_of(game, me, :opening),
         {:ok, chain} <- chain(game.game_id, role(game, me), opts),
         {:ok, remaining} <- remaining(game, me),
         {:ok, {r_cur, r_next}} <- reveal(chain, remaining) do
      content =
        Game.roll(
          game.game_id,
          game.challenge_key,
          opening_round(game),
          Game.hex(r_cur),
          Game.hex(r_next),
          remaining,
          note: opts[:note]
        )

      publish_and_file(content, opts)
    end
  end

  @doc """
  Play a turn: `moves` is Magriel notation (`"13/8 8/3"`) or a list of
  `{from, to}` pairs, with `:bar` and `:off` as the special positions.

  The roll is decided before the play: the mover's next reveal and the
  opponent's last one fix it, which is what lets the page show the dice and
  the player choose. The play then goes out with both halves, so any reader
  can recompute the roll and check the moves against it.
  """
  @spec play(map(), String.t() | [move()], keyword()) :: {:ok, binary()} | {:error, term()}
  def play(game, moves, opts \\ []) do
    with {:ok, me} <- player(game, me(opts)),
         :ok <- turn_of(game, me, :playing),
         {:ok, chain} <- chain(game.game_id, role(game, me), opts),
         {:ok, remaining} <- remaining(game, me),
         {:ok, {r_cur, r_next}} <- reveal(chain, remaining),
         {:ok, dice} <- dice(game, r_cur, me),
         {:ok, moves} <- parse(moves),
         :ok <- legal?(game, dice, moves) do
      content =
        Game.turn(
          game.game_id,
          game.challenge_key,
          game.turn_count + 1,
          Game.roll_string(elem(dice, 0), elem(dice, 1)),
          Notation.turn(moves),
          {Game.hex(r_cur), Game.hex(r_next)},
          remaining,
          note: opts[:note]
        )

      publish_and_file(content, opts)
    end
  end

  @doc "Resign: the game goes to the other player."
  @spec resign(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def resign(game, opts \\ []) do
    with {:ok, me} <- player(game, me(opts)),
         :ok <- turn_of(game, me, :playing) do
      content =
        Game.resign(game.game_id, game.challenge_key, me,
          turn: game.turn_count + 1,
          note: opts[:note]
        )

      publish_and_file(content, opts)
    end
  end

  @doc "Withdraw a challenge nobody has accepted yet."
  @spec withdraw(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def withdraw(game, opts \\ []) do
    me = me(opts)

    with {:ok, game} <- editable(game),
         {:ok, me} <- player(game, me),
         :ok <- open_challenge(game, me) do
      content = Game.withdraw(game.game_id, game.challenge_key)

      publish_and_file(content, opts)
    end
  end

  @doc """
  The dice the next turn will use, for a page that wants to show them before
  the turn is published.

  The first turn after the opening uses the opening dice themselves; every
  turn after that is derived from the mover's next reveal and the opponent's
  last published half.
  """
  @spec next_dice(map(), binary(), keyword()) :: {:ok, {1..6, 1..6}} | {:error, term()}
  def next_dice(game, player, opts \\ []) do
    with {:ok, chain} <- chain(game.game_id, role(game, player), opts),
         {:ok, remaining} <- remaining(game, player),
         {:ok, {r_cur, _r_next}} <- reveal(chain, remaining) do
      dice(game, r_cur, player)
    end
  end

  # -- the chain ---------------------------------------------------------

  # The chain is recovered, not kept: the seed is an HMAC of the identity
  # secret, the game id and the role, so the values committed to at the
  # start can be produced again by whoever holds the secret.
  defp chain(game_id, role, opts) do
    case Keyword.get(opts, :secret) || Identities.secret() do
      secret when is_binary(secret) ->
        {:ok, Chain.generate(Chain.seed_for(secret, game_id, role))}

      _ ->
        {:error, :no_identity}
    end
  end

  defp reveal(chain, remaining) do
    if remaining >= 2 do
      {:ok, Chain.reveal_pair(chain, remaining)}
    else
      {:error, :chain_spent}
    end
  end

  defp remaining(game, player) do
    case Map.get(game.remaining, player) do
      n when is_integer(n) -> {:ok, n}
      _ -> {:error, :no_entropy_left}
    end
  end

  # -- the dice ----------------------------------------------------------

  defp dice(%{turn_count: 0, opener: %{dice: [d1, d2]}}, _r_cur, _player)
       when d1 in 1..6 and d2 in 1..6 do
    {:ok, {d1, d2}}
  end

  defp dice(game, r_cur, player) do
    with opp when is_binary(opp) <- opponent(game, player),
         {:ok, half} <- Game.unhex32(Map.get(game.halves, opp) || ""),
         true <- byte_size(half) == 32 do
      [d1, d2] = Chain.dice(r_cur, half)
      {:ok, {d1, d2}}
    else
      _ -> {:error, :no_opponent_half}
    end
  end

  defp opponent(game, player) do
    cond do
      player == game.challenger -> game.accepter
      player == game.accepter -> game.challenger
      true -> nil
    end
  end

  defp opening_round(game) do
    div(Map.get(game, :opening_rolls) || 0, 2)
  end

  # -- checks ------------------------------------------------------------

  defp me(opts) do
    Keyword.get(opts, :author) || Identities.active_id()
  end

  defp player(game, me) when is_binary(me) do
    if me == game.challenger or me == game.accepter do
      {:ok, me}
    else
      {:error, :not_a_player}
    end
  end

  defp player(_game, _me), do: {:error, :no_identity}

  defp editable(%{status: status}) when status in [:finished, :withdrawn], do: {:error, :closed}
  defp editable(game), do: {:ok, game}

  # The accepter is not a player of the game yet, so this is its own check:
  # anyone but the challenger may take an open challenge.
  defp can_accept(game, me) when is_binary(me) do
    cond do
      game.accepter != nil -> {:error, :already_accepted}
      game.challenger == me -> {:error, :own_challenge}
      Map.get(game, :status) in [:finished, :withdrawn] -> {:error, :closed}
      true -> :ok
    end
  end

  defp can_accept(_game, _me), do: {:error, :no_identity}

  defp open_challenge(game, me) do
    cond do
      game.accepter != nil -> {:error, :already_accepted}
      game.challenger != me -> {:error, :not_the_challenger}
      true -> :ok
    end
  end

  defp turn_of(game, me, phase) do
    cond do
      Map.get(game, :status) in [:finished, :withdrawn] -> {:error, :closed}
      Map.get(game, :error, :none) != :none -> {:error, :game_broken}
      game.phase != phase -> {:error, :wrong_phase}
      game.mover != me -> {:error, :not_your_turn}
      true -> :ok
    end
  end

  defp parse(moves) when is_binary(moves) do
    {:ok, Notation.parse(moves)}
  rescue
    _ -> {:error, :unreadable_moves}
  end

  defp parse(moves) when is_list(moves) do
    if Enum.all?(moves, &valid_move?/1), do: {:ok, moves}, else: {:error, :unreadable_moves}
  end

  defp parse(_), do: {:error, :unreadable_moves}

  defp valid_move?({from, to}), do: point?(from) and point?(to)
  defp valid_move?(_), do: false

  defp point?(:bar), do: true
  defp point?(:off), do: true
  defp point?(n), do: n in 1..24

  defp legal?(%{position: %Engine{} = position}, dice, moves) do
    if Engine.legal_play?(position, dice, moves), do: :ok, else: {:error, :illegal_moves}
  end

  defp legal?(_game, _dice, _moves), do: {:error, :no_position}

  # -- publishing --------------------------------------------------------

  defp default_publisher do
    Application.get_env(:highwire, :game_publisher, &Timeline.publish_content/1)
  end

  defp file(key, content, opts) do
    case Keyword.get(opts, :author) || Identities.active_id() do
      nil ->
        :ok

      id ->
        Store.ingest(%{"key" => key, "value" => %{"author" => id, "content" => content}})
    end
  end

  defp role(game, me) do
    if me == game.challenger, do: "challenger", else: "accepter"
  end
end
