defmodule HighWireWeb.TimelineLive do
  @moduledoc """
  The home timeline: a Patchwork/Poncho Wonky-style infinite-scroll feed.

  Every feed tab is a cursor-paginated thread-root view from the engine
  (`Timeline.feed/2`): Public, Private (decrypted), Participating
  (threads we posted into; opt-in via Settings → Notification options),
  Profile (this account's own roots) and Mentions (threads that name
  us). Pages arrive newest-activity-first and the sentinel fetches the
  next cursor, so no tab ever runs out; the flat window payload keeps
  arriving live and is merged in as fresh roots, so new posts show up
  without a refresh. Threads preview their latest replies and fold votes
  into like counts. A peer chip driven by real `gossip.peers` data
  links to the network page. Clicking a post opens the post viewer at
  `/post/:key`. The app opens straight to this feed. The Public tab's
  composer at the top of the feed publishes through the engine's
  `publish` RPC (`Timeline.publish/1`), with local validation for blank
  drafts and an offline engine.
  """

  use HighWireWeb, :live_view

  require Logger

  alias HighWire.Avatar, as: Ident
  alias HighWire.Markdown
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Nav

  import HighWireWeb.Components.Time, only: [age: 1]

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
    likes_by: %{},
    my_likes: [],
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
        Process.send_after(self(), :peers_tick, 7_000)
      end

    {status, payload} = Timeline.snapshot()

    socket =
      socket
      |> assign(:page_title, "Timeline")
      |> assign(:status, status)
      |> assign_payload(payload)
      |> assign(:peers, Timeline.network())
      |> assign(q: "", expanded: MapSet.new(), view: :public)
      |> assign(compose: "", compose_error: nil)
      |> assign(mention_suggestions: [])
      |> assign(paged: %{}, page_inflight: MapSet.new())
      |> assign(active: true, peers_timer: peers_timer)
      |> maybe_load_page()
      |> merge_paged()

    {:ok, socket}
  end

  @impl true
  def handle_info({Timeline, :updated, payload}, socket) do
    socket = socket |> assign(:status, :ok) |> assign_payload(payload)
    {:noreply, socket |> maybe_load_page() |> merge_paged()}
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

  # Cursor pages load off the render path: maybe_load_page/1 plants a
  # shell entry (which merge_paged/1 fills from the window immediately)
  # and the engine's answer — or its absence — lands here.
  def handle_info({:page_loaded, view, resume, page}, socket) do
    entry =
      socket.assigns.paged
      |> Map.get(view, %{rows: [], resume: nil, more: false})
      |> append_page(page.rows)
      |> Map.put(:resume, page.resume)
      |> Map.put(:more, page.more)
      |> Map.put(:loaded?, true)

    socket =
      socket
      |> assign(:page_inflight, MapSet.delete(socket.assigns.page_inflight, {view, resume}))
      |> assign(:paged, Map.put(socket.assigns.paged, view, merge_into(view, entry, socket)))

    {:noreply, merge_paged(socket)}
  end

  def handle_info({:page_failed, view, resume}, socket) do
    # Clear the in-flight mark; the next payload retries the load.
    {:noreply,
     assign(socket, :page_inflight, MapSet.delete(socket.assigns.page_inflight, {view, resume}))}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, assign(socket, q: String.downcase(q))}
  end

  # Composer drafts debounce into the assign; publish trims, validates
  # locally, then calls the engine. A successful publish clears the box —
  # Timeline itself schedules the reload so the post appears without a
  # poll round-trip.
  def handle_event("compose-draft", %{"body" => body}, socket) do
    {:noreply, assign(socket, compose: body)}
  end

  # The composer's mention popup: the Mentions hook saw a token started
  # with @ or ~ before the caret and sends what follows the sigil. The
  # hook splices the picked feed id into the draft locally (indices stay
  # UTF-16-safe in the browser) and pushes the new body via compose-draft.
  def handle_event("mention-query", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, assign(socket, :mention_suggestions, mention_candidates(socket, q))}
  end

  def handle_event("mention-close", _params, socket) do
    {:noreply, assign(socket, :mention_suggestions, [])}
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

  def handle_event("like", %{"key" => key}, socket) do
    result =
      if key in socket.assigns.my_likes do
        Timeline.unlike(key)
      else
        Timeline.like(key)
      end

    case result do
      {:error, reason} -> Logger.warning("timeline: like publish failed: #{inspect(reason)}")
      _ok -> :ok
    end

    {:noreply, socket}
  end

  def handle_event("view", %{"v" => v}, socket) do
    view =
      Enum.find_value(@views, :public, fn {key, _label} ->
        if Atom.to_string(key) == v, do: key
      end)

    {:noreply, socket |> assign(:view, view) |> maybe_load_page() |> merge_paged()}
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
    view = socket.assigns.view

    case Map.get(socket.assigns.paged, view) do
      %{more: true, resume: resume} when is_integer(resume) ->
        if MapSet.member?(socket.assigns.page_inflight, {view, resume}) do
          {:noreply, socket}
        else
          {:noreply, request_page(socket, view, resume)}
        end

      _ ->
        {:noreply, socket}
    end
  end

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

  # The mention popup's candidates: follows first (already sorted as
  # the sidebar's names), then anyone whose profile the window carries.
  # A bare @ or ~ lists them all; matches run display name first, then
  # the id itself so a typed short id lands too. Capped so the popup
  # never becomes a second feed.
  defp mention_candidates(socket, q) do
    profiles = Map.get(socket.assigns, :profiles, %{})
    follows = Map.get(socket.assigns, :sidebar_contacts, [])
    query = String.downcase(q)

    follows
    |> Kernel.++(Map.keys(profiles))
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
    |> Enum.uniq()
    |> Enum.map(&{&1, display_name(&1, profiles)})
    |> Enum.map(fn {id, name} -> {id, name, mention_score(name, id, query)} end)
    |> Enum.reject(fn {_id, _name, score} -> score == :miss end)
    |> Enum.sort_by(fn {id, name, score} -> {score, String.downcase(name), id} end)
    |> Enum.take(8)
    |> Enum.map(fn {id, name, _score} -> {id, name} end)
  end

  defp mention_score(_name, _id, ""), do: 0

  defp mention_score(name, id, query) do
    down_name = String.downcase(name)

    cond do
      String.starts_with?(down_name, query) -> 1
      String.contains?(down_name, query) -> 2
      String.contains?(String.downcase(id), query) -> 3
      true -> :miss
    end
  end

  defp schedule_peers(socket) do
    assign(socket, :peers_timer, Process.send_after(self(), :peers_tick, 7_000))
  end

  # The active tab's first page: fetched once the engine reports :ok,
  # kept per view so switching back restores the loaded rows. The engine's
  # flat window rides along, so follow/about events are in the tab from
  # first paint and after a view switch.
  # The cursor page loads off the render path. Until it arrives the tab
  # renders from a shell entry, which merge_paged/1 fills with window
  # rows right away — mount and tab switches never wait on the engine.
  defp maybe_load_page(
         %{assigns: %{status: status, view: view, paged: paged, page_inflight: inflight}} = socket
       ) do
    cond do
      not (connected?(socket) and status == :ok) ->
        socket

      MapSet.member?(inflight, {view, nil}) ->
        socket

      true ->
        case Map.fetch(paged, view) do
          {:ok, %{loaded?: true}} ->
            socket

          {:ok, _shell} ->
            request_page(socket, view, nil)

          :error ->
            shell = %{rows: [], resume: nil, more: false, loaded?: false}

            socket
            |> assign(:paged, Map.put(paged, view, shell))
            |> request_page(view, nil)
        end
    end
  end

  defp request_page(socket, view, resume) do
    owner = self()

    spawn(fn ->
      message =
        try do
          {:page_loaded, view, resume, Timeline.feed(view, resume)}
        catch
          _kind, _reason -> {:page_failed, view, resume}
        end

      send(owner, message)
    end)

    assign(socket, :page_inflight, MapSet.put(socket.assigns.page_inflight, {view, resume}))
  end

  # Cursor pages append at the tail, deduped in favour of the page row:
  # a quiet feed carries the same root in the window's rows too, and the
  # roots view has the true reply rollup and the newest replies.
  defp append_page(%{rows: rows} = entry, page_rows) do
    merged =
      (rows ++ page_rows)
      |> Enum.reverse()
      |> Enum.uniq_by(&row_uid/1)
      |> Enum.reverse()

    %{entry | rows: merged}
  end

  # Fresh rows from the engine's flat window merge into every loaded tab
  # within that tab's scope, then the list re-sorts by activity so
  # follows and abouts sit in chronological context among the paged
  # threads. Like totals re-annotate on the way past — a cursor page can
  # arrive carrying counts from an earlier payload.
  defp merge_paged(socket) do
    paged =
      Map.new(socket.assigns.paged, fn {view, entry} ->
        {view, merge_into(view, entry, socket)}
      end)

    socket
    |> assign(paged: paged)
    |> request_missing_profiles()
  end

  # Cursor pages, chips and likers land outside the window payload's
  # profile coverage, so whatever the rows now render that no payload
  # ever shipped a profile for goes back to the Timeline as an ensure.
  # Without this the older you page, the more rows sit on identicons.
  defp request_missing_profiles(socket) do
    known = Map.get(socket.assigns, :profiles, %{})
    likes_by = Map.get(socket.assigns, :likes_by, %{})

    missing =
      socket.assigns.paged
      |> Map.values()
      |> Enum.flat_map(&Map.get(&1, :rows, []))
      |> Enum.flat_map(&row_profile_ids(&1, likes_by))
      |> Enum.reject(&Map.has_key?(known, &1))
      |> Enum.uniq()

    if missing != [] do
      Timeline.ensure_profiles(missing)
    end

    socket
  end

  defp row_profile_ids(row, likes_by) do
    likers = Map.get(likes_by, like_target(row), [])

    [author_of(row.msg), Map.get(row, :participants, []), Map.get(row, :followed, []), likers]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
  end

  # Private rows come from the decrypted feed; the public window never
  # carries boxed messages, so there is nothing to merge in.
  defp merge_into(:private, entry, _socket), do: entry

  defp merge_into(view, entry, socket) do
    self_id = socket.assigns.self_id
    known = MapSet.new(entry.rows, &row_uid/1)

    {fresh_contacts, fresh_rows} =
      socket.assigns.feed
      |> Enum.filter(&in_scope?(view, &1, self_id))
      |> Enum.split_with(&(&1.kind == :contact))

    # A follow row's message key changes with every new follow, so its
    # identity is the author: the fresh row replaces the loaded one.
    contact_authors = MapSet.new(fresh_contacts, &author_of(&1.msg))
    {entry_contacts, entry_rest} = Enum.split_with(entry.rows, &(&1.kind == :contact))

    kept_contacts =
      Enum.reject(entry_contacts, &MapSet.member?(contact_authors, author_of(&1.msg)))

    fresh_rows = Enum.reject(fresh_rows, &MapSet.member?(known, row_uid(&1)))

    rows =
      (fresh_rows ++ fresh_contacts ++ kept_contacts ++ entry_rest)
      |> annotate_likes(socket.assigns.like_counts)
      |> Enum.sort_by(& &1.activity, :desc)
      |> Enum.uniq_by(&dedupe_id/1)

    %{entry | rows: rows}
  end

  # Thread identity is the root key — a window row whose root never
  # reached the window still carries it, while a cursor row IS the root.
  defp row_uid(%{root_key: root}) when is_binary(root), do: root
  defp row_uid(%{msg: msg}), do: msg["key"]

  # One row per follow author; everything else keys by thread identity.
  defp dedupe_id(%{kind: :contact} = row), do: {:contact, author_of(row.msg)}
  defp dedupe_id(row), do: {:row, row_uid(row)}

  defp annotate_likes(rows, like_counts) when is_map(like_counts) do
    Enum.map(rows, fn row ->
      key = row_uid(row)

      case like_counts do
        %{^key => n} when is_integer(n) -> %{row | likes: n}
        _ -> row
      end
    end)
  end

  # The window reaches the Public tab whole (threads, follows, abouts);
  # the other tabs keep the thread-only predicates below, whose guards
  # reject contact/other rows themselves.
  defp in_scope?(:public, row, _self_id), do: row.kind in [:thread, :post, :contact, :other]
  defp in_scope?(:participating, row, _self_id), do: participating?(row)
  defp in_scope?(:mentions, row, _self_id), do: mention_match?(row)
  defp in_scope?(:profile, row, self_id), do: profile_match?(row, self_id)

  defp publish_error(:offline), do: "SSB engine offline."

  defp publish_error(reason) when is_binary(reason), do: reason
  defp publish_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp publish_error(_reason), do: "Publish failed — the engine refused the message."

  @impl true
  def render(assigns) do
    page = Map.get(assigns.paged, assigns.view, %{rows: [], more: false})

    assigns =
      assign(assigns,
        rows: Enum.filter(page.rows, &matches_query?(&1, assigns.q)),
        views: @views,
        left_views: Enum.filter(@views, fn {v, _} -> v in @left_views end),
        right_views: Enum.filter(@views, fn {v, _} -> v in @right_views end),
        more: page.more,
        as: %{
          expanded: assigns.expanded,
          index: assigns.index,
          profiles: assigns.profiles,
          rev: assigns.blob_rev,
          my_likes: assigns.my_likes,
          likes_by: assigns.likes_by
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
          <p :if={@sidebar_contacts == []} class="px-4 py-1 text-xs italic text-faint">
            No contacts yet — open a profile to follow someone.
          </p>
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
            <.feed_tab :for={{v, label} <- @left_views} v={v} label={label} current={@view} />
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
            <.feed_tab :for={{v, label} <- @right_views} v={v} label={label} current={@view} />
          </nav>
          <.link
            navigate="/network"
            title="Network — connections and dialing"
            class={[
              "flex shrink-0 items-center gap-1.5 rounded px-2 py-1 text-xs transition",
              "hover:bg-raised",
              peer_tone(@peers, @status)
            ]}
          >
            <span class={["h-1.5 w-1.5 rounded-full", peer_dot(@peers, @status)]}></span>
            {peer_label(@peers, @status)}
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
                <div class="relative">
                  <textarea
                    id="compose-body"
                    name="body"
                    phx-hook="Mentions"
                    phx-debounce="300"
                    placeholder="Write a post…"
                    rows="3"
                    class="w-full resize-none rounded border border-edge bg-input px-3 py-2 text-sm text-paper placeholder:text-dim focus:border-focus focus:outline-none"
                  >{@compose}</textarea>
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
      {@label}
    </button>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true
  attr :idx, :integer, required: true

  defp post_row(assigns) do
    raw_text = text(assigns.row.msg)

    likers = Map.get(assigns.ctx.likes_by || %{}, like_target(assigns.row), [])

    assigns =
      assigns
      |> assign(:author, author_of(assigns.row.msg))
      |> assign(:author_href, profile_href(author_of(assigns.row.msg)))
      |> assign(:text_body, raw_text)
      |> assign(:private?, Map.get(assigns.row, :private?, false))
      |> assign(:like_target, like_target(assigns.row))
      |> assign(:liked, like_target(assigns.row) in assigns.ctx.my_likes)
      |> assign(:likers, Enum.take(likers, 4))
      |> assign(:liker_more, max(length(likers) - 4, 0))
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
      <div class="w-10 shrink-0">
        <Avatar.avatar
          id={@author}
          size={40}
          image={image_of(@author, @ctx.profiles)}
          rev={@ctx.rev}
          class="mt-0.5"
        />
      </div>
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="text-sm font-semibold text-paper">
            <.link :if={@author_href} navigate={@author_href} class="hover:underline">
              {display_name(@author, @ctx)}
            </.link>
            <span :if={@author_href == nil}>{display_name(@author, @ctx)}</span>
          </span>
          <span :if={@row.self?} class="text-[10px] uppercase text-faint">you</span>
          <span class="text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
          <span :if={@row.activity > ts(@row.msg)} class="text-xs text-faint">
            · active <.age ts={@row.activity} />
          </span>
          <span
            :if={@private?}
            class="rounded border border-edge px-1 text-[10px] uppercase text-faint"
          >
            private
          </span>
        </div>

        <p :if={meta = meta_line(@row, @ctx)} class="mt-0.5 text-xs text-dim">
          {meta.prefix}<.age ts={meta.ts} />
        </p>

        <div :if={@body_html != ""} class="md-body mt-1 line-clamp-4 text-sm leading-5 text-ink">
          {raw(@body_html)}
        </div>

        <div class="mt-1.5 flex items-center gap-4 text-xs text-dim">
          <span :if={@row.replies > 0}>{@row.replies} replies</span>
          <div :if={@like_target} class="flex items-center gap-1.5">
            <button
              type="button"
              phx-click="like"
              phx-value-key={@like_target}
              class={["transition-colors hover:text-paper", @liked and "font-medium text-accent"]}
              title={if(@liked, do: "Unlike", else: "Like")}
            >
              ❤
            </button>
            <span :for={liker <- @likers} title={display_name(liker, @ctx)} class="inline-flex">
              <Avatar.avatar
                id={liker}
                size={16}
                image={image_of(liker, @ctx.profiles)}
                rev={@ctx.rev}
              />
            </span>
            <span :if={@liker_more > 0} class="text-[11px] text-faint">+{@liker_more}</span>
          </div>
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
            <span class="truncate text-xs text-sub">{snippet(reply, @ctx)}</span>
            <span class="ml-auto shrink-0 text-[11px] text-faint">
              <.age ts={ts(reply)} />
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
      <div class="w-10 shrink-0">
        <Avatar.avatar
          id={author_of(@row.msg)}
          size={24}
          image={image_of(author_of(@row.msg), @ctx.profiles)}
          rev={@ctx.rev}
        />
      </div>
      <p>
        <span class="text-ink">{display_name(author_of(@row.msg), @ctx)}</span>
        liked <span class="text-ink">{vote_target_label(@row.msg, @ctx)}</span>
      </p>
      <span class="ml-auto text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
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
      <div class="w-10 shrink-0">
        <Avatar.avatar
          id={@author}
          size={24}
          image={image_of(@author, @ctx.profiles)}
          rev={@ctx.rev}
        />
      </div>
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
      <span class="ml-auto shrink-0 text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  defp other_row(assigns) do
    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm italic text-faint hover:bg-panel">
      <div class="w-10 shrink-0">
        <Avatar.avatar
          id={author_of(@row.msg)}
          size={24}
          image={image_of(author_of(@row.msg), @ctx.profiles)}
          rev={@ctx.rev}
        />
      </div>
      <p>
        <span class="not-italic text-ink">{display_name(author_of(@row.msg), @ctx)}</span>
        {other_label(@row.msg)}
      </p>
      <span class="ml-auto not-italic text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
    </div>
    """
  end

  # -- payload / assigns -------------------------------------------------

  defp assign_payload(socket, %{feed: feed} = payload) do
    # Accumulate: a cursor page may have asked Timeline for profiles
    # this payload never carried, and the next payload (status-only
    # broadcasts carry no profiles) must not evict them.
    profiles =
      Map.merge(Map.get(socket.assigns, :profiles, %{}), Map.get(payload, :profiles, %{}))

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
    |> assign(:likes_by, Map.get(payload, :likes_by, %{}))
    |> assign(:my_likes, Map.get(payload, :my_likes, []))
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
    |> assign(:likes_by, @empty_payload.likes_by)
    |> assign(:my_likes, @empty_payload.my_likes)
    |> assign(:index, @empty_payload.index)
    |> assign(:self_id, nil)
    |> assign(:profiles, Map.get(socket.assigns, :profiles, %{}))
    |> assign(:blob_rev, 0)
    |> assign(:sidebar_contacts, Map.get(socket.assigns, :sidebar_contacts, []))
    |> assign(:suggestions, @empty_payload.suggestions)
  end

  # -- row selection ------------------------------------------------------
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
  # The header network chip is the timeline's always-visible way into
  # /network: the live peer count when a report exists, a status-aware
  # fallback otherwise. It never hides — a hidden chip is exactly when
  # users need the dialing page most.
  defp peer_count(network) when is_map(network), do: length(network["connections"] || [])

  defp peer_label(nil, :connecting), do: "Connecting…"
  defp peer_label(nil, :disabled), do: "Engine off"
  defp peer_label(nil, _status), do: "Network"

  defp peer_label(peers, _status) do
    n = peer_count(peers)
    "#{n} peer#{if n == 1, do: "", else: "s"}"
  end

  defp peer_dot(nil, :connecting), do: "bg-dot-info animate-pulse"
  defp peer_dot(nil, :disabled), do: "bg-dot-bad"
  defp peer_dot(nil, _status), do: "bg-dot"

  defp peer_dot(peers, _status) do
    if peer_count(peers) > 0, do: "bg-dot-ok", else: "bg-dot"
  end

  defp peer_tone(nil, :connecting), do: "text-info"
  defp peer_tone(nil, :disabled), do: "text-bad"
  defp peer_tone(nil, _status), do: "text-dim"

  defp peer_tone(peers, _status) do
    if peer_count(peers) > 0, do: "text-ok", else: "text-dim"
  end

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

  # One-line plain preview of a recent reply. The markdown renders
  # first — so **bold**, > quotes and [links](…) preview as their text
  # instead of their source — then tags drop out, entities decode, and
  # the line clamps. Public (with @doc false) for direct tests.
  @doc false
  def snippet(msg, ctx \\ %{rev: nil}) do
    msg
    |> text()
    |> String.replace(@image_re, "[image]")
    |> Markdown.to_html(blob_rev: Map.get(ctx, :rev))
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#x27;", "'")
    |> String.replace("&amp;", "&")
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
    %{prefix: "in a thread · last activity ", ts: activity}
  end

  defp meta_line(%{kind: :thread, replies: replies, recent: recent, activity: activity}, ctx)
       when replies > 0 do
    names =
      recent
      |> Enum.map(&author_of/1)
      |> Enum.uniq()
      |> Enum.take(2)
      |> Enum.map_join(", ", &display_name(&1, ctx))

    %{prefix: "#{names} replied · ", ts: activity}
  end

  defp meta_line(_row, _ctx), do: nil

  # The message a row's heart votes on: the thread root for threads
  # (counts aggregate the whole thread), the message itself otherwise.
  # Contact rows have no vote target.
  defp like_target(%{kind: :thread, root_key: key}) when is_binary(key), do: key
  defp like_target(%{kind: :thread, msg: msg}), do: msg["key"]
  defp like_target(%{kind: :post, msg: msg}), do: msg["key"]
  defp like_target(_row), do: nil

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
      %{"type" => "channel"} = c -> channel_label(c)
      %{"type" => "about"} -> "updated their profile"
      %{"type" => type} when is_binary(type) -> "sent a #{type} message"
      _ -> "sent a message"
    end
  end

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
end
