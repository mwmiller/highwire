defmodule HighWire.Backgammon.Fold do
  @moduledoc """
  Fold a backgammon game's play log into a replayable position + history,
  including the opening-roll sequence that decides who moves first.

  The store collects every `"roll"` and `"turn"` both players published for
  a game, then folds them in order, verifying along the way:

  * opening rounds alternate challenger then accepter; each side's single
    die mixes their freshly-published reveal with the opponent's
    most-recently-published half (`Chain.dice(r_cur, halves[opp], 1)`) — the
    accepter's accept-reveal for the challenger's first roll — so each die is
    knowable the moment the player publishes, and the higher single die
    starts the game. Ties re-roll with the next round — an indeterminate
    number of rounds, which is why the reveal counter is carried on entries
    rather than derived from the turn number (they are independent).
  * every `roll`/`turn` entry carries `reveals`, the author's reveal count
    **remaining** before the entry (counting down from the chain length; the
    accepter starts one lower, their accept reveal consuming `chain[-1]`).
    The fold checks the counter steps down by two per entry; `0` means the
    chain is spent. The turn counter counts **up from 1** and is unrelated.
  * the mover is determined by the game phase: during `:opening` it is the
    `next_roll_author`; during `:playing` it is `other(last_actor)`; during
    `:finished` it is the winner.
  * the entry's roll recomputes from `Chain.dice(mover_half, opponent_half)`
    with the two freshly published halves,
  * the moves are a legal, maximal play on the position before the turn,
  * each player's reveals walk their committed chain backward
    (`Chain.verify_first/2` then `Chain.verify_next/3`).

  The fold yields the live position (in the *next* mover's frame, mirrored
  after the last turn), the resolved `turn_count`, whose turn is next, the
  `phase` (`:opening`, `:playing`, or `:finished`), each player's remaining
  reveal count, and a `history` of per-turn snapshots for replay:

      %{turn, player, roll, moves, frames}   # mover-frame positions

  `frames` steps the turn one move at a time (from before to after) so the
  UI can animate a turn. A malformed entry stops the fold early; `error`
  carries the reason (`:none` when the fold succeeds).
  """

  alias HighWire.Backgammon.{Chain, Engine, Game, Notation}

  @type entry :: %{optional(String.t()) => term()}

  @type history_item :: %{
          turn: pos_integer(),
          player: String.t(),
          type: String.t() | nil,
          roll: String.t() | nil,
          moves: String.t() | nil,
          frames: [Engine.t()],
          after: Engine.t(),
          note: String.t() | nil
        }

  @type phase :: :opening | :playing | :finished

  @type stake_type :: :single | :gammon | :backgammon

  @type fold_result :: %{
          position: Engine.t(),
          turn_count: non_neg_integer(),
          mover: String.t() | nil,
          winner: %{player: String.t(), stake: pos_integer(), type: stake_type()} | nil,
          phase: phase(),
          opener: %{starter: String.t(), dice: [integer()], rounds: non_neg_integer()} | nil,
          opening_rolls: non_neg_integer(),
          opp_for_next: String.t() | nil,
          halves: %{String.t() => String.t() | nil},
          remaining: %{String.t() => non_neg_integer()},
          last_note: String.t() | nil,
          history: [history_item()],
          error: String.t() | :none
        }

  @doc """
  Fold one game. `game` carries `challenger`, `accepter`, `game_id` (hex),
  `challenge_commit`, `accept_commit`.

  `opts`:

    * `:entries` — `%{player => [entry]}` of already-normalised entries (see
      `HighWire.Backgammon.Reader`); the default is empty, which folds to the
      opening position.
    * `:accept_reveal` — the accepter's reveal, hex, from their accept message.
    * `:spec` — the chain spec; defaults to `Chain.spec/0`.
  """
  @spec fold_game(map(), map()) :: fold_result()
  def fold_game(game, opts \\ %{}) do
    spec = Map.get(opts, :spec) || Map.get(game, :challenge_spec) || Chain.spec()

    case Base.decode16(game.game_id, case: :lower) do
      {:ok, gid} when byte_size(gid) == 32 ->
        entries = Map.get(opts, :entries) || %{}

        entries =
          Enum.flat_map([game.challenger, game.accepter], &Map.get(entries, &1, []))

        do_fold(game, spec, Map.get(opts, :accept_reveal), entries)

      _ ->
        %{
          position: Engine.initial(),
          turn_count: 0,
          mover: Map.get(game, :challenger),
          winner: nil,
          phase: :opening,
          opener: nil,
          opening_rolls: 0,
          opp_for_next: nil,
          halves: %{},
          remaining: %{},
          last_note: "",
          history: [],
          error: "unreadable game id"
        }
    end
  end

  @doc false
  def resign(%{type: "resign"} = msg) do
    %{
      status: :finished,
      winner: %{player: msg["player"], reason: :resign},
      phase: :finished
    }
  end

  def resign(_msg), do: nil

  @doc false
  def fold(game, store) do
    if Map.has_key?(game, :status) do
      game
    else
      %{
        game
        | status: store.status,
          error: store.error,
          phase: store.phase,
          turn_count: store.turn_count,
          mover: store.mover,
          accepter: store.accepter,
          challenger: store.challenger,
          position: store.position,
          remaining: store.remaining,
          halves: store.halves,
          opening_rolls: store.opening_rolls,
          challenge_key: store.challenge_key,
          opener: store.opener
      }
    end
  end

  defp do_fold(game, spec, accept_reveal, entries) do
    len = spec["length"]
    %{rolls: rolls, turns: turns, resigns: resigns} = decode_entries(entries, game)

    folded =
      initial_state(game, len, accept_reveal)
      |> reduce_rolls(rolls)
      |> reduce_turns(turns)
      |> maybe_fold_resign(resigns)

    build_result(folded)
  end

  defp reduce_rolls(state, rolls), do: Enum.reduce_while(rolls, state, &fold_roll/2)

  defp reduce_turns(%{error: :none} = state, turns),
    do: Enum.reduce_while(turns, state, &fold_turn/2)

  defp reduce_turns(state, _turns), do: state

  defp decode_entries(entries, game) do
    decoded = Enum.map(entries, &decode/1)

    %{
      rolls: decoded |> Enum.filter(&(&1["type"] == "roll")) |> sort_rolls(game),
      turns: decoded |> Enum.filter(&(&1["type"] == "turn")) |> sort_turns(),
      resigns: Enum.filter(decoded, &(&1["type"] == "resign"))
    }
  end

  defp sort_rolls(rolls, game) do
    Enum.sort_by(rolls, fn e ->
      {e["round"] || -1, if(e["player"] == game.challenger, do: 0, else: 1)}
    end)
  end

  defp sort_turns(turns), do: Enum.sort_by(turns, & &1["turn"], :asc)

  defp initial_state(game, len, accept_reveal) do
    %{
      game: game,
      len: len,
      remaining: %{game.challenger => len, game.accepter => len - 1},
      halves: %{game.accepter => unhex(accept_reveal), game.challenger => nil},
      prior: prior_from_accept(game, accept_reveal),
      rolls_done: 0,
      phase: :opening,
      starter: nil,
      last_actor: nil,
      winner: nil,
      stake: nil,
      opp_for_next: nil,
      next_roll_author: game.challenger,
      opening_dice: nil,
      last_note: "",
      pos: Engine.initial(),
      turn_count: 0,
      history: [],
      error: :none
    }
  end

  defp build_result(final) do
    %{
      position: final.pos,
      turn_count: final.turn_count,
      mover: result_mover(final),
      winner: result_winner(final),
      phase: final.phase,
      opener: result_opener(final),
      # How many opening rolls have landed, which is the only thing that says
      # which round the next one belongs to: a tie leaves `opener` nil, and
      # the round it expects is `div(rolls, 2)`. A writer that guessed from
      # `opener` would keep naming round 0 and the fold would reject it.
      opening_rolls: final.rolls_done,
      opp_for_next: final.opp_for_next,
      halves: result_halves(final),
      remaining: final.remaining,
      last_note: final.last_note,
      history: final.history,
      error: final.error
    }
  end

  defp result_mover(%{phase: :opening} = st) do
    if rem(st.rolls_done, 2) == 0, do: st.game.challenger, else: st.game.accepter
  end

  defp result_mover(%{phase: :playing} = st), do: mover_for(st)
  defp result_mover(%{phase: :finished} = st), do: st.winner

  # Each player's most recently published half, hex, for the writer that has
  # to know the opponent's before it can publish its own: the next turn's
  # dice are those two halves. It is also how a page shows the dice that are
  # already determined for the player who is to move.
  defp result_halves(%{halves: halves}) do
    Map.new(halves, fn {player, value} -> {player, value && Game.hex(value)} end)
  end

  defp result_winner(%{winner: nil}), do: nil

  defp result_winner(%{winner: player, stake: stake}) when is_binary(player) do
    %{player: player, stake: stake, type: stake_type(stake)}
  end

  defp result_opener(%{starter: nil}), do: nil

  defp result_opener(%{starter: s, opening_dice: d, rolls_done: r}) do
    %{starter: s, dice: d, rounds: div(r, 2)}
  end

  # One opening-roll entry. Entries alternate challenger (even count) then
  # accepter (odd count) per round. Each side's single die mixes their
  # just-published reveal with the opponent's most-recently-published half —
  # the accepter's accept-reveal for the challenger's first roll — so both
  # dice land on the table the moment each player publishes, and no die is
  # ever sealed. The winner of the round is decided when both halves land.
  defp fold_roll(entry, st) do
    author = Map.get(entry, "player")
    expected = if rem(st.rolls_done, 2) == 0, do: st.game.challenger, else: st.game.accepter

    case validate_roll(entry, st, author, expected) do
      {:error, reason} ->
        {:halt, %{st | error: reason}}

      :ok ->
        with {:ok, r_cur} <- unhex32(Map.get(entry, "r_cur")),
             {:ok, r_next} <- unhex32(Map.get(entry, "r_next")),
             :ok <- fold_reveal(st, author, r_cur, r_next) do
          st = apply_roll(st, author, r_next, entry)
          resolve_roll_author(st, author, r_cur)
        else
          {:error, :bad_hex} -> {:halt, %{st | error: "bad reveal hex on roll #{st.rolls_done}"}}
          {:error, _} -> {:halt, %{st | error: "chain violation on roll #{st.rolls_done}"}}
        end
    end
  end

  defp validate_roll(entry, st, author, expected) do
    reveals_mismatch = Map.get(entry, "reveals") not in [nil, st.remaining[author]]

    cond do
      author != expected ->
        {:error, "opening roll #{st.rolls_done} authored by #{author}, expected #{expected}"}

      Map.get(entry, "round", -1) != div(st.rolls_done, 2) ->
        {:error, "opening round mismatch at entry #{st.rolls_done}"}

      st.remaining[author] < 2 ->
        {:error, "entropy exhausted: #{author} has #{st.remaining[author]} reveal(s) left"}

      reveals_mismatch ->
        {:error,
         "reveal counter on roll #{st.rolls_done} says #{entry["reveals"]}, expected #{st.remaining[author]}"}

      true ->
        :ok
    end
  end

  defp apply_roll(st, author, r_next, entry) do
    %{
      st
      | remaining: Map.put(st.remaining, author, st.remaining[author] - 2),
        halves: Map.put(st.halves, author, r_next),
        prior: Map.put(st.prior, author, r_next),
        rolls_done: st.rolls_done + 1,
        next_roll_author:
          if(rem(st.rolls_done, 2) == 0, do: st.game.accepter, else: st.game.challenger),
        last_note: Map.get(entry, "note", "")
    }
  end

  defp resolve_roll_author(st, author, r_cur) when author == st.game.accepter do
    case held_challenger_die(st) do
      nil ->
        {:halt,
         %{
           st
           | error:
               "opening roll #{st.rolls_done} by #{author} arrives before the challenger's die"
         }}

      d_c ->
        {:cont, resolve_round(st, d_c, opening_die(r_cur, st.halves[st.game.challenger]))}
    end
  end

  defp resolve_roll_author(st, _author, r_cur) do
    {:cont, %{st | opening_dice: [opening_die(r_cur, st.halves[st.game.accepter]), nil]}}
  end

  # The challenger's die for the current (incomplete) opening round, once they
  # have published; `nil` when no challenger roll is on the board.
  defp held_challenger_die(%{opening_dice: [d, _]}), do: d
  defp held_challenger_die(_), do: nil

  # A player's single opening die: one die mixed from their freshly-published
  # reveal and the opponent's most-recently-published half.
  defp opening_die(half, opp) when is_binary(half) and is_binary(opp),
    do: Chain.dice(half, opp, 1) |> hd()

  defp opening_die(_, _), do: nil

  # A completed opening round flips the challenger-vs-accepter single dice.
  # A tie keeps rolling; the first non-tie names the starter, who plays the
  # odd-numbered turns thereafter.
  defp resolve_round(st, d_c, d_a) when is_integer(d_c) and is_integer(d_a) do
    cond do
      d_c > d_a ->
        %{
          st
          | starter: st.game.challenger,
            last_actor: st.game.accepter,
            phase: :playing,
            opp_for_next: st.halves[st.game.accepter],
            opening_dice: [d_c, d_a]
        }

      d_a > d_c ->
        %{
          st
          | starter: st.game.accepter,
            last_actor: st.game.challenger,
            phase: :playing,
            opp_for_next: st.halves[st.game.challenger],
            opening_dice: [d_c, d_a]
        }

      true ->
        %{st | opening_dice: nil}
    end
  end

  # The starter is decided only by opening rolls; a game that has not
  # resolved one stays in the opening (no starter, no turns). Every game now
  # opens with rolls, so there is no legacy "challenger just starts" default —
  # a turn arriving without a decided starter is an error, never a silent
  # brand-new starter with reveals untouched.

  defp check_roll(d1, d2, e1, e2) do
    if (d1 == e1 and d2 == e2) or (d1 == e2 and d2 == e1), do: :roll_match, else: :roll_mismatch
  end

  defp check_play_legal(pos, dice, moves) do
    if Engine.legal_play?(pos, dice, moves), do: :play_legal, else: :play_illegal
  end

  defp fold_turn(entry, st) do
    author = Map.get(entry, "player")
    turn = Map.get(entry, "turn", -1)
    mover = mover_for(st)

    case validate_turn(entry, st, author, turn, mover) do
      {:error, reason} ->
        {:halt, %{st | error: reason}}

      :ok ->
        with {:ok, r_cur} <- unhex32(Map.get(entry, "r_cur")),
             {:ok, r_next} <- unhex32(Map.get(entry, "r_next")),
             opp when is_binary(opp) and byte_size(opp) == 32 <- st.opp_for_next,
             [d1, d2] <- turn_dice(st, r_cur, opp),
             {e1, e2} <- Game.parse_roll(Map.get(entry, "roll")),
             :roll_match <- check_roll(d1, d2, e1, e2),
             {:ok, moves} <- parse_moves(entry),
             :play_legal <- check_play_legal(st.pos, {d1, d2}, moves),
             :ok <- fold_reveal(st, author, r_cur, r_next),
             frames <- apply_frames(st.pos, moves),
             next_pos <- Engine.mirror(List.last(frames)) do
          maybe_halt_winner(apply_turn(st, author, r_next, turn, entry, frames, next_pos))
        else
          :roll_mismatch -> {:halt, %{st | error: "roll mismatch on turn #{turn}"}}
          :error -> {:halt, %{st | error: "bad roll on turn #{turn}"}}
          :play_illegal -> {:halt, %{st | error: "illegal or non-maximal play on turn #{turn}"}}
          {:error, :bad_moves} -> {:halt, %{st | error: "bad moves on turn #{turn}"}}
          {:error, :bad_hex} -> {:halt, %{st | error: "bad reveal hex on turn #{turn}"}}
          {:error, _} -> {:halt, %{st | error: "chain violation on turn #{turn}"}}
        end
    end
  end

  defp maybe_halt_winner(%{winner: nil} = st), do: {:cont, st}
  defp maybe_halt_winner(st), do: {:halt, %{st | phase: :finished}}

  # The first turn after the opening must use the opener dice directly.
  # Every subsequent turn derives dice from the player's fresh reveal.
  defp turn_dice(%{turn_count: 0, opening_dice: [d1, d2], starter: s}, _r_cur, _opp)
       when is_binary(s) and d1 in 1..6 and d2 in 1..6,
       do: [d1, d2]

  defp turn_dice(_st, r_cur, opp), do: Chain.dice(r_cur, opp)

  defp validate_turn(entry, st, author, turn, mover) do
    reveals_mismatch? =
      case Map.get(entry, "reveals") do
        nil -> false
        expected -> expected != st.remaining[author]
      end

    cond do
      st.phase == :opening ->
        {:error, "turn #{turn} before the opening resolved"}

      author != mover ->
        {:error, "turn #{turn} authored by #{author}, expected #{mover}"}

      turn != st.turn_count + 1 ->
        {:error, "turn sequence gap: #{turn} after #{st.turn_count}"}

      st.remaining[author] < 2 ->
        {:error, "entropy exhausted: #{author} has #{st.remaining[author]} reveal(s) left"}

      reveals_mismatch? ->
        {:error,
         "reveal counter on turn #{turn} says #{entry["reveals"]}, expected #{st.remaining[author]}"}

      true ->
        :ok
    end
  end

  defp apply_turn(st, author, r_next, turn, entry, frames, next_pos) do
    after_pos = List.last(frames)

    {winner, stake} =
      if st.winner == nil and Engine.checkers(after_pos) == 0,
        do: {author, Engine.stake(after_pos)},
        else: {st.winner, nil}

    %{
      st
      | pos: next_pos,
        opp_for_next: r_next,
        remaining: Map.put(st.remaining, author, st.remaining[author] - 2),
        prior: Map.put(st.prior, author, r_next),
        turn_count: st.turn_count + 1,
        last_actor: author,
        winner: winner,
        stake: stake || st.stake,
        last_note: Map.get(entry, "note", ""),
        history:
          st.history ++
            [
              %{
                turn: turn,
                player: author,
                type: "turn",
                roll: Map.get(entry, "roll"),
                moves: Map.get(entry, "moves"),
                frames: frames,
                after: List.last(frames),
                note: Map.get(entry, "note", "")
              }
            ]
    }
  end

  # A resign entry terminates the game. Only the first resign is processed;
  # the author must be the current mover and the turn must match.
  defp maybe_fold_resign(%{error: :none, winner: nil} = st, resigns), do: fold_resign(resigns, st)
  defp maybe_fold_resign(st, _resigns), do: st

  defp fold_resign([], st), do: st

  defp fold_resign([entry | _], st) do
    author = Map.get(entry, "player")
    turn = Map.get(entry, "turn")
    mover = mover_for(st)

    cond do
      st.phase == :opening ->
        %{st | error: "resign before the opening resolved"}

      author != mover ->
        %{st | error: "resign by #{author}, expected mover #{mover}"}

      turn != st.turn_count + 1 ->
        %{st | error: "resign turn #{turn}, expected #{st.turn_count + 1}"}

      true ->
        turn = st.turn_count + 1

        %{
          st
          | winner: other(st, mover),
            phase: :finished,
            stake: 1,
            last_note: Map.get(entry, "note", ""),
            turn_count: turn,
            history:
              st.history ++
                [
                  %{
                    turn: turn,
                    player: mover,
                    type: "resign",
                    roll: nil,
                    moves: nil,
                    frames: [],
                    after: st.pos,
                    note: Map.get(entry, "note", "")
                  }
                ]
        }
    end
  end

  defp mover_for(%{phase: :playing, last_actor: last} = st) when is_binary(last) do
    other(st, last)
  end

  defp mover_for(st), do: other(st, st.starter)

  defp stake_type(1), do: :single
  defp stake_type(2), do: :gammon
  defp stake_type(3), do: :backgammon

  defp other(%{game: game}, player) do
    if player == game.challenger, do: game.accepter, else: game.challenger
  end

  # A player's reveals walk their committed chain backward: the first value
  # published checks against the commitment (`verify_first`), and every later
  # value extends the one before it (`verify_next`). The accepter's
  # reveal-at-accept is their first value, so their later reveals extend that.
  defp fold_reveal(st, player, r_cur, r_next) do
    with :ok <- extend_or_first(st, player, r_cur) do
      Chain.verify_next(r_next, r_cur)
    end
  end

  defp extend_or_first(st, player, r_cur) do
    case Map.get(st.prior, player) do
      nil ->
        commit =
          if player == st.game.challenger,
            do: st.game.challenge_commit,
            else: st.game.accept_commit

        case unhex32(commit) do
          {:ok, c} -> Chain.verify_first(r_cur, c)
          _ -> {:error, "no commitment"}
        end

      prev ->
        Chain.verify_next(r_cur, prev)
    end
  end

  defp prior_from_accept(game, accept_reveal) do
    case unhex32(accept_reveal) do
      {:ok, reveal} -> %{game.accepter => reveal}
      _ -> %{}
    end
  end

  defp apply_frames(pos, moves) do
    Enum.scan(moves, pos, fn mv, cur -> Engine.apply_move(cur, mv) end)
    |> then(&[pos | &1])
  end

  defp parse_moves(entry) do
    {:ok, Notation.parse(Map.get(entry, "moves", ""))}
  rescue
    e in [ArgumentError, MatchError] ->
      _ = e
      {:error, :bad_moves}
  end

  # The reader hands the fold normalised maps already, so decoding is the
  # identity — one place to change when an entry arrives in another shape.
  defp decode(entry) when is_map(entry), do: entry
  defp decode(_), do: %{}

  defp unhex(nil), do: nil
  defp unhex(hex) when is_binary(hex), do: Base.decode16!(hex, case: :lower)

  defp unhex32(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bin} when byte_size(bin) == 32 -> {:ok, bin}
      _ -> {:error, :bad_hex}
    end
  end

  defp unhex32(_), do: {:error, :bad_hex}
end
