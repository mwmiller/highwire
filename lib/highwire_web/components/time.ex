defmodule HighWireWeb.Components.Time do
  @moduledoc """
  Relative-time labels shared by every live view.

  "just now" up to a week, then an absolute date — one implementation so
  the timeline, thread, profile, and network pages never drift apart.

  age/1 renders the label inside a `<time>` stamped with `data-ts`; a
  single client interval rewrites the text from that stamp, so the
  labels stay accurate without periodic server re-renders.
  """

  use Phoenix.Component

  def rel_time(nil), do: "never"
  def rel_time(0), do: "never"

  def rel_time(t) when is_number(t) do
    diff = System.system_time(:millisecond) - t

    cond do
      diff < 60_000 -> "just now"
      diff < 3_600_000 -> "#{div(diff, 60_000)}m ago"
      diff < 86_400_000 -> "#{div(diff, 3_600_000)}h ago"
      diff < 604_800_000 -> "#{div(diff, 86_400_000)}d ago"
      true -> t |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%b %d, %Y")
    end
  end

  @doc """
  A relative-time label the browser keeps current: rel_time/1 supplies
  the initial text and `data-ts` the stamp the client-side interval
  recomputes it from.
  """
  # nil renders "never" with no data-ts at all; 0 (also "never") gets
  # no stamp either, so the client-side ager leaves it alone.
  attr :ts, :integer, default: nil

  def age(assigns) do
    ~H"""
    <time datetime={iso8601(@ts)} data-ts={stamp(@ts)}>{rel_time(@ts)}</time>
    """
  end

  defp stamp(nil), do: nil
  defp stamp(0), do: nil
  defp stamp(t), do: t

  defp iso8601(t) when is_integer(t) and t > 0,
    do: t |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  defp iso8601(_), do: nil
end
