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

  def board(assigns) do
    pos = assigns.position

    assigns =
      assign(assigns,
        off: pos.off,
        opp_off: pos.opp_off,
        bar: pos.bar,
        opp_bar: pos.opp_bar
      )

    ~H"""
    <div class="rounded border border-edge bg-panel p-2">
      <div class="grid grid-cols-12 gap-1">
        <.point :for={p <- 13..24} p={p} count={Engine.count(@position, p)} top? compact={@compact} />
      </div>

      <div class="my-1.5 flex items-center justify-between border-y border-edge-soft py-1 text-[10px] text-faint">
        <span title="checkers on the bar, then borne off">bar {@bar} · off {@off}</span>
        <span class="uppercase tracking-wider">mover's view</span>
        <span title="opponent on the bar, then borne off">bar {@opp_bar} · off {@opp_off}</span>
      </div>

      <div class="grid grid-cols-12 gap-1">
        <.point :for={p <- 12..1//-1} p={p} count={Engine.count(@position, p)} compact={@compact} />
      </div>
    </div>
    """
  end

  attr :p, :integer, required: true
  attr :count, :integer, required: true
  attr :top?, :boolean, default: false
  attr :compact, :boolean, default: false

  defp point(assigns) do
    assigns =
      assign(assigns,
        dots: min(abs(assigns.count), @cap),
        extra: max(abs(assigns.count) - @cap, 0),
        own?: assigns.count > 0
      )

    ~H"""
    <div class={[
      "flex flex-col items-center gap-0.5 rounded-sm bg-raised px-1 py-1",
      @compact && "h-10",
      !@compact && "h-14",
      @top? && "justify-start",
      !@top? && "justify-end"
    ]}>
      <span :if={!@top?} class="text-[9px] leading-none text-faint">{@p}</span>

      <span
        :for={_ <- 1..@dots//1}
        class={["h-2 w-2 rounded-full", @own? && "bg-paper", !@own? && "bg-dot"]}
      />
      <span :if={@extra > 0} class="text-[9px] font-medium text-dim">{@extra}</span>

      <span :if={@top?} class="text-[9px] leading-none text-faint">{@p}</span>
    </div>
    """
  end
end
