defmodule HighWire.Timeline do
  @moduledoc """
  Builds the home timeline from the sidecar: whoami → the account's
  follow list (`patchwork.contacts.stateStream`) → one
  `createHistoryStream` per followed feed, merged newest-first.

  Ordering follows Patchwork/Poncho Wonky's `publicFeed.roots`:

    * messages resolve to their thread root (posts → `content.root`,
      abouts → `content.about` when it is a message id)
    * one row per thread, positioned at the thread's **latest activity**
      ("bump") — replies push old threads back to the top
    * votes (likes) never create rows and never bump; they only add to
      like counts inside their thread
    * contact (follow) messages collapse into one row per author listing
      who they followed, positioned at the author's latest follow
    * timestamps are clamped to now (Poncho's `min(arrival, claimed)`
      future-dated guard; arrival time itself is not exposed over muxrpc)

  Messages are broadcast on the PubSub topic `timeline` as
  `{HighWire.Timeline, :updated, payload}` whenever a full pass
  completes; LiveViews also read the current snapshot synchronously.
  The payload is a map:

    * `:feed`         — activity-ordered rows (threads/posts/contacts),
                        capped at 200; each row carries `:kind`, `:msg`,
                        `:activity`, `:participants`, `:replies`, `:likes`,
                        `:recent` (newest replies) and `:self?`
    * `:messages`     — flat newest-first list (order-of-arrival view),
                        capped at 200
    * `:reply_counts` — `%{root_key => n}` from post messages
    * `:like_counts`  — `%{message_key => n}` from vote messages
    * `:likes_by`     — `%{message_key => [author_id]}` the positive
                        voters per target, most recent voter first
    * `:index`        — `%{message_key => author_id}` for the full pass
    * `:follows`      — the account's follow list (includes self)
    * `:self_id`      — the account's own feed id
    * `:profiles`     — `%{feed_id => %{name, image}}` for every feed on
                        screen (participants + follows), resolved through
                        the sidecar's `patchwork.profile.avatar`
                        (ssb-social-index semantics: the viewer's own
                        assignment, then the feed's self-assignment, then
                        plurality); `image` is the raw `&…sha256` ref —
                        `HighWire.Blob.url/1` turns it into `/blob/<hex>`
    * `:blob_rev`     — monotonically increasing image revision: bumped
                        whenever the sidecar's `blobs.ls` live tail
                        reports newly stored blobs, so LiveViews re-render
                        image URLs with a fresh `?v=` and the browser
                        refetches placeholders that have since become real

  Runs in `:disabled` state when the sidecar is off (tests).
  """

  use GenServer

  require Logger

  alias HighWire.Blob
  alias HighWire.SSB.{Client, Keys, Sidecar}

  @topic "timeline"
  @gossip "gossip"

  # First-paint: once this many feed streams have reported, broadcast
  # what has arrived instead of waiting for every stream (up to 400).
  @first_paint_feeds 40

  # Store-wide contact drain: a completed pass is not repeated on the
  # next reload — only after this long (the per-feed window already
  # carries recent follows; the drain back-fills old follow rows).
  # 13 — prime, so the drain refresh never lines up with the 11s
  # network poll or the 7s UI ticks.
  @drain_refresh_ms :timer.minutes(13)

  def topic, do: @topic

  @doc "PubSub topic for gossip events — the live connection set changing."
  @spec gossip_topic() :: binary()
  def gossip_topic, do: @gossip

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec set_activity(pid(), boolean()) :: :ok
  def set_activity(pid, active?) when is_pid(pid) and is_boolean(active?) do
    GenServer.cast(__MODULE__, {:set_activity, pid, active?})
  end

  @spec snapshot() :: {:ok | :loading | :connecting | :disabled | :down, map()}
  def snapshot do
    case Process.whereis(__MODULE__) do
      nil -> {:disabled, empty_payload()}
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc """
  The sidecar's connection report — live peer ids, dialer state,
  candidate counts, recent dial attempts — merged with the
  `admin.peers.known` address book under `"knownPeers"`, or nil when
  the engine is down (or erlbutt predates the RPCs).

  `gossip.peers` is one report; erlbutt builds without it fall back to
  assembling the same dashboard out of `admin.dialer.status` +
  `admin.peers.connected` (candidate counts and dial history then come
  back as absent/empty — they wait for the upstream `gossip.peers`
  batch). Polled every 10s by the server; the /network dashboard reads
  it synchronously.
  """
  @spec network() :: map() | nil
  def network do
    case Process.whereis(__MODULE__) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, :network, 3_000)
        catch
          :exit, _ -> nil
        end
    end
  end

  @doc """
  A feed's full profile card — `%{name, image, description}` — resolved
  through the sidecar (social-value semantics), or nil when the engine
  is down. Used by the profile page; the timeline bulk-fetches only
  name/image via the payload's `:profiles`.
  """
  @spec profile(binary()) ::
          %{name: binary() | nil, image: binary() | nil, description: binary() | nil} | nil
  def profile(id) when is_binary(id) do
    case Process.whereis(__MODULE__) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, {:profile, id}, 5_000)
        catch
          :exit, _ -> nil
        end
    end
  end

  def profile(_), do: nil

  @doc """
  Ask the Timeline to ensure profiles exist for these ids.

  The payload only covers window participants and follows, so views
  rendering rows outside that set — cursor pages, contact chips,
  likers — call this for whatever they are about to show. Ids are
  parked in `profile_wants` and picked up by the next fetch cycle
  (immediately when a fetch is idle and the engine is up), retried
  until they land, and cleared once fetched.
  """
  @spec ensure_profiles([binary()]) :: :ok
  def ensure_profiles(ids) when is_list(ids) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:ensure_profiles, ids})
    end
  end

  @doc """
  One page of an identity's threads (`patchwork.profile.roots`), newest
  root published first — used by the profile page so its feed scrolls
  without bound instead of stopping at a fixed window, in chronological
  order rather than the other tabs' activity order. Rows are the raw
  root items (root content plus reply totals); non-post roots are the
  caller's to filter.

  `resume` is the cursor from the previous page's marker. Returns
  `%{rows, resume, more}` where `more` says another page exists.
  """
  @spec profile_feed(binary(), integer() | nil) :: %{
          rows: [map()],
          resume: integer() | nil,
          more: boolean()
        }
  def profile_feed(id, resume \\ nil) when is_binary(id) do
    case Process.whereis(__MODULE__) do
      nil ->
        %{rows: [], resume: nil, more: false}

      pid ->
        try do
          GenServer.call(pid, {:profile_feed, id, resume}, 15_000)
        catch
          :exit, _ -> %{rows: [], resume: nil, more: false}
        end
    end
  end

  @doc """
  One page of Patchwork's private feed: threads the account can decrypt,
  newest activity first. Rows are shaped like feed rows (decrypted
  content — the view ships metadata plus a fresh decrypt, never stored
  plaintext).

  `resume` is the cursor from the previous page's marker. Returns
  `%{rows, resume, more}` where `more` says another page exists.
  """
  @spec private_feed(integer() | nil) :: %{
          rows: [map()],
          resume: integer() | nil,
          more: boolean()
        }
  def private_feed(resume \\ nil), do: feed(:private, resume)

  @doc """
  One page of a timeline feed tab: the engine's paged thread-root view
  for the tab — `patchwork.<Feed>.roots`, newest activity first — so
  every tab pages without bound. Views: `:public`, `:private`,
  `:participating`, `:profile` (this account's roots) and `:mentions`.

  `resume` is the cursor from the previous page's marker. Returns
  `%{rows, resume, more}`; rows are shaped like feed rows.
  """
  @spec feed(:public | :private | :participating | :profile | :mentions, integer() | nil) :: %{
          rows: [map()],
          resume: integer() | nil,
          more: boolean()
        }
  def feed(view, resume \\ nil)
      when view in [:public, :private, :participating, :profile, :mentions] do
    case Process.whereis(__MODULE__) do
      nil ->
        empty_page()

      pid ->
        try do
          GenServer.call(pid, {:feed, view, resume}, 15_000)
        catch
          :exit, _ -> empty_page()
        end
    end
  end

  defp empty_page, do: %{rows: [], resume: nil, more: false}

  @doc """
  One message with its full thread, for the post viewer: the root
  (unboxed through `get` when it is private) and every reply in causal
  order (`patchwork.thread.sorted`, falling back to the local window).
  nil when the message is not in the local store.
  """
  @spec post(binary()) :: %{root: map(), replies: [map()]} | nil
  def post(key) when is_binary(key) do
    case Process.whereis(__MODULE__) do
      nil ->
        nil

      pid ->
        try do
          GenServer.call(pid, {:post, key}, 15_000)
        catch
          :exit, _ -> nil
        end
    end
  end

  @doc """
  Publishes a public post through the local engine's `publish` RPC and
  schedules an immediate feed reload so the post lands in the timeline
  without waiting for the poll timer. Returns the new message key, or
  `{:error, reason}` when the engine is unreachable or refused.
  """
  @spec publish(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def publish(text) when is_binary(text), do: publish_content(post_content(text))

  @doc """
  Publishes a reply. `root` is the thread's root message key; `branch`
  is the parent message key (a root reply branches from the root
  itself).
  """
  @spec reply(binary(), binary(), binary()) :: {:ok, binary() | nil} | {:error, term()}
  def reply(root, branch, text)
      when is_binary(root) and is_binary(branch) and is_binary(text) do
    publish_content(reply_content(root, branch, text))
  end

  @doc """
  Likes (`like/1`) or unlikes (`unlike/1`) a message by publishing a
  vote. The content shape matches this network's production votes
  (`{type, vote: {link, value, expression}}`), which is also what
  erlbutt's likes view consumes; a non-positive value retracts.
  """
  @spec like(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def like(key) when is_binary(key), do: publish_content(vote_content(key, 1))

  @spec unlike(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def unlike(key) when is_binary(key), do: publish_content(vote_content(key, 0))

  @doc """
  Follows (`follow/1`) or unfollows (`unfollow/1`) an identity by
  publishing a contact message; the engine's social graph turns it
  into a contacts-stateStream delta.
  """
  @spec follow(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def follow(id) when is_binary(id), do: publish_content(contact_content(id, true))

  @spec unfollow(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def unfollow(id) when is_binary(id), do: publish_content(contact_content(id, false))

  # -- publish content (pure; the RPC only serializes these maps) -------

  @doc false
  def post_content(text), do: %{"type" => "post", "text" => text}

  @doc false
  def reply_content(root, branch, text) do
    %{"type" => "post", "text" => text, "root" => root, "branch" => branch}
  end

  @doc false
  def vote_content(key, value) do
    %{"type" => "vote", "vote" => %{"link" => key, "value" => value, "expression" => "like"}}
  end

  @doc false
  def contact_content(id, following) do
    %{"type" => "contact", "contact" => id, "following" => following}
  end

  # Single chokepoint for every outbound message (posts, replies, votes,
  # follows). Publishing is allowed on every network — the switch point
  # is Network, not a policy about who else might write the identity.
  defp publish_content(content) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :offline}

      pid ->
        try do
          GenServer.call(pid, {:publish_content, content}, 12_000)
        catch
          :exit, _ -> {:error, :offline}
        end
    end
  end

  defp empty_payload do
    %{
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
      blob_rev: 0,
      suggestions: []
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      status: :connecting,
      client: nil,
      self_id: nil,
      contacts_ref: nil,
      contacts_primed?: false,
      contact_ref: nil,
      contact_buf: [],
      contact_msgs: [],
      drain_client: nil,
      last_drain_at: nil,
      follows: [],
      pending: %{},
      acc: [],
      messages: empty_payload(),
      blob_ls_ref: nil,
      blob_timer: nil,
      blob_rev: 0,
      network: nil,
      suggestions: [],
      active: %{},
      gen: 0,
      network_timer: nil,
      reload_timer: nil,
      profile_fetching?: false,
      profile_wants: MapSet.new(),
      done_count: 0
    }

    if Sidecar.enabled?() do
      send(self(), :connect)
      {:ok, state}
    else
      {:ok, %{state | status: :disabled}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.status, state.messages}, state}
  end

  def handle_call(:network, _from, state) do
    {:reply, Map.get(state, :network), state}
  end

  def handle_call({:profile, id}, _from, state) do
    base = %{name: nil, image: nil, description: nil}

    profile =
      case avatar_of(state.client, id) do
        {:ok, p} -> Map.merge(base, p)
        _ -> base
      end

    description =
      case about_value(state.client, id, "description") do
        {:ok, v} -> v
        _ -> nil
      end

    {:reply, Map.put(profile, :description, description), state}
  end

  def handle_call({:profile_feed, id, resume}, _from, state) do
    {:reply, fetch_profile(state, id, resume), state}
  end

  def handle_call({:feed, view, resume}, _from, state) do
    {:reply, fetch_view(state, view, resume), state}
  end

  def handle_call({:post, key}, _from, state) do
    {:reply, fetch_post(state, key), state}
  end

  def handle_call({:publish_content, content}, _from, state) do
    with true <- is_pid(state.client),
         true <- Process.alive?(state.client) do
      case Client.call(state.client, ["publish"], [content], 10_000) do
        {:ok, %{"key" => key}} when is_binary(key) ->
          {:reply, {:ok, key}, state |> inject_published(key, content) |> reload_soon()}

        {:ok, _other} ->
          {:reply, {:ok, nil}, reload_soon(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      _ -> {:reply, {:error, :offline}, state}
    end
  catch
    kind, reason -> {:reply, {:error, {kind, reason}}, state}
  end

  # The publish ack beats any reload: fold the message into the window
  # and rebroadcast now, so a like's heart fills on the publish
  # round-trip instead of waiting out a window re-stream — and so a
  # reload whose streams opened before the publish landed cannot
  # finalize without it. The reload that follows rebuilds from the
  # store and agrees.
  defp inject_published(%{self_id: id} = state, key, content) when is_binary(id) do
    envelope = %{
      "key" => key,
      "value" => %{
        "author" => id,
        "timestamp" => System.system_time(:millisecond),
        "content" => content
      }
    }

    finalize(%{state | acc: [envelope | state.acc]})
  end

  defp inject_published(state, _key, _content), do: state

  @impl true
  def handle_cast({:set_activity, pid, true}, state) do
    {:noreply, put_active(state, pid)}
  end

  def handle_cast({:set_activity, pid, false}, state) do
    {:noreply, drop_active(state, pid)}
  end

  def handle_cast({:ensure_profiles, ids}, state) do
    known = state |> Map.get(:messages, %{}) |> Map.get(:profiles, %{})

    wants =
      ids
      |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
      |> Enum.reject(&Map.has_key?(known, &1))
      |> MapSet.new()
      |> MapSet.union(Map.get(state, :profile_wants, MapSet.new()))

    state = Map.put(state, :profile_wants, wants)
    {:noreply, kick_wanted_profiles(state)}
  end

  defp put_active(state, pid) do
    if Map.has_key?(state.active, pid) do
      state
    else
      ref = Process.monitor(pid)
      state = %{state | active: Map.put(state.active, pid, ref)}
      if map_size(state.active) == 1, do: activate(state), else: state
    end
  end

  defp drop_active(state, pid) do
    case Map.pop(state.active, pid) do
      {nil, _} ->
        state

      {ref, active} ->
        Process.demonitor(ref, [:flush])
        state = %{state | active: active}
        if map_size(active) == 0, do: deactivate(state), else: state
    end
  end

  defp activate(state) do
    state
    |> schedule_network(0)
    |> schedule_reload(0)
  end

  defp deactivate(state) do
    state = cancel_timer(state, :network_timer)
    state = cancel_timer(state, :reload_timer)
    %{state | gen: state.gen + 1}
  end

  defp cancel_timer(state, key) do
    case Map.get(state, key) do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.put(state, key, nil)
    end
  end

  defp schedule_network(state, delay) do
    if state.network_timer == nil and active?(state) do
      %{state | network_timer: Process.send_after(self(), {:network, state.gen}, delay)}
    else
      state
    end
  end

  defp schedule_reload(state, delay) do
    if state.reload_timer == nil and active?(state) do
      %{state | reload_timer: Process.send_after(self(), {:reload, state.gen}, delay)}
    else
      state
    end
  end

  # The boot paths open windows directly, not through a reload request.
  # Arm the heartbeat from there too, without schedule_reload/2's
  # active?/1 gate — that set is about live connections, and boot has
  # none yet; a stalled boot still needs a timer to retry on.
  defp ensure_heartbeat(state) do
    if state.reload_timer == nil do
      %{state | reload_timer: Process.send_after(self(), {:reload, state.gen}, 13_000)}
    else
      state
    end
  end

  # A fresh publish (or any reason to refresh right now): drop the queued
  # poll and re-open the feeds on the next tick instead of waiting.
  defp reload_soon(state) do
    state = cancel_timer(state, :reload_timer)
    send(self(), {:reload, state.gen})
    state
  end

  defp active?(state), do: map_size(state.active) > 0

  defp about_value(nil, _dest, _key), do: :error

  defp about_value(client, dest, key) do
    case Client.call(client, ["about", "socialValue"], [%{"dest" => dest, "key" => key}], 2_000) do
      {:ok, v} -> {:ok, about_text(v)}
      _ -> :error
    end
  catch
    :exit, _ -> :error
  end

  defp about_text(v) when is_binary(v), do: v
  defp about_text(%{"link" => link}) when is_binary(link), do: link
  defp about_text(_), do: nil

  # gossip.peers is the whole report in one call. Public (with @doc
  # false) so tests can drive the assembly without a live engine.
  @doc false
  def fetch_network(client) do
    if is_pid(client) and Process.alive?(client) do
      case gossip_report(client) do
        nil -> fallback_report(client)
        net -> Map.put(net, "knownPeers", fetch_known_peers(client))
      end
    else
      nil
    end
  catch
    _, _ -> nil
  end

  defp gossip_report(client) do
    case Client.call(client, ["gossip", "peers"], [], 2_000) do
      {:ok, net} when is_map(net) -> net
      _ -> nil
    end
  end

  # An erlbutt without gossip.peers (upstream as of ace112d): build the
  # same dashboard out of the admin namespace alone. Dialer state and
  # live connections are present there; candidate counts and dial
  # history are not, so the report omits them — "partial" marks it and
  # the view renders what it gets. nil when neither RPC answers: no
  # report beats a fabricated one.
  defp fallback_report(client) do
    {enabled, dialer_answered} =
      case Client.call(client, ["admin", "dialer", "status"], [], 2_000) do
        {:ok, %{"enabled" => value}} when is_boolean(value) -> {value, true}
        {:ok, _other} -> {nil, true}
        _ -> {nil, false}
      end

    {connections, connected_answered} = connected_ids(client)
    known = fetch_known_peers(client)

    if dialer_answered or connected_answered do
      report = %{
        "connections" => connections,
        "knownPeers" => known,
        "dialTry" => [],
        "partial" => true
      }

      if is_nil(enabled), do: report, else: Map.put(report, "enabled", enabled)
    else
      nil
    end
  catch
    _, _ -> nil
  end

  # admin.peers.connected answers one-entry [{id}] rows; unwrapped to
  # the plain id list gossip.peers hands out.
  defp connected_ids(client) do
    case Client.call(client, ["admin", "peers", "connected"], [], 2_000) do
      {:ok, rows} when is_list(rows) ->
        ids =
          Enum.flat_map(rows, fn
            %{"id" => id} when is_binary(id) -> [id]
            _ -> []
          end)

        {ids, true}

      _ ->
        {[], false}
    end
  catch
    _, _ -> {[], false}
  end

  # admin.peers.known — the conn.json address book — rides the same
  # 10s network refresh so the /network dashboard renders it with the
  # live report. Engines predating the admin namespace answer a method
  # error; the book simply stays empty.
  defp fetch_known_peers(client) do
    case Client.call(client, ["admin", "peers", "known"], [], 2_000) do
      {:ok, peers} when is_list(peers) -> Enum.filter(peers, &is_map/1)
      _ -> []
    end
  catch
    _, _ -> []
  end

  # stats.whoToFollow — active feeds we do not follow, ranked by
  # activity with follower counts. Each row is a plain string-keyed map
  # ({id, activity, followers}); rows without a usable id are dropped
  # so the sidebar never renders a dead link.
  defp fetch_suggestions(client) do
    if is_pid(client) and Process.alive?(client) do
      case Client.call(client, ["stats", "whoToFollow"], [], 2_000) do
        {:ok, %{"candidates" => list}} when is_list(list) ->
          Enum.filter(list, &(is_map(&1) and is_binary(&1["id"])))

        _ ->
          []
      end
    else
      []
    end
  catch
    _, _ -> []
  end

  # One-shot history pull on the shared client: open the stream, drain
  # it here (the GenServer mailbox receives it while the caller waits),
  # and return the messages. `order: "timestamp"` is the profile page's
  # chronological view — without it the engine pages by thread activity,
  # so a bumped thread jumps above more recent posts.
  defp fetch_profile(state, id, resume) do
    props = %{"id" => id, "limit" => 60, "reverse" => true, "order" => "timestamp"}
    props = if is_integer(resume), do: Map.put(props, "resume", resume), else: props

    if is_pid(state.client) and Process.alive?(state.client) do
      case Client.stream(
             state.client,
             ["patchwork", "profile", "roots"],
             [props],
             self()
           ) do
        {:ok, ref} -> profile_page(ref)
        _ -> %{rows: [], resume: nil, more: false}
      end
    else
      %{rows: [], resume: nil, more: false}
    end
  catch
    _, _ -> %{rows: [], resume: nil, more: false}
  end

  defp profile_page(ref) do
    {markers, rows} = drain_stream(ref, []) |> Enum.split_with(&(&1["marker"] == true))
    cursor = private_cursor(markers)

    %{
      # Sorted here, not just requested: an engine that does not
      # understand `order: "timestamp"` pages by thread activity, which
      # interleaves a bumped thread above more recent posts. Every row
      # carries the root timestamp either way, so the visible order is
      # fixed regardless of what the engine did. The set is still the
      # engine's window — this cannot recover a post that window
      # dropped — but the two nearly coincide outside feeds where old
      # threads stay busy.
      rows:
        rows
        |> Enum.map(&Map.drop(&1, ["latestReplies", "bumps"]))
        |> Enum.sort_by(& &1["timestamp"], :desc),
      resume: cursor,
      more: is_integer(cursor)
    }
  end

  # -- paged feed tabs -----------------------------------------------------

  # The engine view behind each tab. Every tab is a thread-root scope in
  # the engine (publicFeed, participatingFeed, mentionsFeed, profile,
  # privateFeed) paged by the same resume marker, so the UI never runs
  # out of feed; `profile` targets this account's own roots.
  defp fetch_view(state, :public, resume),
    do: fetch_roots(state, "publicFeed", %{}, resume, false)

  defp fetch_view(state, :participating, resume),
    do: fetch_roots(state, "participatingFeed", %{}, resume, false)

  defp fetch_view(state, :mentions, resume),
    do: fetch_roots(state, "mentionsFeed", %{}, resume, false)

  defp fetch_view(state, :private, resume),
    do: fetch_roots(state, "privateFeed", %{}, resume, true)

  defp fetch_view(%{self_id: id} = state, :profile, resume) when is_binary(id),
    do: fetch_roots(state, "profile", %{"id" => id}, resume, false)

  defp fetch_view(_state, :profile, _resume), do: empty_page()

  # One patchwork.<Feed>.roots page, drained here like fetch_history.
  # The trailing {marker, resume} frame (only sent on a full page)
  # carries the integer cursor for the next one. Rows are shaped like
  # feed rows; private items arrive freshly decrypted from the view.
  defp fetch_roots(state, feed, extra, resume, private?) do
    props = Map.merge(%{"limit" => 30, "reverse" => true}, extra)
    props = if is_integer(resume), do: Map.put(props, "resume", resume), else: props
    self_id = state.self_id
    now = System.system_time(:millisecond)

    if is_pid(state.client) and Process.alive?(state.client) do
      case Client.stream(state.client, ["patchwork", feed, "roots"], [props], self()) do
        {:ok, ref} -> roots_page(ref, state, self_id, now, private?)
        _ -> empty_page()
      end
    else
      empty_page()
    end
  catch
    _, _ -> empty_page()
  end

  defp roots_page(ref, state, self_id, now, private?) do
    {markers, items} = drain_stream(ref, []) |> Enum.split_with(&(&1["marker"] == true))
    cursor = private_cursor(markers)

    like_counts =
      case state.messages do
        %{like_counts: counts} when is_map(counts) -> counts
        _ -> %{}
      end

    rows =
      Enum.map(items, fn item ->
        row = root_row(item, self_id, now, private?)
        Map.put(row, :likes, Map.get(like_counts, item["key"], row.likes))
      end)

    %{rows: rows, resume: cursor, more: is_integer(cursor)}
  end

  defp private_cursor(markers) do
    case List.last(markers) do
      %{"resume" => r} when is_integer(r) -> r
      _ -> nil
    end
  end

  defp drain_stream(ref, acc) do
    receive do
      {Client, ^ref, {:item, msg}} -> drain_stream(ref, [msg | acc])
      {Client, ^ref, :done} -> Enum.reverse(acc)
      {Client, ^ref, {:error, _}} -> Enum.reverse(acc)
    after
      10_000 -> Enum.reverse(acc)
    end
  end

  # -- post viewer ---------------------------------------------------------

  # The viewer's data: the root (a private-capable get first — the
  # window only holds the boxed form of private messages) plus every
  # reply. A URL may point at a reply whose root is elsewhere; one level
  # of `content.root` resolution lands on the thread root.
  defp fetch_post(state, key) do
    window = post_window(state)

    case resolve_root(state, window, key) do
      nil -> nil
      root -> %{root: root, replies: post_replies(state, window, root["key"])}
    end
  end

  # The page reads the raw per-feed window, which the payload's
  # take(2000) never truncated — a deep thread whose older replies fell
  # outside the payload copy still seats them from here. Only a SETTLED
  # acc counts: open_windows resets acc to [] and refills it across the
  # whole stream — on every heartbeat reload — so a mid-reload acc is a
  # partial window, and replies computed from it come out missing
  # parents and forks alike. Until finalize lands, the last payload's
  # window is the freshest complete copy there is.
  defp post_window(state) do
    settled? = map_size(Map.get(state, :pending, %{})) == 0

    case Map.get(state, :acc, []) do
      acc when settled? and acc != [] -> acc
      _ -> Map.get(state.messages, :messages, [])
    end
  end

  defp resolve_root(state, window, key) do
    case fetch_msg(state, window, key) do
      nil -> nil
      msg -> resolve_thread_root(state, window, key, msg, MapSet.new([key]))
    end
  end

  # Walk up to the thread's first message: a plain reply's root IS that
  # message, but a fork's root is the parent reply, so one hop lands on
  # the middle of the thread. The seen set keeps a malformed cycle from
  # walking forever.
  defp resolve_thread_root(state, window, key, msg, seen) do
    root = content(msg)["root"]

    if is_binary(root) and root != key and not MapSet.member?(seen, root) do
      case fetch_msg(state, window, root) do
        nil -> msg
        parent -> resolve_thread_root(state, window, root, parent, MapSet.put(seen, root))
      end
    else
      msg
    end
  end

  defp fetch_msg(state, window, key) do
    get_msg(state.client, key) || Enum.find(window, &(&1["key"] == key))
  end

  defp post_replies(state, window, root_key) do
    replies =
      case fetch_thread(state.client, root_key) do
        list when is_list(list) and list != [] -> list
        _ -> window_replies(window, root_key)
      end

    attach_forks(replies, window, root_key)
  end

  # A reply-to-a-reply is a FORK: patchwork pins content.root to the
  # message being answered rather than the thread's first one, with
  # content.fork naming the thread. thread.sorted and window_replies
  # both match content.root == root_key, so forks vanish from the page
  # — while the feed row (build_feed walks the chain) previews and
  # counts them, and the roots view even issues a row for the fork
  # itself. The thread page must show what the row promised: pull the
  # window's forks out and slot each directly after the message it
  # answers, keeping the engine's causal order for the rest.
  defp attach_forks(replies, window, root_key) do
    have = MapSet.new(replies, & &1["key"])
    by_key = Map.new(window, &{&1["key"], &1})

    window
    |> Enum.filter(fn m ->
      is_binary(m["key"]) and m["key"] != root_key and post?(m) and
        not MapSet.member?(have, m["key"]) and fork_of?(m, by_key, root_key)
    end)
    |> Enum.sort_by(fn m -> m["value"]["timestamp"] || 0 end)
    |> Enum.reduce(replies, &insert_fork(&1, &2, by_key))
  end

  # Membership in this thread: content.fork when the client named it,
  # otherwise the root chain walk the feed rows already use — which is
  # what a fork field left out still reaches.
  defp fork_of?(m, by_key, root_key) do
    content(m)["fork"] == root_key or thread_root(m, by_key) == root_key
  end

  # Seat the fork one past the last seated descendant of the message it
  # answers — its parent included — so siblings queue in timestamp
  # order behind the subtree instead of jumping ahead of it. A parent
  # the window never saw rides at the end rather than vanishing.
  defp insert_fork(fork, replies, by_key) do
    parent = content(fork)["root"]

    last_seat =
      replies
      |> Enum.with_index()
      |> Enum.filter(fn {m, _i} -> m["key"] == parent or descendant_of?(m, parent, by_key) end)
      |> List.last()

    case last_seat do
      nil -> replies ++ [fork]
      {_m, i} -> List.insert_at(replies, i + 1, fork)
    end
  end

  defp descendant_of?(m, ancestor, by_key, seen \\ MapSet.new()) do
    root = content(m)["root"]

    cond do
      not is_binary(root) or MapSet.member?(seen, root) ->
        false

      root == ancestor ->
        true

      true ->
        case by_key[root] do
          nil -> false
          parent -> descendant_of?(parent, ancestor, by_key, MapSet.put(seen, root))
        end
    end
  end

  # Every reply in the thread, causal order (silkpurse_thread sorts with
  # a real topological pass), ending at the {sync: true} sentinel. nil on
  # transport error so the caller falls back to the window; [] is a real
  # "no replies here" that may just mean the backlinks view is still
  # building, which is also when the window knows more.
  defp fetch_thread(client, root_key) do
    if is_pid(client) and Process.alive?(client) do
      case Client.stream(
             client,
             ["patchwork", "thread", "sorted"],
             [%{"dest" => root_key}],
             self()
           ) do
        {:ok, ref} -> drain_thread(ref, [])
        _ -> nil
      end
    else
      nil
    end
  catch
    _, _ -> nil
  end

  defp drain_thread(ref, acc) do
    receive do
      {Client, ^ref, {:item, %{"sync" => true}}} -> Enum.reverse(acc)
      {Client, ^ref, {:item, msg}} -> drain_thread(ref, [msg | acc])
      {Client, ^ref, :done} -> Enum.reverse(acc)
      {Client, ^ref, {:error, _}} -> nil
    after
      8_000 -> Enum.reverse(acc)
    end
  end

  # get unboxes private content in place (value only, private: true) —
  # the one way to read a private message outside silkpurse's views.
  defp get_msg(client, key) do
    if is_pid(client) and Process.alive?(client) do
      case Client.call(client, ["get"], [%{"id" => key, "private" => true}], 5_000) do
        {:ok, value} when is_map(value) ->
          %{"key" => key, "value" => value, "timestamp" => value["timestamp"] || 0}

        _ ->
          nil
      end
    else
      nil
    end
  catch
    _, _ -> nil
  end

  defp window_replies(window, root_key) do
    window
    |> Enum.filter(fn m -> m["key"] != root_key and content(m)["root"] == root_key end)
    |> Enum.sort_by(fn m -> m["value"]["timestamp"] || 0 end)
  end

  @impl true
  def handle_info(:connect, state) do
    if Sidecar.status() == :ready do
      connect(state)
    else
      Process.send_after(self(), :connect, 3_000)
      {:noreply, %{state | status: :connecting}}
    end
  end

  def handle_info(:fetch_follows, state) do
    case Client.call(state.client, ["whoami"], []) do
      {:ok, who} ->
        id = who["id"]

        {:ok, ref} =
          Client.stream(
            state.client,
            ["patchwork", "contacts", "stateStream"],
            # live: keep the stream open for {contact => state}
            # deltas — without it silkpurse sends the snapshot and
            # ends, and follow/unfollow never reach the UI.
            [%{"feedId" => id, "live" => true}],
            self()
          )

        {:noreply,
         %{state | status: :loading, self_id: id, contacts_ref: ref, contacts_primed?: false}}

      {:error, reason} ->
        Logger.warning("timeline: whoami failed: #{inspect(reason)}")
        reconnect(state)
    end
  end

  # The contacts stream opens with the full {id => state} dict, then
  # emits single-edge deltas ({contact => state}) as contact messages
  # land (the stream is opened with live: true — without it silkpurse
  # sends the snapshot and ends, and follow/unfollow never reach the
  # UI). The first item therefore replaces the list wholesale and
  # continues the boot sequence where stream :done used to; later items
  # merge — true adds the edge, false or null drops it (unfollow or
  # block). A delta means a follow changed, so reload to re-broadcast
  # the payload promptly.
  def handle_info({Client, ref, {:item, graph}}, %{contacts_ref: ref} = state)
      when is_map(graph) do
    first? = not state.contacts_primed?

    others =
      Enum.reduce(graph, if(first?, do: [], else: state.follows), fn
        {id, true}, acc when is_binary(id) -> [id | acc]
        {id, _state}, acc when is_binary(id) -> List.delete(acc, id)
        _other, acc -> acc
      end)

    # Your own feed is not in the contacts graph — pin it so your own
    # published messages always show up in the timeline.
    follows = if is_binary(state.self_id), do: Enum.uniq([state.self_id | others]), else: others
    state = %{state | follows: follows, contacts_primed?: true}

    if first? do
      if follows == [] do
        {:noreply, finalize(state)}
      else
        # Arm the heartbeat here: this path opens windows directly, not
        # through a reload request, and a boot that stalls must still
        # have a timer to retry on.
        {:noreply, state |> Map.put(:status, :loading) |> open_windows() |> ensure_heartbeat()}
      end
    else
      {:noreply, reload_soon(state)}
    end
  end

  def handle_info({Client, ref, :done}, %{contacts_ref: ref} = state) do
    if state.contacts_primed? do
      # A live stream never ends on its own — reconnect reopens it.
      Logger.warning("timeline: contacts stream ended; reconnecting")
      reconnect(state)
    else
      # No item ever arrived (snapshot-only server): keep the old path.
      state = %{state | contacts_ref: nil}

      if state.follows == [] do
        {:noreply, finalize(state)}
      else
        {:noreply, state |> Map.put(:status, :loading) |> open_windows() |> ensure_heartbeat()}
      end
    end
  end

  def handle_info({Client, ref, {:error, reason}}, %{contacts_ref: ref} = state) do
    Logger.warning("timeline: contacts stream failed: #{inspect(reason)}")
    reconnect(state)
  end

  # blobs.ls live tail: newly stored blobs — heal any generated image
  # placeholder by bumping the revision (debounced so a burst of arrivals
  # causes one re-render).
  def handle_info({Client, ref, {:item, _id}}, %{blob_ls_ref: ref} = state) do
    if state.blob_timer, do: Process.cancel_timer(state.blob_timer)
    {:noreply, %{state | blob_timer: Process.send_after(self(), :rebroadcast, 500)}}
  end

  def handle_info({Client, ref, :done}, %{blob_ls_ref: ref} = state) do
    {:noreply, %{state | blob_ls_ref: nil}}
  end

  def handle_info({Client, ref, {:error, reason}}, %{blob_ls_ref: ref} = state) do
    Logger.debug("timeline: blobs.ls stream failed: #{inspect(reason)}")
    {:noreply, %{state | blob_ls_ref: nil}}
  end

  # messagesByType("contact"): the store-wide follow-event drain. The
  # per-feed window only carries each author's last N messages and the
  # paged publicFeed never carries contacts at all, so without this
  # drain follow rows would age out of the timeline and disappear.
  def handle_info({Client, ref, {:item, msg}}, %{contact_ref: ref} = state) do
    {:noreply, %{state | contact_buf: [msg | state.contact_buf]}}
  end

  def handle_info({Client, ref, :done}, %{contact_ref: ref} = state) do
    contact_drained(state)
  end

  def handle_info({Client, ref, {:error, reason}}, %{contact_ref: ref} = state) do
    Logger.debug("timeline: contact drain failed: #{inspect(reason)}")
    state = stop_drain_client(%{state | contact_ref: nil, contact_buf: []})
    {:noreply, state}
  end

  def handle_info(:rebroadcast, state) do
    rev = state.blob_rev + 1
    payload = %{state.messages | blob_rev: rev}
    Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {__MODULE__, :updated, payload})
    {:noreply, %{state | messages: payload, blob_rev: rev, blob_timer: nil}}
  end

  # gossip.peers refresh for the /network dashboard — a cheap local
  # sync RPC — and the stats.whoToFollow feed for the sidebar. Both are
  # absent on engines predating those RPCs (the calls answer `true`,
  # which neither branch accepts), so the dashboard and the "Who to
  # follow" section simply stay hidden.
  def handle_info({:network, gen}, %{gen: current} = state) when gen == current do
    state = %{state | network_timer: nil}
    previous = connections_of(Map.get(state, :network))
    state = Map.put(state, :network, fetch_network(Map.get(state, :client)))
    connections = connections_of(state.network)

    # A peer joined or left — the rail badge's flare rides this event.
    if connections != previous do
      broadcast_gossip(%{connected: length(connections)})
    end

    old = Map.get(state, :suggestions, [])

    state =
      Map.put(state, :suggestions, fetch_suggestions(Map.get(state, :client)))

    state =
      if state.suggestions != old and state.status == :ok do
        payload = Map.put(state.messages, :suggestions, state.suggestions)
        Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {__MODULE__, :updated, payload})
        %{state | messages: payload}
      else
        state
      end

    {:noreply, schedule_network(state, 11_000)}
  end

  def handle_info({:network, _stale}, state), do: {:noreply, state}

  def handle_info({:reload, gen}, %{gen: current} = state) when gen == current do
    state = %{state | reload_timer: nil}
    state = maybe_reload(state)
    {:noreply, schedule_reload(state, 13_000)}
  end

  def handle_info({:reload, _stale}, state), do: {:noreply, state}

  # feed history items
  def handle_info({Client, ref, {:item, msg}}, state) do
    if Map.has_key?(state.pending, ref) do
      {:noreply, %{state | acc: [msg | state.acc]}}
    else
      Logger.debug("timeline: stray item dropped ref=#{inspect(ref)}")
      {:noreply, state}
    end
  end

  def handle_info({Client, ref, :done}, state) do
    feed_done(state, ref, :done)
  end

  def handle_info({Client, ref, {:error, reason}}, state) do
    Logger.debug("timeline: feed stream error: #{inspect(reason)}")
    feed_done(state, ref, :error)
  end

  # the client died under us (sidecar restart, socket drop): reconnect
  def handle_info({:EXIT, pid, _reason}, %{client: pid} = state) do
    reconnect(%{state | client: nil})
  end

  # the dedicated drain connection died mid-pass: drop the dangling
  # ref so the next reload can re-dial instead of blocking the drain.
  def handle_info({:EXIT, pid, _reason}, %{drain_client: pid} = state) do
    {:noreply, %{state | drain_client: nil, contact_ref: nil, contact_buf: []}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    if Map.get(state.active, pid) == ref do
      active = Map.delete(state.active, pid)
      state = %{state | active: active}
      {:noreply, if(map_size(active) == 0, do: deactivate(state), else: state)}
    else
      {:noreply, state}
    end
  end

  # The async profile pass: merge into whatever payload is current and
  # re-broadcast so names and avatars fill in without a full reload.
  def handle_info({:profiles_fetched, fetched}, state) do
    state = %{state | profile_fetching?: false}

    # Fetched ids leave the wants set; ids the fetch missed stay
    # parked for the next finalize or ensure to retry. (No re-kick
    # here: a hard-failing id would hot-loop the fetch worker.)
    wants =
      state
      |> Map.get(:profile_wants, MapSet.new())
      |> MapSet.difference(MapSet.new(Map.keys(fetched)))

    state = Map.put(state, :profile_wants, wants)

    if map_size(fetched) == 0 do
      {:noreply, state}
    else
      payload = %{state.messages | profiles: Map.merge(state.messages.profiles, fetched)}
      Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {__MODULE__, :updated, payload})
      {:noreply, %{state | messages: payload}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp connections_of(%{"connections" => connections}) when is_list(connections), do: connections
  defp connections_of(_), do: []

  defp broadcast_gossip(payload) do
    Phoenix.PubSub.broadcast(HighWire.PubSub, @gossip, {__MODULE__, :gossip, payload})
  end

  # -- flow --------------------------------------------------------------
  defp maybe_reload(state) do
    cond do
      # Boot stalled mid-sequence: a stream that failed to open (or a
      # contacts snapshot that never arrived) would otherwise leave the
      # app on an empty payload forever, with no reload request armed to
      # recover it. Re-open the window once follows are known; re-dial
      # when the contacts stream never primed.
      stalled_boot?(state) ->
        resume_boot(state)

      # Streams are already in flight: come back shortly rather than
      # losing this request to the 13s heartbeat. A publish's refresh
      # must not wait out a full tick to show up on screen.

      map_size(state.pending) != 0 ->
        schedule_reload(state, 400)

      state.status != :ok ->
        state

      state.follows == [] ->
        state

      not (is_pid(state.client) and Process.alive?(state.client)) ->
        state

      true ->
        open_windows(%{state | done_count: 0})
    end
  catch
    _, _ -> state
  end

  defp stalled_boot?(state) do
    state.status == :loading and map_size(state.pending) == 0
  end

  defp resume_boot(state) do
    if state.contacts_primed? do
      open_windows(%{state | done_count: 0})
    else
      reset_connection(state)
    end
  end

  defp connect(state) do
    secret = Path.join([HighWire.home_dir(), ".ssberl", "secret"])

    if File.exists?(secret) do
      case start_client(secret) do
        {:ok, client} ->
          send(self(), :fetch_follows)
          blob_ls_ref = open_blob_tail(client)
          {:noreply, %{state | status: :connecting, client: client, blob_ls_ref: blob_ls_ref}}

        {:error, reason} ->
          Logger.debug("timeline: connect failed: #{inspect(reason)}")
          schedule_reconnect()
          {:noreply, %{state | status: :connecting}}
      end
    else
      schedule_reconnect()
      {:noreply, %{state | status: :connecting}}
    end
  end

  # Live tail of newly stored blobs — the healing signal for generated
  # placeholders (a failure here just disables healing, never the app).
  defp open_blob_tail(client) do
    case Client.stream(client, ["blobs", "ls"], [%{"old" => false}], self()) do
      {:ok, ref} -> ref
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  defp start_client(secret) do
    keys = Keys.load!(secret)

    Client.start_link(
      port: Sidecar.port(),
      remote_pk: keys.public,
      net_id: Base.decode64!(Sidecar.net_id()),
      keys: keys
    )
  rescue
    e -> {:error, e}
  end

  # Open the per-follow window streams plus the store-wide contact
  # drain. The drain is separate because contact messages never enter
  # the paged publicFeed (silkpurse_threads classifies them `ignore`)
  # and only the last `messages_per_feed` of each feed ever reach the
  # window — without it, follow rows age out of the timeline and
  # vanish. One drain at a time: a reload while one is still flying
  # skips reopening it, and the drain's :done/:error clears the ref.
  defp open_windows(state) do
    state = %{state | pending: open_feeds(state), acc: []}
    maybe_open_drain(state)
  catch
    _, _ -> state
  end

  # The drain streams the entire contact table (200k+ items, tens of
  # seconds). On the shared client those ordered box-stream frames sit
  # ahead of every cursor page and starve it past the 10s page timeout
  # — tabs fall back to window-only rows. So the drain gets its own SHS
  # connection, and a completed pass is not repeated until
  # @drain_refresh_ms later.
  defp maybe_open_drain(state) do
    if state.contact_ref == nil and drain_due?(state) do
      open_drain(state)
    else
      state
    end
  catch
    _, _ -> state
  end

  defp open_drain(state) do
    {client, state} = drain_endpoint(state)

    with true <- is_pid(client),
         {:ok, ref} <- Client.stream(client, ["messagesByType"], [%{"type" => "contact"}], self()) do
      %{state | contact_ref: ref, contact_buf: []}
    else
      _ -> state
    end
  catch
    _, _ -> state
  end

  defp drain_due?(%{last_drain_at: nil}), do: true

  defp drain_due?(%{last_drain_at: at}) do
    System.monotonic_time(:millisecond) - at > @drain_refresh_ms
  end

  # An already-open dedicated connection wins; tests (drain_connection:
  # false) and a failed dial fall back to the main client — correct in
  # both cases: the fake client answers stream calls directly, and the
  # main client still works, just with the starvation caveat.
  defp drain_endpoint(state) do
    cond do
      is_pid(state.drain_client) and Process.alive?(state.drain_client) ->
        {state.drain_client, state}

      Keyword.get(Sidecar.config(), :drain_connection, true) == false ->
        {state.client, state}

      not is_pid(state.client) ->
        {nil, state}

      true ->
        dial_drain(state)
    end
  end

  defp dial_drain(state) do
    secret = Path.join([HighWire.home_dir(), ".ssberl", "secret"])

    if File.exists?(secret) do
      case start_client(secret) do
        {:ok, client} -> {client, %{state | drain_client: client}}
        _ -> {state.client, state}
      end
    else
      {state.client, state}
    end
  end

  # Best-effort teardown of the dedicated drain connection — a failed
  # pass must not leak a half-open socket until Timeline restarts.
  defp stop_drain_client(%{drain_client: pid} = state) when is_pid(pid) do
    Client.stop(pid)
    %{state | drain_client: nil}
  catch
    _, _ -> %{state | drain_client: nil}
  end

  defp stop_drain_client(state), do: state

  defp open_feeds(state) do
    max = Keyword.get(Sidecar.config(), :max_feeds, 400)
    per = Keyword.get(Sidecar.config(), :messages_per_feed, 10)

    # Own feed first, then alphabetical; the take(max) below can never
    # drop the account's own messages off the timeline.
    ids =
      case state.self_id do
        nil ->
          Enum.sort(state.follows)

        self ->
          [self | state.follows |> Enum.reject(&(&1 == self)) |> Enum.sort()]
      end
      |> Enum.take(max)

    ids
    |> Map.new(fn fid ->
      {:ok, ref} =
        Client.stream(
          state.client,
          ["createHistoryStream"],
          [%{"id" => fid, "limit" => per, "reverse" => true}],
          self()
        )

      {ref, fid}
    end)
  end

  defp feed_done(state, ref, _result) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        {:noreply, state}

      {_feed, pending} ->
        state = %{state | pending: pending, done_count: state.done_count + 1}

        cond do
          map_size(pending) == 0 ->
            {:noreply, finalize(state)}

          # First load only: paint once a sliver of the window is in,
          # rather than waiting on all 400 streams. The final payload
          # replaces this one wholesale.
          state.status != :ok and state.done_count == @first_paint_feeds ->
            {:noreply, broadcast_preliminary(state)}

          true ->
            {:noreply, state}
        end
    end
  end

  # acc survives finalize: the contact drain can land after the feed
  # payload is already final, and the rebuild needs the window that
  # built it. The next reload resets acc anyway.
  defp finalize(state) do
    {payload, missing, base, post_refs} = build_payload(state)

    Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {__MODULE__, :updated, payload})

    state = %{state | status: :ok, messages: payload, pending: %{}, done_count: 0}
    kick_profile_fetch(state, missing, base, post_refs)
  end

  # The contact drain finished: fold the follow events into the
  # store-wide list. If the feed payload is already final, rebuild so
  # the rows show now instead of on the next reload; when feeds are
  # still streaming, their own finalize pass picks the messages up.
  defp contact_drained(state) do
    known = MapSet.new(state.contact_msgs, & &1["key"])
    fresh = Enum.reject(state.contact_buf, &MapSet.member?(known, &1["key"]))

    state = %{
      state
      | contact_ref: nil,
        contact_buf: [],
        contact_msgs: state.contact_msgs ++ fresh,
        last_drain_at: System.monotonic_time(:millisecond)
    }

    if fresh != [] and state.status == :ok and map_size(state.pending) == 0 do
      {:noreply, finalize(state)}
    else
      {:noreply, state}
    end
  end

  # First-paint snapshot: same payload, nothing cleared — feeds are
  # still streaming and the final pass rebuilds it wholesale.
  defp broadcast_preliminary(state) do
    {payload, _missing, _base, _refs} = build_payload(state)

    Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {__MODULE__, :updated, payload})

    %{state | status: :ok, messages: payload}
  end

  defp build_payload(state) do
    now = System.system_time(:millisecond)
    # The window (acc) plus the store-wide contact drain: follow events
    # are rare and old, so they routinely sit outside the per-feed
    # window and would otherwise age out of every payload.
    acc = Enum.uniq_by(state.acc ++ state.contact_msgs, & &1["key"])

    reply_counts = reply_counts(acc)
    likes = likes_state(acc)
    like_counts = like_counts(likes)
    index = author_index(acc)

    # Flat list (order-of-arrival view). Generous cap — the LiveView
    # paginates display for infinite scroll; grouping means the feed is
    # smaller than the message count anyway.
    messages =
      acc
      |> Enum.sort_by(&clamped_ts(&1, now), :desc)
      |> Enum.take(2000)

    feed = build_feed(acc, state.self_id, like_counts, now)

    # Suggestion rows need names/avatars too, or the sidebar shows bare
    # short ids for strangers — profile fetch covers them on top of the
    # usual participants + follows.
    suggestions = Map.get(state, :suggestions, [])
    sugg_ids = for s <- suggestions, is_binary(s["id"]), do: s["id"]

    # Parked ensure_profiles ids ride along, so every finalize also
    # retries whatever the window never asked for and the fetch missed.
    wants = state |> Map.get(:profile_wants, MapSet.new()) |> MapSet.to_list()

    ids = Enum.uniq(profile_ids(feed, state.follows) ++ sugg_ids ++ wants)
    known = Map.get(state.messages, :profiles, %{})
    missing = Enum.reject(ids, &Map.has_key?(known, &1))
    base = Map.take(known, ids)
    post_refs = post_image_refs(acc)

    payload = %{
      feed: feed,
      messages: messages,
      reply_counts: reply_counts,
      like_counts: like_counts,
      likes_by: like_authors(likes),
      my_likes: my_likes(likes, state.self_id),
      index: index,
      follows: state.follows,
      self_id: state.self_id,
      profiles: base,
      blob_rev: state.blob_rev,
      suggestions: suggestions
    }

    {payload, missing, base, post_refs}
  end

  # Names and blob wants run after the payload is out: the feed must not
  # wait on hundreds of avatar round trips. One worker at a time — a
  # finalize while it runs skips, and the pass after it finishes rechecks
  # whatever is still missing. The worker also carries the blob wants, so
  # a finalize whose profiles are ALL known must still run it when the
  # window holds unseen images: blobs from fresh posts by known authors
  # are exactly when the wants matter, and skipping on an empty missing
  # list is what left those bytes never filling in.
  defp kick_profile_fetch(%{profile_fetching?: true} = state, _missing, _base, _refs),
    do: state

  defp kick_profile_fetch(state, missing, base, post_refs) do
    if missing == [] and post_refs == [] and Enum.all?(image_refs(base), &is_nil/1) do
      state
    else
      spawn_profile_worker(state, missing, base, post_refs)
    end
  end

  defp spawn_profile_worker(state, missing, base, post_refs) do
    if is_pid(state.client) and Process.alive?(state.client) do
      client = state.client
      parent = self()

      spawn(fn ->
        try do
          t0 = System.monotonic_time(:millisecond)
          fetched = fetch_profiles(client, missing)
          want_missing_blobs(client, post_refs ++ image_refs(Map.merge(base, fetched)))
          took = System.monotonic_time(:millisecond) - t0
          Logger.debug("timeline: #{map_size(fetched)} profiles + wants in #{took}ms")
          send(parent, {:profiles_fetched, fetched})
        catch
          kind, reason ->
            Logger.debug("timeline: profile worker failed: #{inspect({kind, reason})}")
            send(parent, {:profiles_fetched, %{}})
        end
      end)

      %{state | profile_fetching?: true}
    else
      state
    end
  end

  # An ensure_profiles arrived: fetch now if a worker is idle. When one
  # is already running it is not interrupted — build_payload unions the
  # wants into its missing list, so the pass after it finishes retries
  # whatever the wants still hold.
  defp kick_wanted_profiles(%{profile_fetching?: true} = state), do: state

  defp kick_wanted_profiles(state) do
    known = state |> Map.get(:messages, %{}) |> Map.get(:profiles, %{})

    wanted =
      state
      |> Map.get(:profile_wants, MapSet.new())
      |> MapSet.to_list()
      |> Enum.reject(&Map.has_key?(known, &1))

    kick_profile_fetch(state, wanted, Map.take(known, wanted), [])
  end

  # -- profiles -----------------------------------------------------------

  # Feeds whose name/avatar the UI can show: every thread participant
  # plus the follow list (sidebar), capped so a huge graph cannot turn
  # one finalize into thousands of round trips.
  defp profile_ids(feed, follows) do
    (Enum.flat_map(feed, & &1.participants) ++ follows)
    |> Enum.filter(&(is_binary(&1) and String.starts_with?(&1, "@")))
    |> Enum.uniq()
    |> Enum.take(600)
  end

  # Concurrent across ids: the muxrpc client pipelines in-flight requests
  # over one connection, so 8-wide turns a serial crawl into a couple of
  # round-trip groups. A dead client or a timeout drops that id only.
  defp fetch_profiles(client, ids) do
    ids
    |> Task.async_stream(
      fn id ->
        case avatar_of(client, id) do
          {:ok, profile} -> {id, profile}
          _other -> nil
        end
      end,
      max_concurrency: 8,
      ordered: false,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {id, profile}}, acc when not is_nil(profile) -> Map.put(acc, id, profile)
      {:ok, nil}, acc -> acc
      {:exit, _reason}, acc -> acc
    end)
  end

  # One patchwork.profile.avatar call per feed; a dead client stops the
  # pass (keep what came back), a timeout just skips that feed.
  defp avatar_of(nil, _id), do: :stop

  defp avatar_of(client, id) do
    case Client.call(client, ["patchwork", "profile", "avatar"], [%{"id" => id}], 1_500) do
      {:ok, %{"name" => name, "image" => image}} ->
        {:ok, %{name: label(name), image: image_ref(image)}}

      _ ->
        :error
    end
  catch
    _kind, _reason -> if is_pid(client) and Process.alive?(client), do: :error, else: :stop
  end

  # Avatars and post images whose blob we have never seen: register
  # wants so the sidecar pulls them from the gossip graph; /blob/ serves
  # a neutral missing-blob placeholder until the bytes land (the
  # blobs.ls tail then bumps blob_rev and the UI refetches).
  defp want_missing_blobs(client, refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and not Blob.local?(&1)))
    |> Enum.uniq()
    |> Enum.take(300)
    |> Enum.each(fn ref ->
      try do
        _ = Client.call(client, ["blobs", "want"], [ref], 1_500)
        :ok
      catch
        _, _ -> :ok
      end
    end)
  end

  defp image_refs(profiles) do
    Enum.map(profiles, fn {_id, p} -> p[:image] end)
  end

  # Markdown image targets (![alt](&…sha256)) in post bodies — these are
  # rendered inline, so their blobs are wanted alongside avatar images.
  defp post_image_refs(acc) do
    acc
    |> Enum.filter(&post?/1)
    |> Enum.map(fn msg -> content(msg)["text"] || "" end)
    |> Enum.flat_map(fn body ->
      Regex.scan(~r/!\[[^\]]*\]\(\s*(&[A-Za-z0-9+\/=_-]+\.sha256)/, body, capture: :all_but_first)
      |> List.flatten()
    end)
    |> Enum.uniq()
  end

  defp label(v) when is_binary(v) and v != "", do: v
  defp label(_), do: nil

  defp image_ref(%{"link" => link}) when is_binary(link), do: link
  defp image_ref(v) when is_binary(v), do: v
  defp image_ref(_), do: nil

  # Patchwork/Poncho Wonky publicFeed.roots semantics: one row per thread
  # positioned at its latest bumping activity; votes never row/bump;
  # rootless posts are their own rows; contact messages collapse into
  # one row per author listing who they followed.
  @doc false
  def build_feed(acc, self_id, like_counts, now) do
    # Boxed (encrypted) messages never form public rows — the Private tab
    # shows them decrypted, straight from privateFeed.
    acc = Enum.reject(acc, &boxed?/1)

    by_key = Map.new(acc, fn msg -> {msg["key"], msg} end)
    {contacts, rest} = Enum.split_with(acc, &contact?/1)
    {threaded, standalone} = Enum.split_with(rest, &(thread_root(&1, by_key) != nil))

    thread_entries =
      threaded
      |> Enum.group_by(&thread_root(&1, by_key))
      |> Enum.map(fn {root_key, group} ->
        root_msg = Map.get(by_key, root_key)
        sorted = Enum.sort_by(group, &clamped_ts(&1, now), :desc)
        row_msg = root_msg || hd(sorted)

        # The head never previews itself; a fallback head (root absent
        # from the window) is excluded too, else it greets its own row.
        recent =
          sorted
          |> Enum.reject(&(&1["key"] in [root_key, row_msg["key"]]))
          |> Enum.filter(&post?/1)
          |> Enum.take(3)

        replies =
          group
          |> Enum.filter(&post?/1)
          |> Enum.reject(&(&1["key"] == row_msg["key"]))
          |> length()

        likes = thread_likes(group, root_key, like_counts)

        activity = sorted |> Enum.map(&clamped_ts(&1, now)) |> Enum.max()

        participants = thread_participants(group, root_msg)

        # A mention anywhere in the thread marks the row — including the
        # root when it never made it into the window, which is exactly
        # where keying off content["root"] alone loses mentions.
        mentioned? = Enum.any?(maybe_cons(root_msg, group), &mentions_self?(&1, self_id))

        build_entry(:thread, row_msg, activity, participants, replies, likes, recent,
          self_id: self_id,
          rooted: root_msg != nil,
          mentioned?: mentioned?,
          root_key: root_key
        )
      end)

    contact_entries = contact_rows(contacts, self_id, now)

    other_entries =
      standalone
      |> Enum.reject(&vote?/1)
      |> Enum.map(fn msg ->
        kind = if post?(msg), do: :post, else: :other

        build_entry(
          kind,
          msg,
          clamped_ts(msg, now),
          [msg["value"]["author"]],
          0,
          Map.get(like_counts, msg["key"] || "", 0),
          [],
          self_id: self_id,
          rooted: true,
          mentioned?: mentions_self?(msg, self_id)
        )
      end)

    (thread_entries ++ contact_entries ++ other_entries)
    |> Enum.sort_by(& &1.activity, :desc)
    |> Enum.take(2000)
  end

  # A run of "X followed a", "X followed b" messages collapses into ONE
  # row per author — listing everyone they followed (the UI shows their
  # avatars) — positioned at the latest follow.
  defp contact_rows(msgs, self_id, now) do
    msgs
    |> Enum.filter(fn msg ->
      is_binary(msg["value"]["author"]) and is_binary(content(msg)["contact"])
    end)
    |> Enum.group_by(& &1["value"]["author"])
    |> Enum.map(fn {author, group} ->
      latest = Enum.max_by(group, &clamped_ts(&1, now))

      followed =
        group
        |> Enum.map(&content(&1)["contact"])
        |> Enum.uniq()

      build_entry(:contact, latest, clamped_ts(latest, now), [author], 0, 0, [],
        self_id: self_id,
        rooted: true
      )
      |> Map.put(:followed, followed)
    end)
  end

  defp build_entry(kind, msg, activity, participants, replies, likes, recent, opts) do
    self_id = Keyword.fetch!(opts, :self_id)

    %{
      kind: kind,
      msg: msg,
      activity: activity,
      participants: participants,
      replies: replies,
      likes: likes,
      recent: recent,
      self?: is_binary(self_id) and self_id in participants,
      mentioned?: Keyword.get(opts, :mentioned?, false),
      rooted?: Keyword.fetch!(opts, :rooted),
      root_key: Keyword.get(opts, :root_key)
    }
  end

  # A `roots` view item (thread summary + rollup extras) shaped exactly
  # like a feed row, so the timeline renders it with the same
  # components. private? marks it for the private badge.
  @doc false
  def root_row(item, self_id, now, private?) do
    msg = %{
      "key" => item["key"],
      "value" => item["value"],
      "timestamp" => item["timestamp"]
    }

    # Engine contract: latestReplies SELECTS the newest few but RETURNS
    # them oldest-first (rollups render in list order). Feed rows store
    # recent newest-first and the template reverses for display, so flip
    # here or the thread renders backwards — and keep the newest cap.
    recent = item["latestReplies"] |> List.wrap() |> Enum.reverse() |> Enum.take(3)
    replies = item["totalReplies"] || 0
    author = msg["value"]["author"]

    activity =
      [clamped_ts(msg, now) | Enum.map(recent, &clamped_ts(&1, now))]
      |> Enum.max()

    row =
      build_entry(
        if(replies > 0, do: :thread, else: :post),
        msg,
        activity,
        [author],
        replies,
        0,
        recent,
        self_id: self_id,
        rooted: true,
        mentioned?: mentions_self?(msg, self_id)
      )

    if private?, do: Map.put(row, :private?, true), else: row
  end

  # Everyone in the thread: reply authors plus the root's author.
  defp thread_participants(group, root_msg) do
    authors = Enum.map(group, & &1["value"]["author"])
    authors = if root_msg, do: authors ++ [root_msg["value"]["author"]], else: authors
    Enum.uniq(authors)
  end

  defp maybe_cons(nil, list), do: list
  defp maybe_cons(head, list), do: [head | list]

  # Names us anywhere in the post's raw text (markdown link targets
  # include the full id, e.g. [@dtBy](@DgsA...=.ed25519)).
  defp mentions_self?(msg, self_id) when is_binary(self_id) do
    String.contains?(content(msg)["text"] || "", self_id)
  end

  defp mentions_self?(_msg, _self_id), do: false

  # The thread a message belongs to, following get-root.js: posts → root,
  # rootless posts → their own key (so a thread with replies yields ONE
  # row, never a standalone duplicate of its root), abouts → about when
  # it references a message. Votes are not grouped (they never become
  # rows); they only contribute like counts.
  #
  # Roots are chain-normalized: when only part of a conversation's chain
  # is in the window, walk up through in-window post parents so every
  # piece groups under one key — otherwise an intermediate parent heads
  # its own row while the replies it spawned head another (the split
  # conversations bug).
  defp thread_root(msg, by_key) do
    c = content(msg)

    cond do
      c["type"] == "post" and msg_id?(c["root"]) -> walk_root(c["root"], by_key)
      c["type"] == "post" and is_binary(msg["key"]) -> msg["key"]
      c["type"] == "about" and msg_id?(c["about"]) -> c["about"]
      true -> nil
    end
  end

  # Bounded upward walk: posts only; stop at the first ancestor missing
  # from the window (its further chain is unknowable here), at a
  # non-post or rootless parent, on revisit, or at depth 32 so a cyclic
  # or pathological chain can never hang the finalize pass.
  defp walk_root(root, by_key, seen \\ MapSet.new(), depth \\ 0) do
    parent = Map.get(by_key, root)

    if parent != nil and post?(parent) and msg_id?(content(parent)["root"]) and
         depth < 32 and not MapSet.member?(seen, root) do
      walk_root(content(parent)["root"], by_key, MapSet.put(seen, root), depth + 1)
    else
      root
    end
  end

  defp msg_id?(<<"%", _::binary>> = id), do: String.ends_with?(id, ".sha256")
  defp msg_id?(_), do: false

  # Poncho's get-timestamp guard: never trust future-dated claimed times
  # (true arrival order needs a local receive-time index; not on the wire).
  defp clamped_ts(msg, now) do
    case msg["value"]["timestamp"] do
      ts when is_number(ts) -> min(round(ts), now)
      _ -> 0
    end
  end

  defp vote?(msg), do: content(msg)["type"] == "vote"
  defp contact?(msg), do: content(msg)["type"] == "contact"
  defp post?(msg), do: content(msg)["type"] == "post"
  defp boxed?(msg), do: is_binary(msg["value"]["content"])

  # Replies reference the thread root by key; counts only count post
  # messages, not votes/contacts that share the root.
  defp reply_counts(acc) do
    acc
    |> Enum.filter(fn msg -> post?(msg) and msg_id?(content(msg)["root"]) end)
    |> Enum.frequencies_by(fn msg -> content(msg)["root"] end)
  end

  # A row's like total: the seed already covers the root key, so the
  # in-window root is skipped — re-adding it per member double-counted
  # likes on every rooted row (the "likes exactly 2x" bug).
  defp thread_likes(group, root_key, like_counts) do
    Enum.reduce(group, Map.get(like_counts, root_key, 0), fn msg, acc ->
      if msg["key"] == root_key do
        acc
      else
        acc + Map.get(like_counts, msg["key"] || "", 0)
      end
    end)
  end

  # Per-target like state: `%{target => %{author => {timestamp, value}}}`.
  # The latest vote per author wins, so an unlike lands even though both
  # messages sit in the window; a positive value likes and anything else
  # retracts (silkpurse_likes' rule).
  @doc false
  def likes_state(acc) do
    Enum.reduce(acc, %{}, &add_vote/2)
  end

  defp add_vote(msg, likes) do
    c = content(msg)
    author = msg["value"]["author"]
    link = vote_link(c)

    if c["type"] == "vote" and is_binary(link) and is_binary(author) do
      put_vote(likes, link, author, vote_ts(msg), vote_value(c))
    else
      likes
    end
  end

  defp put_vote(likes, link, author, ts, value) do
    entry = {ts, value}
    by_author = Map.get(likes, link, %{})

    by_author =
      case Map.get(by_author, author) do
        {prev_ts, _prev} when prev_ts > ts -> by_author
        _ -> Map.put(by_author, author, entry)
      end

    Map.put(likes, link, by_author)
  end

  @doc false
  def like_counts(likes) do
    Enum.reduce(likes, %{}, fn {link, by_author}, counts ->
      n = Enum.count(by_author, fn {_author, {_ts, value}} -> is_number(value) and value > 0 end)
      if n > 0, do: Map.put(counts, link, n), else: counts
    end)
  end

  # The same votes as like_counts/1, but as the liker ids themselves,
  # newest voter first — the feed shows who liked, not how many.
  @doc false
  def like_authors(likes) do
    Enum.reduce(likes, %{}, fn {link, by_author}, acc ->
      authors =
        by_author
        |> Enum.filter(fn {_author, {_ts, value}} -> is_number(value) and value > 0 end)
        |> Enum.sort_by(fn {author, {ts, _}} -> {ts, author} end, :desc)
        |> Enum.map(&elem(&1, 0))

      if authors == [], do: acc, else: Map.put(acc, link, authors)
    end)
  end

  @doc false
  def my_likes(likes, self_id) when is_binary(self_id) do
    likes
    |> Enum.filter(fn {_link, by_author} ->
      case Map.get(by_author, self_id) do
        {_ts, value} -> is_number(value) and value > 0
        nil -> false
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  def my_likes(_likes, _self_id), do: []

  # Vote content appears in three shapes: this network's nested
  # {type, vote: {link, value}}, the classic js-client
  # {type, value: {link, value}}, and a flat {type, link}. Read all.
  @doc false
  def vote_link(c) do
    cond do
      is_map(c["vote"]) and is_binary(c["vote"]["link"]) -> c["vote"]["link"]
      is_map(c["value"]) and is_binary(c["value"]["link"]) -> c["value"]["link"]
      is_binary(c["link"]) -> c["link"]
      true -> nil
    end
  end

  defp vote_value(c) do
    value =
      cond do
        is_map(c["vote"]) -> c["vote"]["value"]
        is_map(c["value"]) -> c["value"]["value"]
        true -> nil
      end

    if is_number(value), do: value, else: 1
  end

  defp vote_ts(msg) do
    case msg["value"]["timestamp"] do
      t when is_number(t) -> t
      _ -> 0
    end
  end

  # key → author for the whole pass, so vote rows can name their target.
  defp author_index(acc) do
    Enum.reduce(acc, %{}, fn msg, idx ->
      case {msg["key"], msg["value"]["author"]} do
        {k, a} when is_binary(k) and is_binary(a) -> Map.put_new(idx, k, a)
        _ -> idx
      end
    end)
  end

  defp content(msg) do
    case msg do
      %{"value" => %{"content" => c}} when is_map(c) -> c
      _ -> %{}
    end
  end

  defp reconnect(state) do
    {:noreply, reset_connection(state)}
  end

  defp reset_connection(state) do
    schedule_reconnect()

    %{
      state
      | status: :connecting,
        client: nil,
        contacts_ref: nil,
        contacts_primed?: false,
        pending: %{},
        blob_ls_ref: nil
    }
  end

  defp schedule_reconnect, do: Process.send_after(self(), :connect, 3_000)
end
