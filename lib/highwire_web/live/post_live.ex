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
  alias HighWireWeb.MessageText

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
       reply_pending: false,
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
        # Accumulate, as the timeline does: a finalize evicts profile ids
        # outside its window from the payload, and this view must not drop
        # avatars it has already shown over a transient.
        profiles: Map.merge(socket.assigns.profiles, Map.get(payload, :profiles, %{})),
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
    {root, replies, not_found} = thread(post, socket.assigns)

    socket
    |> assign(
      raw_key: raw_key,
      status: status,
      root: root,
      replies: replies,
      not_found: not_found,
      # Same accumulate as handle_info — snapshot payloads evict the same
      # way broadcasts do, and a reload here must not undo a fill-in.
      profiles:
        Map.merge(Map.get(socket.assigns, :profiles, %{}), Map.get(payload, :profiles, %{})),
      like_counts: Map.get(payload, :like_counts, %{}),
      likes_by: Map.get(payload, :likes_by, %{}),
      my_likes: Map.get(payload, :my_likes, []),
      self_id: Map.get(payload, :self_id),
      blob_rev: Map.get(payload, :blob_rev, 0)
    )
    |> request_missing_profiles()
  end

  # Timeline.post/1 answers nil both for a key the local store does not
  # hold and for a fetch that failed — its call has a hard timeout and
  # the engine restarts on a store switch or a sidecar bounce. Only the
  # first is news: blanking a thread already on screen because a call
  # timed out reads as "this post was deleted", and a reload here runs
  # on every broadcast. So a nil keeps what we are showing, and
  # not-found stands only when there is nothing to keep.
  defp thread(nil, %{root: root} = assigns) when not is_nil(root) do
    {root, Map.get(assigns, :replies, []), false}
  end

  defp thread(nil, _assigns), do: {nil, [], true}

  defp thread(post, _assigns), do: {post.root, post.replies || [], false}

  # Whatever this thread renders that no payload ever shipped a profile
  # for goes back to the Timeline as an ensure — the same contract the
  # timeline's cursor pages use. The window payload only covers followed
  # feeds' threads, so a thread with an unfollowed author (or a liker
  # outside the window) would otherwise sit on identicons and short ids.
  defp request_missing_profiles(socket) do
    known = Map.get(socket.assigns, :profiles, %{})
    likes_by = Map.get(socket.assigns, :likes_by, %{})

    missing =
      socket.assigns
      |> rendered_ids(likes_by)
      |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
      |> Enum.reject(&Map.has_key?(known, &1))
      |> Enum.uniq()

    if missing != [] do
      Timeline.ensure_profiles(missing)
    end

    socket
  end

  # Every identity this page puts on screen: the root author, the reply
  # authors (also the rail's avatars), and the liker tiles under each
  # message.
  defp rendered_ids(%{root: root, replies: replies}, likes_by) when is_map(root) do
    [author_of(root) | Enum.map(replies, &author_of/1)] ++
      Map.get(likes_by, root["key"], []) ++
      Enum.flat_map(replies, &Map.get(likes_by, &1["key"], []))
  end

  defp rendered_ids(_assigns, _likes_by), do: []

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
        {:noreply, assign(socket, reply_error: "Replying is turned off in this configuration.")}

      not is_binary(socket.assigns.self_id) ->
        {:noreply, assign(socket, reply_error: "Still connecting. Try again in a moment.")}

      socket.assigns.reply_pending ->
        {:noreply, socket}

      true ->
        {:noreply, reply_now(socket, root, body)}
    end
  end

  def handle_event("like", %{"key" => key}, socket) do
    # The pill fills on the click itself; the publish's ack rebroadcast
    # reconciles it with the store, and a refusal re-reads the thread so
    # a failed like never lingers on screen.
    liked? = key in socket.assigns.my_likes
    socket = assign(socket, Heart.toggle(socket.assigns, key))

    result =
      if private_thread?(socket.assigns.root) do
        value = if liked?, do: 0, else: 1
        Timeline.like_private(key, private_recipients(socket), value)
      else
        if liked?, do: Timeline.unlike(key), else: Timeline.like(key)
      end

    case result do
      {:error, reason} ->
        Logger.warning("post: like publish failed: #{inspect(reason)}")
        {:noreply, load(socket, socket.assigns.raw_key)}

      _ok ->
        {:noreply, socket}
    end
  end

  def handle_event("mention-query", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, assign(socket, :mention_suggestions, mention_candidates(socket, q))}
  end

  def handle_event("mention-close", _params, socket) do
    {:noreply, assign(socket, :mention_suggestions, [])}
  end

  # The reply itself, with the button held down while it waits: a
  # second press on the same body is a duplicate, not a second reply.
  defp reply_now(socket, root, body) do
    socket = assign(socket, reply_pending: true)

    # A reply from this view answers the thread root; branch points
    # at the same root (there is no per-reply addressing here).
    # A private thread's reply is boxed for its participants so the
    # answer never leaves the box the thread arrived in.
    result =
      if private_thread?(root) do
        Timeline.reply_private(root["key"], root["key"], body, private_recipients(socket))
      else
        Timeline.reply(root["key"], root["key"], body)
      end

    socket =
      case result do
        {:ok, _key} ->
          assign(socket, reply_body: "", reply_error: nil)

        {:error, reason} ->
          assign(socket, reply_error: reply_error(reason))
      end

    assign(socket, reply_pending: false)
  end

  defp mention_candidates(socket, q) do
    profiles = Map.get(socket.assigns, :profiles, %{})
    Mentions.candidates(q, Map.keys(profiles), &Ident.display_name(&1, profiles))
  end

  defp reply_error(:offline), do: "Still connecting. Try again in a moment."

  defp reply_error(_reason), do: "Reply failed."

  # A thread is private when its root arrived boxed; the badge already
  # keys off the same flag.
  defp private_thread?(%{"value" => %{"private" => true}}), do: true
  defp private_thread?(_), do: false

  # Everyone a private reply in this thread must reach: the root author,
  # the reply authors, and self — the participants a box should carry.
  # The root author and self go first, so a thread too large for one box
  # keeps the two readers it cannot drop; Timeline caps the rest.
  defp private_recipients(socket) do
    root = socket.assigns.root
    replies = Map.get(socket.assigns, :replies, [])

    [author_of(root)]
    |> Kernel.++([socket.assigns.self_id])
    |> Kernel.++(Enum.map(replies, &author_of/1))
    |> Enum.filter(&feed_id?/1)
    |> Enum.uniq()
  end

  # A recipient must be a real feed id; `author_of/1` answers "unknown"
  # for a message with no author on it, which is not one.
  defp feed_id?(<<"@", _::binary>> = id), do: String.ends_with?(id, ".ed25519")
  defp feed_id?(_), do: false

  defp liked?(assigns, key), do: key in assigns.my_likes

  attr :msg, :map, required: true
  attr :profiles, :map, required: true
  attr :rev, :any, default: nil
  attr :class, :string, default: "mt-1.5"

  # A message that says nothing in words still said something — a block,
  # a follow, a like — and reads as a sentence here instead of leaving a
  # blank body under the byline. When the sentence names a feed (a contact
  # edit), that feed rides along as a chip with its own avatar, linking
  # through to the profile — where the reader can look them over and block
  # them for themselves.
  #
  # A div, not a p: the chip carries the avatar component's own div, and a
  # div inside a p makes the HTML parser close the p — which drops the
  # chip (avatar and name) out of the sentence entirely. The timeline's
  # contact row learned the same lesson.
  defp message_line(assigns) do
    ~H"""
    <div class={["text-sm italic text-sub", @class]}>
      <%= case MessageText.contact_edit(@msg) do %>
        <% nil -> %>
          {MessageText.describe(@msg, %{profiles: @profiles})}
        <% {verb, id, name} -> %>
          {verb}
          <span class="ml-1 inline-flex items-center gap-1.5 align-middle">
            <.link
              :if={href = profile_href(id)}
              navigate={href}
              class="inline-flex items-center gap-1.5 not-italic text-ink hover:underline"
            >
              <Avatar.avatar
                id={id}
                size={16}
                image={image_of(id, @profiles)}
                rev={@rev}
              />
              <span>{name || Ident.display_name(id, @profiles)}</span>
            </.link>
            <span :if={profile_href(id) == nil} class="not-italic text-ink">
              {name || Ident.display_name(id, @profiles)}
            </span>
          </span>
      <% end %>
    </div>
    """
  end

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
      <Nav.rail gossip={@gossip}>
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
            <span class="min-w-0 truncate">{Ident.display_name(who, @profiles)}</span>
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
          Nothing loaded. This message may not have arrived yet.
        </p>
      </Nav.rail>
      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-2xl px-6 py-6">
          <.link id="post-back" navigate="/" title="Back to the timeline" class="btn mb-4">
            ← Timeline
          </.link>

          <div :if={@not_found} class="text-sm text-dim">
            That message hasn't arrived yet.
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
                        {Ident.display_name(author_of(@root), @profiles)}
                      </.link>
                      <span :if={profile_href(author_of(@root)) == nil}>
                        {Ident.display_name(author_of(@root), @profiles)}
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

                  <%!-- The full key is the URL of this page; on the
                  page itself a nine-character stub plus a hover title
                  identifies the post without a wall of base64 between
                  the byline and the body. --%>
                  <p class="mt-1 font-mono text-[11px] text-faint" title={@root["key"]}>
                    {Ident.short_id(@root["key"] || "")}
                  </p>

                  <div :if={text(@root) != ""} class="md-body mt-3 text-sm text-ink">
                    {raw(Markdown.to_html(text(@root), blob_rev: @blob_rev))}
                  </div>

                  <%!-- A root with no body of its own still says what it
                  did — see message_line/1. --%>
                  <.message_line
                    :if={text(@root) == ""}
                    msg={@root}
                    profiles={@profiles}
                    rev={@blob_rev}
                    class="mt-3"
                  />

                  <div class="mt-3 flex gap-4 text-xs text-dim">
                    <span :if={length(@replies) > 0}>
                      {length(@replies)} {if length(@replies) == 1, do: "reply", else: "replies"}
                    </span>
                    <div class="flex items-center gap-1.5">
                      <Heart.pill key={@root["key"]} liked={@root_liked} />
                      <span
                        :for={liker <- @root_likers}
                        title={Ident.display_name(liker, @profiles)}
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
                      {Ident.display_name(author_of(reply), @profiles)}
                    </.link>
                    <span :if={profile_href(author_of(reply)) == nil}>
                      {Ident.display_name(author_of(reply), @profiles)}
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

                <.message_line
                  :if={text(reply) == ""}
                  msg={reply}
                  profiles={@profiles}
                  rev={@blob_rev}
                />

                <div class="mt-1.5 flex items-center gap-1.5">
                  <Heart.pill key={reply["key"]} liked={reply["key"] in @my_likes} />
                  <span
                    :for={liker <- Enum.take(Map.get(@likes_by, reply["key"], []), 4)}
                    title={Ident.display_name(liker, @profiles)}
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
              No replies yet.
            </p>

            <form
              id="reply-form"
              phx-submit="reply"
              phx-hook="Attach"
              data-attach-zone
              class="mt-6 border-t border-edge pt-4"
            >
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
                    class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm hover:bg-raised"
                  >
                    <Avatar.avatar
                      id={id}
                      size={16}
                      image={image_of(id, @profiles)}
                      rev={@blob_rev}
                      class="shrink-0"
                    />
                    <span class="min-w-0 truncate text-paper">{name}</span>
                    <span class="ml-auto shrink-0 font-mono text-[10px] text-faint">
                      {Ident.short_id(id)}
                    </span>
                  </button>
                </div>
              </div>
              <p :if={@reply_error} role="alert" class="mt-1 text-xs text-bad">
                {@reply_error}
              </p>
              <p
                id="reply-attach-status"
                phx-update="ignore"
                data-attach-status
                role="status"
                class="mt-1 text-xs text-faint"
              >
              </p>
              <div class="mt-2 flex items-center justify-end gap-3">
                <span :if={@self_id} class="mr-auto min-w-0 truncate text-xs text-faint">
                  Replying as {Ident.display_name(@self_id, @profiles)}
                </span>
                <label
                  class="btn cursor-pointer"
                  title="Attach an image, or paste or drop one here"
                >
                  Attach <input type="file" accept="image/*" data-attach-input class="hidden" />
                </label>
                <button
                  type="submit"
                  class="btn btn-primary"
                  phx-disable-with="Replying…"
                  disabled={@reply_pending}
                >
                  {if @reply_pending, do: "Replying…", else: "Reply"}
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
