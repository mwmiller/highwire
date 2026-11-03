defmodule HighWireWeb.GamesLive do
  @moduledoc """
  The gameroom: every game this node knows about — backgammon and chess, in
  flight or finished — read from the local stores rather than from feeds.

  Nothing here plays a game — it observes. Each board is drawn from its
  fold's snapshot, and the stores push a change whenever a move lands, so an
  opponent's turn appears in a second instead of on a feed reload.

  Games that are waiting on you sort first: that is the only thing this page
  has to tell a reader at a glance.
  """

  use HighWireWeb, :live_view

  alias HighWire.Backgammon.Store
  alias HighWire.Chess
  alias HighWire.Games.Catalog
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Board, ChessBoard, Nav, Time}

  # The stores are append-only, so the room shows a page of what changed
  # recently and pages back through the catalog's window. Nothing here
  # folds a game it is not showing.
  @page_size 40

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HighWire.PubSub, Store.topic())
      Phoenix.PubSub.subscribe(HighWire.PubSub, Chess.Store.topic())
      Phoenix.PubSub.subscribe(HighWire.PubSub, Chess.Legacy.Store.topic())
    end

    self_id = self_id()

    {:ok,
     socket
     |> assign(:page_title, "Games")
     |> assign(:self_id, self_id)
     |> assign(:error, nil)
     |> assign(:page, 0)
     |> assign(:total, Catalog.count())
     |> assign(:games, page(self_id, 0))}
  end

  def handle_event("more", _params, socket) do
    page = socket.assigns.page + 1
    more = page_games(socket.assigns.self_id, page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:games, socket.assigns.games ++ more)
     |> assign(:total, Catalog.count())}
  end

  @impl true
  def handle_event("open", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/games/#{id}")}
  end

  # Opening a game publishes the challenge from this identity, so the key
  # that comes back is the thread root every later move answers to.
  def handle_event("new", %{"color" => color}, socket) do
    case HighWire.Chess.Log.open(color) do
      {:ok, game_id, _key} ->
        {:noreply, push_navigate(socket, to: ~p"/games/#{game_id}")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not open a game: #{inspect(reason)}")}
    end
  end

  def handle_event("accept", %{"id" => id}, socket) do
    with %{} = game <- Chess.Store.get(id),
         {:ok, _key} <- HighWire.Chess.Log.accept(game) do
      {:noreply, assign(socket, :games, page(socket.assigns.self_id, socket.assigns.page))}
    else
      _ -> {:noreply, assign(socket, :error, "Could not accept that game.")}
    end
  end

  def handle_event("withdraw", %{"id" => id}, socket) do
    with %{} = game <- Chess.Store.get(id),
         {:ok, _key} <- HighWire.Chess.Log.withdraw(game) do
      {:noreply, assign(socket, :games, page(socket.assigns.self_id, socket.assigns.page))}
    else
      _ -> {:noreply, assign(socket, :error, "Could not withdraw that game.")}
    end
  end

  # A message names one game, so one game is re-read: the room keeps the
  # rest of its rows rather than folding every board in the store again on
  # each event, which is what a busy tail would ask it to do.
  @impl true
  def handle_info({_kind, game_id}, socket) do
    games = refresh(socket.assigns.games, game_id, socket.assigns.self_id)
    {:noreply, assign(socket, :games, games)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  defp refresh(games, game_id, self_id) do
    rest = Enum.reject(games, &(&1.game_id == game_id))

    case Chess.Store.get(game_id) || Chess.Legacy.Store.get(game_id) || Store.get(game_id) do
      nil -> rest
      game -> [put_live_status(game, self_id) | rest]
    end
  end

  defp page(self_id, page), do: page_games(self_id, page)

  # A page is a window's worth of ids, and each one is read from the store
  # that holds it — the cost is the page, not the number of games.
  defp page_games(self_id, page) do
    Catalog.recent(@page_size, page * @page_size)
    |> Enum.map(fn {kind, game_id} -> snapshot(kind, game_id) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&put_live_status(&1, self_id))
  end

  defp snapshot(:chess, id), do: Chess.Store.get(id)
  defp snapshot(:chess_legacy, id), do: Chess.Legacy.Store.get(id)
  defp snapshot(:backgammon, id), do: Store.get(id)
  defp snapshot(_kind, _id), do: nil

  defp put_live_status(game, self_id) do
    Map.put(game, :yours?, game.mover == self_id and game.status in [:playing, :opening])
  end

  defp self_id do
    case Identities.active() do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # The room is three places and a past: games it is your turn in, games
  # you are waiting on, everything else in flight — which is what there is
  # to watch — and what is over. The grouping is the same for either game.
  defp your_move(games, _self_id), do: Enum.filter(games, &(&1.yours? and in_flight?(&1)))

  defp waiting(games, self_id),
    do: Enum.filter(games, &(not &1.yours? and mine?(&1, self_id) and in_flight?(&1)))

  defp spectate(games, self_id),
    do: Enum.filter(games, &(not mine?(&1, self_id) and in_flight?(&1) and not open?(&1)))

  # Somebody else's challenge with no opponent yet is not a game to watch; it
  # is one you can take. Only the games this node can write are offered, so a
  # challenge read off the network stays an artifact rather than an invitation.
  defp open_games(games, self_id), do: Enum.filter(games, &(open?(&1) and not mine?(&1, self_id)))

  defp open?(game),
    do: Map.get(game, :writable?, true) and in_flight?(game) and game.accepter == nil

  defp finished(games, _self_id), do: Enum.filter(games, &(not in_flight?(&1)))

  defp in_flight?(game), do: game.status in [:playing, :opening]

  # A game is yours when you are one of the two players, whichever way the
  # game names them: a chess game has a challenger and an accepter, and a
  # backgammon one keeps white and black.
  defp mine?(game, self_id) when is_binary(self_id) do
    players = Enum.map([:challenger, :accepter, :white, :black], &Map.get(game, &1))
    self_id in players
  end

  defp mine?(_game, _self_id), do: false

  attr :title, :string, required: true
  attr :games, :list, required: true
  attr :self_id, :string, default: nil

  defp section(assigns) do
    ~H"""
    <section class="mb-6">
      <h3 class="mb-2 text-[11px] uppercase tracking-wider text-faint">
        {@title} <span class="text-faint">· {length(@games)}</span>
      </h3>
      <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.game_card :for={game <- @games} game={game} self_id={@self_id} />
      </div>
    </section>
    """
  end

  defp name(nil), do: "unknown"
  defp name(id), do: Profile.display_name(id)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <h1 class="sr-only">Games</h1>
        <Nav.rail_label>Games</Nav.rail_label>
        <p class="px-4 pb-4 text-xs leading-relaxed text-dim">
          Backgammon and chess games this node has seen. A game appears once its challenge reaches you.
        </p>
        <Nav.rail_link navigate={~p"/"}>Timeline</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-4xl px-6 py-6">
          <header class="mb-5 flex items-baseline justify-between gap-3">
            <h2 class="text-lg font-semibold text-paper">Gameroom</h2>

            <div class="flex items-center gap-2">
              <span class="text-xs text-faint">
                {if @total > 0, do: "#{length(@games)} of #{@total} recent", else: "0 games"}
              </span>
              <span class="text-[10px] uppercase tracking-wide text-faint">new chess game as</span>

              <button
                phx-click="new"
                phx-value-color="white"
                class="rounded border border-edge px-2 py-1 text-xs text-muted transition hover:border-focus hover:text-paper"
              >
                white
              </button>
              <button
                phx-click="new"
                phx-value-color="black"
                class="rounded border border-edge px-2 py-1 text-xs text-muted transition hover:border-focus hover:text-paper"
              >
                black
              </button>
            </div>
          </header>

          <p
            :if={@error}
            role="alert"
            class="mb-3 rounded border border-edge bg-raised px-3 py-2 text-xs text-bad"
          >
            {@error}
          </p>

          <p :if={@games == []} class="rounded border border-edge bg-panel px-4 py-6 text-sm text-dim">
            No games yet. Open one above and it appears here at once; when someone challenges you,
            their game lands here on the next move.
          </p>

          <.section
            :if={your_move(@games, @self_id) != []}
            title="Your move"
            games={your_move(@games, @self_id)}
            self_id={@self_id}
          />
          <.section
            :if={waiting(@games, @self_id) != []}
            title="Waiting on them"
            games={waiting(@games, @self_id)}
            self_id={@self_id}
          />
          <.section
            :if={open_games(@games, @self_id) != []}
            title="Open games"
            games={open_games(@games, @self_id)}
            self_id={@self_id}
          />
          <.section
            :if={spectate(@games, @self_id) != []}
            title="Spectate"
            games={spectate(@games, @self_id)}
            self_id={@self_id}
          />
          <.section
            :if={finished(@games, @self_id) != []}
            title="Finished"
            games={finished(@games, @self_id)}
            self_id={@self_id}
          />

          <div :if={length(@games) < @total} class="mt-4 flex justify-center">
            <button
              phx-click="more"
              class="rounded border border-edge px-3 py-1.5 text-xs text-muted transition hover:border-focus hover:text-paper"
            >
              older games
            </button>
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
    <div class={[
      "rounded border bg-panel p-3 transition hover:border-focus",
      if(@game.yours?, do: "border-accent/60", else: "border-edge")
    ]}>
      <div
        role="link"
        tabindex="0"
        phx-click="open"
        phx-value-id={@game.game_id}
        class="block cursor-pointer"
      >
        <div class="mb-2 flex items-center justify-between gap-3">
          <div class="flex min-w-0 items-center gap-2">
            <Avatar.avatar :if={@game.challenger} id={@game.challenger} size={18} />
            <span class="truncate text-xs text-muted">{name(@game.challenger)}</span>
            <span class="text-[10px] uppercase tracking-wide text-faint">vs</span>
            <Avatar.avatar :if={@game.accepter} id={@game.accepter} size={18} />
            <span class="truncate text-xs text-muted">{name(@game.accepter)}</span>
          </div>
        </div>

        <Board.board :if={@game.kind == :backgammon} position={@game.position} compact />
        <ChessBoard.board :if={@game.kind == :chess} board={@game.board} compact />
      </div>

      <div class="mt-2 flex items-center justify-between gap-2 text-[10px] text-faint">
        <span class="flex shrink-0 items-center gap-1">
          {counter(@game)}
          <span class="text-faint">·</span>
          <Time.age ts={@game.updated_at} />
        </span>
        <span :if={@game.last_note not in [nil, ""]} class="truncate italic">{@game.last_note}</span>

        <span
          :if={@game.accepter == nil and @game.kind == :chess and Map.get(@game, :writable?, true)}
          class="flex shrink-0 items-center gap-2"
        >
          <span>{phase_label(@game)}</span>
          <button
            :if={@game.challenger != @self_id}
            phx-click="accept"
            phx-value-id={@game.game_id}
            class="rounded border border-edge px-2 py-0.5 text-[10px] uppercase tracking-wide text-muted transition hover:border-focus hover:text-paper"
          >
            accept
          </button>
          <button
            :if={@game.challenger == @self_id}
            phx-click="withdraw"
            phx-value-id={@game.game_id}
            class="rounded border border-edge px-2 py-0.5 text-[10px] uppercase tracking-wide text-faint transition hover:border-focus hover:text-paper"
          >
            withdraw
          </button>
        </span>

        <span :if={@game.accepter != nil or @game.kind != :chess} class="shrink-0">
          {label(@game)}
        </span>
      </div>
    </div>
    """
  end

  defp counter(%{kind: :chess, turn_count: plies}) when plies > 0,
    do: "#{div(plies + 1, 2)}. move"

  defp counter(%{turn_count: turns}), do: "turn #{turns}"

  defp label(%{status: :finished, winner: %{player: player}}) do
    case player do
      nil -> "finished"
      id -> name(id) <> " won"
    end
  end

  defp label(%{status: :withdrawn}), do: "withdrawn"
  defp label(%{status: :broken}), do: "unverified"
  # A chess invitation waits on the other player, not on a roll of yours.
  defp label(%{kind: :chess, phase: :opening}), do: "waiting"
  defp label(%{yours?: true, phase: :opening}), do: "your roll"
  defp label(%{yours?: true}), do: "your move"
  defp label(%{phase: :opening}), do: "opening"
  defp label(%{mover: mover}), do: "#{name(mover)} to move"

  defp phase_label(%{phase: :finished} = game), do: chess_end(game, "finished")
  defp phase_label(%{kind: :chess, phase: :opening}), do: "waiting"
  defp phase_label(%{phase: :opening}), do: "opening roll"
  defp phase_label(_), do: "playing"

  # A chess game that is over says how: the verdict is the engine's, not a
  # sentence someone typed.
  defp chess_end(%{kind: :chess} = game, fallback) do
    case game do
      %{status: :broken} -> "unverified"
      %{verdict: {:checkmate, _}} -> "checkmate"
      %{verdict: :stalemate} -> "stalemate"
      %{verdict: {:draw, reason}} -> draw_reason(reason)
      %{winner: %{reason: :resign}} -> "resigned"
      _ -> fallback
    end
  end

  defp chess_end(_game, fallback), do: fallback

  defp draw_reason(:fifty_moves), do: "fifty-move draw"
  defp draw_reason(:insufficient_material), do: "insufficient material"
  defp draw_reason(:repetition), do: "draw by repetition"
  defp draw_reason(_), do: "draw"
end
