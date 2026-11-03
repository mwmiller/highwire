defmodule HighWireWeb.GameLive do
  @moduledoc """
  One game, observed: the board as the fold sees it, the turn history with the
  roll and moves that produced it, and the reveal budget each player has left.

  The page never trusts the store's word for what happened — the snapshot it
  renders is the fold's, so a game that does not verify says so where the
  history would be, with the fold's own reason.
  """

  use HighWireWeb, :live_view

  alias HighWire.Backgammon.Store
  alias HighWire.Chess
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Board, ChessBoard, Nav}

  @impl true
  def mount(%{"game_id" => game_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HighWire.PubSub, Store.topic())
      Phoenix.PubSub.subscribe(HighWire.PubSub, Chess.Store.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Game")
     |> assign(:game_id, game_id)
     |> assign(:self_id, self_id())
     |> assign(:game, load(game_id))}
  end

  @impl true
  def handle_info({:backgammon, game_id}, %{assigns: %{game_id: game_id}} = socket) do
    {:noreply, assign(socket, :game, load(game_id))}
  end

  def handle_info({:chess, game_id}, %{assigns: %{game_id: game_id}} = socket) do
    {:noreply, assign(socket, :game, load(game_id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The id shape is the same for both games, so the kind is what the store
  # finds rather than what the URL claims.
  defp load(game_id) do
    case Chess.Store.get(game_id) do
      nil -> Store.get(game_id)
      chess -> chess
    end
  end

  defp self_id do
    case Identities.active() do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp name(nil), do: "unknown"
  defp name(id), do: Profile.display_name(id)

  @impl true
  def render(%{game: nil} = assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">Games</div>
        <Nav.rail_link navigate={~p"/games"}>Gameroom</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-10">
          <p class="text-sm text-dim">
            No game with that id has reached this node.
          </p>
          <.link navigate={~p"/games"} class="mt-4 inline-block text-xs text-accent hover:underline">
            Back to the gameroom
          </.link>
        </div>
      </main>
    </div>
    """
  end

  def render(%{game: %{kind: :chess}} = assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">Games</div>
        <Nav.rail_link navigate={~p"/games"}>Gameroom</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-6">
          <header class="mb-4">
            <div class="grid grid-cols-2 gap-2">
              <.side id={@game.white} color={:white} turn={@game.turn} />
              <.side id={@game.black} color={:black} turn={@game.turn} />
            </div>
            <p class="mt-2 text-xs text-dim">{chess_line(@game, @self_id)}</p>
          </header>

          <p
            :if={@game.status == :broken}
            class="mb-3 rounded border border-edge bg-raised px-3 py-2 text-xs text-bad"
          >
            This game does not verify: {@game.error}
          </p>

          <ChessBoard.board board={@game.board} />

          <dl class="mt-3 grid grid-cols-3 gap-2 text-[11px] text-faint">
            <div>
              <dt class="uppercase tracking-wide">ply</dt>
              <dd class="text-muted">{@game.turn_count}</dd>
            </div>
            <div>
              <dt class="uppercase tracking-wide">to move</dt>
              <dd class="text-muted">{side_word(@game)}</dd>
            </div>
            <div>
              <dt class="uppercase tracking-wide">result</dt>
              <dd class="text-muted">{result_word(@game)}</dd>
            </div>
          </dl>

          <h3 class="mt-6 mb-2 text-[11px] uppercase tracking-wider text-faint">Moves</h3>

          <p :if={@game.history == []} class="text-xs italic text-faint">
            No moves played yet.
          </p>

          <ol class="grid grid-cols-2 gap-x-4">
            <li
              :for={item <- @game.history}
              class="flex items-baseline gap-2 border-b border-edge-soft py-0.5 text-xs"
            >
              <span class="w-8 shrink-0 text-right text-faint">{item.ply}.</span>
              <span class="font-mono text-[11px] text-dim">{item.san || item.uci}</span>
              <span
                :if={item.note not in [nil, ""]}
                class="min-w-0 truncate italic text-[10px] text-faint"
              >
                {item.note}
              </span>
            </li>
          </ol>
        </div>
      </main>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">Games</div>
        <Nav.rail_link navigate={~p"/games"}>Gameroom</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-6">
          <header class="mb-4">
            <div class="flex items-center gap-2">
              <Avatar.avatar :if={@game.challenger} id={@game.challenger} size={20} />
              <span class="text-sm text-paper">{name(@game.challenger)}</span>
              <span class="text-[10px] uppercase tracking-wide text-faint">vs</span>
              <Avatar.avatar :if={@game.accepter} id={@game.accepter} size={20} />
              <span class="text-sm text-paper">{name(@game.accepter)}</span>
            </div>
            <p class="mt-1 text-xs text-dim">{turn_line(@game, @self_id)}</p>
          </header>

          <p
            :if={@game.status == :broken}
            class="mb-3 rounded border border-edge bg-raised px-3 py-2 text-xs text-bad"
          >
            This game does not verify: {@game.error}
          </p>

          <Board.board position={@game.position} />

          <dl class="mt-3 grid grid-cols-3 gap-2 text-[11px] text-faint">
            <div>
              <dt class="uppercase tracking-wide">turn</dt>
              <dd class="text-muted">{@game.turn_count}</dd>
            </div>
            <div>
              <dt class="uppercase tracking-wide">reveals left</dt>
              <dd class="text-muted">
                {reveals(@game, @game.challenger)} / {reveals(@game, @game.accepter)}
              </dd>
            </div>
            <div>
              <dt class="uppercase tracking-wide">opened by</dt>
              <dd class="text-muted">{opener(@game)}</dd>
            </div>
          </dl>

          <h3 class="mt-6 mb-2 text-[11px] uppercase tracking-wider text-faint">History</h3>

          <p :if={@game.history == []} class="text-xs italic text-faint">
            No turns played yet.
          </p>

          <ol class="space-y-1">
            <li
              :for={item <- @game.history}
              class="grid grid-cols-[auto_1fr_auto] items-baseline gap-2 border-b border-edge-soft pb-1 text-xs"
            >
              <span class="text-faint">{item.turn}</span>
              <span class="min-w-0">
                <span class="text-muted">{name(item.player)}</span>
                <span :if={item.type == "resign"} class="ml-1 text-faint">resigned</span>
                <span :if={item.type != "resign"} class="ml-1 font-mono text-[11px] text-dim">
                  {item.roll} {item.moves}
                </span>
              </span>
              <span :if={item.note not in [nil, ""]} class="truncate italic text-faint">{item.note}</span>
            </li>
          </ol>
        </div>
      </main>
    </div>
    """
  end

  attr :id, :string, default: nil
  attr :color, :atom, required: true
  attr :turn, :atom, required: true

  defp side(assigns) do
    ~H"""
    <div class={[
      "flex items-center gap-2 rounded border px-2 py-1.5",
      @turn == @color && "border-focus bg-raised",
      @turn != @color && "border-edge bg-panel"
    ]}>
      <Avatar.avatar :if={@id} id={@id} size={20} />
      <div class="min-w-0">
        <div class="text-[10px] uppercase tracking-wide text-faint">{@color}</div>
        <div class="truncate text-sm text-paper">{name(@id)}</div>
      </div>
    </div>
    """
  end

  defp chess_line(%{status: :finished} = game, _self), do: result_sentence(game)
  defp chess_line(%{status: :withdrawn}, _self), do: "Withdrawn by the challenger"
  defp chess_line(%{status: :opening}, _self), do: "Waiting for an opponent to accept"
  defp chess_line(%{status: :broken}, _self), do: "The fold stopped on a move it cannot verify"

  defp chess_line(%{mover: mover} = game, self) when mover == self,
    do: "Your move" <> check_note(game)

  defp chess_line(%{mover: mover} = game, _self) when is_binary(mover),
    do: name(mover) <> " to move" <> check_note(game)

  defp chess_line(_game, _self), do: "Waiting for an opponent"

  defp check_note(%{check?: true}), do: " — check"
  defp check_note(_game), do: ""

  defp result_sentence(%{winner: %{player: player, reason: :resign}}),
    do: name(player) <> " won by resignation"

  defp result_sentence(%{winner: %{player: player}}), do: name(player) <> " won by checkmate"
  defp result_sentence(%{verdict: :stalemate}), do: "Stalemate"
  defp result_sentence(%{verdict: {:draw, :fifty_moves}}), do: "Draw by the fifty-move rule"

  defp result_sentence(%{verdict: {:draw, :insufficient_material}}),
    do: "Draw by insufficient material"

  defp result_sentence(%{verdict: {:draw, :repetition}}), do: "Draw by repetition"
  defp result_sentence(_game), do: "Finished"

  defp side_word(%{status: :finished}), do: "—"
  defp side_word(%{turn: :white}), do: "white"
  defp side_word(%{turn: :black}), do: "black"

  defp result_word(%{status: :finished} = game), do: short_result(game)
  defp result_word(%{check?: true}), do: "check"
  defp result_word(_game), do: "in play"

  defp short_result(%{winner: %{reason: reason}}) when reason != nil, do: to_string(reason)
  defp short_result(%{verdict: :stalemate}), do: "stalemate"
  defp short_result(%{verdict: {:draw, reason}}), do: to_string(reason)
  defp short_result(_game), do: "finished"

  defp turn_line(%{status: :finished, winner: %{player: player}}, _self) when is_binary(player),
    do: name(player) <> " won"

  defp turn_line(%{status: :withdrawn}, _self), do: "Withdrawn by the challenger"
  defp turn_line(%{status: :broken}, _self), do: "The fold stopped on an entry it cannot verify"

  defp turn_line(%{mover: mover, self_id: _}, self) when mover == self,
    do: "Your move"

  defp turn_line(%{mover: mover}, _self) when is_binary(mover), do: name(mover) <> " to move"
  defp turn_line(_game, _self), do: "Waiting for an opponent"

  defp reveals(game, player) do
    case game.remaining do
      %{^player => n} -> n
      _ -> "—"
    end
  end

  defp opener(%{opener: %{starter: starter, dice: dice}}) when is_list(dice),
    do: "#{name(starter)} (#{Enum.join(dice, "-")})"

  defp opener(_), do: "—"
end
