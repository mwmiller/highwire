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
  `put_all/1` leaves the name alone and `put_about/3` writes it.

  The feed's word for itself and ours about it live in separate slots,
  and a read answers with ours first. An alias this store published
  therefore applies no matter what the feed names itself later — the
  order the messages arrived in does not decide — and taking the alias
  back (an about carrying `""` for the field) falls to the feed's own
  name again.

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
  Names come from the about drain through `put_about/3`, in both name
  slots, which this merge carries along untouched.
  """
  @spec put_all(map()) :: :ok
  def put_all(profiles) when is_map(profiles) do
    entries =
      Enum.map(profiles, fn
        {id, profile} when is_map(profile) ->
          {id, payload_entry(raw(id), profile)}

        {id, _other} ->
          {id, payload_entry(raw(id), %{})}
      end)

    true = :ets.insert(ensure_table(), entries)
    :ok
  end

  @doc """
  Fold one feed's `about` message into its entry: the display name and
  the bio the profile page shows. The store-wide about drain already
  reads every about message, but only the feed's own word for itself
  (or ours about it) arrives here — that is what makes this the one
  source of names.

  The source decides which slot the fields land in: `:own` is the
  feed's own word for itself, `:ours` the identity using this store
  speaking about the feed. Each field the message carries replaces its
  slot; a field it does not carry leaves the slot alone; a field
  carrying `""` clears it — the way a name or bio is taken back, the
  other side's slot then standing for the feed.
  """
  @spec put_about(binary(), map(), :own | :ours) :: :ok
  def put_about(id, fields, source)
      when is_binary(id) and is_map(fields) and source in [:own, :ours] do
    true = :ets.insert(ensure_table(), {id, about_entry(raw(id), fields, source)})
    :ok
  end

  @doc "The feed's own word for itself — `put_about/3` with `:own` as the source."
  @spec put_about(binary(), map()) :: :ok
  def put_about(id, fields), do: put_about(id, fields, :own)

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

  # The stored entry, before resolution: the feed's own word for itself
  # beside ours, and the payload's image. Entries written before the
  # split carry only the feed's own name and bio; the slots the split
  # added read as nil.
  defp raw(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, entry}] -> entry(entry)
      [] -> entry(%{})
    end
  rescue
    ArgumentError -> entry(%{})
  end

  defp entry(entry) when is_map(entry) do
    %{
      name: Map.get(entry, :name),
      ours_name: Map.get(entry, :ours_name),
      image: Map.get(entry, :image),
      description: Map.get(entry, :description),
      ours_description: Map.get(entry, :ours_description)
    }
  end

  defp entry(_entry), do: entry(%{})

  # A payload speaks for the window it covers: its image is the answer,
  # so a present key wins even when it is nil — a feed whose avatar went
  # away must lose the stale one. Its name is not the feed's own word for
  # itself, so both name slots (the feed's word and ours) are carried
  # over as they are.
  defp payload_entry(existing, profile) do
    %{existing | image: value(profile, "image") || value(profile, :image)}
  end

  # An about message is the feed's own word for itself (or ours about
  # it), so the fields it carries are the answer — for its source's
  # slot. Fields it does not carry leave their slot as it is: an about
  # that only revises the bio must not take the name away.
  defp about_entry(existing, fields, source) do
    case source do
      :own ->
        %{
          existing
          | name: written(existing.name, about_name(fields)),
            description: written(existing.description, about_description(fields))
        }

      :ours ->
        %{
          existing
          | ours_name: written(existing.ours_name, about_name(fields)),
            ours_description: written(existing.ours_description, about_description(fields))
        }
    end
  end

  # A field the message carries replaces the slot; an empty field
  # clears it — "" is how a name or bio is taken back; a field the
  # message does not carry leaves the slot alone.
  defp written(current, nil), do: current
  defp written(_current, ""), do: nil
  defp written(_current, value), do: value

  defp about_name(fields), do: value(fields, "name") || value(fields, :name)
  defp about_description(fields), do: value(fields, "description") || value(fields, :description)

  defp value(map, key) when is_map(map) do
    case Map.get(map, key) do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp value(_map, _key), do: nil

  # What a reader sees: our word for the feed when we have one — the
  # alias this store published, standing until it is taken back — over
  # the feed's own name and bio. The slots behind this are the writes';
  # `get/1` is the only shape callers ever read.
  defp normalize(%{} = entry) do
    entry = entry(entry)

    %{
      name: entry.ours_name || entry.name,
      image: entry.image,
      description: entry.ours_description || entry.description
    }
  end

  defp normalize(_entry), do: %{name: nil, image: nil, description: nil}

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
