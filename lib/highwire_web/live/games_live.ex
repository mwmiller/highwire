defmodule HighWireWeb.GamesLive do
  @moduledoc """
  The gameroom: every backgammon game this node knows about, in flight or
  finished, read from the local store rather than from feeds.

  Nothing here plays a game — it observes. The board is drawn from the fold's
  snapshot, and the store pushes a change whenever a move lands, so an
  opponent's turn appears in a second instead of on a feed reload.

  Games that are waiting on you sort first: that is the only thing this page
  has to tell a reader at a glance.
  """

  use HighWireWeb, :live_view

  alias HighWire.Backgammon.Store
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Board, Nav}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(HighWire.PubSub, Store.topic())

    self_id = self_id()

    {:ok,
     socket
     |> assign(:page_title, "Games")
     |> assign(:self_id, self_id)
     |> assign(:games, games(self_id))}
  end

  @impl true
  def handle_info({:backgammon, _game_id}, socket) do
    {:noreply, assign(socket, :games, games(socket.assigns.self_id))}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp games(self_id) do
    Store.games()
    |> Enum.map(&put_live_status(&1, self_id))
    |> Enum.sort_by(fn game -> {rank(game), -game.updated_at} end)
  end

  defp put_live_status(game, self_id) do
    Map.put(game, :yours?, game.mover == self_id and game.status in [:playing, :opening])
  end

  defp rank(%{yours?: true}), do: 0
  defp rank(%{status: :playing}), do: 1
  defp rank(%{status: :opening}), do: 2
  defp rank(%{status: :finished}), do: 3
  defp rank(_), do: 4

  defp self_id do
    case Identities.active() do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp name(nil), do: "unknown"
  defp name(id), do: Profile.display_name(id)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <h1 class="sr-only">Games</h1>
        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">Games</div>
        <p class="px-4 pb-4 text-xs leading-relaxed text-dim">
          Backgammon games this node has seen. A game appears once its challenge reaches you.
        </p>
        <Nav.rail_link navigate={~p"/"}>Timeline</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-4xl px-6 py-6">
          <header class="mb-5 flex items-baseline justify-between">
            <h2 class="text-lg font-semibold text-paper">Gameroom</h2>
            <span class="text-xs text-faint">{length(@games)} game(s)</span>
          </header>

          <p :if={@games == []} class="rounded border border-edge bg-panel px-4 py-6 text-sm text-dim">
            No games yet. When someone challenges you — or you open a game — it shows up here,
            with the board as it stands.
          </p>

          <div class="grid gap-3">
            <.game_card :for={game <- @games} game={game} self_id={@self_id} />
          </div>
        </div>
      </main>
    </div>
    """
  end

  attr :game, :map, required: true
  attr :self_id, :string, default: nil

  defp game_card(assigns) do
    ~H"""
    <.link
      navigate={~p"/games/#{@game.game_id}"}
      class="block rounded border border-edge bg-panel p-3 transition hover:border-focus"
    >
      <div class="mb-2 flex items-center justify-between gap-3">
        <div class="flex min-w-0 items-center gap-2">
          <Avatar.avatar :if={@game.challenger} id={@game.challenger} size={18} />
          <span class="truncate text-xs text-muted">{name(@game.challenger)}</span>
          <span class="text-[10px] uppercase tracking-wide text-faint">vs</span>
          <Avatar.avatar :if={@game.accepter} id={@game.accepter} size={18} />
          <span class="truncate text-xs text-muted">{name(@game.accepter)}</span>
        </div>

        <span class={["shrink-0 rounded px-2 py-0.5 text-[10px] uppercase tracking-wide", chip(@game)]}>
          {label(@game)}
        </span>
      </div>

      <Board.board position={@game.position} compact />

      <div class="mt-2 flex items-center justify-between text-[10px] text-faint">
        <span>turn {@game.turn_count}</span>
        <span :if={@game.last_note not in [nil, ""]} class="truncate italic">{@game.last_note}</span>
        <span>{phase_label(@game)}</span>
      </div>
    </.link>
    """
  end

  defp chip(%{status: :finished}), do: "bg-raised text-dim"
  defp chip(%{status: :broken}), do: "bg-raised text-bad"
  defp chip(%{yours?: true}), do: "bg-accent text-paper"
  defp chip(_), do: "bg-raised text-muted"

  defp label(%{status: :finished, winner: %{player: player}}) do
    case player do
      nil -> "finished"
      id -> name(id) <> " won"
    end
  end

  defp label(%{status: :withdrawn}), do: "withdrawn"
  defp label(%{status: :broken}), do: "unverified"
  defp label(%{yours?: true, phase: :opening}), do: "your roll"
  defp label(%{yours?: true}), do: "your move"
  defp label(%{phase: :opening}), do: "opening"
  defp label(%{mover: mover}), do: "#{name(mover)} to move"

  defp phase_label(%{phase: :finished}), do: "finished"
  defp phase_label(%{phase: :opening}), do: "opening roll"
  defp phase_label(_), do: "playing"
end
