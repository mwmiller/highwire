defmodule HighWireWeb.Components.Relationship do
  @moduledoc """
  The reader's standing with one feed, as one small mark beside the name.

  A face and a name say who someone is; the mark says what they are to the
  reader. It is a small, dim glyph rather than a word: a byline already
  carries a name, a time and often a label, and phrases repeated down a
  feed would outweigh the names they qualify. The mark has no ring or plate
  around it, so nothing frames it as a control; it sits beside the name,
  smaller and dimmer than the name, and annotates the person instead of
  competing with them. Its title spells it out on hover, and `legend/1`
  names every mark in one place.

  Eight standings are marks of their own — you, each of the three follow
  directions, no connection, a block either way, and a block both ways. The
  rest are combinations the protocol allows and people do not: a follow and
  a block on the same pair, in any of their nine arrangements. They share
  one mark, an interrobang, rather than nine phrases that read like a
  contradiction. Their hover text still says exactly which edges exist, so
  nothing is lost to the shorthand.

  Marks are distinct in shape before they are distinct in colour — a star,
  an arrow, a slash, a bang, a cross, an interrobang, a ring — so they stay
  apart at this size and for a reader who cannot rely on colour. The two
  plainest marks are the ones with nothing to report: a muted dot for the
  reader's own feed, because being yourself is not news, and a faint
  hollow ring for a feed with no edge either way.
  """

  use Phoenix.Component

  attr :standing, :map, default: nil, doc: "a HighWire.SSB.Relations standing"
  attr :class, :any, default: nil

  def badge(assigns) do
    assigns = assign(assigns, :mark, mark(assigns.standing))

    ~H"""
    <span
      :if={@mark.glyph != ""}
      role="img"
      aria-label={@mark.title}
      title={@mark.title}
      class={[
        "inline-flex h-3.5 min-w-3.5 shrink-0 items-center justify-center text-[10px] leading-none",
        @mark.class,
        @class
      ]}
    >
      {@mark.glyph}
    </span>
    """
  end

  @doc """
  Every mark, in one place — the eight standings a person can be in, then
  the one that stands for the nine a protocol can. Collapsed by default, so
  the rail keeps its room for people.
  """
  def legend(assigns) do
    assigns =
      assign(assigns, :marks, [
        mark(%{self?: true}),
        mark(%{follows?: true, follows_you?: true}),
        mark(%{follows?: true}),
        mark(%{follows_you?: true}),
        mark(%{}),
        mark(%{blocked?: true}),
        mark(%{blocks_you?: true}),
        mark(%{blocked?: true, blocks_you?: true}),
        mark(%{follows?: true, blocked?: true})
      ])

    ~H"""
    <details id="relationship-legend" class="px-4 pb-4">
      <summary class="cursor-pointer text-[11px] uppercase tracking-wider text-faint transition hover:text-paper">
        Relationships
      </summary>
      <ul class="mt-2 space-y-1.5 text-xs text-faint">
        <li :for={mark <- @marks} class="flex items-start gap-2" title={mark.title}>
          <span class="flex h-4 w-5 shrink-0 items-center justify-center">
            <span
              :if={mark.glyph != ""}
              class={[
                "inline-flex h-3.5 min-w-3.5 items-center justify-center text-[10px] leading-none",
                mark.class
              ]}
            >
              {mark.glyph}
            </span>
          </span>
          <span class="min-w-0">{mark.meaning}</span>
        </li>
      </ul>
      <p class="mt-2 text-[11px] leading-snug text-faint">
        Hover a mark for the exact edges.
      </p>
    </details>
    """
  end

  defp mark(%{self?: true}),
    do: %{
      meaning: "you",
      glyph: "•",
      title: "This is you",
      class: "text-faint/50"
    }

  defp mark(standing) when is_map(standing) do
    standing = {
      Map.get(standing, :follows?, false),
      Map.get(standing, :follows_you?, false),
      Map.get(standing, :blocked?, false),
      Map.get(standing, :blocks_you?, false)
    }

    mark(standing)
  end

  defp mark({follows?, follows_you?, blocked?, blocks_you?})
       when (follows? or follows_you?) and (blocked? or blocks_you?) do
    complicated(
      follows?: follows?,
      follows_you?: follows_you?,
      blocked?: blocked?,
      blocks_you?: blocks_you?
    )
  end

  defp mark({true, true, _, _}), do: friend()
  defp mark({true, _, _, _}), do: fan()
  defp mark({_, true, _, _}), do: follower()
  defp mark({_, _, true, true}), do: both_blocked()
  defp mark({_, _, true, _}), do: blocked()
  defp mark({_, _, _, true}), do: blocks_you()
  defp mark({_, _, _, _}), do: stranger()
  defp mark(_standing), do: stranger()

  defp friend,
    do: %{
      meaning: "you follow each other",
      glyph: "⇄",
      title: "You follow each other",
      class: "text-accent/60"
    }

  defp fan,
    do: %{
      meaning: "you follow them",
      glyph: "★",
      title: "You follow them; they do not follow you",
      class: "text-info/60"
    }

  defp follower,
    do: %{
      meaning: "they follow you",
      glyph: "←",
      title: "They follow you; you do not follow them",
      class: "text-ok/60"
    }

  defp stranger,
    do: %{
      meaning: "no connection",
      glyph: "○",
      title: "No connection either way",
      class: "text-faint/50"
    }

  defp blocked,
    do: %{
      meaning: "you block them",
      glyph: "⊘",
      title: "You block them",
      class: "text-bad/60"
    }

  defp blocks_you,
    do: %{
      meaning: "they block you",
      glyph: "!",
      title: "They block you",
      class: "text-warn/60"
    }

  defp both_blocked,
    do: %{
      meaning: "blocked both ways",
      glyph: "✕",
      title: "Blocked both ways: you block them and they block you",
      class: "text-bad/70"
    }

  # The nine arrangements of a follow with a block. Their hover names the
  # edges exactly, so the one mark loses no information.
  defp complicated(standing) do
    %{
      meaning: "it's complicated",
      glyph: "‽",
      title: "It's complicated: " <> edges(standing),
      class: "text-warn/70"
    }
  end

  defp edges(standing) do
    standing
    |> Keyword.take([:follows?, :follows_you?, :blocked?, :blocks_you?])
    |> Enum.filter(fn {_edge, present?} -> present? end)
    |> Enum.map_join("; ", fn {edge, _} -> edge_phrase(edge) end)
  end

  defp edge_phrase(:follows?), do: "you follow them"
  defp edge_phrase(:follows_you?), do: "they follow you"
  defp edge_phrase(:blocked?), do: "you block them"
  defp edge_phrase(:blocks_you?), do: "they block you"
end
