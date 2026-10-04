defmodule HighWire.SSB.Keys do
  @moduledoc """
  Reads an ssb-keys `secret` file — the format Poncho Wonky, Patchwork,
  and erlbutt all share: comment lines (`#`, `%`) around one JSON object
  with `public` / `private` / `id` base64 fields suffixed `.ed25519`.

  This is a reader only: HighWire never writes or rotates keys.
  """

  defstruct [:id, :public, :secret]

  @type t :: %__MODULE__{id: String.t(), public: binary(), secret: binary()}

  @spec load!(Path.t()) :: t()
  def load!(path) do
    json =
      path
      |> File.stream!()
      |> Stream.map(&String.trim_leading/1)
      |> Stream.reject(&(String.trim(&1) == "" or String.starts_with?(&1, "#") or String.starts_with?(&1, "%")))
      |> Enum.join()
      |> Jason.decode!()

    %__MODULE__{
      id: json["id"],
      public: decode_field!(json["public"]),
      secret: decode_field!(json["private"])
    }
  end

  @spec id_to_public(String.t()) :: binary()
  def id_to_public("@" <> rest), do: decode_field!(rest)

  defp decode_field!(field) do
    field
    |> String.replace_suffix(".ed25519", "")
    |> Base.decode64!(padding: true)
  end
end
