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
      <Avatar.face id={id} profiles={@profiles} rev={@rev} size={@size} />
    </span>
    """
  end
end
