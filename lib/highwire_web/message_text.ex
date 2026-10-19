defmodule HighWireWeb.MessageText do
  @moduledoc """
  What a message said, when it said nothing.

  SSB messages are typed: a contact edit, a like, a channel toggle, a
  profile patch — most carry no body text at all. Rendered literally,
  those arrive on screen as a bare message key and a blank where the
  words should be. This module turns the payload into one plain sentence
  the reader can act on, resolved through the same
  `HighWire.Avatar.display_name/2` every other page uses so a feed is
  called the same thing everywhere.

  Every view asks here, so a block reads identically in the timeline,
  the thread page, and anywhere else messages are listed.
  """

  alias HighWire.Avatar, as: Ident

  @doc """
  One sentence describing `msg`'s content, written without its author —
  the UI already names them. `ctx` is a row context (carrying `:profiles`
  and optionally the key→author `:index`) or the bare id→profile map.
  """
  @spec describe(map(), map()) :: binary()
  def describe(msg, ctx \\ %{}) do
    case content(msg) do
      c when map_size(c) == 0 -> "sent a private message"
      %{"type" => type} = c when is_binary(type) -> typed_label(type, c, msg, ctx)
      _ -> "sent a message"
    end
  end

  # Every type carries its own payload, so name the specific thing
  # rather than echoing the raw protocol type at the reader.
  defp typed_label("contact", c, _msg, ctx), do: contact_label(c, ctx)
  defp typed_label("about", c, _msg, ctx), do: about_label(c, ctx)
  defp typed_label("channel", c, _msg, _ctx), do: channel_label(c)
  defp typed_label("pub", c, _msg, _ctx), do: pub_label(c)
  defp typed_label("room/alias", c, _msg, _ctx), do: alias_label(c)
  defp typed_label("post-edit", c, msg, ctx), do: edit_label(c, msg, ctx)
  defp typed_label("vote", c, _msg, ctx), do: vote_label(c, ctx)
  defp typed_label("post", c, _msg, _ctx), do: post_label(c)
  defp typed_label(type, _c, _msg, _ctx), do: "sent a #{humanize_type(type)} message"

  # A contact edit is the reader's social ledger: which way the
  # relationship went, and with whom. The edit may also carry a name for
  # the target feed (patchwork's about-name), shown verbatim — the
  # profile store may never have seen that feed at all.
  defp contact_label(c, ctx) do
    who = contact_target(c, ctx)

    cond do
      c["blocking"] == true -> "blocked #{who}"
      c["following"] == true -> "followed #{who}"
      c["following"] == false -> "unfollowed #{who}"
      true -> "edited their contact list for #{who}"
    end
  end

  defp contact_target(c, ctx) do
    case c do
      %{"about" => %{"name" => name}} when is_binary(name) and name != "" -> name
      %{"contact" => id} when is_binary(id) -> Ident.display_name(id, ctx)
      _ -> "someone"
    end
  end

  # An about message sets a name/description for the feed it points at.
  # Resolve that feed to a display name when we can; fall back to the
  # generic phrase when the target isn't in the index.
  defp about_label(%{"about" => about} = c, ctx) when is_binary(about) do
    target = Map.get(index(ctx), about) || about

    cond do
      is_binary(c["name"]) -> "set #{Ident.display_name(target, ctx)}'s display name"
      is_binary(c["description"]) -> "wrote #{Ident.display_name(target, ctx)}'s bio"
      true -> "updated #{Ident.display_name(target, ctx)}'s profile"
    end
  end

  defp about_label(c, _ctx) do
    cond do
      Map.has_key?(c, "name") -> "set a display name"
      Map.has_key?(c, "description") -> "wrote a bio"
      true -> "updated a profile"
    end
  end

  # A like carries its target as a link. The row ctx maps message keys to
  # authors, so name the liker's target where it is known and keep the
  # protocol's own general phrase where it has scrolled past.
  defp vote_label(%{"link" => link}, ctx) when is_binary(link) do
    case Map.get(index(ctx), link) do
      nil -> "liked a message"
      author -> "liked #{Ident.display_name(author, ctx)}'s message"
    end
  end

  defp vote_label(_c, _ctx), do: "liked a message"

  defp pub_label(%{"address" => %{"host" => host}}) when is_binary(host),
    do: "announced the pub #{host}"

  defp pub_label(_), do: "announced a pub"

  defp alias_label(%{"alias" => alias} = c) when is_binary(alias) do
    room = if is_binary(c["room"]), do: " on #{c["room"]}", else: ""
    "registered the alias #{alias}#{room}"
  end

  defp alias_label(_), do: "registered a room alias"

  # Subscription toggles get a sentence of their own: "sent a channel
  # message" hid both the channel and which way the toggle went.
  defp channel_label(%{"channel" => channel, "subscribed" => subscribed})
       when is_binary(channel) and is_boolean(subscribed) do
    name = channel |> String.trim() |> String.trim_leading("#")

    if name == "" do
      "toggled a channel subscription"
    else
      "#{channel_verb(subscribed)} ##{name}"
    end
  end

  defp channel_label(_), do: "toggled a channel subscription"

  defp channel_verb(true), do: "subscribed to"
  defp channel_verb(false), do: "unsubscribed from"

  # A post-edit points at the post it revises via
  # revisionRoot/revisionBranch. Resolve that key to a name through the
  # index so the sentence reads as "edited their post" or "edited
  # <name>'s post" instead of naming the protocol type.
  defp edit_label(c, msg, ctx) do
    root = c["revisionRoot"] || c["revisionBranch"] || c["root"]
    author = author_of(msg)

    cond do
      is_nil(root) ->
        "edited a post"

      Map.get(index(ctx), root) == author ->
        "edited their post"

      target = Map.get(index(ctx), root) ->
        "edited #{Ident.display_name(target, ctx)}'s post"

      true ->
        "edited an older post"
    end
  end

  # A post with no body: name the channel when there is one — that is
  # the only thing the payload tells the reader about where it landed.
  defp post_label(%{"channel" => channel}) when is_binary(channel) do
    case channel |> String.trim() |> String.trim_leading("#") do
      "" -> "posted without any text"
      name -> "posted in ##{name}"
    end
  end

  defp post_label(_c), do: "posted without any text"

  # The last-resort fallback: strip protocol punctuation so an unknown
  # type reads as a phrase, not as "sent a room/alias message".
  defp humanize_type(type) do
    type
    |> String.replace(["/", "_", "-"], " ")
    |> String.downcase()
  end

  defp index(%{index: index}) when is_map(index), do: index
  defp index(_ctx), do: %{}

  defp content(msg) do
    case msg do
      %{"value" => %{"content" => c}} when is_map(c) -> c
      _ -> %{}
    end
  end

  defp author_of(msg), do: msg["value"]["author"]
end
