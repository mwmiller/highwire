defmodule HighWire.SSB.Profile do
  @moduledoc """
  What followers see — each feed's display name and avatar image — as
  a small ETS read model beside the Timeline that resolves it.

  Every payload broadcast carries `%{id => %{name, image}}` for the
  feeds in that window, but a payload belongs to a moment: the next
  finalize evicts ids the window no longer covers, and the rail is a
  function component with no process to ask. So the Timeline shadows
  each payload here before it broadcasts, and entries only ever
  accumulate — the union of everything the engine has ever answered —
  which is the set the identity page needs to show its own feeds
  whether or not they still hold a window seat.

  The payload owns the image; an `about` owns the name and the bio. The
  engine resolves a name for every feed it can, but that answer may be a
  third party's label for the feed rather than the feed's own word for
  itself, so it is never applied here. A name is written only from an
  about message the feed itself (or we) published, which is why
  `put_all/1` leaves the name alone and `put_about/2` writes it.

  A read degrades to nil: a feed whose own about has not been read has
  no name, and `HighWire.Avatar.display_name/2` then falls back to the
  short id — what that feed shows its followers anyway.
  """

  alias HighWire.Avatar, as: Ident

  @table __MODULE__

  @type profile :: %{name: binary() | nil, image: binary() | nil, description: binary() | nil}
  @type profiles :: %{optional(binary()) => profile()}

  @doc """
  Create the table when it is not up yet. The Timeline calls this from
  its init so the writer owns the table; writes also self-heal, so a
  read model whose table is gone rebuilds on the next payload.
  """
  @spec create() :: :ok
  def create do
    ensure_table()
    :ok
  end

  @doc """
  Store a payload's profile images (id → `%{name, image}`), merging over
  what is already known. Entries are never dropped — a later payload
  that no longer covers a feed must not take its image away from the
  pages still showing it.

  The name the payload carries is not written: it is whatever the
  engine's profile call resolved, which may be a third party's label.
  Names come from the about drain through `put_about/2`.
  """
  @spec put_all(map()) :: :ok
  def put_all(profiles) when is_map(profiles) do
    entries =
      Enum.map(profiles, fn
        {id, profile} when is_map(profile) ->
          {id, payload_entry(get(id), profile)}

        {id, _other} ->
          {id, payload_entry(get(id), %{})}
      end)

    true = :ets.insert(ensure_table(), entries)
    :ok
  end

  @doc """
  Fold one feed's `about` message into its entry: the display name and
  the bio the profile page shows. The store-wide about drain already
  reads every about message, but only the feed's own word for itself
  (or ours about it) arrives here — that is what makes this the one
  source of names. The profile page then reads a bio from the read
  model instead of waiting on a sidecar round-trip through the Timeline.
  """
  @spec put_about(binary(), map()) :: :ok
  def put_about(id, fields) when is_binary(id) and is_map(fields) do
    true = :ets.insert(ensure_table(), {id, about_entry(get(id), fields)})
    :ok
  end

  @doc "Record the blob revision avatar URLs cache-bust on."
  @spec put_rev(integer()) :: :ok
  def put_rev(rev) when is_integer(rev) do
    true = :ets.insert(ensure_table(), {:rev, rev})
    :ok
  end

  @doc "One feed's presentation — nil while nothing has resolved it."
  @spec get(binary()) :: profile() | nil
  def get(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, profile}] -> normalize(profile)
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  # A payload speaks for the window it covers: its image is the answer,
  # so a present key wins even when it is nil — a feed whose avatar went
  # away must lose the stale one. Its name is not the feed's own word for
  # itself, so the name already known (from an about) is carried over.
  defp payload_entry(existing, profile) do
    %{
      name: existing_name(existing),
      image: value(profile, "image") || value(profile, :image),
      description: existing_description(existing)
    }
  end

  # An about message is the feed's own word for itself (or ours about
  # it), so the name and bio it carries are the answer. Fields it does
  # not carry are left as they are: an about that only revises the bio
  # must not take the name away.
  defp about_entry(existing, fields) do
    %{
      name: value(fields, "name") || value(fields, :name) || existing_name(existing),
      image: existing_image(existing),
      description:
        value(fields, "description") || value(fields, :description) ||
          existing_description(existing)
    }
  end

  defp value(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp value(_map, _key), do: nil

  defp existing_name(%{name: name}), do: name
  defp existing_name(_), do: nil

  defp existing_image(%{image: image}), do: image
  defp existing_image(_), do: nil

  defp existing_description(%{description: description}), do: description
  defp existing_description(_), do: nil

  # Entries written before the bio joined the model carry only name and
  # image; read them as a bio-less profile rather than crashing on the
  # missing key.
  defp normalize(%{} = profile) do
    %{
      name: Map.get(profile, :name),
      image: Map.get(profile, :image),
      description: Map.get(profile, :description)
    }
  end

  defp normalize(_), do: %{name: nil, image: nil, description: nil}

  @doc "Presentations for the given ids, dropping the unresolved ones."
  @spec take([binary()]) :: profiles()
  def take(ids) when is_list(ids) do
    Enum.reduce(ids, %{}, fn id, acc ->
      case get(id) do
        nil -> acc
        profile -> Map.put(acc, id, profile)
      end
    end)
  end

  @doc """
  Lay the read model's names over a payload's `%{id => %{name, image}}`
  map, keeping each entry's image. The payload's name is replaced, not
  trusted: it speaks for the engine's resolution, which may be a third
  party's label. A feed the read model has not named reads as nameless,
  so `HighWire.Avatar.display_name/2` falls back to the short id.
  """
  @spec with_names(profiles()) :: profiles()
  def with_names(profiles) when is_map(profiles) do
    known = take(Map.keys(profiles))

    Map.new(profiles, fn
      {id, profile} when is_map(profile) ->
        known_name =
          case known do
            %{^id => %{name: name}} -> name
            _ -> nil
          end

        {id, Map.put(profile, :name, known_name)}

      entry ->
        entry
    end)
  end

  @doc """
  The name a feed goes by, through the one resolution every view
  shares (`HighWire.Avatar.display_name/2`): its alias when the store
  has one, the short id when it does not.
  """
  @spec display_name(binary()) :: binary()
  def display_name(id) when is_binary(id), do: Ident.display_name(id, %{id => get(id)})

  @doc "The feed's avatar image ref, or nil for the identicon."
  @spec image(binary()) :: binary() | nil
  def image(id) when is_binary(id), do: get(id)[:image]

  @doc "The blob revision for cache-busting avatar URLs, or nil."
  @spec rev() :: integer() | nil
  def rev do
    case :ets.lookup(@table, :rev) do
      [{:rev, rev}] -> rev
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp ensure_table do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    @table
  rescue
    ArgumentError -> @table
  end
end
