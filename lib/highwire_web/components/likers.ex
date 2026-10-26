defmodule HighWireWeb.Components.Likers do
  @moduledoc """
  Who liked a message, drawn as their avatars in a row beside the
  heart.

  The list *is* the count — Patchwork and Poncho Wonky show the faces
  rather than a number — so every voter gets a tile and none fold into
  a "+N" that hides the people behind it. Each tile is a link to that
  profile: a face in a list is an invitation to look the person over.
  """

  use Phoenix.Component

  alias HighWire.Avatar, as: Ident
  alias HighWireWeb.Components.Avatar

  attr :ids, :list, default: [], doc: "the voters, newest voter first"

  attr :profiles, :map,
    default: %{},
    doc: "the payload's id → profile map (or a ctx carrying one)"

  attr :rev, :any, default: nil, doc: "blob_rev — appends ?v=<n> to the tiles"
  attr :size, :integer, default: 16, doc: "tile size in pixels"

  def chips(assigns) do
    ~H"""
    <span :for={id <- @ids} title={Ident.display_name(id, @profiles)} class="inline-flex">
      <.link
        :if={href = profile_href(id)}
        navigate={href}
        aria-label={Ident.display_name(id, @profiles)}
        class="block hover:opacity-80"
      >
        <Avatar.avatar id={id} size={@size} image={image_of(id, @profiles)} rev={@rev} />
      </.link>
      <Avatar.avatar
        :if={profile_href(id) == nil}
        id={id}
        size={@size}
        image={image_of(id, @profiles)}
        rev={@rev}
      />
    </span>
    """
  end

  # Only a feed id has a profile page. Anything else ("unknown", from a
  # row half-built out of an engine answer) keeps its tile unlinked
  # rather than pointing at a page that cannot name it.
  defp profile_href("@" <> _ = id), do: "/profile?id=" <> URI.encode_www_form(id)
  defp profile_href(_id), do: nil

  defp image_of(id, %{profiles: profiles}), do: image_of(id, profiles)

  defp image_of(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{image: image}} -> image
      _ -> nil
    end
  end

  defp image_of(_id, _profiles), do: nil
end
