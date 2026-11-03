defmodule HighWire.Backgammon.Reader do
  @moduledoc """
  Turn an SSB envelope into the fold's entry shape.

  The fold was written against Catenary's entries, where every entry carried
  its own `player` and the game id as raw bytes. In SSB the author is on the
  envelope and the id is hex, so this module is the one place that difference
  lives: everything downstream sees the same maps the fold always took.

  `read/1` returns `{:ok, %{…}}` for a message in the namespace, `:error` for
  anything else — including a message that looks like ours but has no usable
  game id, which is the shape a forged or truncating client produces.
  """

  alias HighWire.Backgammon.Game

  @type read :: %{
          key: binary() | nil,
          author: binary(),
          game_id: binary(),
          type: String.t(),
          root: binary() | nil,
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
         root: content["root"],
         content: content,
         entry: entry(name, content, author)
       }}
    else
      _ -> :error
    end
  end

  def read(_), do: :error

  # Only the three entry types the fold consumes get an entry; challenge,
  # accept and withdraw are read from the game row, not folded as moves.
  defp entry("roll", c, author) do
    %{
      "type" => "roll",
      "player" => author,
      "round" => c["round"],
      "r_cur" => c["r_cur"],
      "r_next" => c["r_next"],
      "reveals" => c["reveals"],
      "note" => c["note"] || ""
    }
  end

  defp entry("turn", c, author) do
    %{
      "type" => "turn",
      "player" => author,
      "turn" => c["turn"],
      "roll" => c["roll"],
      "moves" => c["moves"],
      "r_cur" => c["r_cur"],
      "r_next" => c["r_next"],
      "reveals" => c["reveals"],
      "note" => c["note"] || ""
    }
  end

  defp entry("resign", c, author) do
    %{
      "type" => "resign",
      "player" => author,
      "turn" => c["turn"],
      "note" => c["note"] || ""
    }
  end

  defp entry(_name, _content, _author), do: nil
end
