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
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Board, Nav}

  @impl true
  def mount(%{"game_id" => game_id}, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(HighWire.PubSub, Store.topic())

    {:ok,
     socket
     |> assign(:page_title, "Game")
     |> assign(:game_id, game_id)
     |> assign(:self_id, self_id())
     |> assign(:game, Store.get(game_id))}
  end

  @impl true
  def handle_info({:backgammon, game_id}, %{assigns: %{game_id: game_id}} = socket) do
    {:noreply, assign(socket, :game, Store.get(game_id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

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
