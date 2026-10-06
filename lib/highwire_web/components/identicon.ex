defmodule HighWireWeb.Components.Identicon do
  @moduledoc """
  Deterministic SSB-style identicon: a 5×5 mirrored cell grid tinted from
  the sha256 of a feed id, the same visual language Patchwork/hashable
  use for avatars. Pure SVG, no JS, no external service.
  """

  use Phoenix.Component

  attr :id, :string, required: true
  attr :size, :integer, default: 40
  attr :class, :string, default: ""

  def icon(assigns) do
    hash = :crypto.hash(:sha256, assigns.id)
    hue = hash |> binary_part(0, 2) |> :binary.decode_unsigned() |> rem(360)

    assigns =
      assigns
      |> assign(:hue, hue)
      |> assign(:cells, cells(hash))

    ~H"""
    <svg
      viewBox="0 0 5 5"
      width={@size}
      height={@size}
      class={["rounded-[3px] shrink-0", @class]}
      aria-hidden="true"
    >
      <rect width="5" height="5" fill={"hsl(#{@hue}, 26%, 15%)"} />
      <g fill={"hsl(#{@hue}, 62%, 52%)"}>
        <rect :for={{x, y} <- @cells} x={x} y={y} width="1" height="1" />
      </g>
    </svg>
    """
  end

  # 15 bits from the digest lay out a 5×3 block; columns 0..1 mirror to
  # columns 4..3, column 2 stays as the axis.
  defp cells(hash) do
    for row <- 0..4, col <- 0..2, bit?(hash, row, col) do
      {col, row}
    end
    |> Enum.flat_map(fn
      {2, row} -> [{2, row}]
      {col, row} -> [{col, row}, {4 - col, row}]
    end)
  end

  defp bit?(hash, row, col) do
    hash
    |> :binary.at(3 + row * 3 + col)
    |> rem(2)
    |> Kernel.==(1)
  end
end
