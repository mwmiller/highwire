defmodule HighWire.Chess.Kibitz do
  @moduledoc """
  The talk about a game, from anyone watching it.

  The network's chess protocol has one message for this: `chess_chat`, whose
  `root` is the key of the message that opened the game and whose `msg` is
  what was said. It carries no seat and no move, so a kibitz needs no
  membership of the game — any feed can publish one, and any node that holds
  the message can read it.

  A kibitz is filed under that root, apart from the game. A game's fold is
  decided by its players' moves, and a comment is not an entry in it, so
  nothing here can change a game's position or turn it broken.
  """

  use GenServer

  require Logger

  alias HighWire.Chess.Legacy
  alias HighWire.SSB.Identities
  alias HighWire.Timeline
  alias Phoenix.PubSub

  # A kibitz is a feed message, so it is kept to the length of a post rather
  # than the length of a game note.
  @max_chars 2_000

  @table :highwire_chess_kibitz
  @topic "chess_kibitz"

  @doc "Start the store."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The PubSub topic the store announces new kibitz on."
  def topic, do: @topic

  @doc "Whether content is a kibitz: a `chess_chat` naming a game and saying something."
  @spec message?(term()) :: boolean()
  def message?(%{"type" => "chess_chat", "root" => root, "msg" => msg})
      when is_binary(root) and is_binary(msg),
      do: true

  def message?(_), do: false

  @doc """
  Whether a game's page shows its kibitz to this reader.

  A spectator sees the talk about the game; a player sees it once the game is
  over. That is the protocol's own rule — the observers' chat is not shown to
  the players while the game is in play, so that a comment cannot advise the
  side to move.
  """
  @spec visible?(map(), binary() | nil) :: boolean()
  def visible?(game, self_id) do
    players =
      [:challenger, :accepter, :white, :black]
      |> Enum.map(&Map.get(game, &1))
      |> Enum.reject(&is_nil/1)

    self_id not in players or Map.get(game, :status) in [:finished, :withdrawn]
  end

  @doc """
  Publish a kibitz about `game` and file it here, so the page that sent it
  reads it back straight away.

  Options: `:publish` (a `content -> {:ok, key}` function; tests swap it for
  a stub) and `:author` (tests, and a page with no active identity).
  """
  @spec post(map(), binary(), keyword()) :: {:ok, binary()} | {:error, term()}
  def post(game, text, opts \\ []) do
    with {:ok, root} <- root(game),
         {:ok, msg} <- body(text),
         content = %{"type" => "chess_chat", "root" => root, "msg" => msg},
         {:ok, key} <- publish(content, opts) do
      ingest(%{"key" => key, "value" => %{"author" => author(opts), "content" => content}})
      {:ok, key}
    end
  end

  @doc "One game's kibitz, oldest first."
  @spec thread(map() | nil) :: [map()]
  def thread(game) do
    with {:ok, root} <- root(game),
         %{messages: messages} <- lookup(root) do
      Enum.reverse(messages)
    else
      _ -> []
    end
  end

  @doc "File an envelope without waiting for the write."
  @spec observe(map()) :: :ok
  def observe(msg) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:ingest, msg})
    end
  end

  @doc "File an envelope and wait for the write."
  @spec ingest(map()) :: :ok | :ignored | :seen
  def ingest(msg), do: GenServer.call(__MODULE__, {:ingest, msg}, 10_000)

  @doc "Forget everything. Tests, and a settings page if it ever needs it."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear, 5_000)

  # -- server ------------------------------------------------------------

  @impl true
  def init(_opts) do
    path = dets_path()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(@table, file: String.to_charlist(path), type: :set, repair: true) do
      {:ok, @table} ->
        {:ok, :open}

      {:error, reason} ->
        Logger.warning("chess kibitz store: cannot open #{path}: #{inspect(reason)}")
        {:ok, :closed}
    end
  end

  @impl true
  def handle_cast({:ingest, msg}, state) do
    record(msg)
    {:noreply, state}
  end

  @impl true
  def handle_call({:ingest, msg}, _from, state), do: {:reply, record(msg), state}

  def handle_call(:clear, _from, :closed), do: {:reply, :ok, :closed}

  def handle_call(:clear, _from, :open) do
    :dets.delete_all_objects(@table)
    {:reply, :ok, :open}
  end

  @impl true
  def terminate(_reason, :closed), do: :ok

  def terminate(_reason, :open) do
    :dets.close(@table)
    :ok
  end

  # -- filing ------------------------------------------------------------

  defp record(%{"key" => key, "value" => %{"author" => author, "content" => content}})
       when is_binary(key) and is_binary(author) do
    if message?(content),
      do: append(content["root"], key, author, content["msg"]),
      else: :ignored
  rescue
    ArgumentError -> :ignored
  end

  defp record(_msg), do: :ignored

  # One message is one kibitz, however many times the network delivers it.
  defp append(root, key, author, text) do
    row = lookup(root) || %{messages: []}

    if Enum.any?(row.messages, &(&1.key == key)) do
      :seen
    else
      messages = [%{key: key, author: author, text: text} | row.messages]
      :dets.insert(@table, {{:game, root}, %{messages: messages}})
      PubSub.broadcast(HighWire.PubSub, @topic, :chess_kibitz)
      :ok
    end
  end

  defp lookup(root) do
    case :dets.lookup(@table, {:game, root}) do
      [{_key, row}] -> row
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # -- writing -----------------------------------------------------------

  # The key of the game's opening message: its own challenge here, or the
  # invite key its id was derived from when the game came off the network.
  defp root(%{challenge_key: key}) when is_binary(key), do: {:ok, key}

  defp root(%{game_id: game_id}) do
    case Legacy.root_key(game_id) do
      nil -> {:error, :no_game_root}
      key -> {:ok, key}
    end
  end

  defp root(_game), do: {:error, :no_game_root}

  defp body(text) when is_binary(text) do
    case String.trim(text) do
      "" ->
        {:error, :empty}

      body ->
        if String.length(body) > @max_chars, do: {:error, :too_long}, else: {:ok, body}
    end
  end

  defp body(_text), do: {:error, :empty}

  # The publisher is swappable for the same reason the game log's is: tests
  # read what would have gone to the network without an engine behind them.
  defp publish(content, opts) do
    publisher =
      Keyword.get(opts, :publish) ||
        Application.get_env(:highwire, :game_publisher, &Timeline.publish_content/1)

    publisher.(content)
  end

  defp author(opts), do: Keyword.get(opts, :author) || Identities.active_id()

  defp dets_path, do: Path.join(HighWire.ssb_dir(), "chess_kibitz.dets")
end
