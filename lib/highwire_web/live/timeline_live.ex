defmodule HighWireWeb.TimelineLive do
  @moduledoc """
  The home timeline: a Patchwork/Poncho Wonky-style infinite-scroll feed.

  Ordering comes from `HighWire.Timeline`: one row per thread at its
  latest activity ("bump"), votes folded into like counts, follow
  messages collapsed into one row per author. Patchwork's feed tabs sit
  in the top bar — Public (the window), Private (silkpurse's decrypted
  `privateFeed`, cursor-paginated), Participating (threads we posted
  into; opt-in via Settings → Notification options), Profile (this
  account's own posts) and Mentions (threads that name us) — with a
  peer chip driven by real `gossip.peers` data linking to the network
  page. Clicking a post opens the post viewer at `/post/:key`. The app
  opens straight to this feed. The Public tab's composer at the top of
  the feed publishes through the engine's `publish` RPC (`Timeline.publish/1`),
  with local validation for blank drafts and an offline engine. Swallows
  the Tauri menu/resize/escape events so the shell's bridge never crashes
  the mount.
  """

  use HighWireWeb, :live_view

  alias HighWire.Avatar, as: Ident
  alias HighWire.Markdown
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Nav

  @page_size 60

  # Patchwork's feed tabs: the first three sit left of the search box,
  # the last two right of it (as in Patchwork's top bar). Participating
  # is opt-in — Settings → Notification options, after Patchwork — and
  # hidden by CSS (html[data-participating]) until the pref is on.
  @views [
    {:public, "Public"},
    {:private, "Private"},
    {:participating, "Participating"},
    {:profile, "Profile"},
    {:mentions, "Mentions"}
  ]

  @left_views [:public, :private, :participating]
  @right_views [:profile, :mentions]

  # markdown image syntax: ![alt](target)
  @image_re ~r/!\[([^\]]*)\]\(([^()\s]+)\)/

  @empty_payload %{
    feed: [],
    messages: [],
    reply_counts: %{},
    like_counts: %{},
    index: %{},
    follows: [],
    self_id: nil,
    profiles: %{},
    suggestions: []
  }

  @impl true
  def mount(_params, _session, socket) do
    peers_timer =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(HighWire.PubSub, Timeline.topic())
        Timeline.set_activity(self(), true)
        Process.send_after(self(), :peers_tick, 5_000)
      end

    {status, payload} = Timeline.snapshot()

    {:ok,
     socket
     |> assign(:page_title, "Timeline")
     |> assign(:status, status)
     |> assign_payload(payload)
     |> assign(:peers, Timeline.network())
     |> assign(q: "", expanded: MapSet.new(), limit: @page_size, view: :public)
     |> assign(compose: "", compose_error: nil)
     |> assign(private_rows: [], private_resume: nil, private_more: false)
     |> assign(active: true, peers_timer: peers_timer)}
  end

  @impl true
  def handle_info({Timeline, :updated, payload}, socket) do
    {:noreply, socket |> assign(:status, :ok) |> assign_payload(payload)}
  end

  def handle_info(:peers_tick, socket) do
    if socket.assigns.peers_timer, do: Process.cancel_timer(socket.assigns.peers_timer)
    socket = assign(socket, :peers_timer, nil)

    if socket.assigns.active and connected?(socket) do
      Timeline.set_activity(self(), true)
      {:noreply, socket |> assign(:peers, Timeline.network()) |> schedule_peers()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, q: String.downcase(q), limit: @page_size)}
  end

  # Composer drafts debounce into the assign; publish trims, validates
  # locally, then calls the engine. A successful publish clears the box —
  # Timeline itself schedules the reload so the post appears without a
  # poll round-trip.
  def handle_event("compose-draft", %{"body" => body}, socket) do
    {:noreply, assign(socket, compose: body)}
  end

  def handle_event("publish", %{"body" => body}, socket) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:noreply, assign(socket, compose_error: "Nothing to publish.")}

      socket.assigns.status == :disabled ->
        {:noreply, assign(socket, compose_error: "SSB engine disabled in this configuration.")}

      not is_binary(socket.assigns.self_id) ->
        {:noreply, assign(socket, compose_error: "Not connected to the local SSB engine yet.")}

      true ->
        case Timeline.publish(body) do
          {:ok, _key} ->
            {:noreply, assign(socket, compose: "", compose_error: nil)}

          {:error, reason} ->
            {:noreply, assign(socket, compose_error: publish_error(reason))}
        end
    end
  end

  def handle_event("view", %{"v" => v}, socket) do
    view =
      Enum.find_value(@views, :public, fn {key, _label} ->
        if Atom.to_string(key) == v, do: key
      end)

    socket = socket |> assign(:view, view) |> assign(:limit, @page_size)

    socket =
      if view == :private and socket.assigns.private_rows == [] do
        load_private_page(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("expand", %{"key" => key}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded, key) do
        MapSet.delete(socket.assigns.expanded, key)
      else
        MapSet.put(socket.assigns.expanded, key)
      end

    {:noreply, assign(socket, expanded: expanded)}
  end

  # The post row's OpenPost hook ignores clicks on links/buttons, so a
  # title click lands here: hand the raw message key to the viewer as an
  # url-safe base64 path segment (message keys contain "/").
  def handle_event("open-post", %{"key" => key}, socket) when is_binary(key) do
    {:noreply, push_navigate(socket, to: "/post/" <> Base.url_encode64(key, padding: false))}
  end

  def handle_event("load-more", _params, socket) do
    if socket.assigns.view == :private and socket.assigns.private_more do
      {:noreply, load_private_page(socket)}
    else
      {:noreply, update(socket, :limit, &(&1 + @page_size))}
    end
  end

  # MenuBridge pushes these; unmatched events would crash the view.
  def handle_event("menu", _params, socket), do: {:noreply, socket}
  def handle_event("window-resize", _params, socket), do: {:noreply, socket}
  def handle_event("escape", _params, socket), do: {:noreply, socket}

  def handle_event("tab-active", _params, socket) do
    Timeline.set_activity(self(), true)

    if socket.assigns.active do
      {:noreply, socket}
    else
      send(self(), :peers_tick)
      {:noreply, assign(socket, :active, true)}
    end
  end

  def handle_event("tab-inactive", _params, socket) do
    Timeline.set_activity(self(), false)
    if socket.assigns.peers_timer, do: Process.cancel_timer(socket.assigns.peers_timer)

    {:noreply, socket |> assign(:active, false) |> assign(:peers_timer, nil)}
  end

  defp schedule_peers(socket) do
    assign(socket, :peers_timer, Process.send_after(self(), :peers_tick, 5_000))
  end

  defp publish_error(:offline), do: "SSB engine offline."
  defp publish_error(reason) when is_binary(reason), do: reason
  defp publish_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp publish_error(_reason), do: "Publish failed — the engine refused the message."

  # One more Private tab page from silkpurse's cursor.
  defp load_private_page(socket) do
    %{rows: rows, resume: resume, more: more} =
      Timeline.private_feed(socket.assigns.private_resume)

    assign(socket,
      private_rows: socket.assigns.private_rows ++ rows,
      private_resume: resume,
      private_more: more
    )
  end

  @impl true
  def render(assigns) do
    query_base =
      assigns
      |> rows()
      |> Enum.filter(&matches_query?(&1, assigns.q))

    counts = %{
      public: length(query_base),
      participating: Enum.count(query_base, &participating?/1),
      profile: Enum.count(query_base, &profile_match?(&1, assigns.self_id)),
      mentions: Enum.count(query_base, &mention_match?/1),
      private: length(assigns.private_rows)
    }

    filtered =
      case assigns.view do
        :private -> Enum.filter(assigns.private_rows, &matches_query?(&1, assigns.q))
        :participating -> Enum.filter(query_base, &participating?/1)
        :profile -> Enum.filter(query_base, &profile_match?(&1, assigns.self_id))
        :mentions -> Enum.filter(query_base, &mention_match?/1)
        :public -> query_base
      end

    # Private rows arrive already paged by silkpurse's cursor; the window
    # tabs page by the client-side limit.
    page =
      if assigns.view == :private, do: filtered, else: Enum.take(filtered, assigns.limit)

    more =
      case assigns.view do
        :private -> assigns.private_more
        _ -> counts[assigns.view] > length(page)
      end

    assigns =
      assign(assigns,
        rows: page,
        counts: counts,
        views: @views,
        left_views: Enum.filter(@views, fn {v, _} -> v in @left_views end),
        right_views: Enum.filter(@views, fn {v, _} -> v in @right_views end),
        more: more,
        as: %{
          expanded: assigns.expanded,
          index: assigns.index,
          profiles: assigns.profiles,
          rev: assigns.blob_rev
        }
      )

    ~H"""
    <div
      id="timeline-root"
      phx-hook="TabActivity"
      class="flex h-screen overflow-hidden bg-app text-ink"
    >
      <Nav.rail>
        <h1 class="sr-only">Timeline</h1>

        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">
          Contacts
        </div>
        <div class="pb-4">
          <.link
            :for={c <- @sidebar_contacts}
            navigate={profile_href(c)}
            class="flex items-center gap-2 px-4 py-1 text-xs text-muted hover:bg-raised hover:text-paper"
          >
            <Avatar.avatar
              id={c}
              size={16}
              image={image_of(c, @profiles)}
              rev={@blob_rev}
            />
            <span class="truncate">{display_name(c, @profiles)}</span>
          </.link>
        </div>

        <div
          :if={@suggestions != []}
          class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint"
        >
          Who to follow
        </div>
        <div :if={@suggestions != []} class="pb-4">
          <.link
            :for={s <- @suggestions}
            navigate={profile_href(s["id"])}
            title={"#{s["followers"]} followers · #{s["activity"]} messages"}
            class="flex items-center gap-2 px-4 py-1 text-xs text-muted hover:bg-raised hover:text-paper"
          >
            <Avatar.avatar
              id={s["id"]}
              size={16}
              image={image_of(s["id"], @profiles)}
              rev={@blob_rev}
            />
            <span class="truncate">{display_name(s["id"], @profiles)}</span>
            <span class="ml-auto shrink-0 text-[10px] text-faint">{s["activity"]}</span>
          </.link>
        </div>
      </Nav.rail>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="flex h-11 shrink-0 items-center gap-2 border-b border-edge bg-panel px-4">
          <nav class="flex items-center gap-1" aria-label="Feeds">
            <.feed_tab
              :for={{v, label} <- @left_views}
              v={v}
              label={label}
              current={@view}
              count={@counts[v]}
            />
          </nav>
          <form
            id="feed-search"
            phx-change="search"
            phx-submit="search"
            class="ml-auto"
            role="search"
          >
            <input
              type="search"
              name="q"
              value={@q}
              phx-debounce="300"
              placeholder="Search…"
              class="w-72 rounded border border-edge bg-input px-2 py-1 text-sm text-paper placeholder:text-dim focus:border-focus focus:outline-none"
            />
          </form>
          <nav class="flex items-center gap-1" aria-label="Profile feeds">
            <.feed_tab
              :for={{v, label} <- @right_views}
              v={v}
              label={label}
              current={@view}
              count={@counts[v]}
            />
          </nav>
          <.link
            :if={n = peer_count(@peers)}
            navigate="/network"
            title="Connections"
            class={[
              "flex shrink-0 items-center gap-1.5 rounded px-2 py-1 text-xs transition",
              n > 0 and "text-ok hover:bg-raised",
              n == 0 and "text-dim hover:bg-raised hover:text-paper"
            ]}
          >
            <span class={[
              "h-1.5 w-1.5 rounded-full",
              n > 0 and "bg-dot-ok",
              n == 0 and "bg-dot"
            ]}></span>
            {n} peer{if n == 1, do: "", else: "s"}
          </.link>
        </header>

        <div class="flex-1 overflow-y-auto">
          <form
            :if={@view == :public}
            id="compose"
            phx-submit="publish"
            phx-change="compose-draft"
            class="border-b border-edge px-4 py-3"
          >
            <div class="flex gap-3">
              <Avatar.avatar
                :if={@self_id}
                id={@self_id}
                size={40}
                image={image_of(@self_id, @profiles)}
                rev={@blob_rev}
                class="mt-0.5 shrink-0"
              />
              <div class="min-w-0 flex-1">
                <textarea
                  id="compose-body"
                  name="body"
                  phx-debounce="300"
                  placeholder="Write a post…"
                  rows="3"
                  class="w-full resize-none rounded border border-edge bg-input px-3 py-2 text-sm text-paper placeholder:text-dim focus:border-focus focus:outline-none"
                >{@compose}</textarea>
                <p :if={@compose_error} role="alert" class="mt-1 text-xs text-bad">
                  {@compose_error}
                </p>
                <div class="mt-2 flex items-center justify-end gap-3">
                  <span :if={@self_id} class="mr-auto truncate text-xs text-faint">
                    Posting as {display_name(@self_id, @profiles)}
                  </span>
                  <button type="submit" class="btn btn-primary" phx-disable-with="Publishing…">
                    Publish
                  </button>
                </div>
              </div>
            </div>
          </form>

          <p :if={@status == :connecting} class="px-4 py-3 text-sm text-info">
            Connecting to the local SSB engine…
          </p>
          <p :if={@status == :loading} class="px-4 py-3 text-sm text-info">
            Loading feeds…
          </p>
          <p :if={@status == :disabled} class="px-4 py-3 text-sm text-dim">
            SSB engine disabled in this configuration.
          </p>
          <p
            :if={@status == :ok and @rows == [] and @view == :private}
            class="px-4 py-3 text-sm text-dim"
          >
            No private messages yet.
          </p>
          <p
            :if={@status == :ok and @rows == [] and @view != :private}
            class="px-4 py-3 text-sm text-dim"
          >
            No messages yet.
          </p>

          <div :for={{row, idx} <- Enum.with_index(@rows)} class="border-b border-edge-soft">
            <.post_row :if={row.kind in [:thread, :post]} row={row} ctx={@as} idx={idx} />
            <.vote_row :if={row.kind == :vote} row={row} ctx={@as} />
            <.contact_row :if={row.kind == :contact} row={row} ctx={@as} />
            <.other_row :if={row.kind == :other} row={row} ctx={@as} />
          </div>

          <div :if={@more} id="feed-sentinel" phx-hook="InfiniteScroll" class="h-px"></div>
        </div>
      </div>
    </div>
    """
  end

  attr :v, :atom, required: true
  attr :label, :string, required: true
  attr :current, :atom, required: true
  attr :count, :integer, required: true

  defp feed_tab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="view"
      phx-value-v={@v}
      data-pref-tab={if(@v == :participating, do: "participating")}
      class={[
        "rounded px-2 py-1 text-xs transition",
        @current == @v and "bg-active font-medium text-paper",
        @current != @v and "text-dim hover:bg-raised hover:text-paper"
      ]}
    >
      {@label}<span :if={@count > 0} class="ml-1 text-[10px] text-sub">{@count}</span>
    </button>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true
  attr :idx, :integer, required: true

  defp post_row(assigns) do
    raw_text = text(assigns.row.msg)

    assigns =
      assigns
      |> assign(:author, author_of(assigns.row.msg))
      |> assign(:author_href, profile_href(author_of(assigns.row.msg)))
      |> assign(:text_body, raw_text)
      |> assign(:private?, Map.get(assigns.row, :private?, false))
      |> assign(
        :body_html,
        if(raw_text != "",
          do: Markdown.to_html(raw_text, blob_rev: assigns.ctx.rev),
          else: ""
        )
      )

    ~H"""
    <article
      id={"post-" <> Integer.to_string(@idx)}
      class="flex cursor-pointer gap-3 px-4 py-3 hover:bg-panel"
      phx-hook="OpenPost"
      data-key={@row.msg["key"]}
    >
      <Avatar.avatar
        id={@author}
        size={40}
        image={image_of(@author, @ctx.profiles)}
        rev={@ctx.rev}
        class="mt-0.5"
      />
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="text-sm font-semibold text-paper">
            <.link :if={@author_href} navigate={@author_href} class="hover:underline">
              {display_name(@author, @ctx)}
            </.link>
            <span :if={@author_href == nil}>{display_name(@author, @ctx)}</span>
          </span>
          <span :if={@row.self?} class="text-[10px] uppercase text-faint">you</span>
          <span class="text-xs text-faint">{rel_time(ts(@row.msg))}</span>
          <span :if={@row.activity > ts(@row.msg)} class="text-xs text-faint">
            · active {rel_time(@row.activity)}
          </span>
          <span
            :if={@private?}
            class="rounded border border-edge px-1 text-[10px] uppercase text-faint"
          >
            private
          </span>
        </div>

        <p :if={meta = meta_line(@row, @ctx)} class="mt-0.5 text-xs text-dim">{meta}</p>

        <div :if={@body_html != ""} class="md-body mt-1 line-clamp-4 text-sm leading-5 text-ink">
          {raw(@body_html)}
        </div>

        <div class="mt-1.5 flex items-center gap-4 text-xs text-dim">
          <span :if={@row.replies > 0}>{@row.replies} replies</span>
          <span :if={@row.likes > 0}>❤ {@row.likes}</span>
        </div>

        <div :if={@row.recent != []} class="mt-2 space-y-1.5 border-l border-edge pl-3">
          <div :for={reply <- Enum.reverse(@row.recent)} class="flex items-baseline gap-2">
            <Avatar.avatar
              id={author_of(reply)}
              size={16}
              image={image_of(author_of(reply), @ctx.profiles)}
              rev={@ctx.rev}
              class="self-center"
            />
            <span class="shrink-0 text-xs font-medium text-muted">
              {display_name(author_of(reply), @ctx)}
            </span>
            <span class="truncate text-xs text-sub">{snippet(reply)}</span>
            <span class="ml-auto shrink-0 text-[11px] text-faint">
              {rel_time(ts(reply))}
            </span>
          </div>
        </div>

        <p
          :if={@row.kind == :thread and not @row.rooted?}
          class="mt-1.5 text-xs italic text-faint"
        >
          thread root not in the local window
        </p>
      </div>
    </article>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  defp vote_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm text-sub hover:bg-panel">
      <Avatar.avatar
        id={author_of(@row.msg)}
        size={24}
        image={image_of(author_of(@row.msg), @ctx.profiles)}
        rev={@ctx.rev}
      />
      <p>
        <span class="text-ink">{display_name(author_of(@row.msg), @ctx)}</span>
        liked <span class="text-ink">{vote_target_label(@row.msg, @ctx)}</span>
      </p>
      <span class="ml-auto text-xs text-faint">{rel_time(ts(@row.msg))}</span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  # Feed rows carry :followed (the collapsed list); the arrival tab's
  # individual contact messages fall back to their single contact.
  # "+N more" toggles the full list (same expand event as post bodies);
  # each followed chip links to that feed's profile.
  defp contact_row(assigns) do
    followed =
      Map.get(assigns.row, :followed) || [content(assigns.row.msg)["contact"]]

    followed = Enum.filter(followed, &is_binary/1)
    expanded? = MapSet.member?(assigns.ctx.expanded, assigns.row.msg["key"])

    assigns =
      assigns
      |> assign(:author, author_of(assigns.row.msg))
      |> assign(:followed, followed)
      |> assign(:shown_followed, if(expanded?, do: followed, else: Enum.take(followed, 3)))
      |> assign(:expanded?, expanded?)

    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm text-sub hover:bg-panel">
      <Avatar.avatar
        id={@author}
        size={24}
        image={image_of(@author, @ctx.profiles)}
        rev={@ctx.rev}
      />
      <p class="min-w-0">
        <.link
          :if={href = profile_href(@author)}
          navigate={href}
          class="text-ink hover:underline"
        >
          {display_name(@author, @ctx)}
        </.link>
        <span :if={profile_href(@author) == nil} class="text-ink">
          {display_name(@author, @ctx)}
        </span>
        followed
        <span class="ml-1 inline-flex flex-wrap items-center gap-x-3 gap-y-1 align-middle">
          <span :for={fid <- @shown_followed} class="inline-flex items-center gap-1.5">
            <.link
              navigate={profile_href(fid)}
              class="inline-flex items-center gap-1.5 hover:opacity-80"
            >
              <Avatar.avatar
                id={fid}
                size={16}
                image={image_of(fid, @ctx.profiles)}
                rev={@ctx.rev}
              />
              <span class="text-ink hover:underline">{display_name(fid, @ctx)}</span>
            </.link>
          </span>
          <button
            :if={length(@followed) > length(@shown_followed)}
            type="button"
            phx-click="expand"
            phx-value-key={@row.msg["key"]}
            class="text-accent hover:underline"
          >
            +{length(@followed) - length(@shown_followed)} more
          </button>
          <button
            :if={@expanded? and length(@followed) > 3}
            type="button"
            phx-click="expand"
            phx-value-key={@row.msg["key"]}
            class="text-accent hover:underline"
          >
            show less
          </button>
        </span>
      </p>
      <span class="ml-auto shrink-0 text-xs text-faint">{rel_time(ts(@row.msg))}</span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  defp other_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm italic text-faint hover:bg-panel">
      <Avatar.avatar
        id={author_of(@row.msg)}
        size={24}
        image={image_of(author_of(@row.msg), @ctx.profiles)}
        rev={@ctx.rev}
      />
      <p>
        <span class="not-italic text-ink">{display_name(author_of(@row.msg), @ctx)}</span>
        {other_label(@row.msg)}
      </p>
      <span class="ml-auto not-italic text-xs text-faint">{rel_time(ts(@row.msg))}</span>
    </div>
    """
  end

  # -- payload / assigns -------------------------------------------------

  defp assign_payload(socket, %{feed: feed} = payload) do
    profiles = Map.get(payload, :profiles, %{})

    # Alphabetical by displayed name — the sidebar used to show raw
    # follow-graph order, which reads as random.
    contacts =
      payload.follows
      |> Enum.reject(&(&1 == payload.self_id))
      |> Enum.sort_by(&String.downcase(display_name(&1, profiles)))

    socket
    |> assign(:feed, feed)
    |> assign(:messages, Map.get(payload, :messages, []))
    |> assign(:reply_counts, payload.reply_counts)
    |> assign(:like_counts, payload.like_counts)
    |> assign(:index, payload.index)
    |> assign(:self_id, payload.self_id)
    |> assign(:profiles, profiles)
    |> assign(:blob_rev, Map.get(payload, :blob_rev, 0))
    |> assign(:sidebar_contacts, contacts)
    |> assign(:suggestions, Map.get(payload, :suggestions, []))
  end

  defp assign_payload(socket, _payload) do
    socket
    |> assign(:feed, @empty_payload.feed)
    |> assign(:messages, @empty_payload.messages)
    |> assign(:reply_counts, @empty_payload.reply_counts)
    |> assign(:like_counts, @empty_payload.like_counts)
    |> assign(:index, @empty_payload.index)
    |> assign(:self_id, nil)
    |> assign(:profiles, %{})
    |> assign(:blob_rev, 0)
    |> assign(:sidebar_contacts, [])
    |> assign(:suggestions, @empty_payload.suggestions)
  end

  # -- row selection ------------------------------------------------------
  # The single feed: thread-bumped rows straight from the Timeline.

  defp rows(a), do: a.feed

  defp matches_query?(_row, ""), do: true

  defp matches_query?(row, q) do
    String.contains?(String.downcase(author_of(row.msg)), q) or
      String.contains?(String.downcase(text(row.msg)), q) or
      Enum.any?(Map.get(row, :followed, []), &String.contains?(String.downcase(&1), q))
  end

  # -- view filters ------------------------------------------------------

  # Profile: this account's own posts and threads (votes, follows and
  # other people's threads stay out).
  defp profile_match?(%{kind: kind} = row, self)
       when kind in [:post, :thread] and is_binary(self) do
    author_of(row.msg) == self
  end

  defp profile_match?(_row, _self), do: false

  # Participating (Patchwork's tab): threads we have posted into — our
  # root or our reply. The Timeline already marks that as row.self?;
  # contact and other activity rows are not threads, so they stay out.
  defp participating?(%{kind: kind} = row) when kind in [:thread, :post], do: row.self?
  defp participating?(_row), do: false

  # Mentions: the Timeline marks each row when any message in the thread
  # (root included) carries our id in its text — matching at row level
  # keeps threads whose root never reached the window.
  defp mention_match?(%{kind: kind} = row) when kind in [:thread, :post] do
    Map.get(row, :mentioned?, false)
  end

  defp mention_match?(_row), do: false

  # nil while the engine report is unavailable (old erlbutt / down) —
  # the chip hides rather than claims anything.
  defp peer_count(nil), do: nil
  defp peer_count(network) when is_map(network), do: length(network["connections"] || [])

  # -- message helpers ---------------------------------------------------

  defp content(msg) do
    case msg do
      %{"value" => %{"content" => c}} when is_map(c) -> c
      _ -> %{}
    end
  end

  defp author_of(msg), do: msg["value"]["author"] || "unknown"
  defp text(msg), do: content(msg)["text"] || ""

  defp ts(msg) do
    case msg["value"]["timestamp"] do
      t when is_number(t) -> round(t)
      _ -> 0
    end
  end

  defp snippet(msg) do
    msg
    |> text()
    |> String.replace(@image_re, "[image]")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 120)
  end

  # Profile-aware names: the resolved name from the payload's profiles
  # (bare map, or the row ctx carrying one), else Patchwork's shortFeedId.
  defp display_name(id, _profiles) when not is_binary(id), do: "unknown"
  defp display_name(id, %{profiles: profiles}), do: display_name(id, profiles)

  defp display_name(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{name: name}} when is_binary(name) -> name
      _ -> Ident.short_id(id)
    end
  end

  # Author names open that feed's neutral identity view.
  defp profile_href("@" <> _ = id), do: "/profile?id=" <> URI.encode_www_form(id)
  defp profile_href(_id), do: nil

  defp image_of(id, _profiles) when not is_binary(id), do: nil
  defp image_of(id, %{profiles: profiles}), do: image_of(id, profiles)

  defp image_of(id, profiles) when is_map(profiles) do
    case profiles do
      %{^id => %{image: image}} -> image
      _ -> nil
    end
  end

  defp meta_line(%{kind: :thread, rooted?: false, activity: activity}, _ctx) do
    "in a thread · last activity #{rel_time(activity)}"
  end

  defp meta_line(%{kind: :thread, replies: replies, recent: recent, activity: activity}, ctx)
       when replies > 0 do
    names =
      recent
      |> Enum.map(&author_of/1)
      |> Enum.uniq()
      |> Enum.take(2)
      |> Enum.map_join(", ", &display_name(&1, ctx))

    "#{names} replied · #{rel_time(activity)}"
  end

  defp meta_line(_row, _ctx), do: nil

  defp vote_target_label(msg, ctx) do
    case content(msg)["link"] do
      link when is_binary(link) ->
        case Map.get(ctx.index, link) do
          nil -> "an older message"
          author -> "#{display_name(author, ctx)}'s message"
        end

      _ ->
        "a message"
    end
  end

  defp other_label(msg) do
    case content(msg) do
      c when map_size(c) == 0 -> "sent a private message"
      %{"type" => type} when is_binary(type) -> "sent a #{type} message"
      _ -> "sent a message"
    end
  end

  defp rel_time(t) when is_number(t) do
    diff = System.system_time(:millisecond) - t

    cond do
      diff < 60_000 -> "just now"
      diff < 3_600_000 -> "#{div(diff, 60_000)}m ago"
      diff < 86_400_000 -> "#{div(diff, 3_600_000)}h ago"
      diff < 604_800_000 -> "#{div(diff, 86_400_000)}d ago"
      true -> t |> DateTime.from_unix!(:millisecond) |> Calendar.strftime("%b %d, %Y")
    end
  end
end
