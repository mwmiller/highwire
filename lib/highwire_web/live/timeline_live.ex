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
  use Memoize

  require Logger

  alias HighWire.Avatar, as: Ident
  alias HighWire.Contacts
  alias HighWire.Markdown
  alias HighWire.SearchIndex
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Heart
  alias HighWireWeb.Components.Likers
  alias HighWireWeb.Components.Mentions
  alias HighWireWeb.Components.Nav
  alias HighWireWeb.MessageText

  import HighWireWeb.Components.Time, only: [age: 1]

  # Patchwork's feed tabs: the three left of the search box, and the
  # Mentions tab right of it beside the Profile link. The link is
  # navigation — your own profile page, same as clicking your id — not
  # a feed view. Participating is opt-in — Settings → Notification
  # options, after Patchwork — and hidden by CSS
  # (html[data-participating]) until the pref is on.
  @views [
    {:public, "Public"},
    {:private, "Private"},
    {:participating, "Participating"},
    {:mentions, "Mentions"}
  ]

  # How long "Show another set" holds the button down waiting for the
  # Suggester. The Timeline gives its ranking 25 tries at 400ms; this
  # ends sooner, so a ranking with nothing new to offer cannot leave
  # the reader staring at a dead button for ten seconds.
  @suggestions_hold_ms 6_000

  @left_views [:public, :private, :participating]
  @right_views [:mentions]

  # markdown image syntax: ![alt](target)
  @image_re ~r/!\[([^\]]*)\]\(([^()\s]+)\)/

  # Reply snippets are memoized; 31 minutes matches the Markdown cache.
  @snippet_ttl_ms 1_860_000

  # Backoff for a page the engine failed to return: 1s doubling up to 30s.
  # Long enough not to hammer a restarting engine, short enough that the
  # feed picks itself back up without the reader doing anything.
  @page_retry_ms 1_000
  @page_retry_max_ms 30_000

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
        Process.send_after(self(), :index_tick, 4_000)
        Process.send_after(self(), :peers_tick, 7_000)
      end

    {status, payload} = Timeline.snapshot()

    socket =
      socket
      |> assign(:page_title, "Timeline")
      |> assign(:status, status)
      |> assign_payload(payload)
      |> assign(:peers, live_network(Timeline.network()))
      |> assign(q: "", expanded: MapSet.new(), view: :public)
      |> assign(contacts_expanded: false)
      |> assign(max_sidebar_contacts: Contacts.subset_size())
      |> assign(compose: "", compose_error: nil)
      |> assign(like_pending: MapSet.new(), like_error: nil)
      |> assign(private_recipients: MapSet.new())
      |> assign(compose_pending: false)
      |> assign(suggestions_pending: false)
      |> assign(mention_suggestions: [])
      |> assign(paged: %{}, page_inflight: MapSet.new(), page_retries: %{})
      |> assign(active: true, peers_timer: peers_timer)
      # Arrival shimmer: rows the next wave brings that this store
      # never saw. seen_keys is the top-window baseline — it only
      # moves when a real feed payload lands, so status-only
      # broadcasts can't fake a wave.
      |> assign(arrived: MapSet.new(), arrived_timer: nil)
      |> assign(seen_keys: top_keys(Map.get(payload, :feed, [])))
      |> assign(:transfer, Timeline.transfer_status())
      |> assign(transfer_timer: nil)
      |> assign(:search_hits, [])
      |> assign(:search_q_kicked, "")
      |> assign(:search_state, :idle)
      |> assign(:index_status, SearchIndex.status())
      |> maybe_load_page()
      |> merge_paged()

    {:ok, arm_transfer(socket)}
  end

  @impl true
  def handle_info({Timeline, :updated, payload}, socket) do
    socket = assign(socket, :status, :ok)

    socket =
      if Map.has_key?(payload, :feed) do
        top = top_keys(payload.feed)
        fresh = MapSet.new(top) |> MapSet.difference(MapSet.new(socket.assigns.seen_keys))

        socket
        |> assign(:seen_keys, top)
        |> mark_arrived(fresh |> Enum.take(6) |> MapSet.new())
      else
        socket
      end

    {:noreply, socket |> assign_payload(payload) |> maybe_load_page() |> merge_paged()}
  end

  def handle_info(:arrived_clear, socket) do
    {:noreply, assign(socket, arrived: MapSet.new(), arrived_timer: nil)}
  end

  # Network activity: Timeline pushes the window as it bumps, so the
  # header's indicator rides the real 2.5s window instead of a poll
  # that would be late more often than not.
  def handle_info({Timeline, :transfer, status}, socket) do
    {:noreply, socket |> assign(:transfer, status) |> arm_transfer()}
  end

  def handle_info(:transfer_clear, socket) do
    {:noreply,
     assign(socket, transfer: %{socket.assigns.transfer | active?: false}, transfer_timer: nil)}
  end

  # The other end of the "Show another set" hold: a payload carries the
  # ranking's answer, and this ends the hold when no answer came at all.
  def handle_info(:suggestions_hold_over, socket) do
    {:noreply, assign(socket, :suggestions_pending, false)}
  end

  def handle_info(:peers_tick, socket) do
    if socket.assigns.peers_timer, do: Process.cancel_timer(socket.assigns.peers_timer)
    socket = assign(socket, :peers_timer, nil)

    if socket.assigns.active and connected?(socket) do
      Timeline.set_activity(self(), true)
      {:noreply, socket |> assign(:peers, live_network(Timeline.network())) |> schedule_peers()}
    else
      {:noreply, socket}
    end
  end

  # The index reports through its own ETS table, so this is a lookup
  # rather than a GenServer call that could queue behind a backlog
  # flood. Assign only on change — an unchanged tick must not re-render
  # the header.
  def handle_info(:index_tick, socket) do
    status = SearchIndex.status()

    socket =
      if status == socket.assigns.index_status do
        socket
      else
        assign(socket, :index_status, status)
      end

    {:noreply, schedule_index_tick(socket)}
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
      |> assign(:page_retries, Map.delete(socket.assigns.page_retries, {view, resume}))
      |> assign(:paged, Map.put(socket.assigns.paged, view, merge_into(view, entry, socket)))

    {:noreply, merge_paged(socket)}
  end

  # A page that never arrived is not the end of the feed. Leave `more` and
  # `resume` exactly as they were so the sentinel stays and the reader can
  # carry on, and try again on a backoff. The retry is not optional: the
  # sentinel only asks for more on an intersection *change*, so a failure
  # while the reader sits at the bottom would otherwise strand them — the
  # feed would look finished and never continue.
  def handle_info({:page_failed, view, resume}, socket) do
    socket =
      socket
      |> assign(:page_inflight, MapSet.delete(socket.assigns.page_inflight, {view, resume}))
      |> schedule_page_retry(view, resume)

    {:noreply, socket}
  end

  def handle_info({:retry_page, view, resume}, socket) do
    # A view the reader has left is not paging anymore; the tab switch
    # re-mounts the sentinel, which fires its own initial observation.
    cond do
      socket.assigns.view != view ->
        {:noreply,
         assign(socket, :page_retries, Map.delete(socket.assigns.page_retries, {view, resume}))}

      MapSet.member?(socket.assigns.page_inflight, {view, resume}) ->
        {:noreply, socket}

      true ->
        case Map.get(socket.assigns.paged, view) do
          %{more: true, resume: ^resume} ->
            {:noreply, request_page(socket, view, resume)}

          # The first page never landed: its shell still stands with no
          # cursor and `loaded?` false, and without this arm the retry
          # would be dropped as "nothing outstanding" — the feed would
          # sit with rows on screen, no sentinel, no end, and no ask.
          %{loaded?: false, resume: ^resume} ->
            {:noreply, request_page(socket, view, resume)}

          # Nothing outstanding for this cursor anymore. Drop the count,
          # or the reader would be told the feed is still loading long
          # after it stopped.
          _ ->
            {:noreply,
             assign(
               socket,
               :page_retries,
               Map.delete(socket.assigns.page_retries, {view, resume})
             )}
        end
    end
  end

  @impl true
  def handle_info({:search_results, q, hits}, socket) do
    qd = socket.assigns.q

    if q != "" and String.downcase(q) == qd do
      {:noreply, assign(socket, search_hits: hits || [], search_state: :idle)}
    else
      if qd != "" and qd != socket.assigns.search_q_kicked do
        # What is on screen moved on while this answer was in flight, so
        # the answer belongs to an older query and nothing here may use
        # it. Ask for what is typed now — the kicked marker holds the
        # count to one query in flight, and the answer to this newer ask
        # either lands it or repeats the walk forward.
        {:noreply, kick_search(socket, qd, qd)}
      else
        {:noreply, socket}
      end
    end
  end

  # The publish itself, behind the held button: the press has already
  # been shown the box in flight, and this reply is the one that says
  # whether the post went out. The box and the recipients were settled
  # at press time, so a tab switch under a publish cannot change who
  # it goes to.
  def handle_info({:publish_post, body, recipients, private?}, socket) do
    result =
      if private?, do: Timeline.publish_private(body, recipients), else: Timeline.publish(body)

    socket =
      case result do
        {:ok, _key} ->
          if private? do
            assign(socket, compose: "", compose_error: nil, private_recipients: MapSet.new())
          else
            assign(socket, compose: "", compose_error: nil)
          end

        {:error, reason} ->
          assign(socket, compose_error: publish_error(reason))
      end

    {:noreply, assign(socket, compose_pending: false)}
  end

  # The like itself, behind the filled heart. The heart already shows
  # the state the press asked for; this reply is the one that says
  # whether it took, and a refusal puts the heart back and says so
  # rather than leaving the reader to notice it empty again.
  def handle_info({:publish_like, key, liked?}, socket) do
    result = if liked?, do: Timeline.unlike(key), else: Timeline.like(key)

    socket = update(socket, :like_pending, &MapSet.delete(&1, key))

    case result do
      {:error, reason} ->
        Logger.warning("timeline: like publish failed: #{inspect(reason)}")
        {_status, payload} = Timeline.snapshot()
        {:noreply, socket |> assign_payload(payload) |> assign(:like_error, like_error(reason))}

      _ok ->
        {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # A query goes out with the view marked pending: a fold of the store is
  # not instant, and until the answer lands the view knows nothing yet,
  # so it says it is searching rather than reading as an answer — while
  # the previous query's hits stay up, still the best answer on screen.
  defp kick_search(socket, qtrim, qd) do
    socket = assign(socket, search_q_kicked: qd, search_state: :pending)

    case SearchIndex.search(qtrim, self()) do
      :ok ->
        socket

      {:error, reason} ->
        # No answer is coming; do not leave the reader waiting on one.
        Logger.warning("timeline: search for #{inspect(qtrim)} did not start: #{inspect(reason)}")

        assign(socket, search_state: :stalled)
    end
  end

  defp schedule_page_retry(socket, view, resume) do
    key = {view, resume}
    attempts = Map.get(socket.assigns.page_retries, key, 0)

    Process.send_after(self(), {:retry_page, view, resume}, page_retry_delay(attempts))
    assign(socket, :page_retries, Map.put(socket.assigns.page_retries, key, attempts + 1))
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    qtrim = q |> to_string() |> String.trim()
    qd = String.downcase(qtrim)
    socket = assign(socket, q: qd)

    cond do
      qd == "" ->
        {:noreply, assign(socket, search_hits: [], search_q_kicked: "", search_state: :idle)}

      socket.assigns.search_state == :pending or qd == socket.assigns.search_q_kicked ->
        # One query at a time: while an answer is out it holds the kick,
        # and what was typed over it in the meantime is asked for when it
        # lands — an answer for a superseded query asks forward itself.
        # Re-asking the query that was just asked has nothing to add.
        {:noreply, socket}

      true ->
        {:noreply, kick_search(socket, qtrim, qd)}
    end
  end

  # Composer drafts debounce into the assign; publish trims, validates
  # locally, then calls the engine. A successful publish clears the box —
  # Timeline itself schedules the reload so the post appears without a
  # poll round-trip.
  def handle_event("compose-draft", %{"body" => body} = params, socket) do
    socket = assign(socket, compose: body)

    # The private composer's recipient boxes ride the same change event,
    # so the selection survives the re-render a keystroke triggers.
    if socket.assigns.view == :private do
      {:noreply,
       assign(socket, private_recipients: MapSet.new(Map.get(params, "recipients", [])))}
    else
      {:noreply, socket}
    end
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

  def handle_event("publish", %{"body" => body} = params, socket) do
    body = String.trim(body)

    cond do
      body == "" ->
        {:noreply, assign(socket, compose_error: "Nothing to publish.")}

      socket.assigns.status == :disabled ->
        {:noreply,
         assign(socket, compose_error: "Publishing is turned off in this configuration.")}

      not is_binary(socket.assigns.self_id) ->
        {:noreply, assign(socket, compose_error: "Still connecting. Try again in a moment.")}

      socket.assigns.compose_pending ->
        {:noreply, socket}

      true ->
        {:noreply, publish_now(socket, body, Map.get(params, "recipients", []))}
    end
  end

  # The press is answered by the heart filling, and the publish waits
  # behind it: the pill holds down while it runs, so a second press is a
  # duplicate rather than a second like. The reply that comes back is
  # the one that says whether it took.
  def handle_event("like", %{"key" => key}, socket) do
    if MapSet.member?(socket.assigns.like_pending, key) do
      {:noreply, socket}
    else
      liked? = key in socket.assigns.my_likes

      socket =
        socket
        |> assign(:like_error, nil)
        |> update(:like_pending, &MapSet.put(&1, key))
        |> assign(Heart.toggle(socket.assigns, key))

      send(self(), {:publish_like, key, liked?})

      {:noreply, socket}
    end
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

  def handle_event("toggle-contacts", _params, socket) do
    # The collapsed draw is held by HighWire.Contacts, so folding the
    # full list away just re-shows that draw where it stands.
    {:noreply, assign(socket, contacts_expanded: !socket.assigns.contacts_expanded)}
  end

  # Ranking runs in HighWire.Suggester off-process and comes back over
  # the next payload broadcast, so there is no round trip for the click
  # itself to wait in: the press is answered by taking the hold. It
  # ends with the first answer, however long the ranking took, and the
  # timer ends it even when there was nothing new to say.
  def handle_event("refresh-suggestions", _params, socket) do
    if socket.assigns.suggestions_pending do
      {:noreply, socket}
    else
      Timeline.refresh_suggestions()
      Process.send_after(self(), :suggestions_hold_over, @suggestions_hold_ms)

      {:noreply, assign(socket, :suggestions_pending, true)}
    end
  end

  # The post row's OpenPost hook ignores clicks on links/buttons, so a
  # title click lands here: hand the raw message key to the viewer as an
  # url-safe base64 path segment (message keys contain "/").
  def handle_event("open-post", %{"key" => key}, socket) when is_binary(key) do
    {:noreply, push_navigate(socket, to: "/post/" <> Base.url_encode64(key, padding: false))}
  end

  # Both the sentinel and the manual load ask through the same door. One
  # request per cursor: the answer is keyed {view, resume}, so a second
  # press while one is out would strand the first — the press is instead
  # answered by the footer's own control taking the hold ("Loading…",
  # dead under it) until the answer lands.
  def handle_event("load-more", _params, socket) do
    view = socket.assigns.view

    case Map.get(socket.assigns.paged, view) do
      %{more: true, resume: resume} when is_integer(resume) ->
        ask_page(socket, view, resume)

      # The first page never arrived — or its retry is still owed: a
      # feed whose shell stands unloaded is still a feed to ask for, and
      # this is the manual way past a push the browser never delivered.
      %{loaded?: false, resume: resume} ->
        ask_page(socket, view, resume)

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

    {:noreply, socket |> assign(:active, false) |> assign(peers_timer: nil)}
  end

  # The press is answered by the button taking the hold, and the
  # publish waits behind it: the render that goes out now carries
  # "Publishing…" with the button dead under it, so the post is on its
  # way while the rest of the timeline keeps answering. A press the
  # composer can already refuse on its own never leaves the box: the
  # reason is said at once, with no hold in between.
  defp publish_now(socket, body, chosen) do
    private? = socket.assigns.view == :private
    recipients = boxed_recipients(socket, chosen)

    if private? and recipients == [socket.assigns.self_id] do
      assign(socket, compose_error: "Choose at least one recipient.")
    else
      send(self(), {:publish_post, body, recipients, private?})
      assign(socket, compose_pending: true)
    end
  end

  # A private thread is boxed for the chosen follows plus self, so the
  # author can read back what they wrote. No choice means nothing to send
  # to — the box needs at least one recipient that is not us.
  defp boxed_recipients(socket, chosen) do
    chosen
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Kernel.++([socket.assigns.self_id])
    |> Enum.uniq()
  end

  # The mention popup's candidates: follows first (already sorted as
  # the sidebar's names), then anyone whose profile the window carries.
  # A bare @ or ~ lists them all; matches run display name first, then
  # the id itself so a typed short id lands too. Capped so the popup
  # never becomes a second feed.
  defp mention_candidates(socket, q) do
    profiles = Map.get(socket.assigns, :profiles, %{})
    follows = Map.get(socket.assigns, :all_contacts, [])

    Mentions.candidates(q, follows ++ Map.keys(profiles), &Ident.display_name(&1, profiles))
  end

  defp schedule_peers(socket) do
    assign(socket, :peers_timer, Process.send_after(self(), :peers_tick, 7_000))
  end

  # Deliberately not stored or cancelled: one ETS lookup every 4s is
  # cheaper than the bookkeeping, and the chip should stay fresh even
  # while another tab is in front.
  defp schedule_index_tick(socket) do
    Process.send_after(self(), :index_tick, 4_000)
    socket
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

  # Every request gets an answer. The feed call itself translates the
  # engine's refusals, but a raise the public wrapper does not catch
  # would leave the cursor in `page_inflight` forever — the tail would
  # sit on "Loading more…" with nothing outstanding and no way to ask
  # again. The catch turns that into the failure path, which retries and
  # says so.
  defp request_page(socket, view, resume) do
    owner = self()

    spawn(fn ->
      message =
        try do
          case Timeline.feed(view, resume) do
            {:ok, page} -> {:page_loaded, view, resume, page}
            {:error, _reason} -> {:page_failed, view, resume}
          end
        catch
          _kind, _reason -> {:page_failed, view, resume}
        end

      send(owner, message)
    end)

    assign(socket, :page_inflight, MapSet.put(socket.assigns.page_inflight, {view, resume}))
  end

  defp ask_page(socket, view, resume) do
    if MapSet.member?(socket.assigns.page_inflight, {view, resume}) do
      {:noreply, socket}
    else
      {:noreply, request_page(socket, view, resume)}
    end
  end

  # Cursor pages append at the tail, deduped in favour of the page row:
  # a quiet feed carries the same root in the window's rows too, and the
  # roots view has the true reply rollup and the newest replies.
  # Page rows are tagged: they are the reader's scroll into the past and
  # merge_into carries them whole instead of re-trimming them against the
  # window's cap.
  defp append_page(%{rows: rows} = entry, page_rows) do
    page_rows = Enum.map(page_rows, &Map.put(&1, :paged, true))

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

    [author_of(row.msg), Map.get(row, :participants, []), contact_people(row), likers]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
  end

  # Everyone a contact row is about — the lists are the row's action
  # (:followed, :blocked, :unfollowed, :unblocked), so all of them must
  # be collected for profiles and search alike.
  defp contact_people(row) do
    Map.get(row, :followed, []) ++
      Map.get(row, :blocked, []) ++
      Map.get(row, :unfollowed, []) ++ Map.get(row, :unblocked, [])
  end

  # Private rows come from the decrypted feed; the public window never
  # carries boxed messages, so there is nothing to merge in.
  defp merge_into(:private, entry, _socket), do: entry

  # Cap on the rows a single tab's window contributes. The window's
  # flat feed can build hundreds of rows (its whole job is surfacing
  # activity the roots view hasn't indexed yet), and merge_into
  # prepends them to the cursor pages — left uncapped that paints a
  # wall of rows on first load. It bounds the window only: the cursor
  # pages are the reader's way into the past and are never dropped.
  # Losing the tail loses only the stalest window rows; a row whose
  # root is in a cursor page survives the dedupe via that page.
  @max_tab_rows 30

  defp merge_into(view, entry, socket) do
    self_id = socket.assigns.self_id

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

    # A fresh row for an already-loaded thread raises that row's activity
    # in place instead of being discarded — a new reply must move the
    # thread up. Raise-only: the window slice slides (a reply ages out),
    # and a lower activity must never sink a row that already earned its
    # position. The loaded row keeps its content: a cursor page carries
    # the true reply rollup the window can't see.
    known = MapSet.new(entry_rest, &row_uid/1)
    fresh_by_uid = Map.new(fresh_rows, &{row_uid(&1), &1})

    entry_rest =
      Enum.map(entry_rest, fn loaded ->
        case Map.fetch(fresh_by_uid, row_uid(loaded)) do
          {:ok, fresh} -> raise_activity(fresh, loaded)
          :error -> loaded
        end
      end)

    added = Enum.reject(fresh_rows, &MapSet.member?(known, row_uid(&1)))

    # The cap bounds the window's contribution, not the accumulated
    # list: the window is the only source of "too much, too soon", and
    # paging deeper is exactly what the reader asked for. Trimming the
    # union instead pinned the tab at the cap — every cursor page was
    # older than the 120 newest window rows, so it arrived and was
    # sorted straight back off the bottom.
    #
    # Page rows (tagged by append_page) are therefore carried whole.
    # Everything else is a window row, either fresh or carried from the
    # last merge; the trimmed tail comes back through `added` next time
    # and loses the same sort, so the cap is idempotent.
    {paged_rows, window_carried} = Enum.split_with(entry_rest, &Map.get(&1, :paged, false))

    window_rows =
      (added ++ window_carried ++ fresh_contacts ++ kept_contacts)
      |> Enum.sort_by(& &1.activity, :desc)
      |> Enum.take(@max_tab_rows)

    rows =
      (window_rows ++ paged_rows)
      |> annotate_likes(socket.assigns.like_counts)
      |> Enum.sort_by(& &1.activity, :desc)
      |> Enum.uniq_by(&dedupe_id/1)

    %{entry | rows: rows}
  end

  # A window row's activity raised above the loaded row's: adopt the
  # newer activity (so the sort moves it up) and the window's reply
  # previews (they include the reply that caused the bump), while the
  # loaded row keeps its identity and its engine-true reply count —
  # the window only counts replies its slice happened to see.
  defp raise_activity(fresh, loaded) do
    if fresh.activity > loaded.activity do
      %{
        loaded
        | activity: fresh.activity,
          recent: fresh.recent,
          replies: max(loaded.replies, fresh.replies)
      }
    else
      loaded
    end
  end

  @doc false
  def max_tab_rows, do: @max_tab_rows

  # Exponential backoff, capped, for retrying a page the engine failed to
  # return. The exponent is clamped too: past a handful of attempts the
  # delay is pinned at the cap anyway, and the counter keeps climbing for
  # as long as the engine is out.
  #
  # Exposed for the test: the retry itself is a timer, which is awkward to
  # assert directly.
  @doc false
  def page_retry_delay(attempts) when is_integer(attempts) and attempts >= 0 do
    min(@page_retry_ms * Integer.pow(2, min(attempts, 5)), @page_retry_max_ms)
  end

  # Whether the reader's tab has a page outstanding — requested, or
  # waiting out the backoff before it is requested again. Both sets are
  # keyed {view, resume} and a switch of tab strands neither: the count
  # for an abandoned view is dropped when its timer next fires.
  #
  # The initial fill (resume nil, kicked on mount) is not "more": the
  # window's rows are already on screen and the page is a background
  # top-up, so it must not flash a loading bar over a feed the reader is
  # already reading. Only a page past that first one, or a retry of it,
  # counts.
  defp pending_more?(pending, view) do
    Enum.any?(pending, fn
      {pending_view, resume} when pending_view == view and is_integer(resume) -> true
      _ -> false
    end)
  end

  # Thread identity is the root key — a window row whose root never
  # reached the window still carries it, while a cursor row IS the root.
  defp row_uid(%{kind: :contact} = row) do
    action = Map.get(row, :contact_action, :followed)
    author = author_of(row.msg)
    key = row.msg["key"]

    case {author, key} do
      {a, k} when is_binary(a) and is_binary(k) -> k <> ":" <> to_string(action) <> ":" <> a
      {_, k} when is_binary(k) -> k <> ":" <> to_string(action)
      _ -> nil
    end
  end

  defp row_uid(%{root_key: root}) when is_binary(root), do: root
  defp row_uid(%{msg: msg}), do: msg["key"]

  # One row per author per contact direction per spate — a follow and a
  # block by the same author are two rows, and a spate that cooled off
  # before the next one is its own line. The anchor message keys it: the
  # row moves while its spate is live, then freezes when the cooloff ends.
  # Everything else keys by thread identity.
  defp dedupe_id(%{kind: :contact} = row),
    do: {:contact, author_of(row.msg), Map.get(row, :contact_action, :followed), row.msg["key"]}

  defp dedupe_id(row), do: {:row, row_uid(row)}

  # DOM identity for a feed row. LiveView patches repeated children by
  # id, so a positional post-<idx> id detaches from its message the
  # moment the feed reorders and leaves the old row in the document.
  # Encode the uid rather than interpolating it: keys are base64 with
  # / and = in them, and an id has to survive being used as a selector.
  defp dom_id(prefix, %{kind: :contact} = row) do
    action = Map.get(row, :contact_action, :followed)
    author = author_of(row.msg)
    key = row.msg["key"]

    case {author, key} do
      {a, k} when is_binary(a) and is_binary(k) ->
        id = :erlang.phash2({:contact, a, action, k})
        prefix <> "c-" <> Integer.to_string(id)

      {_, k} when is_binary(k) ->
        prefix <> Base.url_encode64(k, padding: false) <> "-" <> to_string(action)

      _ ->
        prefix <> "anon-" <> Integer.to_string(:erlang.phash2(row))
    end
  end

  defp dom_id(prefix, row) do
    case row_uid(row) do
      uid when is_binary(uid) -> prefix <> Base.url_encode64(uid, padding: false)
      nil -> prefix <> "anon-" <> Integer.to_string(:erlang.phash2(row))
    end
  end

  # -- arrival shimmer ----------------------------------------------------

  # The identity of the top of the feed — what a wave can change.
  defp top_keys(feed) when is_list(feed), do: feed |> Enum.take(8) |> Enum.map(&row_uid/1)
  defp top_keys(_), do: []

  # Always swap in the new set (an empty one retires a glow still
  # playing); only a real wave bumps the pulse and arms the timer.
  defp mark_arrived(socket, arrived) do
    socket = assign(socket, :arrived, arrived)

    if MapSet.size(arrived) > 0 do
      socket |> bump_gossip() |> clear_arrived_later()
    else
      socket
    end
  end

  defp bump_gossip(socket) do
    case socket.assigns do
      %{gossip: %{pulse: pulse} = gossip} ->
        assign(socket, :gossip, %{gossip | pulse: pulse + 1})

      _ ->
        socket
    end
  end

  defp clear_arrived_later(socket) do
    if socket.assigns.arrived_timer, do: Process.cancel_timer(socket.assigns.arrived_timer)
    assign(socket, :arrived_timer, Process.send_after(self(), :arrived_clear, 1_800))
  end

  # The activity window is 2.5s (Timeline's transfer_status). A bump
  # turns the indicator on; this timer turns it back off, re-armed on
  # every bump so a burst reads as one continuous glow.
  defp arm_transfer(socket) do
    if socket.assigns.transfer_timer, do: Process.cancel_timer(socket.assigns.transfer_timer)

    timer =
      if socket.assigns.transfer.active? do
        Process.send_after(self(), :transfer_clear, 2_500)
      end

    assign(socket, :transfer_timer, timer)
  end

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
  # reject contact/other rows themselves. Private follows merge_into's
  # rule: the public window never carries boxed messages, so a private
  # search draws on loaded pages alone.
  defp in_scope?(:public, row, _self_id), do: row.kind in [:thread, :post, :contact, :other]
  defp in_scope?(:private, _row, _self_id), do: false
  defp in_scope?(:participating, row, _self_id), do: participating?(row)
  defp in_scope?(:mentions, row, _self_id), do: mention_match?(row)

  defp publish_error(:offline), do: "Not connected yet. Try again in a moment."

  defp publish_error(reason) when is_binary(reason), do: reason
  defp publish_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp publish_error(_reason), do: "Publish failed."

  # A like the engine refused is the one action on this page that undoes
  # itself, so it names what happened rather than leaving the reader to
  # work it out from a heart that emptied again.
  defp like_error(:offline),
    do: "That like didn't go through: not connected yet. Try again in a moment."

  defp like_error(_reason), do: "That like didn't go through. Try again."

  # The tail of the feed reads four ways: a page on its way back, more
  # rows still to ask for, a page that failed to come back — which says
  # so and offers the ask by hand — or the true end. A reader used to
  # have to guess between them — an invisible load and the end of
  # history looked identical. All of them require rows on screen, so an
  # empty feed keeps its own message and a feed that has not landed a
  # page yet claims nothing about how far back it goes.
  #
  # Search adds a second question: whose hits are the results? When the
  # index is caught up it is the whole truth, so its hits stand alone.
  # While it is still building (or absent), the loaded-row filter runs
  # alongside, so a search never comes up emptier than the feed on
  # screen.
  #
  # And a third: has the index answered at all? A query in flight is not
  # a result, so an empty screen while one is out says it is searching
  # rather than reading as "nothing matches".
  defp ui_state(assigns, page, rows) do
    store_results? = assigns.q != "" and assigns.index_status == :live
    local_rows? = not store_results?

    finished? = finished_rows?(assigns, page, rows)

    # The page the reader would ask for next: the shell's nil cursor
    # while the first fill is outstanding, the last page's cursor after
    # it. A failure counts only when it belongs to THAT page — a stale
    # attempt from a page already superseded must not hang a failure
    # line under a feed that is paging fine.
    next = {assigns.view, Map.get(page, :resume)}
    failed? = load_failed?(assigns, rows, finished?, next)
    pending? = MapSet.member?(assigns.page_inflight, next)

    %{
      loading?: loading_rows?(assigns, rows) and not finished? and not failed?,
      finished?: finished?,
      load_failed?: failed?,
      load_more?:
        rows != [] and assigns.q == "" and not finished? and
          (Map.get(page, :more, false) or failed?),
      load_more_pending?: pending?,
      load_more_label: load_more_label(pending?, failed?),
      local_rows?: local_rows?,
      empty_search?: empty_search?(assigns, rows, local_rows?)
    }
  end

  # A page failure is recognized under the rows it left behind: the line
  # says the load did not land, and the control beside it asks again.
  # The backoff keeps retrying on its own — the button is for the reader
  # who is watching, and for a push the browser never delivered at all:
  # a JS failure leaves no server signal, so the manual load stands
  # whenever there is more to ask for. Rows gate the line as they gate
  # the end — an empty feed keeps its own message rather than claiming
  # failure over silence.
  defp load_failed?(assigns, rows, finished?, next) do
    rows != [] and assigns.q == "" and not finished? and
      Map.has_key?(assigns.page_retries, next)
  end

  # The manual load reads from its own state: a press is answered with a
  # hold, a failure with the ask again, and the rest of the time with the
  # plain offer.
  @doc false
  def load_more_label(pending?, failed?) do
    cond do
      pending? -> "Loading…"
      failed? -> "Try again"
      true -> "Load more"
    end
  end

  defp loading_rows?(assigns, rows) do
    rows != [] and assigns.q == "" and
      (pending_more?(assigns.page_inflight, assigns.view) or
         pending_more?(assigns.page_retries, assigns.view))
  end

  defp finished_rows?(assigns, page, rows) do
    rows != [] and not page.more and Map.get(page, :loaded?, false) and assigns.q == ""
  end

  defp empty_search?(assigns, rows, local_rows?) do
    assigns.status == :ok and assigns.q != "" and assigns.search_state == :idle and
      assigns.search_hits == [] and (not local_rows? or rows == [])
  end

  @impl true
  def render(assigns) do
    page = Map.get(assigns.paged, assigns.view, %{rows: [], more: false})
    rows = search_rows(assigns, page.rows)
    ui = ui_state(assigns, page, rows)

    assigns =
      assign(assigns,
        rows: rows,
        views: @views,
        left_views: Enum.filter(@views, fn {v, _} -> v in @left_views end),
        right_views: Enum.filter(@views, fn {v, _} -> v in @right_views end),
        more: page.more,
        loading?: ui.loading?,
        finished?: ui.finished?,
        load_failed?: ui.load_failed?,
        load_more?: ui.load_more?,
        load_more_pending?: ui.load_more_pending?,
        load_more_label: ui.load_more_label,
        local_rows?: ui.local_rows?,
        empty_search?: ui.empty_search?,
        as: %{
          expanded: assigns.expanded,
          index: assigns.index,
          profiles: assigns.profiles,
          rev: assigns.blob_rev,
          my_likes: assigns.my_likes,
          likes_by: assigns.likes_by,
          like_pending: assigns.like_pending
        }
      )

    ~H"""
    <div
      id="timeline-root"
      phx-hook="TabActivity"
      class="flex h-screen overflow-hidden bg-app text-ink"
    >
      <Nav.rail gossip={@gossip}>
        <h1 class="sr-only">Timeline</h1>

        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">
          Contacts
        </div>
        <div class="pb-4">
          <p :if={@sidebar_contacts == []} class="px-4 py-1 text-xs italic text-faint">
            No contacts yet. Open a profile to follow someone.
          </p>
          <.link
            :for={c <- if(@contacts_expanded, do: @all_contacts, else: @sidebar_contacts)}
            navigate={profile_href(c)}
            class="flex items-center gap-2 px-4 py-1 text-xs text-muted hover:bg-raised hover:text-paper"
          >
            <Avatar.avatar
              id={c}
              size={16}
              image={image_of(c, @profiles)}
              rev={@blob_rev}
            />
            <span class="min-w-0 truncate">{Ident.display_name(c, @profiles)}</span>
          </.link>
          <button
            :if={length(@all_contacts) > @max_sidebar_contacts}
            type="button"
            phx-click="toggle-contacts"
            class="w-full px-4 py-1 text-left text-[11px] text-faint transition hover:bg-raised hover:text-paper"
          >
            {if @contacts_expanded,
              do: "Show fewer",
              else: "Show all #{length(@all_contacts)}"}
          </button>
        </div>

        <div class="px-4 pb-1 pt-5 text-[11px] uppercase tracking-wider text-faint">
          Whom to follow
        </div>
        <div class="pb-4">
          <p :if={@suggestions == []} class="px-4 py-1 text-xs italic text-faint">
            Friend-of-friend suggestions will appear here.
          </p>
          <.link
            :for={s <- @suggestions}
            navigate={profile_href(s["id"])}
            title={"#{s["followers"]} followers"}
            class="flex items-center gap-2 px-4 py-1 text-xs text-muted hover:bg-raised hover:text-paper"
          >
            <Avatar.avatar
              id={s["id"]}
              size={16}
              image={image_of(s["id"], @profiles)}
              rev={@blob_rev}
            />
            <span class="min-w-0 truncate">{Ident.display_name(s["id"], @profiles)}</span>
          </.link>
          <button
            type="button"
            phx-click="refresh-suggestions"
            disabled={@suggestions_pending}
            class={[
              "w-full px-4 py-1 text-left text-[11px] text-faint transition",
              unless(@suggestions_pending, do: "hover:bg-raised hover:text-paper")
            ]}
          >
            {if @suggestions_pending, do: "Finding…", else: "Show another set"}
          </button>
        </div>
      </Nav.rail>

      <div class="flex min-w-0 flex-1 flex-col">
        <header class="flex h-11 shrink-0 items-center gap-2 border-b border-edge bg-panel px-4">
          <nav class="flex shrink-0 items-center gap-1" aria-label="Feeds">
            <.feed_tab :for={{v, label} <- @left_views} v={v} label={label} current={@view} />
          </nav>
          <%!-- The search takes whatever width the row can spare and
          caps at 18rem, so narrow windows shrink the box instead of
          clipping the Profile link, the Mentions tab, and the peer
          chip. The index light rides beside the box it qualifies. --%>
          <div class="flex min-w-0 max-w-72 flex-1 items-center gap-2">
            <form
              id="feed-search"
              phx-change="search"
              phx-submit="search"
              class="min-w-0 flex-1"
              role="search"
            >
              <input
                type="search"
                name="q"
                value={@q}
                phx-debounce="600"
                placeholder="Search"
                class="h-9 w-full rounded-full border border-gray-300 bg-white px-3 text-sm shadow-sm transition focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-500/20 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder-gray-400"
              />
            </form>
            <span
              id="search-index-status"
              data-status={index_status_key(@index_status)}
              title={index_status_title(@index_status)}
              class={["flex shrink-0 items-center", index_status_tone(@index_status)]}
            >
              <span class={[
                "h-2 w-2 rounded-full bg-current transition-shadow",
                index_status_glow(@index_status)
              ]}></span>
            </span>
          </div>
          <nav class="flex shrink-0 items-center gap-1" aria-label="Mentions and profile">
            <.link
              :if={@self_id}
              navigate={profile_href(@self_id)}
              title="Your profile"
              class="rounded px-2 py-1 text-xs text-dim transition hover:bg-raised hover:text-paper"
            >
              Profile
            </.link>
            <.feed_tab :for={{v, label} <- @right_views} v={v} label={label} current={@view} />
          </nav>
          <span
            :if={@transfer.active?}
            id="transfer-activity"
            title="Recent network activity"
            class="flex shrink-0 items-center gap-1.5 rounded px-2 py-1 text-xs text-info"
          >
            <span class="h-1.5 w-1.5 animate-pulse rounded-full bg-dot-info"></span> active
          </span>
          <.link
            navigate="/network"
            title="Network. Connections and dialing."
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

        <div id="feed-scroller" phx-hook="FeedScroll" class="flex-1 overflow-y-auto">
          <%!-- A reading column, not a full-bleed sheet: past about
          eighty characters a line the eye loses the start of the
          next one, and this feed was running to 160. --%>
          <div id="feed-column" phx-hook="ClampRows" class="mx-auto w-full max-w-2xl">
            <form
              :if={@view in [:public, :private] and @q == ""}
              id="compose"
              phx-hook="Attach"
              data-attach-zone
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
                  <div :if={@view == :private} class="mt-2 rounded border border-edge bg-input p-2">
                    <p class="mb-1 text-xs text-faint">
                      Private thread. Choose who can read it.
                    </p>
                    <div
                      :if={@all_contacts == []}
                      class="text-xs italic text-dim"
                    >
                      Follow someone first. There is no one to send to yet.
                    </div>
                    <div class="flex max-h-40 flex-wrap gap-2 overflow-y-auto">
                      <label
                        :for={id <- @all_contacts}
                        class="flex cursor-pointer items-center gap-1.5 rounded border border-edge px-2 py-1 text-xs hover:bg-raised"
                      >
                        <input
                          type="checkbox"
                          name="recipients[]"
                          value={id}
                          checked={id in @private_recipients}
                        />
                        <span class="min-w-0 truncate text-paper">
                          {Ident.display_name(id, @profiles)}
                        </span>
                      </label>
                    </div>
                  </div>
                  <p :if={@compose_error} role="alert" class="mt-1 text-xs text-bad">
                    {@compose_error}
                  </p>
                  <p
                    id="compose-attach-status"
                    phx-update="ignore"
                    data-attach-status
                    role="status"
                    class="mt-1 text-xs text-faint"
                  >
                  </p>
                  <div class="mt-2 flex items-center justify-end gap-3">
                    <span :if={@self_id} class="mr-auto min-w-0 truncate text-xs text-faint">
                      Posting as {Ident.display_name(@self_id, @profiles)}
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
                      phx-disable-with="Publishing…"
                      disabled={@compose_pending}
                    >
                      {if @compose_pending, do: "Publishing…", else: "Publish"}
                    </button>
                  </div>
                </div>
              </div>
            </form>

            <p :if={@status == :connecting} class="px-4 py-3 text-sm text-info">
              Connecting…
            </p>
            <p :if={@status == :loading} class="px-4 py-3 text-sm text-info">
              Loading feeds…
            </p>
            <p :if={@status == :disabled} class="px-4 py-3 text-sm text-dim">
              Publishing is turned off in this configuration.
            </p>
            <p
              :if={@status == :ok and @q != "" and @search_state == :pending}
              class="px-4 py-3 text-sm text-info"
            >
              Searching…
            </p>
            <p
              :if={@status == :ok and @q != "" and @search_state == :stalled}
              class="px-4 py-3 text-sm text-warn"
            >
              Some results may be missing.
            </p>
            <p :if={@empty_search?} class="px-4 py-3 text-sm text-dim">
              {search_empty_message(@index_status, @q)}
            </p>
            <p
              :if={@status == :ok and @rows == [] and @view == :private and @q == ""}
              class="px-4 py-3 text-sm text-dim"
            >
              No private messages yet.
            </p>
            <p
              :if={@status == :ok and @rows == [] and @view != :private and @q == ""}
              class="px-4 py-3 text-sm text-dim"
            >
              No messages yet.
            </p>

            <%= if @q != "" and @search_hits != [] do %>
              <section id="search-results" class="border-b border-edge">
                <p class="px-4 pb-1 pt-3 text-[11px] uppercase tracking-wider text-faint">
                  {match_count(@search_hits)} {if length(@search_hits) == 1,
                    do: "match",
                    else: "matches"}
                </p>
                <article
                  :for={h <- @search_hits}
                  phx-click="open-post"
                  phx-value-key={h.key}
                  class="flex cursor-pointer gap-3 border-b border-edge-soft px-4 py-3 transition last:border-b-0 hover:bg-raised"
                >
                  <Avatar.avatar
                    :if={is_binary(h.author)}
                    id={h.author}
                    size={30}
                    image={image_of(h.author, @profiles)}
                    rev={@blob_rev}
                    class="mt-0.5 shrink-0"
                  />
                  <div class="min-w-0 flex-1">
                    <div class="flex items-baseline gap-2 text-xs">
                      <span class="truncate font-medium text-paper">
                        {Ident.display_name(h.author, @profiles)}
                      </span>
                      <span class="shrink-0 text-faint">{format_ts(h.ts)}</span>
                    </div>
                    <p class="mt-0.5 whitespace-pre-wrap break-words text-sm text-ink">
                      {snippet_hit(h.text, @q)}
                    </p>
                  </div>
                </article>
              </section>
            <% end %>

            <%!-- The one action here that can undo itself also says so:
            the heart fills on the press, and a refusal empties it with
            this line under it. --%>
            <p :if={@like_error} role="alert" class="px-4 py-3 text-xs text-bad">
              {@like_error}
            </p>

            <div
              :for={row <- @rows}
              :if={@local_rows?}
              id={dom_id("row-", row)}
              class="border-b border-edge-soft"
            >
              <.post_row
                :if={row.kind in [:thread, :post]}
                row={row}
                ctx={@as}
                arrived={@arrived}
              />
              <.vote_row :if={row.kind == :vote} row={row} ctx={@as} />
              <.contact_row :if={row.kind == :contact} row={row} ctx={@as} />
              <.other_row :if={row.kind == :other} row={row} ctx={@as} />
            </div>

            <p
              :if={@loading?}
              id="feed-loading"
              role="status"
              class="px-4 py-3 text-sm text-info"
            >
              Loading more…
            </p>

            <p
              :if={@load_failed?}
              id="feed-page-error"
              role="status"
              class="px-4 py-3 text-sm text-bad"
            >
              Older posts did not load.
            </p>

            <div :if={@more and @q == ""} id="feed-sentinel" phx-hook="InfiniteScroll" class="h-px">
            </div>

            <button
              :if={@load_more?}
              id="feed-load-more"
              type="button"
              phx-click="load-more"
              disabled={@load_more_pending?}
              class={[
                "px-4 py-3 text-left text-sm text-info transition",
                unless(@load_more_pending?, do: "hover:text-paper")
              ]}
            >
              {@load_more_label}
            </button>

            <p :if={@finished?} id="feed-end" class="px-4 py-3 text-sm text-dim">
              End of feed.
            </p>
          </div>
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
  attr :arrived, :map, default: MapSet.new(), doc: "row uids lighting up this wave"

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
      |> assign(
        :like_pending,
        MapSet.member?(assigns.ctx.like_pending, like_target(assigns.row))
      )
      |> assign(:likers, likers)
      |> assign(
        :body_html,
        if(raw_text != "",
          do: Markdown.to_html(raw_text, blob_rev: assigns.ctx.rev),
          else: ""
        )
      )
      |> assign(:edit_note, edit_note(assigns.row, assigns.ctx))
      |> assign(:expanded?, MapSet.member?(assigns.ctx.expanded, assigns.row.msg["key"]))

    ~H"""
    <article
      id={dom_id("post-", @row)}
      class={[
        "flex cursor-pointer gap-3 px-4 py-3 hover:bg-panel",
        MapSet.member?(@arrived, row_uid(@row)) && "gossip-arrived"
      ]}
      phx-hook="OpenPost"
      data-key={@row.msg["key"]}
    >
      <div class="w-10 shrink-0">
        <Avatar.face
          id={@author}
          profiles={@ctx}
          rev={@ctx.rev}
          size={40}
          class="mt-0.5"
        />
      </div>
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="text-sm font-semibold text-paper">
            <.link :if={@author_href} navigate={@author_href} class="hover:underline">
              {Ident.display_name(@author, @ctx)}
            </.link>
            <span :if={@author_href == nil}>{Ident.display_name(@author, @ctx)}</span>
          </span>
          <span :if={@row.self?} class="text-[10px] uppercase text-faint">you</span>
          <span class="text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
          <span :if={@row.activity > ts(@row.msg)} class="text-xs text-faint">
            · active <.age ts={@row.activity} />
          </span>
          <span :if={@edit_note} class="text-xs text-faint" title={@edit_note}>
            · {@edit_note}
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

        <div
          :if={@body_html != ""}
          class={["md-body mt-1 text-sm leading-5 text-ink", not @expanded? and "line-clamp-4"]}
          data-clamp-body
        >
          {raw(@body_html)}
        </div>

        <%!-- Rendered hidden: whether a body actually overflows four lines
        depends on width and markdown, which the server cannot know. The
        ClampRows hook measures and reveals this only where it does
        something. --%>
        <button
          :if={@body_html != ""}
          type="button"
          phx-click="expand"
          phx-value-key={@row.msg["key"]}
          data-clamp-toggle
          data-expanded={to_string(@expanded?)}
          hidden
          class="mt-1 text-xs text-accent hover:underline"
        >
          {if @expanded?, do: "show less", else: "show more"}
        </button>

        <div class="mt-1.5 flex items-center gap-4 text-xs text-dim">
          <span :if={@row.replies > 0}>{@row.replies} replies</span>
          <%!-- A wrap, so a post the whole crowd liked adds lines under
          it rather than pushing the row — and the column it sits in —
          sideways off the screen. --%>
          <div :if={@like_target} class="flex flex-wrap items-center gap-1.5">
            <Heart.pill key={@like_target} liked={@liked} pending={@like_pending} />
            <%!-- Every voter, each on their way to their profile: the
            faces are the count, so nothing is folded into a "+N". --%>
            <Likers.chips ids={@likers} profiles={@ctx.profiles} rev={@ctx.rev} />
          </div>
        </div>

        <%!-- A preview is a reply in its own right, so it opens that
        reply and not the row it previews: the post view lands on the
        message it was opened with. --%>
        <div :if={@row.recent != []} class="mt-2 space-y-1.5 border-l border-edge pl-3">
          <.link
            :for={reply <- Enum.reverse(@row.recent)}
            navigate={post_href(reply["key"])}
            class="flex items-baseline gap-2"
          >
            <Avatar.avatar
              id={author_of(reply)}
              size={16}
              image={image_of(author_of(reply), @ctx.profiles)}
              rev={@ctx.rev}
              class="self-center"
            />
            <span class="shrink-0 text-xs font-medium text-muted">
              {Ident.display_name(author_of(reply), @ctx)}
            </span>
            <span class="min-w-0 truncate text-xs text-sub">{snippet(reply, @ctx)}</span>
            <span class="ml-auto shrink-0 text-[11px] text-faint">
              <.age ts={ts(reply)} />
            </span>
          </.link>
        </div>

        <p
          :if={@row.kind == :thread and not @row.rooted?}
          class="mt-1.5 text-xs italic text-faint"
        >
          The post this replies to isn't shown here.
        </p>
      </div>
    </article>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  defp vote_row(assigns) do
    author = author_of(assigns.row.msg)

    assigns =
      assigns
      |> assign(:author, author)
      |> assign(:author_name, Ident.display_name(author, assigns.ctx))
      |> assign(:author_href, profile_href(author))

    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm text-sub hover:bg-panel">
      <%!-- The voter, not just the vote: their tile and their name both
      open their profile, so a face in the feed leads where every other
      face leads. --%>
      <.link
        :if={@author_href}
        navigate={@author_href}
        title={@author_name}
        aria-label={@author_name}
        class="block w-10 shrink-0"
      >
        <Avatar.avatar
          id={@author}
          size={24}
          image={image_of(@author, @ctx.profiles)}
          rev={@ctx.rev}
        />
      </.link>
      <div :if={@author_href == nil} class="w-10 shrink-0">
        <Avatar.avatar
          id={@author}
          size={24}
          image={image_of(@author, @ctx.profiles)}
          rev={@ctx.rev}
        />
      </div>
      <p class="min-w-0 flex-1">
        <.link :if={@author_href} navigate={@author_href} class="text-ink hover:underline">
          {@author_name}
        </.link>
        <span :if={@author_href == nil} class="text-ink">{@author_name}</span>
        liked <span class="text-ink">{vote_target_label(@row.msg, @ctx)}</span>
      </p>
      <span class="ml-auto text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
    </div>
    """
  end

  # The direction word between the author and the chips.
  defp contact_verb(:blocked), do: "blocked"
  defp contact_verb(:unfollowed), do: "unfollowed"
  defp contact_verb(:unblocked), do: "unblocked"
  defp contact_verb(_), do: "followed"

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  # Feed rows carry the collapsed list for their relationship —
  # :followed, :blocked or :unfollowed, keyed by the row's :contact_action
  # (the Timeline groups contact edits by direction so a block never
  # masquerades as a follow). The flat window's individual contact
  # messages fall back to their single contact and its verb. "+N more"
  # toggles the full list (same expand event as post bodies); each chip
  # links to that feed's profile.
  defp contact_row(assigns) do
    action = Map.get(assigns.row, :contact_action, :followed)
    people = Map.get(assigns.row, action) || [content(assigns.row.msg)["contact"]]

    people = Enum.filter(people, &is_binary/1)
    expanded? = MapSet.member?(assigns.ctx.expanded, assigns.row.msg["key"])

    assigns =
      assigns
      |> assign(:author, author_of(assigns.row.msg))
      |> assign(:verb, contact_verb(action))
      |> assign(:people, people)
      |> assign(:shown, if(expanded?, do: people, else: Enum.take(people, 3)))
      |> assign(:expanded?, expanded?)

    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm text-sub hover:bg-panel">
      <div class="w-10 shrink-0">
        <Avatar.face id={@author} profiles={@ctx} rev={@ctx.rev} size={24} />
      </div>
      <%!-- A div, not a p: each chip carries the avatar component's
      own div, and a div inside a p makes the HTML parser close the p —
      which flattened the chips into siblings of this row and pushed
      the timestamp off the page. --%>
      <div class="min-w-0 flex-1">
        <.link
          :if={href = profile_href(@author)}
          navigate={href}
          class="text-ink hover:underline"
        >
          {Ident.display_name(@author, @ctx)}
        </.link>
        <span :if={profile_href(@author) == nil} class="text-ink">
          {Ident.display_name(@author, @ctx)}
        </span>
        {@verb}
        <span class="ml-1 inline-flex flex-wrap items-center gap-x-3 gap-y-1 align-middle">
          <span :for={fid <- @shown} class="inline-flex items-center gap-1.5">
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
              <span class="text-ink hover:underline">{Ident.display_name(fid, @ctx)}</span>
            </.link>
          </span>
          <button
            :if={length(@people) > length(@shown)}
            type="button"
            phx-click="expand"
            phx-value-key={@row.msg["key"]}
            class="text-accent hover:underline"
          >
            +{length(@people) - length(@shown)} more
          </button>
          <button
            :if={@expanded? and length(@people) > 3}
            type="button"
            phx-click="expand"
            phx-value-key={@row.msg["key"]}
            class="text-accent hover:underline"
          >
            show less
          </button>
        </span>
      </div>
      <span class="ml-auto shrink-0 text-xs text-faint"><.age ts={ts(@row.msg)} /></span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :ctx, :map, required: true

  defp other_row(assigns) do
    # A run of the same unknown type is one fact, not several: the row
    # names the type once and says there were some of them. The newest
    # message anchors it.
    description =
      if Map.get(assigns.row, :other_count, 1) > 1 do
        MessageText.describe_spate(assigns.row.msg)
      else
        MessageText.describe(assigns.row.msg, assigns.ctx)
      end

    assigns =
      assigns
      |> assign(:href, profile_href(author_of(assigns.row.msg)))
      |> assign(:description, description)

    ~H"""
    <div class="flex items-center gap-3 px-4 py-2.5 text-sm italic text-faint hover:bg-panel">
      <div class="w-10 shrink-0">
        <Avatar.face
          id={author_of(@row.msg)}
          profiles={@ctx}
          rev={@ctx.rev}
          size={24}
        />
      </div>
      <p class="min-w-0 flex-1">
        <span class="not-italic text-ink">
          <.link :if={@href} navigate={@href} class="hover:underline">
            {Ident.display_name(author_of(@row.msg), @ctx)}
          </.link>
          <span :if={@href == nil}>{Ident.display_name(author_of(@row.msg), @ctx)}</span>
        </span>
        {@description}
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
      |> Enum.sort_by(&String.downcase(Ident.display_name(&1, profiles)))

    # The collapsed rail is a draw HighWire.Contacts holds until the
    # follow list changes, so it never churns under a payload broadcast.
    # The expanded list stays the full alphabetical roll.
    sidebar_contacts = Map.get(payload, :contacts, [])

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
    |> assign(:sidebar_contacts, sidebar_contacts)
    |> assign(:all_contacts, contacts)
    |> assign(:suggestions, Map.get(payload, :suggestions, []))
    # An answer ends the "Finding…" hold: a fresh set replaces the
    # rows, and one that came back the same says there was nothing new.
    |> assign(:suggestions_pending, false)
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
    |> assign(:all_contacts, Map.get(socket.assigns, :all_contacts, []))
    |> assign(:suggestions, @empty_payload.suggestions)
    |> assign(:suggestions_pending, false)
  end

  # -- row selection ------------------------------------------------------
  # Search runs over everything the client holds, not just the rows the
  # viewport happened to load: the direct row filter (root author/text,
  # followed ids) plus every window message — replies included, which the
  # row filter alone never sees — mapped back to its thread row.
  defp search_rows(assigns, page_rows) do
    case assigns.q do
      "" ->
        page_rows

      q ->
        direct = Enum.filter(page_rows, &matches_query?(&1, q))
        known = MapSet.new(direct, &row_uid/1)

        window_rows = matched_threads(assigns.messages, q)

        window =
          assigns.feed
          |> Enum.filter(fn row ->
            in_scope?(assigns.view, row, assigns.self_id) and
              row_uid(row) in window_rows and
              not MapSet.member?(known, row_uid(row))
          end)

        Enum.sort_by(direct ++ window, & &1.activity, :desc)
    end
  end

  defp matched_threads(messages, q) do
    ql = String.downcase(q)

    messages
    |> Enum.filter(fn msg ->
      String.contains?(String.downcase(author_of(msg)), ql) or
        String.contains?(String.downcase(text(msg)), ql)
    end)
    |> Enum.map(&thread_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  # The row a message belongs to: a reply rides its root's row, a
  # rootless post is its own. Non-posts (votes, abouts) never key a row
  # the same way, so they contribute nothing.
  defp thread_id(msg) do
    c = content(msg)

    cond do
      c["type"] != "post" -> nil
      is_binary(c["root"]) -> c["root"]
      true -> msg["key"]
    end
  end

  defp matches_query?(_row, ""), do: true

  defp matches_query?(row, q) do
    String.contains?(String.downcase(author_of(row.msg)), q) or
      String.contains?(String.downcase(text(row.msg)), q) or
      Enum.any?(contact_people(row), &String.contains?(String.downcase(&1), q))
  end

  # -- view filters ------------------------------------------------------

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
  # A cache-seeded report is the peers we last knew, not the peers we are
  # talking to now. The chip speaks for the engine's present state, so a
  # seeded report is dropped here and the helpers below fall through to
  # their status-aware (nil) branches rather than claiming a live count
  # the engine never gave us.
  defp live_network(%{"seeded" => true}), do: nil
  defp live_network(network), do: network

  defp peer_count(network) when is_map(network), do: length(network["connections"] || [])

  defp peer_label(nil, :connecting), do: "Connecting…"
  defp peer_label(nil, :disabled), do: "Offline"
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

  # -- search index status light -----------------------------------------
  # SearchIndex.status/0 (an ETS read) as a one-dot answer to "can I
  # trust the search box right now?" — it sits beside the box itself.
  # The light carries the state; the tooltip carries the detail:
  # filled and steady once caught up, pulsing while work is in flight,
  # dark where there is no index to trust.

  defp index_status_key(:live), do: "live"
  defp index_status_key(:reconnecting), do: "reconnecting"
  defp index_status_key(:unavailable), do: "unavailable"
  defp index_status_key(:disabled), do: "disabled"
  defp index_status_key(:connecting), do: "connecting"
  defp index_status_key({:crawling, _}), do: "crawling"

  # The dot fills from the tone's colour and haloes itself with
  # currentColor, so one class list drives both fill and glow.
  defp index_status_glow(:live), do: "shadow-[0_0_6px_currentColor]"
  defp index_status_glow(:unavailable), do: "shadow-[0_0_6px_currentColor]"
  defp index_status_glow(:disabled), do: ""
  defp index_status_glow(_working), do: "animate-pulse shadow-[0_0_6px_currentColor]"

  defp index_status_tone(:live), do: "text-ok"
  defp index_status_tone(:reconnecting), do: "text-warn"
  defp index_status_tone(:unavailable), do: "text-bad"
  defp index_status_tone(:disabled), do: "text-dim"
  defp index_status_tone(_connecting_or_crawling), do: "text-info"

  defp index_status_title(:disabled),
    do: "Search is turned off in this configuration"

  defp index_status_title(:unavailable),
    do: "Search is unavailable right now"

  defp index_status_title(:connecting),
    do: "Connecting and getting search ready"

  defp index_status_title(:reconnecting),
    do: "Reconnecting and catching up"

  defp index_status_title(:live),
    do: "Search is up to date"

  defp index_status_title({:crawling, n}),
    do:
      "Search is still warming up. #{format_count(n)} messages so far, so results may be incomplete"

  # The query takes at most 200 hits; at the cap the true total is
  # unknown, so say so rather than pass the last page off as the end.
  defp match_count(hits),
    do: if(length(hits) >= 200, do: "200+", else: Integer.to_string(length(hits)))

  defp search_empty_message({:crawling, _}, q),
    do: "Nothing matches “#{q}” yet. Search is still warming up."

  defp search_empty_message(:connecting, q),
    do: "Nothing matches “#{q}” yet. Still connecting."

  defp search_empty_message(:reconnecting, q),
    do: "Nothing matches “#{q}” yet. Search is catching up."

  defp search_empty_message(_status, q), do: "Nothing matches “#{q}”."

  # 412553 -> 412,553. The header's only big number, and not a library.
  # The lookahead is non-capturing on purpose: a capture there lands its
  # triplet in \1 and replaces the digit we mean to keep, so 60_000 came
  # out "6000,000" and every count from 1,000 up lost a digit.
  defp format_count(n) when is_integer(n),
    do: Regex.replace(~r/(\d)(?=(?:\d{3})+$)/, Integer.to_string(n), "\\1,")

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
  # the line clamps. A message with no text at all describes itself in
  # a sentence instead (a block, a like, a channel toggle), so the
  # preview line never comes up blank. Public (with @doc false) for
  # direct tests.
  @doc false
  def snippet(msg, ctx \\ %{rev: nil}) do
    case text(msg) do
      "" -> MessageText.describe(msg, ctx)
      body -> snippet_of(body, Map.get(ctx, :rev))
    end
  end

  # The rendered HTML is immediately stripped back to text, so the
  # preview depends only on the source — the blob revision only ever
  # changes a tag we drop. Memoize on the source alone: this ran once
  # per reply per timeline render and was, by the profiler, the single
  # hottest frame in the VM.
  defmemop snippet_of(source, rev), expires_in: @snippet_ttl_ms do
    source
    |> media_markers()
    |> Markdown.to_html(blob_rev: rev)
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

  # A preview names the media a reply carries: what the bytes are, not
  # always a picture.
  defp media_markers(source) do
    Regex.replace(@image_re, source, fn _whole, _alt, target ->
      if String.starts_with?(target, "&"), do: Markdown.marker(target), else: "[image]"
    end)
  end

  # Author names open that feed's neutral identity view.
  # The path a message is read at: its key as url-safe base64, because
  # raw message ids contain "/" and cannot ride in a route as-is.
  defp post_href(key) when is_binary(key),
    do: "/post/" <> Base.url_encode64(key, padding: false)

  defp post_href(_key), do: nil

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
      |> Enum.map_join(", ", &Ident.display_name(&1, ctx))

    %{prefix: "#{names} replied · ", ts: activity}
  end

  defp meta_line(_row, _ctx), do: nil

  # The row already carries the newest revision's text; `edited_by`
  # (the authors of the head's own revisions) is the only sign the
  # reader gets that what they see is a revision. A lone editor is the
  # author already on the row, so it reads as a plain "edited"; several
  # name everyone who touched it.
  defp edit_note(row, ctx) do
    case Enum.uniq(Map.get(row, :edited_by, [])) do
      [] -> nil
      [_single] -> "edited"
      editors -> "edited by " <> editors_label(editors, ctx)
    end
  end

  defp editors_label(editors, ctx) do
    shown = editors |> Enum.take(2) |> Enum.map_join(", ", &Ident.display_name(&1, ctx))
    if length(editors) > 2, do: "#{shown} +#{length(editors) - 2}", else: shown
  end

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
          author -> "#{Ident.display_name(author, ctx)}'s message"
        end

      _ ->
        "a message"
    end
  end

  # Each message type's sentence lives in HighWireWeb.MessageText, shared
  # with the thread page — a block reads the same wherever it appears.

  defp format_ts(ts) when is_integer(ts) do
    {:ok, dt} = DateTime.from_unix(ts, :millisecond)
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end

  defp format_ts(_), do: ""

  # A result snippet is a three-line window (at text-sm in the reading
  # column) centred on the first match, ellipsised wherever the text
  # continues. Whitespace collapses first so a snippet cannot sprawl to
  # however many lines the original post used.
  @snippet_chars 200
  @snippet_lead 100
  # How far either cut edge may reach to finish the word it landed in.
  @snippet_snap 30

  defp snippet_hit(nil, _q), do: ""

  defp snippet_hit(text, q) when is_binary(text) do
    t = text |> String.trim() |> String.replace(~r/\s+/u, " ")
    total = String.length(t)

    if total <= @snippet_chars do
      t
    else
      at =
        case query_offset(t, q) do
          nil -> 0
          byte -> String.length(binary_part(t, 0, byte))
        end

      cut = min(max(at - @snippet_lead, 0), total - @snippet_chars)
      more? = cut + @snippet_chars < total
      first = if cut > 0, do: snap_open(t, cut), else: 0
      last = if more?, do: snap_closed(t, cut + @snippet_chars), else: total

      prefix = if first > 0, do: "…", else: ""
      suffix = if last < total, do: "…", else: ""
      prefix <> String.slice(t, first, last - first) <> suffix
    end
  end

  # The window edges are chosen by character count, so they land inside
  # words. Reach out to complete the first and last word rather than serve
  # a fragment ("…ure ~dtBy is supposed") — but only within a word's
  # length: an unbroken run longer than the cap (URL, hash, stuck
  # keyboard) is left cut, because it is not a word a reader expects to
  # see finished.
  defp snap_open(t, idx) do
    if word_char?(t, idx) do
      start = word_start(t, idx)
      if idx - start <= @snippet_snap, do: start, else: idx
    else
      idx
    end
  end

  defp snap_closed(t, idx) do
    if word_char?(t, idx) do
      stop = word_stop(t, idx)
      if stop - idx <= @snippet_snap, do: stop, else: idx
    else
      idx
    end
  end

  defp word_char?(t, idx) do
    case String.at(t, idx) do
      nil -> false
      " " -> false
      _ -> true
    end
  end

  defp word_start(t, idx) do
    before = String.slice(t, 0, idx)

    case Regex.run(~r/\S+$/u, before, return: :index) do
      [{start, _len}] -> String.length(binary_part(before, 0, start))
      _ -> idx
    end
  end

  defp word_stop(t, idx) do
    rest = String.slice(t, idx, String.length(t) - idx)

    case Regex.run(~r/\A\S+/u, rest, return: :index) do
      [{0, len}] -> idx + String.length(binary_part(rest, 0, len))
      _ -> idx
    end
  end

  # First match of q in text, as a byte offset (case-insensitive, and the
  # query is escaped — it is user input). nil when the post only matched
  # on its author, in which case the snippet opens the post instead.
  defp query_offset(text, q) do
    case Regex.run(~r/#{Regex.escape(q)}/iu, text, return: :index) do
      [{start, _len}] -> start
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
