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
    * contact (follow/block) messages collapse into one row per author
      per direction — who they followed, who they blocked, who they let
      go — positioned at the author's latest edit of that kind
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
    * `:blocked`      — the feeds the account blocks (never self)
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
  alias HighWire.Contacts
  alias HighWire.SSB.{Client, Keys, MessageIndex, PrivateBox, Profile, Sidecar}
  alias HighWire.Suggester
  alias HighWireWeb.MessageText

  @topic "timeline"
  @gossip "gossip"

  # First-paint: once this many feed streams have reported, broadcast
  # what has arrived instead of waiting for every stream (up to 400).
  @first_paint_feeds 40

  # How many hops up the `content.root` chain the thread-root walk will
  # take before giving up and seating what it has. A reply's root normally
  # IS the thread head, and a fork's root is its parent reply — one or two
  # hops. Anything this deep is either a malformed chain or a hostile one
  # built to fan out remote `get`s on every open, so the walk stops here
  # and the deepest message reached heads the row instead.
  @thread_root_depth 32

  # Store-wide contact drain: a completed pass is not repeated on the
  # next reload — only after this long (the per-feed window already
  # carries recent follows; the drain back-fills old follow rows).
  # 13 — prime, so the drain refresh never lines up with the 11s
  # network poll or the 7s UI ticks.
  @drain_refresh_ms :timer.minutes(13)

  # After a rail refresh the Suggester may serve a prefetched set at
  # once or finish a background ranking in a second or two; the sync
  # samples just long enough to catch either without waiting for the
  # 11s network poll (25 x 400ms), then gives up — the poll still
  # delivers anything slower.
  @suggestions_sync_ms 400
  @suggestions_sync_tries 25

  # A spate of contact edits — one client session's worth of follows or
  # blocks — ends when the author stops for this long. Patchwork-style
  # clients publish one message per change, so a handful of clicks reads
  # as one action; the cooloff opens the next line. Spates chain, so a
  # session that keeps clicking never splits just because it outran the
  # cooloff.
  @contact_cooloff_ms :timer.minutes(20)

  # One page of a roots-shaped view — a profile's feed, a tab. The engine
  # honors this; the drain bounds itself to it too, because the drain runs
  # inside the Timeline's GenServer call.
  @profile_page 60
  @roots_page 30

  def topic, do: @topic

  @doc "PubSub topic for gossip events — the live connection set changing."
  @spec gossip_topic() :: binary()
  def gossip_topic, do: @gossip

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec set_activity(pid(), boolean()) :: :ok
  def set_activity(pid, active?) when is_pid(pid) and is_boolean(active?) do
    GenServer.cast(__MODULE__, {:set_activity, pid, active?})
  end

  @doc """
  Ask the Suggester for a fresh "Whom to follow" set. Ranking is
  off-process and its rows land asynchronously, so this arms a short
  sync that rebroadcasts the payload when they move instead of
  leaving the rail waiting for the next network poll.
  """
  @spec refresh_suggestions() :: :ok
  def refresh_suggestions, do: GenServer.cast(__MODULE__, :refresh_suggestions)

  @spec snapshot() :: {:ok | :loading | :connecting | :disabled | :down, map()}
  def snapshot do
    case Process.whereis(__MODULE__) do
      nil -> {:disabled, empty_payload()}
      pid -> snapshot(pid)
    end
  end

  # Split out so a test can drive the timeout against a process that
  # never answers, without suspending the live timeline every other
  # caller shares.
  @doc false
  @spec snapshot(pid()) :: {:ok | :loading | :connecting | :disabled | :down, map()}
  def snapshot(pid) when is_pid(pid) do
    GenServer.call(pid, :snapshot, 500)
  catch
    # The 500ms budget is meant to lose a race with a reload, not to
    # crash the caller: every mount reads this, and a reload that
    # overruns would otherwise take the LiveView down with it. ":loading"
    # is the honest answer — the process is alive, mid-payload — and the
    # broadcast that ends the reload fills the view in.
    :exit, _ -> {:loading, empty_payload()}
  end

  @doc """
  Live health probes for the diagnostics page — one per engine view the
  timeline depends on, plus the sidecar and the local window.

  Runs in the timeline process so it reuses the authenticated client, and
  returns a map with a `:probes` list (one entry per check, `:ok` /
  `:warn` / `:fail` with a human note) and top-level `:sidecar` and
  `:window` summaries. `:disabled` when the timeline is not running.
  """
  @spec diagnose() :: map()
  def diagnose do
    case Process.whereis(__MODULE__) do
      nil -> %{sidecar: Sidecar.status(), window: nil, probes: []}
      pid -> GenServer.call(pid, :diagnose, 15_000)
    end
  catch
    :exit, _ -> %{sidecar: Sidecar.status(), window: nil, probes: []}
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
  How recently the engine reported network activity — the timestamps of
  the last network and gossip events and `active?` when the network one
  is still inside the 2.5s window the header's indicator rides.

  Every bump is also pushed on the timeline PubSub topic as
  `{HighWire.Timeline, :transfer, status}`, so a live view tracks the
  window without polling it.
  """
  @spec transfer_status() :: %{
          last_net_at: integer() | nil,
          last_gossip_at: integer() | nil,
          active?: boolean()
        }
  def transfer_status do
    case Process.whereis(__MODULE__) do
      nil ->
        %{last_net_at: nil, last_gossip_at: nil, active?: false}

      pid ->
        try do
          GenServer.call(pid, :transfer_status, 3_000)
        catch
          :exit, _ -> %{last_net_at: nil, last_gossip_at: nil, active?: false}
        end
    end
  end

  @doc """
  The locally cached per-peer recency hints (`last_connected_at`,
  `last_activity_at`, `last_seen_at`) keyed by peer id or address.

  Purely a UI hint — the engine's report stays authoritative — but it
  is what lets the constellation distinguish peers it has heard from
  from entries it only knows by name. `%{}` when the timeline is down.
  """
  @spec peer_meta() :: map()
  def peer_meta do
    case Process.whereis(__MODULE__) do
      nil ->
        %{}

      pid ->
        try do
          GenServer.call(pid, :peer_meta, 3_000)
        catch
          :exit, _ -> %{}
        end
    end
  end

  @doc """
  The viewer's own facts — `%{status, self_id, follows, blocked, blob_rev}`
  — as one small read.

  A page that shows a thread or a profile needs the viewer's identity,
  who they follow and block, and the blob revision; it does not need the
  feed, the flat message list or the index. Reading those off the whole
  payload shipped a store-sized map to every such mount, so this answers
  the question actually asked. `:disabled` when the timeline is down.
  """
  @spec viewer() :: %{
          status: atom(),
          self_id: binary() | nil,
          follows: [binary()],
          blocked: [binary()],
          blob_rev: integer()
        }
  def viewer do
    case Process.whereis(__MODULE__) do
      nil ->
        %{status: :disabled, self_id: nil, follows: [], blocked: [], blob_rev: 0}

      pid ->
        try do
          GenServer.call(pid, :viewer, 1_000)
        catch
          :exit, _ -> %{status: :loading, self_id: nil, follows: [], blocked: [], blob_rev: 0}
        end
    end
  end

  @doc """
  A feed's profile card — `%{name, image, description}` — read straight
  from the `HighWire.SSB.Profile` read model, or nil while nothing has
  resolved that feed.

  No Timeline call: the read model is public ETS, written by the payload
  broadcast (name, image) and the store-wide about drain (name,
  description), so the profile page reads it in its own process without
  queueing behind the Timeline's mailbox or waiting on a sidecar
  round-trip. The timeline itself bulk-fetches only name/image via the
  payload's `:profiles`.
  """
  @spec profile(binary()) ::
          %{name: binary() | nil, image: binary() | nil, description: binary() | nil} | nil
  def profile(id) when is_binary(id), do: Profile.get(id)

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
  @spec profile_feed(binary(), integer() | nil) ::
          {:ok, %{rows: [map()], resume: integer() | nil, more: boolean()}}
          | {:error, :offline | :timeout}
  def profile_feed(id, resume \\ nil) when is_binary(id) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :offline}

      pid ->
        try do
          {:ok, GenServer.call(pid, {:profile_feed, id, resume}, 15_000)}
        catch
          :exit, _ -> {:error, :timeout}
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
  def private_feed(resume \\ nil) do
    case feed(:private, resume) do
      {:ok, page} -> page
      {:error, _reason} -> empty_page()
    end
  end

  @doc """
  One page of a timeline feed tab: the engine's paged thread-root view
  for the tab — `patchwork.<Feed>.roots`, newest activity first — so
  every tab pages without bound. Views: `:public`, `:private`,
  `:participating`, `:profile` (this account's roots) and `:mentions`.

  `resume` is the cursor from the previous page's marker. Returns
  `{:ok, %{rows, resume, more}}`; rows are shaped like feed rows. Returns
  `{:error, reason}` when the timeline isn't running or the engine did
  not answer in time — a page that never arrived is not an empty final
  page, and the caller has to be able to tell the two apart.
  """
  @spec feed(:public | :private | :participating | :profile | :mentions, integer() | nil) ::
          {:ok, %{rows: [map()], resume: integer() | nil, more: boolean()}}
          | {:error, :offline | :timeout}
  def feed(view, resume \\ nil)
      when view in [:public, :private, :participating, :profile, :mentions] do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :offline}

      pid ->
        try do
          {:ok, GenServer.call(pid, {:feed, view, resume}, 15_000)}
        catch
          :exit, _ -> {:error, :timeout}
        end
    end
  end

  defp empty_page, do: %{rows: [], resume: nil, more: false}

  @doc """
  One message with its full thread, for the post viewer: the root
  (unboxed through `get` when it is private) and every reply in causal
  order (`patchwork.thread.sorted`, falling back to the local window).
  `focus` is the message of that thread the key named, for the viewer
  to bring into view: an edit keys its own row, so the path can arrive
  naming a message the thread holds under another key. nil when the
  message is not in the local store.
  """
  @spec post(binary()) :: %{root: map(), replies: [map()], focus: binary() | nil} | nil
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
  Publishes a new private thread, boxed for `recipients` — the feeds a
  private message is meant to reach. Returns the new message key, or
  `{:error, reason}` when the engine is unreachable or refused.
  """
  @spec publish_private(binary(), [binary()]) :: {:ok, binary() | nil} | {:error, term()}
  def publish_private(text, recipients) when is_binary(text) do
    boxed_publish(post_content(text), recipients)
  end

  @doc """
  Stores an image in the engine's blob store and returns the SSB
  reference (`&<base64>.sha256`) a post can carry.

  The bytes travel as a muxrpc *sink* (`blobs.add`) over the same
  connection publishing uses, and the engine verifies them against that
  reference before it keeps them — so the returned ref names bytes the
  engine actually holds. The engine caps one blob at 5 MiB
  (`?BLOB_MAX_SIZE`); callers keep the upload under that.
  """
  @spec add_blob(binary()) :: {:ok, binary()} | {:error, term()}
  def add_blob(bytes) when is_binary(bytes) do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :offline}

      pid ->
        try do
          GenServer.call(pid, {:add_blob, bytes}, 30_000)
        catch
          :exit, _ -> {:error, :offline}
        end
    end
  end

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
  Publishes a reply inside a private thread.

  The body is boxed for `recipients` and published like any other
  message, so a reply to a private post never leaves the box it arrived
  in. `recipients` are feed ids — the thread's participants plus self —
  and the box format caps them at seven.
  """
  @spec reply_private(binary(), binary(), binary(), [binary()]) ::
          {:ok, binary() | nil} | {:error, term()}
  def reply_private(root, branch, text, recipients)
      when is_binary(root) and is_binary(branch) and is_binary(text) do
    boxed_publish(reply_content(root, branch, text), recipients)
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
  Likes or unlikes a message inside a private thread, boxing the vote for
  `recipients` so the like does not disclose the thread to the network.
  """
  @spec like_private(binary(), [binary()], 0 | 1) :: {:ok, binary() | nil} | {:error, term()}
  def like_private(key, recipients, value \\ 1) when is_binary(key) do
    boxed_publish(vote_content(key, value), recipients)
  end

  @doc """
  Follows (`follow/1`) or unfollows (`unfollow/1`) an identity by
  publishing a contact message; the engine's social graph turns it
  into a contacts-stateStream delta.
  """
  @spec follow(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def follow(id) when is_binary(id), do: publish_content(contact_content(id, true))

  @spec unfollow(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def unfollow(id) when is_binary(id), do: publish_content(contact_content(id, false))

  @doc """
  Blocks (`block/1`) or unblocks (`unblock/1`) an identity by publishing
  a contact message; the engine's social graph turns it into a
  contacts-stateStream delta.

  Blocking also retracts a follow in the same message: the block is the
  relationship the reader asked for, and a blocked feed has no business
  still being pulled into the timeline. Unblocking does not re-follow —
  the reader can decide that separately.
  """
  @spec block(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def block(id) when is_binary(id), do: publish_content(block_content(id, true))

  @spec unblock(binary()) :: {:ok, binary() | nil} | {:error, term()}
  def unblock(id) when is_binary(id), do: publish_content(block_content(id, false))

  @doc """
  Publish our word for a feed — the name, bio and picture the profile
  page edits. `fields` carries the `"name"`, `"description"` and/or
  `"image"` to send; an emptied field takes that name, bio or picture
  back, and the read falls to the feed's own word. The ack folds the
  message into the read model, so the alias applies as soon as the
  publish lands.
  """
  @spec about(binary(), map()) :: {:ok, binary() | nil} | {:error, term()}
  def about(id, fields) when is_binary(id) and is_map(fields) do
    publish_content(about_content(id, fields))
  end

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

  @doc false
  def block_content(id, true) do
    # One message carries both edges: the engine applies `following` and
    # `blocking` independently, so blocking is also the unfollow.
    %{"type" => "contact", "contact" => id, "following" => false, "blocking" => true}
  end

  def block_content(id, false) do
    %{"type" => "contact", "contact" => id, "blocking" => false}
  end

  @doc false
  def about_content(id, fields) when is_binary(id) and is_map(fields) do
    Map.merge(%{"type" => "about", "about" => id}, fields)
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

  # A private message is boxed here rather than by the engine: the
  # recipient list is all a box needs, and the app already holds the
  # recipients' public keys, so the message goes out through the same
  # publish chokepoint as everything else. `recps` travels inside the
  # ciphertext — it is part of the content every recipient reads back,
  # not a field the network can see.
  defp boxed_publish(content, recipients) do
    with {:ok, box} <- private_content(content, recipients) do
      publish_content(box)
    end
  end

  @doc """
  Boxes `content` for `recipients` — a pure step with no engine or
  process involved. `recps` joins the content before it is sealed, so a
  recipient can read back who the message was for; the box format caps
  the list at seven and self must be among them, which callers who want
  to read their own message back are responsible for.
  """
  @spec private_content(map(), [binary()]) :: {:ok, binary()} | {:error, term()}
  def private_content(content, recipients) when is_map(content) do
    with {:ok, recipients} <- private_recipients(recipients) do
      plaintext = content |> Map.put("recps", recipients) |> Jason.encode!()
      {:ok, PrivateBox.encrypt(plaintext, recipients)}
    end
  end

  @doc false
  @spec private_recipients([binary()]) :: {:ok, [binary()]} | {:error, term()}
  def private_recipients(recipients) do
    ids = recipients |> List.wrap() |> Enum.filter(&is_binary/1) |> Enum.uniq()

    cond do
      ids == [] ->
        {:error, :no_recipients}

      length(ids) > PrivateBox.max_recipients() ->
        Logger.warning(
          "timeline: #{length(ids)} private recipients exceeds the box's " <>
            "#{PrivateBox.max_recipients()}; keeping the first " <>
            "#{PrivateBox.max_recipients()}"
        )

        {:ok, Enum.take(ids, PrivateBox.max_recipients())}

      true ->
        {:ok, ids}
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
      blocked: [],
      self_id: nil,
      profiles: %{},
      blob_rev: 0,
      suggestions: [],
      contacts: []
    }
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    # The rail and the identity page read profiles synchronously, with
    # no process to ask, so every payload shadows into Profile's ETS
    # table first. Creating it here means the writer owns it for the
    # whole life of this process.
    _ = Profile.create()

    state = %{
      status: :connecting,
      client: nil,
      self_id: nil,
      contacts_ref: nil,
      contacts_primed?: false,
      contact_ref: nil,
      contact_buf: [],
      contact_msgs: [],
      # The store-wide contact drain folds into one row per author per
      # direction per spate. That fold is the single most expensive step
      # over the 200k+ edits the drain carries, and running it inside
      # every payload rebuilt it from scratch and held the Timeline — so
      # every mount queued behind it. Kept folded here instead: the rows
      # are computed when edits land (and only for the directions those
      # edits touched), and the payload merges the finished rows.
      collapsed_contacts: %{by_group: %{}, rows: %{}},
      about_ref: nil,
      # True while the about tail's backlog is still arriving: a name
      # taught by the snapshot republishes once, when the sentinel closes
      # it, rather than once per item.
      about_snapshot?: true,
      # The feeds the store holds an `about` message for — the rail
      # suggests nothing else. Starts empty so the filter is armed from
      # the first pass: the about drain fills it, and once it has read
      # the store at least once the candidate list is narrowed for good.
      about_ids: MapSet.new(),
      # Tombstones and edits arrive outside the per-feed windows, so they
      # get their own live store-wide tail and land in the local index the
      # render path consults. The `*_snapshot?` flag is true while the
      # stream's backlog is still arriving: those items buffer and fold
      # together when the `{sync: true}` sentinel closes them, while every
      # item after it folds on its own as it lands.
      tombstone_ref: nil,
      tombstone_buf: [],
      tombstone_snapshot?: true,
      edit_ref: nil,
      edit_buf: [],
      edit_snapshot?: true,
      drain_client: nil,
      last_drain_at: nil,
      follows: [],
      blocked: [],
      pending: %{},
      acc: [],
      messages: empty_payload(),
      blob_ls_ref: nil,
      blob_timer: nil,
      blob_rev: 0,
      network: nil,
      # Seeded from the Suggester's disk cache so the rail shows
      # last-known rows immediately; the ranking process replaces them.
      suggestions: Suggester.get_suggestions(),
      active: %{},
      gen: 0,
      network_timer: nil,
      reload_timer: nil,
      profile_fetching?: false,
      profile_wants: MapSet.new(),
      done_count: 0,
      last_net_at: nil,
      last_gossip_at: nil,
      net_dirty: false,
      peer_meta: HighWire.PeersMeta.load()
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

  def handle_call(:diagnose, _from, state) do
    {:reply, run_probes(state), state}
  end

  def handle_call(:transfer_status, _from, state) do
    {:reply, transfer_status(state, System.monotonic_time(:millisecond)), state}
  end

  def handle_call(:network, _from, state) do
    {:reply, Map.get(state, :network), state}
  end

  def handle_call(:peer_meta, _from, state) do
    {:reply, Map.get(state, :peer_meta, %{}), state}
  end

  def handle_call(:viewer, _from, state) do
    {:reply,
     %{
       status: state.status,
       self_id: state.self_id,
       follows: state.follows,
       blocked: blocked_ids(state),
       blob_rev: state.blob_rev
     }, state}
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

  def handle_call({:add_blob, bytes}, _from, state) do
    {:reply, store_blob(state, bytes), state}
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

  # A blob is no use to anyone until the engine holds it, and the engine
  # advertises what it holds: the push tells peers that ask for it that we
  # have it (erlbutt answers it outright, and falls back to wanting the
  # blob if the store somehow lost it). Its own answer decides nothing, so
  # the add's success is what this reports.
  defp store_blob(state, bytes) do
    with true <- is_pid(state.client),
         true <- Process.alive?(state.client) do
      ref = Blob.ref(bytes)

      case Client.sink(state.client, ["blobs", "add"], [ref], bytes) do
        {:ok, _true} ->
          _ = Client.call(state.client, ["blobs", "push"], [ref], 5_000)
          {:ok, ref}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :offline}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
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

    # An about is our word for its target the moment it publishes: fold
    # it into the read model here, before the finalize broadcasts, so
    # this ack's payload carries the new name and the pages read it
    # without waiting out the drain's live tail. The tail delivers the
    # same message later; the second fold writes the same slot.
    {state, _wrote?} = fold_about(%{state | acc: [envelope | state.acc]}, envelope)

    finalize(state)
  end

  defp inject_published(state, _key, _content), do: state

  @impl true
  def handle_cast({:set_activity, pid, true}, state) do
    {:noreply, put_active(state, pid)}
  end

  def handle_cast({:set_activity, pid, false}, state) do
    {:noreply, drop_active(state, pid)}
  end

  def handle_cast(:refresh_suggestions, state) do
    Suggester.refresh()
    {:noreply, schedule_suggestions_sync(state, @suggestions_sync_tries)}
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

  # The sync is a sampling loop, not a one-shot: it re-arms itself
  # while the fresh rows have not landed and it still has window left.
  defp schedule_suggestions_sync(state, tries) do
    if active?(state) do
      Process.send_after(self(), {:suggestions_sync, tries}, @suggestions_sync_ms)
    end

    state
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

  # gossip.peers is the whole report in one call. Public (with @doc
  # false) so tests can drive the assembly without a live engine.
  @doc false
  def fetch_network(client, peer_meta \\ %{}) do
    if is_pid(client) and Process.alive?(client) do
      case gossip_report(client) do
        nil ->
          merge_cache_into_report(fallback_report(client, peer_meta), peer_meta)

        net ->
          net = Map.put(net, "knownPeers", fetch_known_peers(client))
          peer_meta = update_dial_outcomes(peer_meta, net)
          merge_cache_into_report(net, peer_meta)
      end
    else
      HighWire.PeersMeta.seed_report(peer_meta)
    end
  catch
    _, _ -> HighWire.PeersMeta.seed_report(peer_meta)
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
  # the view renders what it gets. Neither RPC answering leaves a cache-
  # seeded report rather than nil: the engine being down is not the same
  # as having no peers, and the constellation should still open on the
  # peers the last working session knew. "seeded" marks it, so the view
  # can say the numbers are the cache's and not the engine's.
  defp fallback_report(client, peer_meta) do
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
      HighWire.PeersMeta.seed_report(peer_meta)
    end
  catch
    _, _ -> HighWire.PeersMeta.seed_report(peer_meta)
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

  # When the engine is live, fold cached peer hints (from other sessions)
  # into the report so recent activity elsewhere still helps understand
  # connectivity. Only address-keyed cache entries can be meaningfully
  # placed; deduplicate by address/id, preferring engine data.
  defp merge_cache_into_report(%{"knownPeers" => known} = report, peer_meta)
       when is_list(known) and is_map(peer_meta) do
    known_list = Enum.filter(known, &is_map/1)

    present =
      known_list
      |> Enum.flat_map(fn
        %{"address" => addr} when is_binary(addr) -> [addr]
        %{"id" => id} when is_binary(id) -> [id]
        _ -> []
      end)
      |> MapSet.new()

    cached =
      peer_meta
      |> Enum.filter(fn {k, v} ->
        is_binary(k) and is_map(v) and String.starts_with?(k, "net:")
      end)
      |> Enum.reduce([], fn {addr, v}, acc -> merge_cached_entry(acc, present, addr, v) end)
      |> Enum.reverse()

    merged = known_list ++ cached

    report
    |> Map.put("knownPeers", sort_known_peers(merged, report["connections"] || []))
    |> Map.put("peer_meta", peer_meta)
  end

  defp merge_cache_into_report(%{} = report, peer_meta) do
    Map.put(report, "peer_meta", peer_meta)
  end

  defp merge_cache_into_report(report, _peer_meta), do: report

  # A cache entry joins the list only when the engine's own book does
  # not already carry that address, and only when it has something to
  # say (a source or a recency stamp).
  defp merge_cached_entry(acc, present, addr, v) do
    p = build_cache_peer(addr, v)

    if MapSet.member?(present, addr) or not has_cache_fields?(p) do
      acc
    else
      [p | acc]
    end
  end

  # One-shot history pull on the shared client: open the stream, drain
  # it here (the GenServer mailbox receives it while the caller waits),
  # and return the messages. `order: "timestamp"` is the profile page's
  # chronological view — without it the engine pages by thread activity,
  # so a bumped thread jumps above more recent posts.
  defp fetch_profile(state, id, resume) do
    props = %{"id" => id, "limit" => @profile_page, "reverse" => true, "order" => "timestamp"}
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
    # Drain the page plus the marker frame that follows it; the surplus
    # row the extra read may catch is trimmed — the page stays 60 wide.
    {markers, rows} = drain_stream(ref, @profile_page) |> Enum.split_with(&(&1["marker"] == true))
    rows = Enum.take(rows, @profile_page)
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
    props = Map.merge(%{"limit" => @roots_page, "reverse" => true}, extra)
    props = if is_integer(resume), do: Map.put(props, "resume", resume), else: props
    self_id = state.self_id

    if is_pid(state.client) and Process.alive?(state.client) do
      case Client.stream(state.client, ["patchwork", feed, "roots"], [props], self()) do
        {:ok, ref} -> roots_page(ref, state, self_id, private?)
        _ -> empty_page()
      end
    else
      empty_page()
    end
  catch
    _, _ -> empty_page()
  end

  defp roots_page(ref, state, self_id, private?) do
    {markers, items} = drain_stream(ref, @roots_page) |> Enum.split_with(&(&1["marker"] == true))
    items = Enum.take(items, @roots_page)
    cursor = private_cursor(markers)

    like_counts =
      case state.messages do
        %{like_counts: counts} when is_map(counts) -> counts
        _ -> %{}
      end

    rows =
      Enum.map(items, fn item ->
        row = root_row(item, self_id, private?)
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

  # Drain a paged stream up to `page` rows, plus the marker frame the
  # engine sends with a full page. The engine honors the limit it was
  # asked for, so this is a belt on top of the request: an engine that
  # ignores it, or a stream that keeps flowing, cannot hold the Timeline —
  # the call runs inline on the GenServer, so an unbounded drain blocks
  # every mount behind it. The short timeout is the same guard for a
  # stream that goes quiet mid-page.
  defp drain_stream(ref, page, acc \\ []) do
    receive do
      {Client, ^ref, {:item, msg}} ->
        acc = [msg | acc]

        if page_full?(acc, page) do
          Enum.reverse(acc)
        else
          drain_stream(ref, page, acc)
        end

      {Client, ^ref, :done} ->
        Enum.reverse(acc)

      {Client, ^ref, {:error, _}} ->
        Enum.reverse(acc)
    after
      2_000 -> Enum.reverse(acc)
    end
  end

  # The page's rows are in, and either its marker has landed or one row
  # past the page has — the marker follows the last row, so that extra
  # read is what puts the cursor in hand. Once one of those holds the
  # drain stops, however much more the stream is offering.
  defp page_full?(acc, page) do
    rows = Enum.count(acc, &(&1["marker"] != true))

    rows > page or (rows == page and Enum.any?(acc, &(&1["marker"] == true)))
  end

  # -- post viewer ---------------------------------------------------------

  # The viewer's data: the root (a private-capable get first — the
  # window only holds the boxed form of private messages) plus every
  # reply. A URL may point at a reply whose root is elsewhere; one level
  # of `content.root` resolution lands on the thread root.
  defp fetch_post(state, key) do
    window = post_window(state)

    case fetch_msg(state, window, key) do
      nil ->
        nil

      named ->
        root = resolve_root(state, window, key, named)
        replies = post_replies(state, window, root["key"])

        %{root: root, replies: replies, focus: thread_focus(root, replies, named)}
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

  # Walk up from the message the path names to the thread's first
  # message. `named` is that message, already fetched under `key`, so
  # the walk starts without a second lookup.
  defp resolve_root(state, window, key, named) do
    resolve_thread_root(state, window, key, named, MapSet.new([key]), @thread_root_depth)
  end

  # Which message of the thread the path named, for the viewer to bring
  # into view. The path can carry a message with no place in the thread
  # as it stands — an edit keys its own row — so an edit is followed to
  # the post it revises. The root names nothing: the page opens on it
  # anyway, and so does a message nothing here holds.
  defp thread_focus(root, replies, named) do
    target = target_key(named)

    if is_binary(target) and target != root["key"] and
         Enum.any?(replies, &(&1["key"] == target)) do
      target
    end
  end

  # An edit carries the message it revises under revisionRoot, and that
  # is the message on the page — the edit itself never renders there.
  defp target_key(%{"value" => %{"content" => %{"type" => "post-edit"} = content}} = msg) do
    case content do
      %{"revisionRoot" => id} when is_binary(id) -> id
      _ -> msg["key"]
    end
  end

  defp target_key(%{"key" => key}) when is_binary(key), do: key

  defp target_key(_msg), do: nil

  # Walk up to the thread's first message: a plain reply's root IS that
  # message, but a fork's root is the parent reply, so one hop lands on
  # the middle of the thread. The seen set keeps a malformed cycle from
  # walking forever, and the depth budget keeps an acyclic chain from
  # doing it either — each step can be a remote `get`, so an unbounded
  # chain is an unbounded fan-out of remote calls on every open.
  defp resolve_thread_root(state, window, key, msg, seen, depth) do
    root = content(msg)["root"]

    if depth > 0 and is_binary(root) and root != key and not MapSet.member?(seen, root) do
      case fetch_msg(state, window, root) do
        nil ->
          msg

        parent ->
          resolve_thread_root(state, window, root, parent, MapSet.put(seen, root), depth - 1)
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
      Client.call(client, ["get"], [%{"id" => key, "private" => true}], 5_000)
      |> get_value(key)
    else
      nil
    end
  catch
    _, _ -> nil
  end

  # A missing message comes back as {:ok, %{"message" => "message not
  # found", "name" => "Error", "stack" => "_"}} — an error map, not a
  # message. Accepting it made fetch_msg/2 stop at a ghost for every key
  # and never fall back to the window, so resolve_root could not walk up
  # to the thread root and a midlevel URL rendered only its own children
  # instead of the full thread. Only a real message value counts.
  defp get_value({:ok, value}, key) when is_map(value) do
    if message_value?(value) do
      %{"key" => key, "value" => value, "timestamp" => value["timestamp"] || 0}
    end
  end

  defp get_value(_reply, _key), do: nil

  defp message_value?(value),
    do: is_binary(value["author"]) or is_map(value["content"])

  # The engine's thread.sorted is what this falls back to, so it holds
  # to what holds there: a reply is a post. An edit keys its own row
  # over the post it revises — it changed that post, it is not another
  # message in the thread.
  defp window_replies(window, root_key) do
    window
    |> Enum.filter(fn m ->
      m["key"] != root_key and post?(m) and content(m)["root"] == root_key
    end)
    |> Enum.sort_by(fn m -> m["value"]["timestamp"] || 0 end)
  end

  # Live health probes for /diagnostics. Each engine view the timeline
  # depends on gets one check: a bounded call against the shared client,
  # scored :ok / :warn / :fail with a human note. Kept deliberately cheap
  # (small limits, short timeouts) so a click on the page never stalls.
  defp run_probes(state) do
    client = state.client
    alive? = is_pid(client) and Process.alive?(client)
    per = Keyword.get(Sidecar.config(), :messages_per_feed, 10)

    # The history probe also samples the first item's key: the get probe
    # fetches that real message, because `get` is a message-key API —
    # asking it for a feed id returns "message not found" on a perfectly
    # healthy engine, which is the false alarm this avoids.
    {stream_probe, sample_key} = stream_count_probe(alive?, client, state.self_id, per)

    %{
      sidecar: Sidecar.status(),
      window: window_summary(state, per),
      probes: [
        stream_probe,
        get_shape_probe(alive?, client, sample_key),
        roots_count_probe(alive?, client, :publicFeed, %{}, false),
        roots_count_probe(alive?, client, :participatingFeed, %{}, false)
      ]
    }
  end

  # createHistoryStream — the per-feed window the whole timeline rests on.
  # Zero items on the account's own feed means nothing is reaching us.
  # Returns {probe, sample_key}.
  defp stream_count_probe(false, _client, _self_id, _per),
    do: {probe(:createHistoryStream, :fail, "no engine client"), nil}

  defp stream_count_probe(true, client, self_id, per) when is_binary(self_id) do
    case count_stream(client, ["createHistoryStream"], [%{"id" => self_id, "limit" => per}]) do
      {:ok, {0, _key}} ->
        {probe(:createHistoryStream, :fail, "0 items on own feed"), nil}

      {:ok, {n, key}} ->
        {probe(:createHistoryStream, :ok, "#{n} items on own feed"), key}

      {:error, reason} ->
        {probe(:createHistoryStream, :fail, error_note(reason)), nil}
    end
  end

  defp stream_count_probe(true, _client, nil, _per),
    do: {probe(:createHistoryStream, :warn, "no self id yet"), nil}

  # get — the unbox path, asked of a real message sampled from the own
  # feed. The engine's error-map leak (%{"name" => "Error", …}) is the
  # regression the client now rejects, so this check confirms the fix
  # holds end to end.
  defp get_shape_probe(false, _client, _key),
    do: probe(:get, :fail, "no engine client")

  defp get_shape_probe(true, _client, nil),
    do: probe(:get, :warn, "no own message to fetch yet")

  defp get_shape_probe(true, client, key) do
    case Client.call(client, ["get"], [%{"id" => key, "private" => true}], 5_000) do
      {:ok, %{"author" => _}} ->
        probe(:get, :ok, "returns a real message")

      {:ok, %{"name" => "Error"} = err} ->
        probe(:get, :warn, "engine leaked an error map: #{err["message"]}")

      {:ok, _other} ->
        probe(:get, :warn, "unexpected get shape")

      {:error, reason} ->
        probe(:get, :fail, error_note(reason))
    end
  catch
    _, reason -> probe(:get, :fail, error_note(reason))
  end

  # patchwork.<Feed>.roots — the paged tabs. Zero rows while the engine is
  # up usually means the view index is broken, not that the feed is empty.
  defp roots_count_probe(false, _client, _feed, _extra, _private?),
    do: probe(:feed, :fail, "no engine client")

  defp roots_count_probe(true, client, feed, extra, private?) when is_atom(feed) do
    props = Map.merge(%{"limit" => 1, "reverse" => true}, extra)
    view = ["patchwork", Atom.to_string(feed), "roots"]

    case count_stream(client, view, [props], private?) do
      {:ok, {n, _key}} when n > 0 -> probe(feed, :ok, "#{n} roots")
      {:ok, {0, _key}} -> probe(feed, :fail, "0 roots")
      {:error, reason} -> probe(feed, :fail, error_note(reason))
    end
  end

  # Drain a source stream, counting items and remembering the first
  # item's key until :done / error / timeout.
  defp count_stream(client, name, args, private? \\ false) do
    case Client.stream(client, name, args, self()) do
      {:ok, ref} -> {:ok, drain_count(ref, 0, nil, private?)}
      {:error, reason} -> {:error, reason}
    end
  catch
    _, reason -> {:error, reason}
  end

  defp drain_count(ref, n, key, private?) do
    receive do
      {Client, ^ref, {:item, %{"sync" => true}}} -> {n, key}
      {Client, ^ref, {:item, item}} -> drain_count(ref, n + 1, key || item_key(item), private?)
      {Client, ^ref, :done} -> {n, key}
      {Client, ^ref, {:error, _}} -> {n, key}
    after
      8_000 -> {n, key}
    end
  end

  defp item_key(%{"key" => key}) when is_binary(key), do: key
  defp item_key(_item), do: nil

  # The engine's errors ride as maps carrying message/name/stack; only
  # the message is worth a health page.
  defp error_note(%{"message" => message}) when is_binary(message), do: "error: #{message}"
  defp error_note(reason), do: "error: #{inspect(reason)}"

  defp window_summary(state, per) do
    %{
      per_feed: per,
      follows: length(state.follows),
      acc: length(state.acc),
      messages: length(state.messages.messages)
    }
  end

  defp probe(name, level, note), do: %{name: name, level: level, note: note}

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

        # The posting identity's own profile: window authors resolve
        # through finalize, but a just-switched-to identity with
        # nothing in the window never would — ask for it by id.
        _ = ensure_profiles([id])

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
  # merge. true is a follow, false is a block and null is neither — the
  # engine's legacy friend terms, where block wins over follow. A delta
  # means a follow changed, so reload to re-broadcast the payload
  # promptly.
  def handle_info({Client, ref, {:item, graph}}, %{contacts_ref: ref} = state)
      when is_map(graph) do
    first? = not state.contacts_primed?

    follows0 = if first?, do: [], else: state.follows
    blocked0 = if first?, do: [], else: blocked_ids(state)
    {others, blocked} = merge_contacts(graph, follows0, blocked0)

    # Your own feed is not in the contacts graph — pin it so your own
    # published messages always show up in the timeline. (It cannot be
    # blocked, either: a block of yourself is not a relationship.)
    follows = if is_binary(state.self_id), do: Enum.uniq([state.self_id | others]), else: others

    blocked = blocked |> Enum.uniq() |> Enum.reject(&(&1 == state.self_id))
    state = %{state | follows: follows, blocked: blocked, contacts_primed?: true}

    # A changed follow list is a new ranking input (and the moment that
    # matters most: following a suggested feed should regenerate the
    # list). Hand it off-process only once the contact graph is loaded —
    # before that there is nothing to rank against.
    if state.contact_msgs != [] do
      Suggester.cast_inputs(
        state.contact_msgs,
        state.follows,
        state.self_id,
        state.about_ids,
        state.blocked
      )
    end

    # The rail's contacts are drawn by HighWire.Contacts, which re-draws
    # only when this list actually moves — so feed it the candidates.
    Contacts.cast_contacts(Enum.reject(follows, &(&1 == state.self_id)))

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
  # causes one re-render). The activity/transfer broadcast rides the same
  # debounce: firing it per item flooded every subscribed LiveView with a
  # message per blob, and each one forced a full feed re-render, so a
  # store replay left the window thousands of renders behind.
  def handle_info({Client, ref, {:item, _id}}, %{blob_ls_ref: ref} = state) do
    if state.blob_timer, do: Process.cancel_timer(state.blob_timer)
    now = System.monotonic_time(:millisecond)
    blob_timer = Process.send_after(self(), :rebroadcast, 500)

    {:noreply, %{state | blob_timer: blob_timer, last_net_at: now}}
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
    # The connection is torn down with the contact pass — the about
    # pass rode the same one, so its ref dangles too.
    state = stop_drain_client(%{state | contact_ref: nil, contact_buf: [], about_ref: nil})
    {:noreply, state}
  end

  # messagesByType("about"): which feeds the store can speak for — the
  # Suggester's rail filter — and the names and bios the profile page
  # shows. Opened as a live tail like the tombstone/edit drains, so a
  # name published after the pass lands without waiting for a cycle.
  # No cursor, unlike those drains: the read model lives only as long as
  # this process, so every boot must walk the store once to refill it.
  # Only the feed's own word for itself, or ours about them, is written:
  # anyone can publish an about naming someone, and a third party's name
  # for a target is not what that target goes by.
  def handle_info({Client, ref, {:item, msg}}, %{about_ref: ref} = state) do
    if MessageIndex.sentinel?(msg) do
      about_drained(%{state | about_snapshot?: false})
    else
      {state, wrote?} = fold_about(state, msg)

      state =
        if wrote? and not state.about_snapshot? do
          refresh_names(state)
        else
          state
        end

      {:noreply, state}
    end
  end

  def handle_info({Client, ref, :done}, %{about_ref: ref} = state) do
    # :done is the completeness mark — a pass with zero items means the
    # store holds no abouts at all, which the nil "not read yet" state
    # cannot express. A live tail closed by the peer is reopened by the
    # heartbeat; whatever arrived on a failed pass stays, since every id
    # and every trusted field seen is a fact.
    about_drained(%{
      state
      | about_ref: nil,
        about_snapshot?: true,
        about_ids: state.about_ids || MapSet.new()
    })
  end

  def handle_info({Client, ref, {:error, reason}}, %{about_ref: ref} = state) do
    Logger.debug("timeline: about stream failed: #{inspect(reason)}")
    {:noreply, refresh_names(%{state | about_ref: nil, about_snapshot?: true})}
  end

  # messagesByType("delete"): the store-wide tombstone stream. A delete
  # is its author asking readers to drop a message, and it never rides
  # the per-feed windows the timeline renders from, so without it a
  # tombstone is invisible. Opened live and kept open: the snapshot
  # carries only what arrived since the index's last cursor, and the tail
  # pushes each new tombstone as it lands.
  def handle_info({Client, ref, {:item, msg}}, %{tombstone_ref: ref} = state) do
    cond do
      MessageIndex.sentinel?(msg) ->
        tombstone_drained(%{state | tombstone_snapshot?: false})

      state.tombstone_snapshot? ->
        {:noreply, %{state | tombstone_buf: [msg | state.tombstone_buf]}}

      true ->
        tombstone_drained(%{state | tombstone_buf: [msg]})
    end
  end

  # A live source has no end of its own (the sentinel closed the backlog
  # already); this is the finite fallback (no owning peer) and a dropped
  # backlog, both of which mean the buffered pass is complete. The live
  # tails reconnect on their own after an error.
  def handle_info({Client, ref, :done}, %{tombstone_ref: ref} = state) do
    tombstone_drained(%{state | tombstone_ref: nil})
  end

  def handle_info({Client, ref, {:error, reason}}, %{tombstone_ref: ref} = state) do
    Logger.debug("timeline: tombstone stream failed: #{inspect(reason)}")
    {:noreply, %{state | tombstone_ref: nil, tombstone_snapshot?: true}}
  end

  # messagesByType("post-edit"): the store-wide edit stream, so an edit
  # of a post that has aged out of the window still threads where it
  # belongs. Same live shape as the tombstone stream.
  def handle_info({Client, ref, {:item, msg}}, %{edit_ref: ref} = state) do
    cond do
      MessageIndex.sentinel?(msg) ->
        edit_drained(%{state | edit_snapshot?: false})

      state.edit_snapshot? ->
        {:noreply, %{state | edit_buf: [msg | state.edit_buf]}}

      true ->
        edit_drained(%{state | edit_buf: [msg]})
    end
  end

  def handle_info({Client, ref, :done}, %{edit_ref: ref} = state) do
    edit_drained(%{state | edit_ref: nil})
  end

  def handle_info({Client, ref, {:error, reason}}, %{edit_ref: ref} = state) do
    Logger.debug("timeline: edit stream failed: #{inspect(reason)}")
    {:noreply, %{state | edit_ref: nil, edit_snapshot?: true}}
  end

  def handle_info(:rebroadcast, state) do
    # One activity broadcast per debounce window, alongside the revision
    # bump — not one per blob (see the blobs.ls tail above).
    state = note_net_activity(state, System.monotonic_time(:millisecond))
    rev = state.blob_rev + 1
    payload = %{state.messages | blob_rev: rev}
    broadcast_updated(payload)
    {:noreply, %{state | messages: payload, blob_rev: rev, blob_timer: nil}}
  end

  # gossip.peers refresh for the /network dashboard — a cheap local
  # sync RPC — and a read-back of the "Whom to follow" rows, which
  # HighWire.Suggester ranks off-process from the contact drain
  # (Suggest.rank/5; the engine has no whoToFollow RPC). The dashboard
  # stays hidden on engines predating its RPC (the call answers `true`,
  # which the branch does not accept).
  def handle_info({:network, gen}, %{gen: current} = state) when gen == current do
    state = %{state | network_timer: nil}
    old_net = Map.get(state, :network)
    previous = connections_of(old_net)
    now = System.monotonic_time(:millisecond)
    new_net = fetch_network(Map.get(state, :client), Map.get(state, :peer_meta, %{}))
    state = Map.put(state, :network, new_net)
    connections = connections_of(state.network)

    # A peer joined or left — the rail badge's flare rides this event.
    # The poll itself is not activity: bumping last_net_at every 11s
    # would turn transfer_status's 2.5s window into a heartbeat that
    # fires whether or not anything moved.
    state =
      if connections != previous do
        broadcast_gossip(%{connected: length(connections)})
        note_net_activity(state, now, gossip: true)
      else
        state
      end

    # Update peer meta with recency
    state = update_peer_recency(state, old_net, new_net)

    # Suggestion rows are ranked off-process (HighWire.Suggester) and
    # read back here; the rail only needs them when they actually move,
    # so a fresh read that differs from the last payload rebroadcasts.
    # The rail's contacts are drawn just as asynchronously
    # (HighWire.Contacts), and a payload built before the draw lands
    # would otherwise wait for a finalize that may never come.
    old = Map.get(state, :suggestions, [])
    fresh = suggestions(state)
    old_contacts = Map.get(state.messages, :contacts, [])
    fresh_contacts = Contacts.get_contacts()
    moved? = fresh != old or fresh_contacts != old_contacts

    state =
      if moved? and state.status == :ok do
        payload =
          state.messages
          |> Map.put(:suggestions, fresh)
          |> Map.put(:contacts, fresh_contacts)

        broadcast_updated(payload)
        %{state | suggestions: fresh, messages: payload}
      else
        %{state | suggestions: fresh}
      end

    {:noreply, schedule_network(state, 11_003)}
  end

  def handle_info({:network, _stale}, state), do: {:noreply, state}

  # The rail refresh's short sync: same compare-and-rebroadcast as the
  # network poll's suggestion read, polled briefly until the fresh rows
  # land (or the window closes and the poll takes over).
  def handle_info({:suggestions_sync, tries}, state) do
    fresh = suggestions(state)

    cond do
      fresh != Map.get(state, :suggestions, []) and state.status == :ok ->
        payload = Map.put(state.messages, :suggestions, fresh)
        broadcast_updated(payload)
        {:noreply, %{state | suggestions: fresh, messages: payload}}

      tries > 0 ->
        {:noreply, schedule_suggestions_sync(state, tries - 1)}

      true ->
        {:noreply, state}
    end
  end

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
  # refs (both passes ride it) so the next reload can re-dial instead
  # of blocking either drain.
  def handle_info({:EXIT, pid, _reason}, %{drain_client: pid} = state) do
    {:noreply, %{state | drain_client: nil, contact_ref: nil, contact_buf: [], about_ref: nil}}
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
      profiles =
        state.messages.profiles
        |> Map.merge(fetched)
        |> Profile.with_names()

      payload = %{state.messages | profiles: profiles}
      broadcast_updated(payload)
      {:noreply, %{state | messages: payload}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Fold one contacts item into the follow/block lists. The first item is
  # the whole graph (caller passes empty lists); later items are
  # single-edge deltas. Following and blocking are independent edges
  # between the same pair, so each keeps its own list: a block must not
  # read as a follow, and unblocking must not mint one.
  defp merge_contacts(graph, follows, blocked) do
    Enum.reduce(graph, {follows, blocked}, fn
      {id, true}, {f, b} when is_binary(id) -> {[id | f], List.delete(b, id)}
      {id, false}, {f, b} when is_binary(id) -> {List.delete(f, id), [id | b]}
      {id, _neither}, {f, b} when is_binary(id) -> {List.delete(f, id), List.delete(b, id)}
      _other, acc -> acc
    end)
  end

  # The rail's "Whom to follow" rows, with the feeds this account blocks
  # taken out. The ranking drops blocked feeds before it cuts its pool
  # (Suggest.candidates/5), so fresh rows never contain one; this edge
  # filter is what covers the rows loaded from the disk cache at startup,
  # which were ranked before the current block list was known. It also
  # keeps a block applied immediately — a refresh cannot offer back the
  # feed the reader just blocked, even if a re-rank has not run yet.
  defp suggestions(state), do: reject_blocked(Suggester.get_suggestions(), blocked_ids(state))

  defp reject_blocked(rows, blocked), do: Enum.reject(rows, &(&1["id"] in blocked))

  defp blocked_ids(state), do: Map.get(state, :blocked, [])

  defp connections_of(%{"connections" => connections}) when is_list(connections), do: connections
  defp connections_of(_), do: []

  defp broadcast_gossip(payload) do
    Phoenix.PubSub.broadcast(HighWire.PubSub, @gossip, {__MODULE__, :gossip, payload})
  end

  # -- transfer activity ------------------------------------------------

  # A blob landed or the peer set moved: bump the window and push the
  # new status on the timeline topic, so the header's indicator lights
  # without anyone having to ask for it first.
  defp note_net_activity(state, now, opts \\ []) do
    state = %{state | last_net_at: now}
    state = if Keyword.get(opts, :gossip), do: %{state | last_gossip_at: now}, else: state

    Phoenix.PubSub.broadcast(
      HighWire.PubSub,
      @topic,
      {__MODULE__, :transfer, transfer_status(state, System.monotonic_time(:millisecond))}
    )

    state
  end

  # The one way the feed payload goes out: shadow what pages read
  # synchronously — the rail is a function component with no process to
  # ask, and the identity page wants its own feeds' names whether or
  # not they still hold a window seat — *before* telling anyone to
  # look, so a subscriber's render reads a table already current.
  defp broadcast_updated(payload) do
    Profile.put_all(payload.profiles)
    Profile.put_rev(payload.blob_rev)
    Phoenix.PubSub.broadcast(HighWire.PubSub, @topic, {__MODULE__, :updated, payload})
  end

  # How recently the engine reported network activity. The window is what
  # the header's indicator rides, so the polled answer and the broadcast
  # that turns the indicator on read it from the same place.
  defp transfer_status(state, now) do
    active? =
      case state.last_net_at do
        nil -> false
        t -> now - t < 2500
      end

    %{last_net_at: state.last_net_at, last_gossip_at: state.last_gossip_at, active?: active?}
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
    state =
      if state.contact_ref == nil and drain_due?(state) do
        open_drain(state)
      else
        state
      end

    # The about pass rides the same cycle but keeps its own slot: a
    # stalled or failed pass must never hold up the contact drain, and
    # the contact drain must never hold one up either. It is a live tail,
    # so once open it needs no re-walk; a `nil` ref means one is not open
    # yet (boot, or a drop to reconnect).
    state =
      if state.about_ref == nil do
        open_about_drain(state)
      else
        state
      end

    # Tombstones and edits are live tails, opened once and kept open:
    # the snapshot carries only what arrived since the index's cursor,
    # so there is nothing to re-walk on a heartbeat. A `nil` ref means
    # one is not open yet (boot, or a drop to reconnect).
    state =
      if state.tombstone_ref == nil do
        open_tombstone_drain(state)
      else
        state
      end

    if state.edit_ref == nil do
      open_edit_drain(state)
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

  # messagesByType("about"): the rail's feed filter and the names/bios the
  # read model owns. Same dedicated connection as the contact pass, but a
  # live tail: the whole store is walked once per boot (the read model does
  # not outlive this process, so there is no cursor to resume from) and
  # then every new about arrives as it lands.
  defp open_about_drain(state) do
    {client, state} = drain_endpoint(state)
    args = live_by_type("about", nil)

    with true <- is_pid(client),
         {:ok, ref} <- Client.stream(client, ["messagesByType"], args, self()) do
      %{state | about_ref: ref, about_snapshot?: true}
    else
      _ -> state
    end
  catch
    _, _ -> state
  end

  # messagesByType("delete"): the honoured tombstones. Opened as a live
  # tail — the snapshot is bounded by the index's cursor, so a restart
  # carries only what arrived while the timeline was not running, and
  # the tail then pushes each new tombstone as it lands.
  defp open_tombstone_drain(state) do
    {client, state} = drain_endpoint(state)
    args = live_by_type("delete", MessageIndex.cursor("delete"))

    with true <- is_pid(client),
         {:ok, ref} <- Client.stream(client, ["messagesByType"], args, self()) do
      %{state | tombstone_ref: ref, tombstone_buf: [], tombstone_snapshot?: true}
    else
      _ -> state
    end
  catch
    _, _ -> state
  end

  # messagesByType("post-edit"): the store-wide edits. Same live shape;
  # an edit's target may long since have left the window.
  defp open_edit_drain(state) do
    {client, state} = drain_endpoint(state)
    args = live_by_type("post-edit", MessageIndex.cursor("post-edit"))

    with true <- is_pid(client),
         {:ok, ref} <- Client.stream(client, ["messagesByType"], args, self()) do
      %{state | edit_ref: ref, edit_buf: [], edit_snapshot?: true}
    else
      _ -> state
    end
  catch
    _, _ -> state
  end

  # A live type stream: keep the tail open so later items arrive without
  # a re-open, and bound the snapshot to `gt` when there is a cursor.
  # With no cursor the first pass carries the whole backlog — the one
  # time the store is walked — and every pass after it carries only what
  # arrived since. `old` stays true so a restart still catches up on the
  # window it missed; the cursor is what keeps that catch-up small.
  defp live_by_type(type, cursor) do
    base = %{"type" => type, "live" => true, "old" => true}
    [if(cursor, do: Map.put(base, "gt", cursor), else: base)]
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

    # The 13s heartbeat re-fetches the window and lands here every time.
    # A rebuild that produced the same payload as the last one is not
    # news: skip the broadcast and the profile writes, so a quiet feed
    # stays quiet. The comparison is structural — the same window, the
    # same store facts, the same rows.
    state =
      if payload == state.messages do
        state
      else
        broadcast_updated(payload)
        %{state | messages: payload}
      end

    state = %{state | status: :ok, pending: %{}, done_count: 0}
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
        collapsed_contacts: fold_contacts(state.collapsed_contacts, fresh),
        last_drain_at: System.monotonic_time(:millisecond)
    }

    # A refilled store-wide contact graph is a new ranking input. Hand it
    # to the Suggester off-process; Timeline never ranks inline.
    if state.contact_msgs != [] do
      Suggester.cast_inputs(
        state.contact_msgs,
        state.follows,
        state.self_id,
        state.about_ids,
        state.blocked
      )
    end

    if fresh != [] and state.status == :ok and map_size(state.pending) == 0 do
      {:noreply, finalize(state)}
    else
      {:noreply, state}
    end
  end

  # The about pass completed — a tighter rail filter is a new ranking
  # input. Entries only grow, like Profile's read model and the contact
  # list: one pass answers until the next cycle's, and a feed whose
  # about arrives later joins the set on the pass that sees it.
  defp about_drained(state) do
    if state.contact_msgs != [] do
      Suggester.cast_inputs(
        state.contact_msgs,
        state.follows,
        state.self_id,
        state.about_ids,
        state.blocked
      )
    end

    {:noreply, refresh_names(state)}
  end

  # Fold one about into the rail's id set and, when its author is the
  # feed itself or us, its name, bio and picture into the read model —
  # the feed's word and ours into their separate slots, so ours stands
  # over the feed's later words. Returns whether display fields were
  # written, so a live tail can republish just when something changed.
  defp fold_about(state, msg) do
    case about_fields(msg) do
      nil ->
        {state, false}

      {id, author, fields} ->
        state = %{state | about_ids: MapSet.put(state.about_ids || MapSet.new(), id)}

        source = about_source(author, id, state.self_id)

        if source != nil and map_size(fields) > 0 do
          Profile.put_about(id, fields, source)
          {state, true}
        else
          {state, false}
        end
    end
  end

  # Names are applied to the payload from the read model when it is built,
  # and the about stream can teach the model a name the current payload
  # does not carry. Republish it (nothing else moves) so the rail, rows
  # and composer catch up without waiting for unrelated traffic.
  defp refresh_names(%{status: :ok, messages: %{profiles: profiles, blob_rev: _}} = state)
       when is_map(profiles) do
    named = Profile.with_names(profiles)

    if named == profiles do
      state
    else
      payload = %{state.messages | profiles: named}
      broadcast_updated(payload)
      %{state | messages: payload}
    end
  end

  defp refresh_names(state), do: state

  # A tombstone pass — the snapshot's close sentinel or the finite
  # fallback's `:done`. Each delete names the message it asks readers to
  # drop; the index keeps that key with the deleter's id, and the render
  # path honours it only when the deleter is the author. A completed pass
  # re-renders, so a message that just became tombstoned leaves the feed
  # without waiting for the next cycle. The ref is not cleared: the live
  # tail stays open, and later items fold through this same path.
  defp tombstone_drained(state) do
    entries = state.tombstone_buf |> Enum.flat_map(&List.wrap(MessageIndex.tombstone(&1)))
    if entries != [], do: MessageIndex.record_deletes(entries)
    advance_cursor("delete", state.tombstone_buf)

    state = %{state | tombstone_buf: []}

    if entries != [] and state.status == :ok and map_size(state.pending) == 0 do
      {:noreply, finalize(state)}
    else
      {:noreply, state}
    end
  end

  # An edit pass — the snapshot's close sentinel or the finite fallback's
  # `:done`. Each edit names the post it revises; the index keeps the
  # target's thread root so an edit threads under a post that has aged out
  # of the window. Roots resolve against the window in hand — the target's
  # own root pointer when it is here, the target itself when it heads its
  # own conversation, and the index's last answer when the target is not
  # in view at all. The ref is not cleared: the live tail stays open.
  defp edit_drained(state) do
    by_key = Map.new(state.acc, fn msg -> {msg["key"], msg} end)

    entries =
      for msg <- state.edit_buf, {edit_key, target} <- List.wrap(MessageIndex.edit(msg)) do
        {edit_key, target, edit_root(target, by_key) || MessageIndex.edit_thread_root(target)}
      end

    if entries != [], do: MessageIndex.record_edits(entries)
    advance_cursor("post-edit", state.edit_buf)

    state = %{state | edit_buf: []}

    if entries != [] and state.status == :ok and map_size(state.pending) == 0 do
      {:noreply, finalize(state)}
    else
      {:noreply, state}
    end
  end

  # The cursor is the highest received time among the items just folded —
  # the envelope's top-level `timestamp`, the same field the engine's `gt`
  # compares against. An item with no usable time leaves the cursor alone.
  defp advance_cursor(_type, []), do: :ok

  defp advance_cursor(type, msgs) do
    case msgs |> Enum.map(&received_ts/1) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end) do
      nil -> :ok
      ts -> MessageIndex.advance_cursor(type, ts)
    end
  end

  defp received_ts(%{"timestamp" => ts}) when is_integer(ts), do: ts
  defp received_ts(_), do: nil

  defp edit_root(target, by_key) do
    case Map.get(by_key, target) do
      nil -> nil
      parent -> thread_root(parent, by_key) || target
    end
  end

  # The feed an about message speaks for: the `about` field when it
  # names a feed. The target is what counts — the store can name a feed
  # when something says about *it*; a feed whose abouts only speak for
  # others still renders as a bare id.
  # The display fields an about message carries for its target: the name
  # and the bio, the picture, and the author who wrote them. A name is
  # only the feed's own word for itself, or ours about them — anyone can
  # publish an about naming someone, and a third party's "documentary"
  # for a target is not what that target goes by. An about carrying
  # none of the three is still a fact about the id (the store can speak
  # for it) but nothing to write.
  defp about_fields(msg) do
    case content(msg) do
      %{"type" => "about", "about" => <<"@", _::binary>> = about} ->
        {about, author_id(msg), Map.take(content(msg), ["name", "description", "image"])}

      _ ->
        nil
    end
  end

  defp author_id(msg) do
    case msg do
      %{"value" => %{"author" => author}} when is_binary(author) -> author
      _ -> nil
    end
  end

  # Whose word an about carries: the feed's own when author and target
  # are one, ours when the author is the identity using this store —
  # and nothing at all from anyone else. Anyone can publish an about
  # naming another feed, so a third party's name is not what that
  # target wears; ours is ours, kept in its own slot so it holds over
  # the feed's later names and can be taken back.
  defp about_source(author, target, self_id) do
    cond do
      is_binary(author) and author == target -> :own
      is_binary(author) and author == self_id -> :ours
      true -> nil
    end
  end

  # First-paint snapshot: same payload, nothing cleared — feeds are
  # still streaming and the final pass rebuilds it wholesale.
  defp broadcast_preliminary(state) do
    {payload, _missing, _base, _refs} = build_payload(state)

    broadcast_updated(payload)

    %{state | status: :ok, messages: payload}
  end

  defp build_payload(state) do
    # The window (acc) plus the store-wide contact drain: follow events
    # are rare and old, so they routinely sit outside the per-feed window
    # and would otherwise age out of every payload. The drain arrives as
    # one edit per relationship, so only the spate anchors — the edits the
    # rows actually render — merge in; the folded rows carry the rest.
    contacts = state.collapsed_contacts.rows |> Map.values() |> List.flatten()
    anchors = Enum.map(contacts, & &1.anchor)
    acc = Enum.uniq_by(state.acc ++ anchors, & &1["key"])

    reply_counts = reply_counts(acc)
    likes = likes_state(acc)
    like_counts = like_counts(likes)

    # Flat list (order-of-arrival view). The LiveView's search reads only
    # author, text, type/root and key (for rootless posts), so each message
    # is projected down to those before it leaves the payload — the full
    # value/signature/hash bloat was pure bytes on first paint. Same
    # newest-first ordering, same generous cap for infinite scroll.
    messages =
      acc
      |> Enum.sort_by(&bump_ts/1, :desc)
      |> Enum.take(2000)
      |> Enum.map(&search_projection/1)

    feed = build_feed(acc, state.self_id, like_counts, contacts)

    # key → author, but only for the keys the rows about to go out can
    # ask about: each row's own message, its previewed replies, and the
    # targets its sentences name (`about`, `link`, `revisionRoot` and
    # friends). Building it over the whole pass instead shipped a
    # store-sized map — 228k entries and ~90% of the payload — to every
    # view on every mount and reload, to answer lookups the window never
    # makes. The map is now bounded by what is on screen.
    index = author_index(acc, feed, messages)

    # Suggestion rows need names/avatars too, or the sidebar shows bare
    # short ids for strangers — profile fetch covers them on top of the
    # usual participants + follows.
    suggestions = state |> Map.get(:suggestions, []) |> reject_blocked(blocked_ids(state))
    sugg_ids = for s <- suggestions, is_binary(s["id"]), do: s["id"]

    # Parked ensure_profiles ids ride along, so every finalize also
    # retries whatever the window never asked for and the fetch missed.
    wants = state |> Map.get(:profile_wants, MapSet.new()) |> MapSet.to_list()

    ids = Enum.uniq(profile_ids(feed, state.follows) ++ sugg_ids ++ wants)
    known = Map.get(state.messages, :profiles, %{})
    missing = Enum.reject(ids, &Map.has_key?(known, &1))
    # The engine's name for a feed may be someone else's label for it; the
    # payload carries images, and the read model supplies the names.
    base = known |> Map.take(ids) |> Profile.with_names()
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
      blocked: blocked_ids(state),
      self_id: state.self_id,
      profiles: base,
      blob_rev: state.blob_rev,
      suggestions: suggestions,
      contacts: Contacts.get_contacts()
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
    |> Enum.map(fn msg -> content(msg)["text"] end)
    |> Enum.filter(&is_binary/1)
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
  # rootless posts are their own rows; contact messages collapse into one
  # row per author per direction per spate listing who they touched.
  @doc false
  def build_feed(acc, self_id, like_counts) do
    build_feed(acc, self_id, like_counts, nil)
  end

  defp build_feed(acc, self_id, like_counts, contact_entries) do
    # Every row builder below names a message by its value map
    # (value["author"], value["content"], …), so a record whose envelope
    # carries no value map — a corrupt one — would crash the timeline
    # process, and because the supervisor restarts it into the same
    # store window, crash it again on the next reload. Drop those once,
    # here, rather than guarding each reader; a message with nothing in
    # its value has nothing to render anyway.
    acc = Enum.filter(acc, &value_of/1)
    acc = Enum.map(acc, &sanitize_text/1)

    # A caller that already folded the store-wide contact drain (the
    # payload path) hands the finished rows in; the raw path folds them
    # here, once, off the sanitized window.
    contact_entries =
      case contact_entries do
        nil -> collapse_contacts(acc) |> Map.values() |> List.flatten()
        entries -> entries
      end

    # Boxed (encrypted) messages never form public rows — the Private tab
    # shows them decrypted, straight from privateFeed.
    acc = Enum.reject(acc, &boxed?/1)

    # A message its own author has tombstoned is gone: it leaves the feed
    # the same way a boxed message never joins it. The index holds the
    # deleter's id, so a delete from anyone else is ignored here.
    acc = Enum.reject(acc, &tombstoned?/1)

    by_key = Map.new(acc, fn msg -> {msg["key"], msg} end)
    # An edit revises the post named by revisionRoot/revisionBranch/root.
    # It threads under that post instead of standing alone, so the row it
    # lands on carries the newest text rather than a bare "edited a post"
    # line pointing nowhere. `edited_by` records the revisions of the
    # row's head; a reply's revisions belong to the reply itself.
    edit_index = edit_index(acc)
    {_contacts, rest} = Enum.split_with(acc, &contact?/1)

    {threaded, standalone} =
      Enum.split_with(rest, fn msg ->
        thread_root(msg, by_key) != nil or edit_thread(msg, by_key, edit_index) != nil
      end)

    thread_entries =
      threaded
      |> Enum.group_by(fn msg ->
        thread_root(msg, by_key) || edit_thread(msg, by_key, edit_index)
      end)
      |> Enum.map(fn {root_key, group} ->
        build_thread_entry(root_key, group, by_key, like_counts, self_id)
      end)

    contact_entries = Enum.map(contact_entries, &contact_row(&1, self_id))

    other_entries =
      standalone
      |> Enum.reject(&vote?/1)
      |> Enum.map(fn msg ->
        kind = if post?(msg), do: :post, else: :other

        build_entry(
          kind,
          msg,
          bump_ts(msg),
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

  # One row per thread: the head's newest text, the reply rollup, the
  # likes, a preview of the most recent replies, and the activity that
  # positions the row. `edited_by` names the head's own revisers — the
  # note beside the row marks the text the reader sees as a revision.
  defp build_thread_entry(root_key, group, by_key, like_counts, self_id) do
    root_msg = Map.get(by_key, root_key)

    sorted = Enum.sort_by(group, &bump_ts/1, :desc)

    # The revisions the group absorbed, newest first under the post
    # each revises. A revision belongs to its post, not to the thread
    # at large: the root's revisions are the row's own text, and a
    # reply's revisions belong to that reply.
    revised =
      sorted
      |> Enum.filter(&edit?/1)
      |> Enum.group_by(&edit_target_key/1)

    head_edits = Map.get(revised, root_key, [])

    # A row's text is the newest revision of the post it shows —
    # otherwise the feed renders the pre-edit body forever and the
    # edit is a row the reader can't act on. A reply's revision never
    # takes the head's place: the row keeps the root's text.
    row_msg =
      case head_edits do
        [latest | _] -> latest
        [] -> root_msg || hd(sorted)
      end

    # Each reply speaks once, at its newest wording: where a revision
    # absorbed a reply, the revision stands in and the pre-edit
    # original drops out — the same reply at an older wording is not a
    # second reply, and it never greets its own row with the body the
    # edit just replaced. A fallback head (root absent from the
    # window) is excluded too, else it greets its own row.
    fresh =
      sorted
      |> Enum.filter(&post?/1)
      |> Enum.reject(
        &(&1["key"] in [root_key, row_msg["key"]] or Map.has_key?(revised, &1["key"]))
      )
      |> Enum.concat(
        revised
        |> Enum.reject(fn {target, _} -> target == root_key end)
        |> Enum.map(fn {_target, [latest | _]} -> latest end)
      )
      |> Enum.sort_by(&bump_ts/1, :desc)

    recent = Enum.take(fresh, 3)
    replies = length(fresh)

    likes = thread_likes(group, root_key, like_counts)

    # The edit is activity on the post: a revision moves the row up
    # the feed exactly like a reply does.
    activity = sorted |> Enum.map(&bump_ts/1) |> Enum.max()

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
    |> Map.put(:edited_by, Enum.map(head_edits, & &1["value"]["author"]))
  end

  # Contact edits arrive as many messages per author; they collapse into
  # one row per author *per direction* *per spate* — who they followed,
  # who they blocked, who they let go — positioned at the latest edit of
  # that spate. The direction is the row's key, not a detail: a block
  # shown as a follow would invert the reader's picture of the graph.
  #
  # A spate is one session of edits; the cooloff opens the next line, so
  # history keeps its own rows instead of being re-counted at the top.
  # The store-wide drain hands every payload every contact edit the
  # store holds, and folding all of them into a single row pasted the
  # author's whole graph beside a block made this year: "blocked … +199
  # more".
  # Fold a fresh batch of contact edits into the stored collapse. Only
  # the directions the batch touched are re-split; every other direction
  # keeps the rows it already had, so a store-wide drain folds each
  # direction once and a later edit folds its own direction alone rather
  # than re-reading the whole store-wide history.
  defp fold_contacts(collapsed, []), do: collapsed

  defp fold_contacts(%{by_group: groups, rows: rows}, fresh) do
    {groups, rows} =
      fresh
      |> group_contacts()
      |> Enum.reduce({groups, rows}, fn {{_author, _action} = group, msgs}, {g, r} ->
        merged = Map.get(g, group, []) ++ msgs
        {Map.put(g, group, merged), Map.put(r, group, collapse_group(group, merged))}
      end)

    %{by_group: groups, rows: rows}
  end

  # Fold raw contact edits into one entry per author per direction per
  # spate, keyed by the direction. The entry carries the spate's anchor
  # (its newest edit, which positions the row) and the distinct feeds
  # that spate touched.
  defp collapse_contacts(msgs) do
    msgs
    |> group_contacts()
    |> Map.new(fn {group, group_msgs} -> {group, collapse_group(group, group_msgs)} end)
  end

  # Contact edits grouped by direction — the unit a fold touches. A batch
  # merges into the groups it names and leaves the rest alone.
  defp group_contacts(msgs) do
    msgs
    |> Enum.filter(fn msg ->
      is_binary(msg["value"]["author"]) and is_binary(content(msg)["contact"])
    end)
    |> Enum.group_by(fn msg -> {msg["value"]["author"], contact_action(content(msg))} end)
  end

  # One direction's edits — newest first — folded into spate entries.
  defp collapse_group({author, action}, msgs) do
    msgs
    |> Enum.map(fn msg -> {bump_ts(msg), msg} end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> spates()
    |> Enum.map(fn [{anchor_ts, anchor} | _] = spate ->
      contacts =
        spate
        |> Enum.map(&content(elem(&1, 1))["contact"])
        |> Enum.uniq()

      %{
        anchor: anchor,
        anchor_ts: anchor_ts,
        author: author,
        action: action,
        contacts: contacts
      }
    end)
  end

  # One collapsed spate as a feed row. Kept apart from the fold so a
  # stored collapse can be rendered into the payload without re-reading
  # the messages it came from.
  defp contact_row(
         %{anchor: anchor, anchor_ts: anchor_ts, action: action, contacts: contacts},
         self_id
       ) do
    author = anchor["value"]["author"]

    build_entry(:contact, anchor, anchor_ts, [author], 0, 0, [],
      self_id: self_id,
      rooted: true
    )
    |> Map.put(action, contacts)
    |> Map.put(:contact_action, action)
  end

  # Split one direction's edits — newest first — into spates: edits no
  # further apart than the cooloff belong to the same spate, a longer gap
  # opens the next line. Each spate comes back newest first, so its head
  # is the row's anchor and its timestamps are the row's activity.
  defp spates(edits) do
    {spates, current} =
      Enum.reduce(edits, {[], []}, fn {ts, _msg} = edit, {spates, current} ->
        case current do
          [{oldest, _} | _] when oldest - ts <= @contact_cooloff_ms -> {spates, [edit | current]}
          [] -> {spates, [edit]}
          _ -> {[current | spates], [edit]}
        end
      end)

    spates = if current == [], do: spates, else: [current | spates]

    spates
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  # Which way a contact edit went. Blocking wins: an edit may carry both
  # flags, and the block is the relationship that matters. An edit that
  # clears a block is its own direction too — reading it as a follow
  # would claim a relationship the reader just refused.
  defp contact_action(%{"blocking" => true}), do: :blocked
  defp contact_action(%{"following" => true}), do: :followed
  defp contact_action(%{"following" => false}), do: :unfollowed
  defp contact_action(%{"blocking" => false}), do: :unblocked
  defp contact_action(_), do: :followed

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
  def root_row(item, self_id, private?) do
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
    author = value_of(msg)["author"]

    activity =
      [bump_ts(msg) | Enum.map(recent, &bump_ts/1)]
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
    case content(msg)["text"] do
      text when is_binary(text) -> String.contains?(text, self_id)
      _ -> false
    end
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

  defp edit?(msg), do: content(msg)["type"] == "post-edit"

  # key → the post an edit revises. revisionRoot is the protocol's own
  # pointer; revisionBranch and root cover clients that set only one.
  defp edit_index(acc) do
    Enum.reduce(acc, %{}, fn
      msg, idx ->
        if key = edit_target_key(msg) do
          Map.put(idx, msg["key"], key)
        else
          idx
        end
    end)
  end

  defp edit_target_key(msg) do
    if edit?(msg) do
      c = content(msg)
      key = c["revisionRoot"] || c["revisionBranch"] || c["root"]
      if msg_id?(key), do: key
    end
  end

  # The thread an edit belongs to. Revisions point at the post they
  # revise, so resolve that post the same way a reply resolves its root:
  # an edit of a rootless post heads that post's row, an edit of a reply
  # joins the reply's thread. A target outside the window resolves to the
  # thread root the edit drain recorded for it, so a late edit still lands
  # in its conversation.
  defp edit_thread(msg, by_key, edit_index) do
    with true <- edit?(msg),
         target when is_binary(target) <- Map.get(edit_index, msg["key"]) do
      case Map.get(by_key, target) do
        nil -> MessageIndex.edit_thread_root(target)
        parent -> thread_root(parent, by_key) || target
      end
    else
      _ -> nil
    end
  end

  # A message its own author has asked readers to drop. The index answers
  # who wrote the tombstone; when that is not the message's author the
  # delete is not honoured, so anyone can delete their own and no one
  # else's.
  defp tombstoned?(msg) do
    case MessageIndex.deleted_by(msg["key"]) do
      nil -> false
      deleter -> deleter == value_of(msg)["author"]
    end
  end

  # Mirrors silkpurse_threads' sort_ts/2 — the engine's own bump metric —
  # so client and engine agree on feed order. min(claimed, received)
  # contains future-dated claimed times without a `now` dependency: the
  # same message always gets the same activity across rebuilds, so rows
  # can't drift on heartbeats. Either side falls back when unreadable,
  # exactly as the engine does.
  defp bump_ts(msg) do
    claimed = msg["value"]["timestamp"]
    received = msg["timestamp"]

    cond do
      is_number(claimed) and is_number(received) -> min(round(claimed), round(received))
      is_number(claimed) -> round(claimed)
      is_number(received) -> round(received)
      true -> 0
    end
  end

  defp vote?(msg), do: content(msg)["type"] == "vote"
  defp contact?(msg), do: content(msg)["type"] == "contact"
  defp post?(msg), do: content(msg)["type"] == "post"
  defp boxed?(msg), do: is_binary(value_of(msg)["content"])

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

  # Bound on the `content.root` walk in resolve_thread_root/6 — exposed so
  # a test can pin it without hardcoding the number twice.
  @doc false
  def thread_root_depth, do: @thread_root_depth

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

  # key → author for the rows going out, so a vote/about/edit row can
  # name its target. Scoped to the keys those rows can ask about: the
  # rendered messages, their previewed replies, and the message keys
  # their content names. The full pass merges the store-wide contact
  # drain into `acc` — 200k+ messages — so a map over all of it was a
  # store-sized payload that grew with the store and slowed every mount;
  # the window only ever looks its own keys up.
  defp author_index(acc, feed, messages) do
    by_key = author_by_key(acc)
    wanted = referenced_keys(feed, messages)

    wanted
    |> Enum.reduce(%{}, fn key, idx ->
      case Map.fetch(by_key, key) do
        {:ok, author} -> Map.put(idx, key, author)
        :error -> idx
      end
    end)
  end

  # The rendered messages and their previewed replies, plus every message
  # key their content can reach for. The target set comes from
  # `MessageText.target_keys/1` — the same definition the sentences use
  # to read the index, so the payload is built for exactly the keys the
  # render resolves. A hand-written field list here would drift from the
  # labels silently, and the sentence would fall back to its general
  # phrase with no test failing.
  #
  # Targets are taken from every message the render describes: each row's
  # own message, its previewed replies, and the flat list's rows. A reply
  # preview is described exactly like a row (a block, a like, an edit all
  # describe themselves), so its target needs a seat in the index too.
  defp referenced_keys(feed, messages) do
    rendered = Enum.map(messages, & &1["key"])

    row_msgs =
      Enum.flat_map(feed, fn row ->
        [row[:msg] | Map.get(row, :recent, [])]
      end)

    described = row_msgs ++ messages

    keys =
      Enum.flat_map(feed, fn row ->
        msg = row[:msg] || %{}
        recent = Map.get(row, :recent, [])
        [msg["key"], row[:root_key] | Enum.map(recent, & &1["key"])]
      end)

    targets =
      described
      |> Enum.flat_map(&MessageText.target_keys/1)
      |> Enum.filter(&msg_key?/1)

    Enum.uniq(rendered ++ keys ++ targets)
  end

  defp msg_key?(<<"%", _::binary>> = id), do: String.ends_with?(id, ".sha256")
  defp msg_key?(_), do: false

  defp author_by_key(acc) do
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

  # The message's value map, or nil when the envelope has none. Readers
  # use this instead of msg["value"] directly: indexing a non-map (a
  # corrupt value that arrived as a string, say) raises rather than
  # answering nil, and every caller here wants "absent" over a crash.
  defp value_of(%{"value" => v}) when is_map(v), do: v
  defp value_of(_msg), do: nil

  # A post's text is a binary or it is nothing. A corrupt record with,
  # say, a number there would otherwise reach the row templates and the
  # markdown renderer, which expect to slice a string; dropping the key
  # makes it a textless post — the case the feed already has a
  # description for — rather than a crash. Only the offending messages
  # are rebuilt.
  defp sanitize_text(%{"value" => %{"content" => %{"text" => t} = c} = v} = msg)
       when not is_binary(t) do
    %{msg | "value" => %{v | "content" => Map.delete(c, "text")}}
  end

  defp sanitize_text(msg), do: msg

  # A payload message trimmed to only what the LiveView's search reads:
  # the key (rootless posts key a row by it), the author, and the post
  # text's type/root. Everything else — signature, previous, hash, the
  # full value — is carried in the feed rows and never searched, so it
  # only ever rode along as bytes on first paint.
  #
  # The event types the feed renders as a sentence (not as a post) keep
  # the few extra fields that sentence is built from, so the row can
  # name what actually happened — "announced the pub pub.freesocial.co",
  # "set Alice's display name", "edited their post" — instead of
  # echoing the protocol type at the reader. Posts carry no extra cost:
  # this branch only fires for the event types below.
  #
  # The target-carrying fields (`about`, `link`, the edit's root fields)
  # come from `MessageText.target_fields/1` — the same definition the
  # sentences read and the index is built from — so a projection can
  # never strip a key the index was built to answer. Only the
  # non-target extras a sentence names are listed here.
  @event_sentence_fields %{
    "about" => ["name", "description"],
    "pub" => ["address"],
    "room/alias" => ["alias", "aliasURL", "room", "action"]
  }

  @event_projection_types ~w(about pub room/alias post-edit)

  @event_projection_fields Map.new(@event_projection_types, fn type ->
                             {type,
                              Enum.uniq(
                                MessageText.target_fields(type) ++
                                  Map.get(@event_sentence_fields, type, [])
                              )}
                           end)

  @doc false
  def event_projection_fields, do: @event_projection_fields

  defp search_projection(msg) do
    c = content(msg)
    base = ["type", "text", "root"]

    fields =
      case c do
        %{"type" => type} when is_binary(type) ->
          Map.get(@event_projection_fields, type, [])

        _ ->
          []
      end

    %{
      "key" => msg["key"],
      "value" => %{
        "author" => msg["value"]["author"],
        "content" => Map.take(c, base ++ fields)
      }
    }
  end

  defp reconnect(state) do
    {:noreply, reset_connection(state)}
  end

  defp reset_connection(state) do
    schedule_reconnect()
    state = stop_client(state)

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

  # A reconnect drops the client. If it is still alive — the whoami
  # path can fail while the socket is fine — nothing else will ever
  # stop it: it holds its connection and keeps streaming into refs this
  # process no longer tracks, so every item it delivers lands as a
  # "stray" while the next connection duplicates the work. The client
  # is linked, so a dead one has already told us via :EXIT; GenServer.stop
  # exits on a dead pid, so only touch a live one.
  defp stop_client(%{client: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: Client.stop(pid)
    %{state | client: nil}
  catch
    :exit, _ -> %{state | client: nil}
  end

  defp stop_client(state), do: %{state | client: nil}

  defp schedule_reconnect, do: Process.send_after(self(), :connect, 3_000)

  defp update_peer_recency(state, _old_net, nil), do: state

  defp update_peer_recency(state, old_net, new_net) do
    now = System.system_time(:millisecond)

    old_conns = connections_of(old_net || %{})
    new_conns = connections_of(new_net)

    meta =
      state
      |> Map.get(:peer_meta, %{})
      |> update_conns_recency(new_conns, old_conns, now)
      |> update_known_recency(new_net, now)
      |> update_dial_outcomes(new_net)

    if meta != Map.get(state, :peer_meta, %{}) do
      state = %{state | peer_meta: meta, net_dirty: true}
      maybe_persist_peer_meta(state)
    else
      state
    end
  end

  defp update_conns_recency(meta, new_conns, old_conns, now) do
    Enum.reduce(new_conns, meta, fn id, acc ->
      was_connected = id in old_conns
      m = HighWire.PeersMeta.get(acc, id)

      m1 =
        if was_connected and Map.has_key?(m, "last_connected_at") do
          m
        else
          Map.put(m, "last_connected_at", now)
        end

      m2 = Map.put(m1, "last_activity_at", now)
      Map.put(acc, id, m2)
    end)
  end

  defp update_known_recency(meta, %{"knownPeers" => peers} = _net, now)
       when is_list(peers) do
    Enum.reduce(peers, meta, fn
      %{"address" => addr} = peer, acc when is_binary(addr) ->
        m = HighWire.PeersMeta.get(acc, addr)
        m = Map.put(m, "last_seen_at", now)
        m = if peer["source"], do: Map.put_new(m, "source", peer["source"]), else: m
        Map.put(acc, addr, m)

      _, acc ->
        acc
    end)
  end

  defp update_known_recency(meta, _net, _now), do: meta

  # The dial ledger is the engine's own record of how an address
  # behaved: `attempts` counts consecutive failures since its last
  # handshake, and `lastOk` is when it last completed one — 0, the
  # column's default, when it never has. Only the handful of most
  # recent rows ride the report, so remember each verdict as it passes:
  # a row that rotates out must not take its answer with it. A success
  # is remembered for good (the key is the max ever seen), because an
  # address that has answered once is not an address that never will;
  # the failure count tracks the latest row.
  defp update_dial_outcomes(meta, %{"dialTry" => rows}) when is_list(rows) do
    Enum.reduce(rows, meta, fn
      %{"addr" => addr} = row, acc when is_binary(addr) ->
        m = HighWire.PeersMeta.get(acc, addr)
        m = put_dial_attempts(m, row["attempts"])
        m = put_dial_ok_at(m, row["lastOk"])
        Map.put(acc, addr, m)

      _, acc ->
        acc
    end)
  end

  defp update_dial_outcomes(meta, _net), do: meta

  defp put_dial_attempts(m, attempts) when is_integer(attempts),
    do: Map.put(m, "dial_attempts", attempts)

  defp put_dial_attempts(m, _attempts), do: m

  defp put_dial_ok_at(m, ok) when is_integer(ok) and ok > 0,
    do: Map.put(m, "dial_ok_at", max(ok, m["dial_ok_at"] || 0))

  defp put_dial_ok_at(m, _ok), do: m

  defp build_cache_peer(addr, v) do
    p = %{"address" => addr}
    p = if s = v["source"], do: Map.put(p, "source", s), else: p
    p = if seen = v["last_seen_at"], do: Map.put(p, "last_seen_at", seen), else: p
    p = if act = v["last_activity_at"], do: Map.put(p, "last_activity_at", act), else: p
    p = if conn = v["last_connected_at"], do: Map.put(p, "last_connected_at", conn), else: p
    p
  end

  defp has_cache_fields?(p) do
    p["source"] || p["last_seen_at"] || p["last_activity_at"] || p["last_connected_at"]
  end

  # Connected first, then most recent state change (or cached recency),
  # then address alphabetically. "Connected" is membership in the
  # report's live connections list — the address book itself only
  # carries timestamps (`stateChange` is epoch ms, not a state name).
  defp sort_known_peers(peers, connections) when is_list(peers) do
    live = MapSet.new(connections)

    Enum.sort_by(peers, fn peer ->
      {if(MapSet.member?(live, peer_id(peer)), do: 0, else: 1), -peer_recency(peer),
       String.downcase(to_string(peer["address"] || ""))}
    end)
  end

  defp sort_known_peers(peers, _connections), do: peers

  defp peer_id(%{"key" => id}) when is_binary(id), do: id
  defp peer_id(%{"address" => "net:" <> _ = addr}), do: shs_id(addr)
  defp peer_id(_peer), do: nil

  defp shs_id(addr) do
    case String.split(addr, "~shs:", parts: 2) do
      [_, key] when byte_size(key) > 0 -> "@" <> key <> ".ed25519"
      _ -> nil
    end
  end

  defp peer_recency(peer) do
    case ts(peer) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  defp ts(peer) do
    ts_field(peer["stateChange"]) || ts_field(peer["stateChangeAt"]) ||
      ts_field(peer["state_change_at"]) || ts_field(peer["stateChangeTs"]) ||
      ts_field(peer["last_connected_at"]) || ts_field(peer["last_seen_at"]) ||
      ts_field(peer["last_activity_at"]) || ts_field(peer["birth"])
  end

  defp ts_field(nil), do: nil
  defp ts_field(b) when is_integer(b) and b > 0, do: b
  defp ts_field(f) when is_float(f) and f > 0, do: trunc(f)
  defp ts_field(_), do: nil

  defp maybe_persist_peer_meta(state) do
    case state do
      %{net_dirty: true, peer_meta: meta} ->
        _ = HighWire.PeersMeta.save(meta)
        %{state | net_dirty: false}

      _ ->
        state
    end
  end
end
