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
  alias HighWire.Games.{Catalog, Filter, Interest}
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Board, ChessBoard, Nav, Time}

  # The stores are append-only, so the room shows a page of what changed
  # recently and pages back through every game the catalog holds. Nothing
  # here folds a game it is not showing, and the count is the node's, not a
  # window's: a participant reading the room sees how much this node has.
  @page_size 40

  # The groups review reads the room in. A game falls in exactly one of each
  # list, so the titles are the order they appear in rather than sorted by
  # count.
  # What a filter can ask for. The chip labels come from these lists, so a
  # view can never push a facet or a value the module does not know: the
  # event is matched against the same whitelist before it is turned into an
  # atom.
  @facets %{
    "who" => ~w(any played followed strangers mine),
    "length" => ~w(any short medium long),
    "age" => ~w(any today week month year),
    "kind" => ~w(any chess backgammon)
  }

  @groups ~w(room period result)

  @periods [
    "Today",
    "Earlier this week",
    "Earlier this month",
    "Earlier this year",
    "Older",
    "Undated"
  ]
  @results ["Checkmate", "Decided", "Draw", "Unfinished", "Withdrawn", "Does not verify"]

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
     |> assign(:filters, %{})
     |> assign(:group, :room)
     |> assign_games(page(self_id, 0))}
  end

  # The room's sections are what this reader should see, in that order, so
  # they are worked out once per change of games rather than per render.
  defp assign_games(socket, games) do
    viewer = viewer(socket.assigns.self_id, games)

    socket
    |> assign(:games, games)
    |> assign(:viewer, viewer)
    |> assign(:sections, sections(Map.merge(socket.assigns, %{games: games, viewer: viewer})))
  end

  # Who the reader is, who they follow, and who they have played. The follow
  # list is the Timeline's, which is already reading the contact graph; the
  # played list is read off the games in hand, which is what the ranking is
  # about to order anyway.
  defp viewer(self_id, games) do
    follows =
      case Process.whereis(HighWire.Timeline) do
        nil -> []
        _pid -> HighWire.Timeline.viewer().follows
      end

    %{self_id: self_id, follows: follows, played: played(self_id, games)}
  end

  defp played(nil, _games), do: MapSet.new()

  defp played(self_id, games) do
    for game <- games,
        mine?(game, self_id),
        id <- Interest.players(game),
        id != self_id,
        into: MapSet.new(),
        do: id
  end

  def handle_event("more", _params, socket) do
    page = socket.assigns.page + 1
    more = page_games(socket.assigns.self_id, page)

    {:noreply,
     socket
     |> assign(:page, page)
     |> assign(:total, Catalog.count())
     |> assign_games(socket.assigns.games ++ more)}
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

  # Backgammon has no side to choose: the opening roll decides who starts.
  def handle_event("new", %{"kind" => "backgammon"}, socket) do
    case HighWire.Backgammon.Log.open() do
      {:ok, game_id, _key} ->
        {:noreply, push_navigate(socket, to: ~p"/games/#{game_id}")}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not open a backgammon game: #{inspect(reason)}")}
    end
  end

  def handle_event("accept", %{"id" => id} = params, socket) do
    with {:ok, game} <- find(params, id),
         {:ok, _key} <- accept(game) do
      {:noreply, assign_games(socket, page(socket.assigns.self_id, socket.assigns.page))}
    else
      _ -> {:noreply, assign(socket, :error, "Could not accept that game.")}
    end
  end

  # A facet is one question at a time: setting it to the value it already has
  # is how a reader takes it back off, so a chip never needs a second control.
  def handle_event("filter", %{"facet" => facet, "value" => value}, socket) do
    filters = socket.assigns.filters
    key = facet_atom(facet)
    value = value_atom(facet, value)

    filters =
      cond do
        key == nil or value == nil -> filters
        value == :any -> Map.delete(filters, key)
        Map.get(filters, key) == value -> Map.delete(filters, key)
        true -> Map.put(filters, key, value)
      end

    {:noreply, assign_filters(socket, filters)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply, assign_filters(socket, %{})}
  end

  def handle_event("group", %{"by" => by}, socket) do
    {:noreply,
     socket
     |> assign(:group, group_atom(by))
     |> then(&assign(&1, :sections, sections(&1.assigns)))}
  end

  def handle_event("withdraw", %{"id" => id} = params, socket) do
    with {:ok, game} <- find(params, id),
         {:ok, _key} <- withdraw(game) do
      {:noreply, assign_games(socket, page(socket.assigns.self_id, socket.assigns.page))}
    else
      _ -> {:noreply, assign(socket, :error, "Could not withdraw that game.")}
    end
  end

  # The card says which store its game came from, so a game this node can
  # write is written through the writer that owns its namespace.
  defp find(params, id) do
    case Map.get(params, "kind") do
      "backgammon" -> wrap(Store.get(id))
      _ -> wrap(Chess.Store.get(id))
    end
  end

  defp wrap(nil), do: :error
  defp wrap(game), do: {:ok, game}

  defp accept(%{kind: :backgammon} = game), do: HighWire.Backgammon.Log.accept(game)
  defp accept(game), do: HighWire.Chess.Log.accept(game)

  defp withdraw(%{kind: :backgammon} = game), do: HighWire.Backgammon.Log.withdraw(game)
  defp withdraw(game), do: HighWire.Chess.Log.withdraw(game)

  # A message names one game, so one game is re-read: the room keeps the
  # rest of its rows rather than folding every board in the store again on
  # each event, which is what a busy tail would ask it to do.
  @impl true
  def handle_info({_kind, game_id}, socket) do
    games = refresh(socket.assigns.games, game_id, socket.assigns.self_id)
    {:noreply, assign_games(socket, games)}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # A message names a game, not a store row, and the two do not have to arrive
  # in step: a touch can be heard before the store it names can answer for the
  # game. The card the room already has stays where it is in that case — a
  # room whose rows blink out and back is a room that looks like it forgot.
  defp refresh(games, game_id, self_id) do
    case Chess.Store.get(game_id) || Chess.Legacy.Store.get(game_id) || Store.get(game_id) do
      nil -> games
      game -> [put_live_status(game, self_id) | Enum.reject(games, &(&1.game_id == game_id))]
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

  # A game is yours to move in when you are the one to move. Without an
  # identity there is no "yours": a game whose mover this node could not name
  # would otherwise count as yours for a reader with no identity at all.
  defp put_live_status(game, self_id) do
    yours? =
      is_binary(self_id) and game.mover == self_id and game.status in [:playing, :opening]

    Map.put(game, :yours?, yours?)
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

  defp facet_atom(facet), do: facet_key(facet)

  defp facet_key("who"), do: :who
  defp facet_key("length"), do: :length
  defp facet_key("age"), do: :age
  defp facet_key("kind"), do: :kind
  defp facet_key(_facet), do: nil

  defp value_atom(facet, value) do
    if facet in Map.keys(@facets) and value in Map.fetch!(@facets, facet) do
      String.to_existing_atom(value)
    else
      nil
    end
  end

  defp group_atom(by) when by in @groups, do: String.to_existing_atom(by)
  defp group_atom(_by), do: :room

  defp assign_filters(socket, filters) do
    socket
    |> assign(:filters, filters)
    |> then(&assign(&1, :sections, sections(&1.assigns)))
  end

  defp sections(assigns) do
    %{self_id: self_id, games: games, viewer: viewer, filters: filters, group: group} = assigns

    games = Filter.apply(games, viewer, filters)

    case group do
      :period -> grouped(games, viewer, &Filter.period/1, @periods, keep_empty: true)
      :result -> grouped(games, viewer, &Filter.result/1, @results)
      _ -> room(games, self_id, viewer)
    end
  end

  # The room in order: what is waiting on you, then games to take, then what
  # there is to watch. The last two are ordered by what this reader is most
  # likely to want — a stranger's abandoned opening does not belong above a
  # game between two people they follow.
  defp room(games, self_id, viewer) do
    [
      {"Your move", your_move(games, self_id)},
      {"Waiting on them", waiting(games, self_id)},
      {"Open games", open_games(games, self_id)},
      {"Spectate", Interest.rank(spectate(games, self_id), viewer)},
      {"Finished", Interest.rank(finished(games, self_id), viewer)}
    ]
    |> Enum.reject(fn {_title, list} -> list == [] end)
  end

  # Review reads the same set as a run: every game in a period together, or
  # every game that ended the same way, in the order that reader would want
  # them.
  #
  # Periods keep their empty groups, because a period is a position on a
  # scale: a week with nothing in it is a fact about what this node holds, and
  # dropping the heading makes the scale look like it has a missing rung.
  # Results do not — a room with no draws does not need to say so six times.
  defp grouped(games, viewer, key, order, opts \\ []) do
    by_key = Enum.group_by(games, key)
    keep_empty? = Keyword.get(opts, :keep_empty, false)

    order
    |> Enum.map(fn title -> {title, Map.get(by_key, title, [])} end)
    |> Enum.reject(fn {_title, list} -> list == [] and not keep_empty? end)
    |> Enum.map(fn {title, list} -> {title, Interest.rank(list, viewer)} end)
  end

  defp in_flight?(game), do: game.status in [:playing, :opening]

  # A game is yours when you are one of the two players, whichever way the
  # game names them: a chess game has a challenger and an accepter, and a
  # backgammon one keeps white and black.
  defp mine?(game, self_id) when is_binary(self_id) do
    players = Enum.map([:challenger, :accepter, :white, :black], &Map.get(game, &1))
    self_id in players
  end

  defp mine?(_game, _self_id), do: false

  attr :filters, :map, required: true
  attr :group, :atom, required: true
  attr :shown, :integer, required: true
  attr :total, :integer, required: true

  # Narrowing the room is four questions about a game — who is playing, how
  # long it ran, when it last moved, which game it is — and a fifth about how
  # to read the answer. One chip per answer, and the chip that is on is the
  # answer in force; clicking it again takes the question back off.
  # The filters read as a sentence rather than a panel of switches: four
  # words you can open, the grouping, and how much of the room survives them.
  # A facet says its own name while it is asking for nothing, and the answer
  # once it has one — so a room that is not being filtered reads as four
  # quiet words, and one that is says what it is asking.
  defp filters(assigns) do
    assigns =
      assign(assigns,
        who: [
          {"anyone", :any},
          {"you played", :played},
          {"you follow", :followed},
          {"strangers", :strangers},
          {"yours", :mine}
        ],
        length: [{"any", :any}, {"under 10", :short}, {"10-39", :medium}, {"40+", :long}],
        age: [
          {"any", :any},
          {"today", :today},
          {"week", :week},
          {"month", :month},
          {"year", :year}
        ],
        kind: [{"any", :any}, {"chess", :chess}, {"backgammon", :backgammon}]
      )

    ~H"""
    <div class="mb-5 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px]">
      <.facet_menu title="who" facet="who" key={:who} options={@who} filters={@filters} />
      <.facet_menu title="when" facet="age" key={:age} options={@age} filters={@filters} />
      <.facet_menu title="moves" facet="length" key={:length} options={@length} filters={@filters} />
      <.facet_menu title="game" facet="kind" key={@kind} options={@kind} filters={@filters} />

      <span class="h-3 w-px shrink-0 bg-edge" aria-hidden="true" />

      <span class="flex items-center gap-1.5">
        <span class="text-[10px] uppercase tracking-wider text-faint">by</span>
        <.group_chip by={:room} label="room" group={@group} />
        <.group_chip by={:period} label="period" group={@group} />
        <.group_chip by={:result} label="result" group={@group} />
      </span>

      <span class="ml-auto flex items-center gap-2 text-[10px] text-faint">
        <span>{@shown} of {@total} shown</span>
        <button
          :if={@filters != %{}}
          phx-click="clear_filters"
          class="rounded px-1 py-0.5 uppercase tracking-wide text-muted transition hover:text-paper"
        >
          clear
        </button>
      </span>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :facet, :string, required: true
  attr :key, :atom, required: true
  attr :options, :list, required: true
  attr :filters, :map, required: true

  # A facet is a word that opens. The chevron and the word carry the whole
  # affordance at rest; the menu is the choices, with the current one marked.
  defp facet_menu(assigns) do
    current = Map.get(assigns.filters, assigns.key, :any)
    {answered, _} = List.keyfind(assigns.options, current, 1, {nil, current})

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:current_label, if(answered, do: answered, else: "any"))

    ~H"""
    <details class="group relative">
      <summary class="flex cursor-pointer list-none items-center gap-1 rounded px-1 py-0.5 transition hover:text-paper [&::-webkit-details-marker]:hidden">
        <span class="text-[10px] uppercase tracking-wider text-faint">{@title}</span>
        <span :if={@current != :any} class="text-accent">{@current_label}</span>
        <svg
          class="h-2.5 w-2.5 text-faint transition group-open:rotate-180"
          viewBox="0 0 10 10"
          aria-hidden="true"
          fill="none"
          stroke="currentColor"
          stroke-width="1.4"
          stroke-linecap="round"
        >
          <path d="M2 4l3 3 3-3" />
        </svg>
      </summary>
      <div class="absolute left-0 top-full z-20 mt-1 w-40 rounded border border-edge bg-panel py-1 shadow-lg shadow-black/30">
        <button
          :for={{label, value} <- @options}
          phx-click={
            Phoenix.LiveView.JS.push("filter", value: %{facet: @facet, value: to_string(value)})
          }
          onclick="this.closest('details').removeAttribute('open')"
          data-facet={@facet}
          data-value={to_string(value)}
          class={[
            "block w-full px-2 py-1 text-left text-[11px] transition",
            if(value == @current,
              do: "text-accent",
              else: "text-muted hover:bg-raised hover:text-paper"
            )
          ]}
        >
          {label}
        </button>
      </div>
    </details>
    """
  end

  attr :by, :atom, required: true
  attr :label, :string, required: true
  attr :group, :atom, required: true

  defp group_chip(assigns) do
    ~H"""
    <button
      phx-click={Phoenix.LiveView.JS.push("group", value: %{by: to_string(@by)})}
      data-group={to_string(@by)}
      aria-pressed={@by == @group}
      class={[
        "rounded px-1 py-0.5 text-[10px] uppercase tracking-wide transition",
        if(@by == @group,
          do: "text-accent",
          else: "text-faint hover:text-paper"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp count_games(sections),
    do: sections |> Enum.map(fn {_title, games} -> length(games) end) |> Enum.sum()

  attr :title, :string, required: true
  attr :games, :list, required: true
  attr :self_id, :string, default: nil

  defp section(assigns) do
    ~H"""
    <section class="mb-6">
      <h3 class="mb-2 text-[11px] uppercase tracking-wider text-faint">
        {@title} <span class="text-faint">· {count(@games)}</span>
      </h3>
      <div :if={@games != []} class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <.game_card :for={game <- @games} game={game} self_id={@self_id} />
      </div>
    </section>
    """
  end

  # A group with nothing in it says so in a word, rather than wearing a 0.
  defp count([]), do: "none"
  defp count(games), do: length(games)

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
                {if @total > 0, do: "#{length(@games)} of #{@total} games", else: "0 games"}
              </span>
              <span class="text-[10px] uppercase tracking-wide text-faint">new game</span>

              <button
                phx-click="new"
                phx-value-color="white"
                class="rounded border border-edge px-2 py-1 text-xs text-muted transition hover:border-focus hover:text-paper"
              >
                chess as white
              </button>
              <button
                phx-click="new"
                phx-value-color="black"
                class="rounded border border-edge px-2 py-1 text-xs text-muted transition hover:border-focus hover:text-paper"
              >
                chess as black
              </button>
              <button
                phx-click="new"
                phx-value-kind="backgammon"
                class="rounded border border-edge px-2 py-1 text-xs text-muted transition hover:border-focus hover:text-paper"
              >
                backgammon
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

          <.filters
            filters={@filters}
            group={@group}
            shown={count_games(@sections)}
            total={length(@games)}
          />

          <p
            :if={@filters != %{} and count_games(@sections) == 0}
            class="rounded border border-edge bg-panel px-4 py-6 text-sm text-dim"
          >
            No game matches that. Widen a filter or load older games.
          </p>

          <.section
            :for={{title, games} <- @sections}
            title={title}
            games={games}
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
            <Avatar.face :if={@game.challenger} id={@game.challenger} size={18} />
            <span class="truncate text-xs text-muted">{name(@game.challenger)}</span>
            <span class="text-[10px] uppercase tracking-wide text-faint">vs</span>
            <Avatar.face :if={@game.accepter} id={@game.accepter} size={18} />
            <span class="truncate text-xs text-muted">{name(@game.accepter)}</span>
          </div>
        </div>

        <Board.board :if={@game.kind == :backgammon} position={@game.position} compact />
        <ChessBoard.board
          :if={@game.kind == :chess}
          id={"board-" <> @game.game_id}
          board={@game.board}
          compact
        />
      </div>

      <div class="mt-2 flex items-center justify-between gap-2 text-[10px] text-faint">
        <span class="flex shrink-0 items-center gap-1">
          {counter(@game)}
          <span class="text-faint">·</span>
          <Time.age ts={@game.updated_at} />
        </span>
        <span :if={@game.last_note not in [nil, ""]} class="truncate italic">{@game.last_note}</span>

        <span
          :if={@game.accepter == nil and Map.get(@game, :writable?, true)}
          class="flex shrink-0 items-center gap-2"
        >
          <span>{phase_label(@game)}</span>
          <button
            :if={@game.challenger != @self_id}
            phx-click="accept"
            phx-value-id={@game.game_id}
            phx-value-kind={@game.kind}
            class="rounded border border-edge px-2 py-0.5 text-[10px] uppercase tracking-wide text-muted transition hover:border-focus hover:text-paper"
          >
            accept
          </button>
          <button
            :if={@game.challenger == @self_id}
            phx-click="withdraw"
            phx-value-id={@game.game_id}
            phx-value-kind={@game.kind}
            class="rounded border border-edge px-2 py-0.5 text-[10px] uppercase tracking-wide text-faint transition hover:border-focus hover:text-paper"
          >
            withdraw
          </button>
        </span>

        <span :if={@game.accepter != nil} class="shrink-0">
          {label(@game)}
        </span>
      </div>

      <%!-- Why this game is where it is. The order is a judgement, and a
           judgement the reader cannot see the grounds for is one they have
           no reason to trust. --%>
      <p
        :if={reasons(@game) != []}
        class="mt-1 text-[10px] leading-relaxed text-accent/80"
      >
        {Enum.join(reasons(@game), " · ")}
      </p>
    </div>
    """
  end

  defp reasons(%{interest: %{reasons: reasons}}), do: reasons
  defp reasons(_game), do: []

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
