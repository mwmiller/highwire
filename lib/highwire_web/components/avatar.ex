defmodule HighWireWeb.Components.Avatar do
  @moduledoc """
  Patchwork/Poncho-style avatar tile: the feed's image as a cover-fit
  `<img>` over a `color-hash(id)` background, 3px rounded corners and a
  1px frame — the same geometry and colors Poncho Wonky renders
  (`HighWire.Avatar` is a pixel-exact port of color-hash v1.0.3).

  Resolution order: the feed's blob (`/blob/<hex>`, which serves a
  neutral missing-blob placeholder while the bytes are not local yet —
  deliberately not an identicon) → for feeds with no avatar image at
  all, the Excon `:framed` identicon keyed by the feed id
  (`/identicon/<hex>`), which is stable for as long as the identity
  is. The color tile underneath is what shows while the image loads —
  and what remains if it fails.
  """

  use Phoenix.Component

  alias HighWire.Avatar, as: Ident

  attr :id, :string, required: true
  attr :size, :integer, default: 40
  attr :image, :string, default: nil, doc: "the blob ref (&…sha256), if any"
  attr :rev, :integer, default: nil, doc: "blob_rev — appends ?v=<n> when positive"
  attr :class, :any, default: nil, doc: "extra classes for the tile"

  def avatar(assigns) do
    ~H"""
    <div
      class={[
        "relative shrink-0 overflow-hidden rounded-[3px] border border-edge",
        @class
      ]}
      style={"width:#{@size}px;height:#{@size}px;background-color:#{Ident.hex(@id)}"}
    >
      <img
        src={Ident.avatar_src(@id, @image) <> Ident.rev_query(@rev)}
        alt=""
        loading="lazy"
        class="h-full w-full object-cover"
        onerror="this.remove()"
      />
    </div>
    """
  end

  @doc """
  The tile for one person, on its way to that person's profile.

  Every face in the app answers the same way — a face is a person, so
  it opens their page — which is what makes a tile worth recognising
  rather than decoration. The tile carries the name as its title and
  its accessible label, so a face says who it is on hover and to a
  screen reader even where the byline beside it does not.

  An id that cannot have a profile page ("unknown", from a row
  half-built out of an engine answer) keeps its tile unlinked rather
  than pointing at a page that cannot name it.
  """

  attr :id, :string, required: true, doc: "the feed id the tile stands for"

  attr :profiles, :map,
    default: %{},
    doc: "the payload's id → profile map (or a ctx carrying one)"

  attr :size, :integer, default: 40
  attr :rev, :any, default: nil, doc: "blob_rev — appends ?v=<n> when positive"
  attr :class, :any, default: nil, doc: "extra classes for the tile"

  def face(assigns) do
    ~H"""
    <.link
      :if={href = profile_href(@id)}
      navigate={href}
      title={Ident.display_name(@id, @profiles)}
      aria-label={Ident.display_name(@id, @profiles)}
      class="block hover:opacity-80"
    >
      <.avatar
        id={@id}
        size={@size}
        image={image_of(@id, @profiles)}
        rev={@rev}
        class={@class}
      />
    </.link>
    <.avatar
      :if={profile_href(@id) == nil}
      id={@id}
      size={@size}
      image={image_of(@id, @profiles)}
      rev={@rev}
      class={@class}
    />
    """
  end

  # Only a feed id has a profile page. Anything else ("unknown") keeps
  # its tile unlinked rather than pointing at a page that cannot name it.
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
