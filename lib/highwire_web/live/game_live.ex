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
  alias HighWire.Chess.Engine
  alias HighWire.Games.Catalog
  alias HighWire.SSB.{Identities, Profile}
  alias HighWireWeb.Components.{Avatar, Board, ChessBoard, Nav}

  # How long one ply of playback stays on the board: fast enough to read a
  # game, slow enough to see the move land.
  @tick 700

  @impl true
  def mount(%{"game_id" => game_id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HighWire.PubSub, Store.topic())
      Phoenix.PubSub.subscribe(HighWire.PubSub, Chess.Store.topic())
      Phoenix.PubSub.subscribe(HighWire.PubSub, Chess.Legacy.Store.topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Game")
     |> assign(:self_id, self_id())
     |> assign(:error, nil)
     |> open(game_id)}
  end

  # Walking from one game to the next is a patch, not a reload: the socket
  # stays, the subscriptions stay, and only what the page shows changes.
  @impl true
  def handle_params(%{"game_id" => game_id}, _uri, socket) do
    {:noreply, open(socket, game_id)}
  end

  defp open(socket, game_id) do
    game = load(game_id)
    {previous, following} = neighbours(game_id)

    socket
    |> assign(:game_id, game_id)
    |> assign(:previous, previous)
    |> assign(:following, following)
    |> assign_board(game)
  end

  # The room's own order, so browsing from a game goes where the room would
  # have gone. A game the catalog has forgotten has no neighbours rather
  # than invented ones.
  defp neighbours(game_id) do
    ids =
      Catalog.recent(400)
      |> Enum.map(fn {_kind, id} -> id end)

    case Enum.find_index(ids, &(&1 == game_id)) do
      nil -> {nil, nil}
      at -> {if(at > 0, do: Enum.at(ids, at - 1)), Enum.at(ids, at + 1)}
    end
  end

  # The board's own state: which square is picked up and where that piece
  # can go. Both are derived from the folded position, so the page can only
  # offer moves the same engine the fold used would accept.
  defp assign_board(socket, game, keep_at \\ nil) do
    {line, stop} = line(game)
    last = length(line) - 1

    # A move arriving while the reader is looking back leaves them where they
    # are; only the new end of the line is out of reach. Reaching that end is
    # how the page goes live again, so play stops there too.
    at = if is_integer(keep_at) and keep_at < last, do: keep_at, else: nil

    socket
    |> assign(:game, game)
    |> assign(:selected, nil)
    |> assign(:targets, [])
    |> assign(:movable, movable(game, socket.assigns.self_id))
    |> assign(:promos, [])
    |> assign(:line, line)
    |> assign(:line_stop, stop)
    |> assign(:pairs, pairs((game && game.history) || []))
    |> assign(:at, at)
    |> assign(:playing?, Map.get(socket.assigns, :playing?, false) and at != nil)
  end

  # Only a game this node writes can be played here. A game read from the
  # network's own format belongs to its players and has no writer.
  defp movable(%{writable?: false}, _self_id), do: []

  defp movable(%{kind: :chess, status: :playing, mover: mover, position: position}, self_id)
       when is_binary(self_id) and mover == self_id and is_map(position) do
    position
    |> Engine.legal_moves()
    |> Enum.map(&binary_part(&1, 0, 2))
    |> Enum.uniq()
  end

  defp movable(_game, _self_id), do: []

  @impl true
  def handle_event("square", %{"sq" => square}, socket) do
    %{game: game, selected: selected} = socket.assigns

    cond do
      game == nil or game.kind != :chess ->
        {:noreply, socket}

      square == selected ->
        {:noreply, assign(socket, selected: nil, targets: [], promos: [])}

      square in socket.assigns.movable ->
        moves = moves_from(game, square)

        {:noreply,
         assign(socket, selected: square, targets: Enum.map(moves, & &1.to), promos: [])}

      selected != nil and square in socket.assigns.targets ->
        play(game, Enum.filter(moves_from(game, selected), &(&1.to == square)), socket)

      true ->
        {:noreply, assign(socket, selected: nil, targets: [], promos: [])}
    end
  end

  # Looking back through the line. The last position is the live one, so
  # arriving there leaves replay rather than pinning the page to a copy of the
  # board it is already showing.
  def handle_event("replay", %{"to" => to}, socket) do
    {:noreply, socket |> stop() |> seek(to)}
  end

  def handle_event("scrub", %{"to" => to}, socket) do
    {:noreply, socket |> stop() |> seek(to)}
  end

  # Playing the game back is the same walk the buttons take, a ply at a time.
  # From live, play starts over at the top, which is what a finished game's
  # audience wants; from anywhere else it carries on from there.
  def handle_event("play", _params, socket) do
    %{line: line, at: at} = socket.assigns
    last = length(line) - 1

    cond do
      socket.assigns.playing? ->
        {:noreply, stop(socket)}

      last <= 0 ->
        {:noreply, socket}

      at == nil or at >= last ->
        Process.send_after(self(), :tick, @tick)
        {:noreply, socket |> seek(0) |> assign(:playing?, true)}

      true ->
        Process.send_after(self(), :tick, @tick)
        {:noreply, assign(socket, :playing?, true)}
    end
  end

  def handle_event("promote", %{"uci" => uci}, socket) do
    case Chess.Log.play(socket.assigns.game, uci) do
      {:ok, _key} ->
        {:noreply, assign_board(socket, load(socket.assigns.game_id))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "That move did not go out: #{inspect(reason)}")}
    end
  end

  def handle_event("resign", _params, socket) do
    case Chess.Log.resign(socket.assigns.game) do
      {:ok, _key} ->
        {:noreply, assign_board(socket, load(socket.assigns.game_id))}

      {:error, reason} ->
        {:noreply, assign(socket, :error, "Could not resign: #{inspect(reason)}")}
    end
  end

  defp seek(socket, to) do
    %{line: line, at: at} = socket.assigns
    last = length(line) - 1

    at =
      case to do
        "first" ->
          0

        "prev" ->
          min(max((at || last) - 1, 0), last)

        "next" ->
          min((at || last) + 1, last)

        "live" ->
          last

        n when is_integer(n) ->
          min(max(n, 0), last)

        ply ->
          case Integer.parse(ply) do
            {n, ""} -> min(max(n, 0), last)
            _ -> at || last
          end
      end

    socket
    |> assign(:at, if(at == last, do: nil, else: at))
    |> assign(:selected, nil)
    |> assign(:targets, [])
    |> assign(:promos, [])
  end

  defp stop(socket), do: assign(socket, :playing?, false)

  @impl true
  def handle_info({:backgammon, game_id}, %{assigns: %{game_id: game_id}} = socket) do
    {:noreply, assign(socket, :game, load(game_id))}
  end

  def handle_info({:chess, game_id}, %{assigns: %{game_id: game_id}} = socket) do
    {:noreply, assign_board(socket, load(game_id), socket.assigns.at)}
  end

  def handle_info({:chess_legacy, game_id}, %{assigns: %{game_id: game_id}} = socket) do
    {:noreply, assign_board(socket, load(game_id), socket.assigns.at)}
  end

  def handle_info(:tick, %{assigns: %{playing?: true}} = socket) do
    %{line: line, at: at} = socket.assigns
    last = length(line) - 1
    next = (at || 0) + 1

    if next >= last do
      {:noreply, socket |> stop() |> seek("live")}
    else
      Process.send_after(self(), :tick, @tick)
      {:noreply, socket |> seek(next) |> assign(:playing?, true)}
    end
  end

  def handle_info(:tick, socket), do: {:noreply, socket}

  def handle_info(_other, socket), do: {:noreply, socket}

  defp moves_from(game, square) do
    for uci <- Engine.legal_moves(game.position),
        binary_part(uci, 0, 2) == square,
        do: %{
          uci: uci,
          to: binary_part(uci, 2, 2),
          promo: binary_part(uci, 4, byte_size(uci) - 4)
        }
  end

  # One destination, one move. A promotion offers four, so the page asks
  # which piece rather than picking one for the player.
  defp play(game, moves, socket) do
    case moves do
      [] ->
        {:noreply, assign(socket, selected: nil, targets: [], promos: [])}

      [move] ->
        case Chess.Log.play(game, move.uci) do
          {:ok, _key} ->
            {:noreply, assign_board(socket, load(game.game_id))}

          {:error, reason} ->
            {:noreply, assign(socket, :error, "That move did not go out: #{inspect(reason)}")}
        end

      many ->
        {:noreply, socket |> assign(selected: nil, targets: [], promos: many)}
    end
  end

  # Every position the game has stood in, starting from the board before the
  # first move: a game is a path, and a page that only shows the last square
  # on it cannot say how anyone got there.
  #
  # Only a game whose log runs from the first move can be replayed. A game
  # read off the network often arrives as a fragment — the chain this node
  # holds can begin at move 139 of 166 — and the position those moves started
  # from is not in the log, so there is no line and the page says why rather
  # than pretending the fragment is the whole game.
  defp line(%{kind: :chess, history: [%{ply: 1} | _]} = game) do
    start = Engine.initial()
    {steps, stop} = walk(game.history, start, [])
    {[step(0, start, nil) | steps], stop}
  end

  defp line(%{kind: :chess, history: []}), do: {[step(0, Engine.initial(), nil)], nil}
  defp line(_game), do: {[], nil}

  defp walk([], _pos, acc), do: {Enum.reverse(acc), nil}

  defp walk([%{uci: uci} = item | rest], pos, acc) when is_binary(uci) do
    case Engine.play(pos, uci) do
      {:ok, next, _san} -> walk(rest, next, [step(item.ply, next, item) | acc])
      {:error, reason} -> {Enum.reverse(acc), %{ply: item.ply, reason: reason}}
    end
  end

  defp walk([_other | rest], pos, acc), do: walk(rest, pos, acc)

  defp step(ply, pos, item) do
    %{
      ply: ply,
      san: item && (item.san || item.uci),
      turn: pos.turn,
      from: item && String.slice(item.uci, 0, 2),
      to: item && String.slice(item.uci, 2, 2),
      board: pos.board
    }
  end

  # The list reads in moves, not plies: white then black on one row, which is
  # how a game is written down anywhere else. Rows come from the log rather
  # than from the line, so a fragment still lists every move it holds, and
  # each is numbered by the ply it was played as.
  defp pairs(history) do
    history
    |> Enum.filter(&is_binary(Map.get(&1, :uci)))
    |> Enum.chunk_by(&div(&1.ply + 1, 2))
    |> Enum.map(fn moves ->
      %{
        number: div(hd(moves).ply + 1, 2),
        white: Enum.find(moves, &(rem(&1.ply, 2) == 1)),
        black: Enum.find(moves, &(rem(&1.ply, 2) == 0))
      }
    end)
  end

  defp board_at(_line, nil, board), do: board
  defp board_at(line, at, board), do: line |> Enum.at(at) |> then(&(&1 && &1.board)) || board

  # The squares the position on show was reached from. Live shows the last
  # move played, which is the one a player turned up to see. Without a line
  # there are no positions to draw from, so the log's last move is the one
  # that produced the board being shown.
  defp last_move([], _at, game) do
    case List.last(game.history) do
      %{uci: uci} when is_binary(uci) -> [String.slice(uci, 0, 2), String.slice(uci, 2, 2)]
      _ -> []
    end
  end

  defp last_move(line, at, _game) do
    case Enum.at(line, at || length(line) - 1) do
      %{from: from, to: to} when is_binary(from) -> [from, to]
      _ -> []
    end
  end

  # Where this node's log picks the game up, when it does not start at one.
  defp fragment(%{history: []}), do: nil
  defp fragment(%{history: [%{ply: 1} | _]}), do: nil
  defp fragment(%{history: [first | _]}), do: first.ply

  # The id shape is the same for both games, so the kind is what the store
  # finds rather than what the URL claims.
  defp load(game_id) do
    Chess.Store.get(game_id) || Chess.Legacy.Store.get(game_id) || Store.get(game_id)
  end

  # Which side of the glass you are on, whichever way the game names its
  # players: a chess game has a challenger and an accepter, a backgammon
  # one keeps white and black, and a game read from the network has both.
  defp spectating?(game, self_id) do
    players = Enum.map([:challenger, :accepter, :white, :black], &Map.get(game, &1))
    is_nil(self_id) or self_id not in players
  end

  defp self_id do
    case Identities.active() do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  attr :step, :map, default: nil
  attr :current, :integer, default: 0

  defp ply(assigns) do
    ~H"""
    <button
      :if={@step}
      phx-click="replay"
      phx-value-to={@step.ply}
      data-active={to_string(@step.ply == @current)}
      class={[
        "truncate rounded px-1.5 py-0.5 text-left font-mono text-[11px] transition",
        if(@step.ply == @current,
          do: "bg-accent text-paper",
          else: "text-dim hover:bg-raised hover:text-paper"
        )
      ]}
    >
      {@step.san}
    </button>
    """
  end

  attr :at, :integer, default: nil
  attr :current, :integer, required: true
  attr :last, :integer, required: true
  attr :playing?, :boolean, default: false
  attr :status, :atom, default: nil

  # The line is the game, so the transport walks it: one position per ply, a
  # scrubber for the jumps nobody wants to click through, and a play button
  # that runs it forwards. Every part of it is the same seek the move list
  # uses, so the board, the number and the list never disagree.
  defp transport(assigns) do
    ~H"""
    <div class="mt-2 flex flex-wrap items-center gap-2 rounded border border-edge bg-panel px-2 py-1.5">
      <div class="flex items-stretch overflow-hidden rounded border border-edge">
        <.step to="first" glyph="⏮" title="The position before the first move" off={@at == 0} />
        <.step to="prev" glyph="‹" title="The move before this one" off={@at == 0} />
        <button
          phx-click="play"
          title={if @playing?, do: "Stop playing back", else: "Play the game from here"}
          aria-label={if @playing?, do: "Stop playing back", else: "Play the game from here"}
          class={[
            "grid h-7 w-8 place-items-center border-x border-edge text-xs transition",
            if(@playing?,
              do: "bg-accent/20 text-accent hover:bg-accent/30",
              else: "text-muted hover:bg-raised hover:text-paper"
            )
          ]}
        >
          {if @playing?, do: "❚❚", else: "▶"}
        </button>
        <.step to="next" glyph="›" title="The move after this one" off={@at == nil} />
        <.step to="live" glyph="⏭" title="The latest position" off={@at == nil} />
      </div>

      <%!-- The slider reports through a form: change events are how a range
           input says where it was dragged to, and a bare input does not
           report them. --%>
      <form id="scrub" phx-change="scrub" class="min-w-24 flex-1">
        <input
          type="range"
          name="to"
          min="0"
          max={@last}
          value={@at || @last}
          aria-label="Position in the game"
          class="w-full cursor-pointer accent-accent"
          style="accent-color: var(--accent)"
        />
      </form>

      <span class="shrink-0 font-mono text-[11px] tabular-nums text-faint">
        {@current} / {@last}
      </span>

      <button
        :if={@at != nil}
        phx-click="replay"
        phx-value-to="live"
        class="shrink-0 rounded border border-accent/40 px-2 py-0.5 text-[10px] uppercase tracking-wide text-accent transition hover:bg-accent/15"
      >
        {if @status == :playing, do: "back to live", else: "latest"}
      </button>

      <span
        :if={@at == nil and @status == :playing}
        class="flex shrink-0 items-center gap-1.5 text-[10px] uppercase tracking-wide text-faint"
      >
        <span class="size-1.5 rounded-full bg-accent"></span> live
      </span>
    </div>
    """
  end

  attr :to, :string, required: true
  attr :glyph, :string, required: true
  attr :title, :string, required: true
  attr :off, :boolean, default: false

  defp step(assigns) do
    ~H"""
    <button
      phx-click="replay"
      phx-value-to={@to}
      title={@title}
      aria-label={@title}
      disabled={@off}
      class={[
        "grid h-7 w-7 place-items-center border-r border-edge text-xs transition last:border-r-0",
        if(@off,
          do: "cursor-default text-faint/40",
          else: "text-muted hover:bg-raised hover:text-paper"
        )
      ]}
    >
      {@glyph}
    </button>
    """
  end

  defp name(nil), do: "unknown"
  defp name(id), do: Profile.display_name(id)

  @impl true
  def render(%{game: nil} = assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <Nav.rail_label>Games</Nav.rail_label>
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
    # Live is the end of the line, so the highlighted move is the last one
    # played whether or not the reader has stepped back. A game the node holds
    # only the tail of has no line to index, so its log supplies the number.
    current =
      case assigns.at do
        nil ->
          case List.last(assigns.line) do
            %{ply: ply} -> ply
            nil -> assigns.game.history |> List.last() |> then(&((&1 && &1.ply) || 0))
          end

        at ->
          at
      end

    # The facts beside the board belong to the position drawn on it: showing
    # move 0 and calling it black's move would be a lie the picture does not
    # tell.
    now =
      case assigns.at do
        nil ->
          %{live?: true, ply: assigns.game.turn_count, side: side_word(assigns.game)}

        at ->
          case Enum.at(assigns.line, at) do
            %{ply: ply, turn: turn} -> %{live?: false, ply: ply, side: to_string(turn)}
            _ -> %{live?: false, ply: 0, side: "—"}
          end
      end

    assigns = assign(assigns, current: current, now: now)

    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <Nav.rail_label>Games</Nav.rail_label>
        <Nav.rail_link navigate={~p"/games"}>Gameroom</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-4xl px-6 py-6">
          <.walk previous={@previous} following={@following} />

          <header class="mb-4">
            <div class="grid grid-cols-2 gap-2">
              <.side id={@game.white} color={:white} turn={@game.turn} />
              <.side id={@game.black} color={:black} turn={@game.turn} />
            </div>
            <p class="mt-2 flex items-center gap-2 text-xs text-dim">
              <span :if={@now.live?}>{chess_line(@game, @self_id)}</span>
              <span :if={!@now.live?}>
                Looking back at move {@now.ply} of {length(@line) - 1}
              </span>
              <span
                :if={spectating?(@game, @self_id)}
                class="rounded bg-raised px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-faint"
              >
                spectating
              </span>
            </p>
          </header>

          <p
            :if={@game.status == :broken}
            class="mb-3 rounded border border-edge bg-raised px-3 py-2 text-xs text-bad"
          >
            This game does not verify: {@game.error}
          </p>

          <p
            :if={@error}
            role="alert"
            class="mb-3 rounded border border-edge bg-raised px-3 py-2 text-xs text-bad"
          >
            {@error}
          </p>

          <div class="grid gap-6 md:grid-cols-[minmax(0,1fr)_16rem]">
            <div>
              <ChessBoard.board
                board={board_at(@line, @at, @game.board)}
                last={last_move(@line, @at, @game)}
                playable={@at == nil and @movable != []}
                movable={if @at == nil, do: @movable, else: []}
                selected={@selected}
                targets={@targets}
              />

              <.transport
                :if={length(@line) > 1}
                at={@at}
                current={@current}
                last={length(@line) - 1}
                playing?={@playing?}
                status={@game.status}
              />

              <div
                :if={@promos != []}
                class="mt-2 flex items-center gap-2 rounded border border-edge bg-panel px-3 py-2"
              >
                <span class="text-[10px] uppercase tracking-wide text-faint">promote to</span>
                <button
                  :for={move <- @promos}
                  phx-click="promote"
                  phx-value-uci={move.uci}
                  class="rounded border border-edge px-2 py-0.5 text-xs text-muted transition hover:border-focus hover:text-paper"
                >
                  {piece_name(move.promo)}
                </button>
              </div>

              <p :if={@selected != nil} class="mt-2 text-[11px] text-faint">
                {@selected} picked up — click a marked square to play it.
              </p>

              <div :if={@movable != []} class="mt-2 flex justify-end">
                <button
                  phx-click="resign"
                  class="rounded border border-edge px-2 py-1 text-xs text-faint transition hover:border-focus hover:text-bad"
                >
                  resign
                </button>
              </div>

              <dl class="mt-3 grid grid-cols-3 gap-2 text-[11px] text-faint">
                <div>
                  <dt class="uppercase tracking-wide">ply</dt>
                  <dd class="text-muted">{@now.ply}</dd>
                </div>
                <div>
                  <dt class="uppercase tracking-wide">to move</dt>
                  <dd class="text-muted">{@now.side}</dd>
                </div>
                <div>
                  <dt class="uppercase tracking-wide">result</dt>
                  <dd class="text-muted">{result_word(@game)}</dd>
                </div>
              </dl>
            </div>

            <aside class="flex min-w-0 flex-col gap-2">
              <div class="flex items-baseline justify-between gap-2">
                <h3 class="text-[11px] uppercase tracking-wider text-faint">Moves</h3>
                <span
                  :if={@at != nil}
                  class="rounded bg-raised px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-accent"
                >
                  replay
                </span>
              </div>

              <p :if={@pairs == []} class="text-xs italic text-faint">
                No moves played yet.
              </p>

              <p :if={@at != nil} class="text-[11px] leading-relaxed text-faint">
                Showing the position after move {@at} of {length(@line) - 1}. The board is
                read-only while you look back.
              </p>

              <%!-- A game whose chain this node holds only part of cannot be
                   stepped through, and saying so is better than buttons that
                   would do nothing. --%>
              <p :if={fragment(@game)} class="text-[11px] leading-relaxed text-faint">
                This node's log picks this game up at move {div(fragment(@game) + 1, 2)}, so the
                positions before that are not in it. Every move since is listed below.
              </p>

              <%!-- The same courtesy for a game this node has from the start
                   but cannot walk all the way through: the moves it can show
                   are worth stepping through, and the break is worth naming
                   rather than leaving as a transport that stops early for no
                   stated reason. --%>
              <p :if={@line_stop} class="text-[11px] leading-relaxed text-faint">
                <span :if={length(@line) > 1}>
                  The log stops verifying at move {@line_stop.ply}, so the line runs as far as
                  move {length(@line) - 1}.
                </span>
                <span :if={length(@line) <= 1}>
                  This game's first move does not verify here, so there is no line to walk. Its
                  moves are still listed below.
                </span>
              </p>

              <ol
                id="moves"
                phx-hook="FollowMoves"
                class="max-h-[26rem] min-w-0 overflow-y-auto pr-1"
              >
                <li
                  :for={pair <- @pairs}
                  class="grid grid-cols-[1.75rem_minmax(0,1fr)_minmax(0,1fr)] items-center gap-1"
                >
                  <span class="text-right text-[10px] text-faint">{pair.number}.</span>
                  <.ply step={pair.white} current={@current} />
                  <.ply step={pair.black} current={@current} />
                </li>
              </ol>
            </aside>
          </div>
        </div>
      </main>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <Nav.rail_label>Games</Nav.rail_label>
        <Nav.rail_link navigate={~p"/games"}>Gameroom</Nav.rail_link>
      </Nav.rail>

      <main class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-6">
          <.walk previous={@previous} following={@following} />

          <header class="mb-4">
            <div class="flex items-center gap-2">
              <Avatar.face :if={@game.challenger} id={@game.challenger} size={20} />
              <span class="text-sm text-paper">{name(@game.challenger)}</span>
              <span class="text-[10px] uppercase tracking-wide text-faint">vs</span>
              <Avatar.face :if={@game.accepter} id={@game.accepter} size={20} />
              <span class="text-sm text-paper">{name(@game.accepter)}</span>
            </div>
            <p class="mt-1 flex items-center gap-2 text-xs text-dim">
              <span>{turn_line(@game, @self_id)}</span>
              <span
                :if={spectating?(@game, @self_id)}
                class="rounded bg-raised px-1.5 py-0.5 text-[10px] uppercase tracking-wide text-faint"
              >
                spectating
              </span>
            </p>
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

  # Walking the games in the room's order. A game is part of a room full of
  # them, and going back to the list to reach the next one is a detour that
  # loses your place.
  attr :previous, :string, default: nil
  attr :following, :string, default: nil

  defp walk(assigns) do
    ~H"""
    <div class="mb-3 flex items-center gap-3 text-[11px]">
      <.link
        :if={@previous}
        navigate={~p"/games/#{@previous}"}
        class="text-dim transition hover:text-paper"
      >
        ‹ previous game
      </.link>
      <.link
        :if={@following}
        navigate={~p"/games/#{@following}"}
        class="text-dim transition hover:text-paper"
      >
        next game ›
      </.link>
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
      <Avatar.face :if={@id} id={@id} size={24} />
      <div class="min-w-0">
        <div class="text-[10px] uppercase tracking-wide text-faint">{@color}</div>
        <div class="truncate text-sm text-paper">{name(@id)}</div>
      </div>
    </div>
    """
  end

  defp piece_name("q"), do: "queen"
  defp piece_name("r"), do: "rook"
  defp piece_name("b"), do: "bishop"
  defp piece_name("n"), do: "knight"
  defp piece_name(other), do: other

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
