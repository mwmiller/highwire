defmodule HighWireWeb.Components.Heart do
  @moduledoc """
  The like toggle as one obvious control: a raised pill with an
  inline SVG heart — outline when the message isn't liked, filled
  accent with a pressed border when it is — so both the affordance
  and the state read at a glance in either theme, independent of
  how the platform happens to render `❤`.
  """

  use Phoenix.Component

  attr :key, :string, required: true, doc: "the message key this pill likes"
  attr :liked, :boolean, default: false, doc: "whether the viewer has liked it"

  def pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="like"
      phx-value-key={@key}
      aria-pressed={if(@liked, do: "true", else: "false")}
      aria-label={if(@liked, do: "Unlike", else: "Like")}
      title={if(@liked, do: "Unlike", else: "Like")}
      class={[
        "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-1.5 text-xs leading-none transition-colors",
        if(@liked,
          do: "border-accent bg-active font-medium text-accent",
          else: "border-edge bg-raised text-dim hover:border-accent hover:text-accent"
        )
      ]}
    >
      <svg
        class="h-3.5 w-3.5"
        viewBox="0 0 24 24"
        fill={if(@liked, do: "currentColor", else: "none")}
        stroke="currentColor"
        stroke-width="2"
        stroke-linejoin="round"
        aria-hidden="true"
      >
        <path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z" />
      </svg>
    </button>
    """
  end

  @doc """
  The local half of a like click: the three assigns that draw the pill
  and its counts, flipped as the click lands so the heart fills without
  waiting on a payload broadcast. The publish's rebroadcast — or the
  revert on a refusal — reconciles it with the store.
  """
  def toggle(assigns, key) do
    liked? = key in assigns.my_likes

    [
      my_likes: toggle_membership(assigns.my_likes, key, liked?),
      like_counts: toggle_count(assigns.like_counts, key, liked?),
      likes_by: toggle_authors(assigns.likes_by, key, assigns[:self_id], liked?)
    ]
  end

  defp toggle_membership(list, key, true), do: List.delete(list, key)
  defp toggle_membership(list, key, false), do: [key | list]

  defp toggle_count(counts, key, false), do: Map.update(counts, key, 1, &(&1 + 1))

  defp toggle_count(counts, key, true) do
    case Map.get(counts, key, 0) do
      n when n <= 1 -> Map.delete(counts, key)
      n -> Map.put(counts, key, n - 1)
    end
  end

  defp toggle_authors(by, _key, self, _liked?) when not is_binary(self), do: by

  defp toggle_authors(by, key, self, true) do
    case Map.get(by, key, []) |> List.delete(self) do
      [] -> Map.delete(by, key)
      authors -> Map.put(by, key, authors)
    end
  end

  defp toggle_authors(by, key, self, false),
    do: Map.update(by, key, [self], &[self | List.delete(&1, self)])
end
