defmodule HighWireWeb.Components.Board do
  @moduledoc """
  A read-only backgammon board.

  The position a fold produces is actor-relative: point 1 is the mover's home
  and positive counts are the mover's checkers. This draws it that way, with
  the mover at the bottom, so the same fold renders sensibly whether the
  reader is one of the players or a spectator. The gameroom never needs to
  know whose side it is on; it shows the position from the side that has to
  move, and says so.

  Dots are capped at five per point with a count beside them: a point holding
  eight checkers should read at a glance rather than as a column of dots.
  """

  use Phoenix.Component

  alias HighWire.Backgammon.Engine

  @cap 5

  attr :position, :any, required: true, doc: "an Engine position, actor-relative"
  attr :compact, :boolean, default: false

  attr :playable, :boolean,
    default: false,
    doc: "whether the mover may pick a point up here"

  attr :movable, :list, default: [], doc: "points holding a checker that can move"
  attr :selected, :any, default: nil, doc: "the point picked up, or :bar"
  attr :targets, :list, default: [], doc: "points the picked-up checker can reach, or :off"

  def board(assigns) do
    pos = assigns.position

    states =
      Map.new(1..24, fn p -> {p, point_state(assigns, p)} end)
      |> Map.put(:bar, point_state(assigns, :bar))
      |> Map.put(:off, point_state(assigns, :off))

    # With a checker in hand, the only things worth clicking are where it can
    # go and the checker itself (to put it back). Without one, the points that
    # can be picked up are the ones that respond.
    actionable =
      case assigns.selected do
        nil -> MapSet.new(assigns.movable)
        selected -> MapSet.new([selected | assigns.targets])
      end

    assigns =
      assign(assigns,
        off: pos.off,
        opp_off: pos.opp_off,
        bar: pos.bar,
        opp_bar: pos.opp_bar,
        states: states,
        actionable: actionable
      )

    ~H"""
    <div class="rounded border border-edge bg-panel p-2">
      <div class="grid grid-cols-12 gap-1">
        <.point
          :for={p <- 13..24}
          p={p}
          count={Engine.count(@position, p)}
          top?
          compact={@compact}
          playable={@playable and MapSet.member?(@actionable, p)}
          state={Map.get(@states, p, :quiet)}
        />
      </div>

      <div class="my-1.5 flex items-center justify-between gap-2 border-y border-edge-soft py-1 text-[10px] text-faint">
        <span class="flex items-center gap-1" title="checkers on the bar, then borne off">
          <.special
            name={:bar}
            label="bar"
            count={@bar}
            playable={@playable and MapSet.member?(@actionable, :bar)}
            state={@states.bar}
          />
          <span>·</span>
          <.special
            name={:off}
            label="off"
            count={@off}
            playable={@playable and MapSet.member?(@actionable, :off)}
            state={@states.off}
          />
        </span>
        <span class="uppercase tracking-wider">mover's view</span>
        <span title="opponent on the bar, then borne off">bar {@opp_bar} · off {@opp_off}</span>
      </div>

      <div class="grid grid-cols-12 gap-1">
        <.point
          :for={p <- 12..1//-1}
          p={p}
          count={Engine.count(@position, p)}
          compact={@compact}
          playable={@playable and MapSet.member?(@actionable, p)}
          state={Map.get(@states, p, :quiet)}
        />
      </div>
    </div>
    """
  end

  # A point is quiet until it is asked something: the ones holding a checker
  # that can move are marked, the pick-up is filled, and its destinations are
  # outlined. Nothing else about the board changes, because the position is
  # the thing being read.
  defp point_state(%{selected: selected, targets: targets, movable: movable}, p) do
    cond do
      p == selected -> :selected
      p in targets -> :target
      p in movable -> :movable
      true -> :quiet
    end
  end

  attr :p, :integer, required: true
  attr :count, :integer, required: true
  attr :top?, :boolean, default: false
  attr :compact, :boolean, default: false
  attr :playable, :boolean, default: false
  attr :state, :atom, default: :quiet

  defp point(assigns) do
    # Only the points that would do something are controls: everything else
    # stays a piece of the picture, so the board does not read as two dozen
    # buttons with one live one.
    assigns =
      assign(assigns,
        dots: min(abs(assigns.count), @cap),
        extra: max(abs(assigns.count) - @cap, 0),
        own?: assigns.count > 0,
        actionable: assigns.playable
      )

    ~H"""
    <button
      type="button"
      phx-click={if @actionable, do: "point"}
      phx-value-p={@p}
      disabled={not @actionable}
      data-point={@p}
      data-state={@state}
      class={[
        "flex flex-col items-center gap-0.5 rounded-sm bg-raised px-1 py-1 transition",
        @compact && "h-10",
        !@compact && "h-14",
        @top? && "justify-start",
        !@top? && "justify-end",
        @actionable && "cursor-pointer hover:bg-raised/70",
        @state == :movable && "ring-1 ring-inset ring-edge",
        @state == :selected && "bg-accent/20 ring-1 ring-inset ring-accent/60",
        @state == :target && "ring-1 ring-inset ring-accent/50"
      ]}
    >
      <span :if={!@top?} class="text-[9px] leading-none text-faint">{@p}</span>

      <span
        :for={_ <- 1..@dots//1}
        class={["h-2 w-2 rounded-full", @own? && "bg-paper", !@own? && "bg-dot"]}
      />
      <span :if={@extra > 0} class="text-[9px] font-medium text-dim">{@extra}</span>

      <span :if={@top?} class="text-[9px] leading-none text-faint">{@p}</span>
    </button>
    """
  end

  attr :name, :atom, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true
  attr :playable, :boolean, default: false
  attr :state, :atom, default: :quiet

  # The bar and the off-tray are places a checker moves between, so a turn
  # that starts on the bar or ends off the board is played the way every
  # other move is: point at where the checker is, then where it goes.
  defp special(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={if @playable, do: "point"}
      phx-value-p={@name}
      disabled={not @playable}
      data-point={@name}
      data-state={@state}
      class={[
        "rounded px-1 py-0.5 transition",
        @playable && "cursor-pointer text-muted hover:text-paper",
        @state == :selected && "bg-accent/20 text-accent",
        @state == :target && "text-accent ring-1 ring-inset ring-accent/50"
      ]}
    >
      {@label} {@count}
    </button>
    """
  end
end
