defmodule HighWireWeb.Components.Time do
  @moduledoc """
  Relative-time labels shared by every live view.

  "just now" up to a week, then an absolute date — one implementation so
  the timeline, thread, profile, and network pages never drift apart.
  """

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
end
