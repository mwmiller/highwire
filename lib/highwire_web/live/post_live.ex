defmodule HighWireWeb.PostLive do
  @moduledoc """
  The post viewer: one message and its full thread, unforeshortened —
  no line clamp, every reply in causal order (through
  `HighWire.Timeline.post/1`, which unboxes private messages and falls
  back to the local window).

  The path segment is the message id as url-safe base64, because raw
  message ids contain "/" and cannot ride in a route as-is.
  """

  use HighWireWeb, :live_view

  require Logger

  alias HighWire.Avatar, as: Ident
  alias HighWire.Markdown
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Heart
  alias HighWireWeb.Components.Mentions
  alias HighWireWeb.Components.Nav

  import HighWireWeb.Components.Time, only: [age: 1]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(HighWire.PubSub, Timeline.topic())

    {:ok,
     socket
     |> assign(
       page_title: "Post",
       root: nil,
       replies: [],
       not_found: false,
       profiles: %{},
       like_counts: %{},
       likes_by: %{},
       my_likes: [],
       self_id: nil,
       status: :disabled,
       raw_key: nil,
       reply_body: "",
       reply_error: nil,
       mention_suggestions: [],
       blob_rev: 0
     )}
  end

  @impl true
  def handle_params(%{"key" => key}, _uri, socket) do
    case Base.url_decode64(key, padding: false) do
      {:ok, raw} when is_binary(raw) -> {:noreply, load(socket, raw)}
      :error -> {:noreply, push_navigate(socket, to: "/")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, push_navigate(socket, to: "/")}
  end

  @impl true
  def handle_info({Timeline, :updated, payload}, socket) do
    socket =
      assign(socket,
        blob_rev: Map.get(payload, :blob_rev, 0),
        profiles: Map.get(payload, :profiles, socket.assigns.profiles),
        like_counts: Map.get(payload, :like_counts, socket.assigns.like_counts),
        likes_by: Map.get(payload, :likes_by, socket.assigns.likes_by),
        my_likes: Map.get(payload, :my_likes, socket.assigns.my_likes),
        self_id: Map.get(payload, :self_id, socket.assigns.self_id)
      )

    # Re-read the thread so a reply or like we just published appears
    # without a navigation — fetch_post scans the in-memory window.
    {:noreply, if(socket.assigns.raw_key, do: load(socket, socket.assigns.raw_key), else: socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load(socket, raw_key) do
    {status, payload} = Timeline.snapshot()
    post = Timeline.post(raw_key)

    socket
    |> assign(
      raw_key: raw_key,
      status: status,
      root: post && post.root,
      replies: (post && post.replies) || [],
      not_found: post == nil,
      profiles: Map.get(payload, :profiles, %{}),
      like_counts: Map.get(payload, :like_counts, %{}),
      likes_by: Map.get(payload, :likes_by, %{}),
      my_likes: Map.get(payload, :my_likes, []),
      self_id: Map.get(payload, :self_id),
      blob_rev: Map.get(payload, :blob_rev, 0)
    )
  end

  # -- events ------------------------------------------------------------

  @impl true
  def handle_event("reply-draft", %{"body" => body}, socket) do
    {:noreply, assign(socket, reply_body: body)}
  end

  def handle_event("reply", _params, socket) do
    root = socket.assigns.root
    body = String.trim(socket.assigns.reply_body)

    cond do
      root == nil ->
        {:noreply, socket}

      body == "" ->
        {:noreply, assign(socket, reply_error: "Nothing to reply.")}

      socket.assigns.status == :disabled ->
        {:noreply, assign(socket, reply_error: "SSB engine disabled in this configuration.")}

      not is_binary(socket.assigns.self_id) ->
        {:noreply, assign(socket, reply_error: "Not connected to the local SSB engine yet.")}

      true ->
        # A reply from this view answers the thread root; branch points
        # at the same root (there is no per-reply addressing here).
        case Timeline.reply(root["key"], root["key"], body) do
          {:ok, _key} ->
            {:noreply, assign(socket, reply_body: "", reply_error: nil)}

          {:error, reason} ->
            {:noreply, assign(socket, reply_error: reply_error(reason))}
        end
    end
  end

  def handle_event("like", %{"key" => key}, socket) do
    result =
      if key in socket.assigns.my_likes do
        Timeline.unlike(key)
      else
        Timeline.like(key)
      end

    case result do
      {:error, reason} -> Logger.warning("post: like publish failed: #{inspect(reason)}")
      _ok -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("mention-query", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, assign(socket, :mention_suggestions, mention_candidates(socket, q))}
  end

  def handle_event("mention-close", _params, socket) do
    {:noreply, assign(socket, :mention_suggestions, [])}
  end

  defp mention_candidates(socket, q) do
    profiles = Map.get(socket.assigns, :profiles, %{})
    Mentions.candidates(q, Map.keys(profiles), &display_name(&1, profiles))
  end

  defp reply_error(:offline), do: "Not connected to the local SSB engine yet."

  defp reply_error(_reason), do: "Reply failed — the engine refused the message."

  defp liked?(assigns, key), do: key in assigns.my_likes

  # -- message helpers (the timeline's, kept local as on the profile page) --

  defp content(msg) do
    case msg do
      %{"value" => %{"content" => c}} when is_map(c) -> c
      _ -> %{}
    end
  end

  defp text(msg), do: content(msg)["text"] || ""
  defp author_of(msg), do: msg["value"]["author"] || "unknown"

  defp ts(msg) do
    case msg["value"]["timestamp"] do
      t when is_number(t) -> round(t)
      _ -> 0
    end
  end

  defp display_name(id, %{profiles: profiles}), do: display_name(id, profiles)

  defp display_name(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{name: name}} when is_binary(name) -> name
      _ -> Ident.short_id(id)
    end
  end

  defp display_name(_id, _profiles), do: "unknown"

  defp image_of(id, %{profiles: profiles}), do: image_of(id, profiles)

  defp image_of(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{image: image}} -> image
      _ -> nil
    end
  end

  defp image_of(_id, _profiles), do: nil

  defp profile_href("@" <> _ = id), do: "/profile?id=" <> URI.encode_www_form(id)
  defp profile_href(_id), do: nil

  @impl true
  def render(assigns) do
    likes = if assigns.root, do: Map.get(assigns.like_counts, assigns.root["key"], 0), else: 0
    root_liked = is_map(assigns.root) and liked?(assigns, assigns.root["key"])

    root_likers =
      if assigns.root, do: Map.get(assigns.likes_by, assigns.root["key"], []), else: []

    participants =
      case assigns.root do
        nil -> []
        root -> Enum.uniq([author_of(root) | Enum.map(assigns.replies, &author_of/1)])
      end

    assigns =
      assign(assigns,
        likes: likes,
        root_liked: root_liked,
        root_likers: Enum.take(root_likers, 4),
        participants: participants
      )

    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail>
        <div class="pb-1 pt-4">
          <Nav.rail_link navigate="/" title="Back to the timeline">
            Timeline
          </Nav.rail_link>
        </div>

        <Nav.rail_label>In this thread</Nav.rail_label>

        <div :if={@root}>
          <Nav.rail_link
            :for={who <- @participants}
            navigate={profile_href(who)}
            title={who}
          >
            <Avatar.avatar
              id={who}
              size={16}
              image={image_of(who, @profiles)}
              rev={@blob_rev}
            />
            <span class="min-w-0 truncate">{display_name(who, @profiles)}</span>
            <span
              :if={who == @self_id}
              class="ml-auto shrink-0 text-[10px] uppercase text-faint"
            >
              you
            </span>
          </Nav.rail_link>

          <p :if={@replies != []} class="px-4 pt-3 text-xs text-faint">
            {length(@replies)} {if length(@replies) == 1, do: "reply", else: "replies"}
          </p>
        </div>

        <p :if={@root == nil} class="px-4 pb-4 text-xs italic text-faint">
          Nothing loaded — the message may not be in the local store yet.
        </p>
      </Nav.rail>
      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-6">
          <div :if={@not_found} class="text-sm text-dim">
            That message is not in the local store — it may not have replicated yet.
          </div>

          <div :if={@root}>
            <article class="border-b border-edge pb-6">
              <div class="flex items-start gap-3">
                <Avatar.avatar
                  id={author_of(@root)}
                  size={48}
                  image={image_of(author_of(@root), @profiles)}
                  rev={@blob_rev}
                  class="mt-0.5"
                />
                <div class="min-w-0 flex-1">
                  <div class="flex items-baseline gap-2">
                    <span class="font-semibold text-paper">
                      <.link
                        :if={href = profile_href(author_of(@root))}
                        navigate={href}
                        class="hover:underline"
                      >
                        {display_name(author_of(@root), @profiles)}
                      </.link>
                      <span :if={profile_href(author_of(@root)) == nil}>
                        {display_name(author_of(@root), @profiles)}
                      </span>
                    </span>
                    <span :if={author_of(@root) == @self_id} class="text-[10px] uppercase text-faint">
                      you
                    </span>
                    <span class="text-xs text-faint"><.age ts={ts(@root)} /></span>
                    <span
                      :if={@root["value"]["private"]}
                      class="rounded border border-edge px-1 text-[10px] uppercase text-faint"
                    >
                      private
                    </span>
                    <span
                      :if={ch = content(@root)["channel"]}
                      class="text-xs text-accent"
                    >
                      #{ch}
                    </span>
                  </div>

                  <p class="mt-1 break-all font-mono text-[11px] text-faint">{@root["key"]}</p>

                  <div :if={text(@root) != ""} class="md-body mt-3 text-sm text-ink">
                    {raw(Markdown.to_html(text(@root), blob_rev: @blob_rev))}
                  </div>

                  <div class="mt-3 flex gap-4 text-xs text-dim">
                    <span :if={length(@replies) > 0}>
                      {length(@replies)} {if length(@replies) == 1, do: "reply", else: "replies"}
                    </span>
                    <div class="flex items-center gap-1.5">
                      <Heart.pill key={@root["key"]} liked={@root_liked} />
                      <span
                        :for={liker <- @root_likers}
                        title={display_name(liker, @profiles)}
                        class="inline-flex"
                      >
                        <Avatar.avatar
                          id={liker}
                          size={16}
                          image={image_of(liker, @profiles)}
                          rev={@blob_rev}
                        />
                      </span>
                    </div>
                  </div>
                </div>
              </div>
            </article>

            <h2
              :if={@replies != []}
              class="mt-6 text-sm font-semibold uppercase tracking-wide text-sub"
            >
              Replies
            </h2>

            <div
              :for={reply <- @replies}
              class="flex gap-3 border-b border-edge-soft py-4"
            >
              <Avatar.avatar
                id={author_of(reply)}
                size={32}
                image={image_of(author_of(reply), @profiles)}
                rev={@blob_rev}
                class="mt-0.5"
              />
              <div class="min-w-0 flex-1">
                <div class="flex items-baseline gap-2">
                  <span class="text-sm font-semibold text-paper">
                    <.link
                      :if={href = profile_href(author_of(reply))}
                      navigate={href}
                      class="hover:underline"
                    >
                      {display_name(author_of(reply), @profiles)}
                    </.link>
                    <span :if={profile_href(author_of(reply)) == nil}>
                      {display_name(author_of(reply), @profiles)}
                    </span>
                  </span>
                  <span :if={author_of(reply) == @self_id} class="text-[10px] uppercase text-faint">
                    you
                  </span>
                  <span class="text-xs text-faint"><.age ts={ts(reply)} /></span>
                  <span
                    :if={reply["value"]["private"]}
                    class="rounded border border-edge px-1 text-[10px] uppercase text-faint"
                  >
                    private
                  </span>
                </div>

                <div :if={text(reply) != ""} class="md-body mt-1.5 text-sm text-ink">
                  {raw(Markdown.to_html(text(reply), blob_rev: @blob_rev))}
                </div>

                <div class="mt-1.5 flex items-center gap-1.5">
                  <Heart.pill key={reply["key"]} liked={reply["key"] in @my_likes} />
                  <span
                    :for={liker <- Enum.take(Map.get(@likes_by, reply["key"], []), 4)}
                    title={display_name(liker, @profiles)}
                    class="inline-flex"
                  >
                    <Avatar.avatar
                      id={liker}
                      size={16}
                      image={image_of(liker, @profiles)}
                      rev={@blob_rev}
                    />
                  </span>
                </div>
              </div>
            </div>

            <p :if={@replies == []} class="mt-6 text-sm italic text-faint">
              No replies in the local store.
            </p>

            <form phx-submit="reply" class="mt-6 border-t border-edge pt-4">
              <label for="reply-body" class="sr-only">Reply</label>
              <div class="relative">
                <textarea
                  id="reply-body"
                  name="body"
                  phx-hook="Mentions"
                  data-draft-event="reply-draft"
                  phx-change="reply-draft"
                  phx-debounce="300"
                  placeholder="Write a reply…"
                  rows="3"
                  class="w-full resize-none rounded border border-edge bg-input px-3 py-2 text-sm text-paper placeholder:text-dim focus:border-focus focus:outline-none"
                >{@reply_body}</textarea>
                <div
                  :if={@mention_suggestions != []}
                  id="mention-list"
                  class="absolute left-0 right-0 top-full z-10 mt-1 max-h-64 overflow-y-auto rounded border border-edge bg-panel shadow-lg"
                >
                  <button
                    :for={{id, name} <- @mention_suggestions}
                    type="button"
                    data-mention-option
                    data-id={id}
                    data-name={name}
                    class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-panel2"
                  >
                    <Avatar.avatar
                      id={id}
                      size={16}
                      image={image_of(id, @profiles)}
                      rev={@blob_rev}
                      class="shrink-0"
                    />
                    <span class="truncate text-paper">{name}</span>
                    <span class="ml-auto shrink-0 font-mono text-[10px] text-faint">
                      {Ident.short_id(id)}
                    </span>
                  </button>
                </div>
              </div>
              <p :if={@reply_error} role="alert" class="mt-1 text-xs text-bad">
                {@reply_error}
              </p>
              <div class="mt-2 flex items-center justify-end gap-3">
                <span :if={@self_id} class="mr-auto truncate text-xs text-faint">
                  Replying as {display_name(@self_id, @profiles)}
                </span>
                <button type="submit" class="btn btn-primary" phx-disable-with="Replying…">
                  Reply
                </button>
              </div>
            </form>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
