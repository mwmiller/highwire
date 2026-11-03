defmodule HighWire.Chess.Reader do
  @moduledoc """
  Turn an SSB envelope into the fold's entry shape.

  The author is on the envelope and the game id is hex, so this is the one
  place that difference lives; everything downstream sees plain maps.

  `read/1` returns `{:ok, %{…}}` for a message in the namespace, `:error` for
  anything else — including a message that looks like ours but carries no
  usable game id, which is the shape a forged or truncating client produces.
  """

  alias HighWire.Chess.{Engine, Game}

  @type read :: %{
          key: binary() | nil,
          author: binary(),
          game_id: binary(),
          type: String.t(),
          content: map(),
          entry: map() | nil
        }

  @doc "Read one envelope into the fold's entry shape."
  @spec read(term()) :: {:ok, read()} | :error
  def read(%{"value" => %{"content" => content, "author" => author}} = msg)
      when is_binary(author) and is_map(content) do
    with name when is_binary(name) <- Game.local_type(content["type"]),
         game_id when is_binary(game_id) <- content["game_id"],
         true <- Game.id?(game_id) do
      {:ok,
       %{
         key: msg["key"],
         author: author,
         game_id: game_id,
         type: name,
         content: content,
         entry: entry(name, content, author)
       }}
    else
      _ -> :error
    end
  end

  def read(_), do: :error

  # Only moves and resignations fold; a challenge, accept or withdrawal is
  # read from the game's row, not replayed.
  defp entry("move", c, author) do
    with ply when is_integer(ply) and ply > 0 <- c["ply"],
         uci when is_binary(uci) <- c["uci"],
         true <- legal_shape?(uci) do
      %{
        "type" => "move",
        "player" => author,
        "ply" => ply,
        "uci" => uci,
        "note" => c["note"]
      }
    else
      _ -> nil
    end
  end

  defp entry("resign", c, author) do
    case c["ply"] do
      ply when is_integer(ply) and ply > 0 ->
        %{"type" => "resign", "player" => author, "ply" => ply, "note" => c["note"]}

      _ ->
        nil
    end
  end

  defp entry(_name, _content, _author), do: nil

  # The shape only: the board decides whether the move is legal, and the
  # fold refuses the ones it is not.
  defp legal_shape?(uci) when byte_size(uci) in [4, 5] do
    <<from::binary-size(2), to::binary-size(2), rest::binary>> = uci

    Engine.square?(from) and Engine.square?(to) and
      (rest == "" or rest in ["q", "r", "b", "n"])
  end

  defp legal_shape?(_), do: false
end
