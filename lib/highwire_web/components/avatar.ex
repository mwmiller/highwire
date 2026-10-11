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
end
