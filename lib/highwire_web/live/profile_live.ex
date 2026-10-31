defmodule HighWireWeb.ProfileLive do
  @moduledoc """
  An identity's profile page: avatar, resolved name, about text and
  their threads — paged from the sidecar so the history scrolls without
  bound. The name, bio and picture are edited where they read: the edit
  publishes our word for the feed, or the feed's own when the feed is
  the signed-in identity, and an emptied field takes that name, bio or
  picture back. Nothing here treats the viewer's own identity specially;
  `/profile` without a param simply defaults to the signed-in feed.
  """

  use HighWireWeb, :live_view

  require Logger

  alias HighWire.Avatar, as: Ident
  alias HighWire.Markdown
  alias HighWire.Timeline
  alias HighWireWeb.Components.Avatar
  alias HighWireWeb.Components.Nav

  import HighWireWeb.Components.Time, only: [age: 1]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(HighWire.PubSub, Timeline.topic())

      # The timeline refreshes only while a view says it is being read,
      # and this is the page the only Follow button lives on — without
      # this registration the heartbeat stops the moment the reader
      # opens a profile, and the follow pressed here has to wait for
      # them to return to a timeline before its feed is fetched at all.
      Timeline.set_activity(self(), true)
    end

    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:blob_rev, 0)
     |> assign(:status, :disabled)
     |> assign(:id, nil)
     |> assign(:profile, nil)
     |> assign(:messages, [])
     |> assign(:posts_error, nil)
     |> assign(:posts_loading?, false)
     |> assign(:resume, nil)
     |> assign(:follows, [])
     |> assign(:blocked, [])
     |> assign(:self_id, nil)
     |> assign(:more, false)
     |> assign(:loading_more, false)
     |> assign(:follow_pending, MapSet.new())
     |> assign(:block_pending, MapSet.new())
     |> assign(:action_error, nil)
     |> assign(:about_editing?, false)
     |> assign(:about_name, "")
     |> assign(:about_bio, "")
     |> assign(:about_image, nil)
     |> assign(:about_base, nil)
     |> assign(:avatar_busy?, false)
     |> assign(:about_pending?, false)
     |> assign(:about_error, nil)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) when is_binary(id) and id != "" do
    {:noreply, load(socket, id)}
  end

  def handle_params(_params, _uri, socket) do
    case Timeline.viewer().self_id do
      nil -> {:noreply, socket}
      self -> {:noreply, load(socket, self)}
    end
  end

  @impl true
  def handle_info({Timeline, :updated, payload}, socket) do
    {:noreply,
     assign(socket,
       blob_rev: Map.get(payload, :blob_rev, 0),
       follows: Map.get(payload, :follows, socket.assigns.follows),
       blocked: Map.get(payload, :blocked, socket.assigns.blocked),
       self_id: Map.get(payload, :self_id, socket.assigns.self_id)
     )}
  end

  # The publish itself, behind the held-down button. The render that
  # comes out of this is the one the reader keeps: the relationship the
  # rail now stands on, or the refusal under it. How long that takes is
  # the engine's to say.
  def handle_info({:publish_follow, id, followed?}, socket) do
    result = if followed?, do: Timeline.unfollow(id), else: Timeline.follow(id)

    socket = update(socket, :follow_pending, &MapSet.delete(&1, id))

    case result do
      {:error, reason} ->
        Logger.warning("profile: follow publish failed: #{inspect(reason)}")
        {:noreply, assign(socket, :action_error, follow_error(reason))}

      _ok ->
        {:noreply, follow_settled(socket, id, followed?)}
    end
  end

  def handle_info({:publish_block, id, blocked?}, socket) do
    result = if blocked?, do: Timeline.unblock(id), else: Timeline.block(id)

    socket = update(socket, :block_pending, &MapSet.delete(&1, id))

    case result do
      {:error, reason} ->
        Logger.warning("profile: block publish failed: #{inspect(reason)}")
        {:noreply, assign(socket, :action_error, block_error(reason))}

      _ok ->
        {:noreply, block_settled(socket, id, blocked?)}
    end
  end

  # The about publish, behind the held-down Save. The ack lands the
  # change: the read model has folded the message already, so the page
  # reads what was just saved — and a refusal keeps the form up with
  # what was typed under the line that says the press did not take.
  def handle_info({:publish_about, id, fields}, socket) do
    result = Timeline.about(id, fields)

    socket = assign(socket, :about_pending?, false)

    case result do
      {:error, reason} ->
        Logger.warning("profile: about publish failed: #{inspect(reason)}")
        {:noreply, assign(socket, :about_error, about_error(reason))}

      _ok ->
        {:noreply,
         socket
         |> assign(:profile, Timeline.profile(id))
         |> assign(:about_editing?, false)
         |> assign(:about_error, nil)}
    end
  end

  # The page's rows land as a message, so while they were out the view
  # kept answering its reader: the Follow button, the timeline events,
  # the tabs. An answer for a page that has moved on — or that already
  # has its rows — speaks for posts the reader is no longer waiting
  # on, and is dropped.
  @impl true
  def handle_info({:posts, {messages, resume, more, posts_error}, id}, socket) do
    if id != socket.assigns.id or not socket.assigns.posts_loading? do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         messages: messages,
         posts_error: posts_error,
         posts_loading?: false,
         resume: resume,
         more: more
       )}
    end
  end

  # A page lands with the cursor it was asked for, so an answer that
  # belongs to where the reader was cannot land on where they are now.
  def handle_info({:load_more, id, resume}, socket) do
    if id != socket.assigns.id or resume != socket.assigns.resume do
      {:noreply, assign(socket, :loading_more, false)}
    else
      case Timeline.profile_feed(id, resume) do
        {:ok, %{rows: rows, resume: resume, more: more}} ->
          new = Enum.filter(rows, &post?/1)

          {:noreply,
           assign(socket,
             messages: socket.assigns.messages ++ new,
             resume: resume,
             more: more,
             loading_more: false
           )}

        {:error, _reason} ->
          {:noreply, assign(socket, :loading_more, false)}
      end
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # The page comes back over a handle_info, so the request is answered
  # by the loading line going up and the profile keeps answering while
  # the store is read: a page fetch must not queue the follow and block
  # buttons behind it.
  @impl true
  def handle_event("load-more", _params, socket) do
    id = socket.assigns.id

    if socket.assigns.more and is_binary(id) and not socket.assigns.loading_more do
      # The cursor rides along so an answer that belongs to where the
      # reader was cannot land on where they are now.
      send(self(), {:load_more, id, socket.assigns.resume})
      {:noreply, assign(socket, :loading_more, true)}
    else
      {:noreply, socket}
    end
  end

  # The page that would not come is asked for again, by hand. Only the
  # posts are refetched: the identity around them already answered, and a
  # second ask must not clear a follow still on its way. The answer is
  # read here rather than in a message so no render ever stands between
  # the press and its outcome.
  def handle_event("retry-posts", _params, socket) do
    case socket.assigns.id do
      nil ->
        {:noreply, socket}

      id ->
        {messages, resume, more, posts_error} = fetch_posts(id)

        {:noreply,
         assign(socket,
           messages: messages,
           posts_error: posts_error,
           resume: resume,
           more: more,
           loading_more: false
         )}
    end
  end

  # The press is answered by holding the button down, and the publish
  # itself waits behind it: the render that goes out now carries the
  # held-down state — the verb in flight, the button dead under it — so
  # the reader sees the engine has the press before the engine answers.
  def handle_event("toggle-follow", %{"id" => id}, socket) do
    if MapSet.member?(socket.assigns.follow_pending, id) do
      # The button is already down. A second press is a duplicate, not a
      # second relationship.
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:action_error, nil)
        |> update(:follow_pending, &MapSet.put(&1, id))
        |> update(:block_pending, &MapSet.delete(&1, id))

      send(self(), {:publish_follow, id, id in socket.assigns.follows})

      {:noreply, socket}
    end
  end

  # Blocking publishes one contact message that carries both edges — the
  # block and the retracted follow — so a blocked feed also stops feeding
  # the timeline. Unblocking clears only the block.
  def handle_event("toggle-block", %{"id" => id}, socket) do
    if MapSet.member?(socket.assigns.block_pending, id) do
      {:noreply, socket}
    else
      socket =
        socket
        |> assign(:action_error, nil)
        |> update(:block_pending, &MapSet.put(&1, id))
        |> update(:follow_pending, &MapSet.delete(&1, id))

      send(self(), {:publish_block, id, id in socket.assigns.blocked})

      {:noreply, socket}
    end
  end

  # The about info — the name, bio and picture this page shows — is
  # edited where it reads. Opening prefills both fields and the picture
  # with what the page shows; saving publishes our word for this feed
  # (its own, when the feed is the signed-in identity), and only what
  # changed rides along — an untouched bio must not be pinned as ours
  # behind the copy. An emptied field is the clear: it takes that name,
  # bio or picture back, and the page falls to the other side's word.
  def handle_event("edit-about", _params, socket) do
    name = (socket.assigns.profile && socket.assigns.profile.name) || ""
    bio = (socket.assigns.profile && socket.assigns.profile.description) || ""
    image = (socket.assigns.profile && socket.assigns.profile.image) || nil

    {:noreply,
     socket
     |> assign(:about_editing?, true)
     |> assign(:about_name, name)
     |> assign(:about_bio, bio)
     |> assign(:about_image, image)
     |> assign(:about_base, %{name: name, bio: bio, image: image})
     |> assign(:about_error, nil)}
  end

  def handle_event("cancel-about", _params, socket) do
    {:noreply,
     socket
     |> assign(:about_editing?, false)
     |> assign(:about_error, nil)
     |> assign(:avatar_busy?, false)}
  end

  # The avatar the form shows is what the reader picked, held beside
  # the name and bio it will be saved with — one save publishes all
  # three, so the picture is staged here rather than published on its
  # own. The upload itself is the JS hook's: it posts the file to
  # /blob, and these three events answer the round-trip.
  def handle_event("avatar-uploading", _params, socket) do
    {:noreply, socket |> assign(:avatar_busy?, true) |> assign(:about_error, nil)}
  end

  def handle_event("avatar-picked", %{"ref" => ref}, socket) when is_binary(ref) do
    {:noreply, socket |> assign(:avatar_busy?, false) |> assign(:about_image, ref)}
  end

  def handle_event("avatar-failed", _params, socket) do
    {:noreply,
     socket
     |> assign(:avatar_busy?, false)
     |> assign(:about_error, "That image didn't upload. Try again.")}
  end

  # The picture is taken back the way a name is: it clears here, and
  # the save publishes the clear — the page then falls to the feed's
  # own picture.
  def handle_event("avatar-clear", _params, socket) do
    {:noreply, assign(socket, :about_image, nil)}
  end

  def handle_event("save-about", %{"name" => name, "description" => bio}, socket) do
    # The typed values join the assigns here, so even a full re-render —
    # a refusal landing on a fresh tree — shows what was written.
    socket = assign(socket, about_name: name, about_bio: bio)

    fields =
      about_changes(socket.assigns.about_base, %{
        name: name,
        bio: bio,
        image: socket.assigns.about_image
      })

    cond do
      socket.assigns.about_pending? or socket.assigns.avatar_busy? ->
        # Save is already down, or the picture is still uploading — the
        # reader's pick has not landed yet. A second press is a
        # duplicate, not a second publish.
        {:noreply, socket}

      fields == %{} ->
        # Nothing changed, so nothing was sent: the press is answered
        # by the form closing over what the page already shows.
        {:noreply, socket |> assign(:about_editing?, false) |> assign(:about_error, nil)}

      true ->
        send(self(), {:publish_about, socket.assigns.id, fields})

        {:noreply,
         socket
         |> assign(:about_pending?, true)
         |> assign(:about_error, nil)}
    end
  end

  # Clicking a post opens its thread — the same journey as the timeline
  # row: PostLive carries the reply composer and the like toggle.
  def handle_event("open-post", %{"key" => key}, socket) when is_binary(key) do
    {:noreply, push_navigate(socket, to: "/post/" <> Base.url_encode64(key, padding: false))}
  end

  # The pair the timeline and network pages carry, driven by the same
  # TabActivity hook on the root below: a reader who is not looking at
  # this page should not keep the window's timers running either.
  def handle_event("tab-active", _params, socket) do
    Timeline.set_activity(self(), true)
    {:noreply, socket}
  end

  def handle_event("tab-inactive", _params, socket) do
    Timeline.set_activity(self(), false)
    {:noreply, socket}
  end

  # The publish has landed, and the rail reads as the press. The payload
  # that carries the same relationship is built by that publish, so the
  # two agree while the engine's own delta is still on its way — where a
  # payload that knew only the delta would hand back the state the press
  # just undid, as if the click had done nothing. If the delta ever
  # disagrees, the payload it builds corrects this.
  defp follow_settled(socket, id, true), do: update(socket, :follows, &List.delete(&1, id))
  defp follow_settled(socket, id, false), do: update(socket, :follows, &Enum.uniq([id | &1]))

  defp block_settled(socket, id, true), do: update(socket, :blocked, &List.delete(&1, id))

  # A block arrives with the follow's retraction already in it, so the
  # rail stops reading as following the moment the block lands.
  defp block_settled(socket, id, false) do
    socket
    |> update(:blocked, &Enum.uniq([id | &1]))
    |> update(:follows, &List.delete(&1, id))
  end

  defp load(socket, id) do
    viewer = Timeline.viewer()

    # Neither render owes the browser a wait on the engine. The one
    # served before the socket opens does not ask at all — those rows
    # land only to be fetched again by the connected mount that
    # follows — and the connected mount asks from a task, so the view
    # opens with its Follow button and its timeline events while the
    # rows are still on their way. The identity reads from the read
    # model either way; only the posts are outstanding, and until they
    # land the page says so.
    if connected?(socket), do: queue_posts(id)

    assign(socket,
      status: viewer.status,
      id: id,
      profile: Timeline.profile(id),
      messages: [],
      posts_error: nil,
      posts_loading?: true,
      resume: nil,
      more: false,
      follows: viewer.follows,
      blocked: viewer.blocked,
      self_id: viewer.self_id,
      blob_rev: viewer.blob_rev,
      follow_pending: MapSet.new(),
      block_pending: MapSet.new(),
      action_error: nil,
      about_editing?: false,
      about_pending?: false,
      avatar_busy?: false,
      about_error: nil,
      loading_more: false
    )
  end

  # The page either comes or it does not, and the two are told apart
  # here: a failure carries its reason forward as the reason, because
  # folding it into an empty page is what makes a load that never
  # landed read as a feed with nothing in it.
  defp fetch_posts(id) do
    case Timeline.profile_feed(id) do
      {:ok, %{rows: rows, resume: resume, more: more}} ->
        {Enum.filter(rows, &post?/1), resume, more, nil}

      {:error, reason} ->
        {[], nil, false, posts_error(reason)}
    end
  catch
    # The page is held rather than answered while its rows are on their
    # way, so a call that runs out of time exits instead of returning.
    # That is a page that did not come, and it is read here as one.
    :exit, reason -> {[], nil, false, posts_error(reason)}
  end

  # A page the engine is still reaching for holds its caller, and the
  # caller here is the view itself — every click, every event behind
  # it, queued for as long as that takes. So the ask is made from a
  # task of its own and its answer comes back as a message: the view
  # opens on the identity it already has, and the posts land on it.
  defp queue_posts(id) do
    parent = self()

    Task.start(fn -> send(parent, {:posts, fetch_posts(id), id}) end)
  end

  # The posts could not be read, so the page says that — under a press
  # that asks again — rather than standing in for an empty feed.
  defp posts_error(:offline), do: "Not connected yet."
  defp posts_error(_reason), do: "Couldn't load posts yet."

  # A publish the engine refuses says so under the buttons: the working
  # state goes with the reply, so without these lines a click that did
  # not take reads as a click that did nothing.
  defp follow_error(:offline), do: "Not connected yet. Try again in a moment."
  defp follow_error(_reason), do: "Follow didn't go through. Try again."

  defp block_error(:offline), do: "Not connected yet. Try again in a moment."
  defp block_error(_reason), do: "Block didn't go through. Try again."

  defp about_error(:offline), do: "Not connected yet. Try again in a moment."
  defp about_error(_reason), do: "The change didn't go through. Try again."

  # Only what changed is published. An emptied field rides along as
  # "": that is the clear — take the name or bio back — while a field
  # left as it was sends nothing, so the feed's own later updates stay
  # visible behind a copy we never made. A picture follows the same
  # rule, in the shape an about's image travels in: the ref as a
  # message link when it is set, null when it is taken back.
  defp about_changes(base, sent) do
    %{}
    |> changed("name", sent.name, base.name)
    |> changed("description", sent.bio, base.bio)
    |> image_changed(sent.image, base.image)
  end

  defp changed(fields, _key, value, value), do: fields
  defp changed(fields, key, value, _base), do: Map.put(fields, key, value)

  defp image_changed(fields, image, image), do: fields
  defp image_changed(fields, nil, _base), do: Map.put(fields, "image", nil)
  defp image_changed(fields, ref, _base), do: Map.put(fields, "image", %{"link" => ref})

  # Guarded: private messages carry an encrypted binary `content`.
  defp post?(msg) do
    case msg["value"]["content"] do
      %{"type" => "post"} -> true
      _ -> false
    end
  end

  defp text(msg) do
    case msg["value"]["content"] do
      %{"text" => t} when is_binary(t) -> t
      _ -> ""
    end
  end

  defp ts(msg) do
    case msg["value"]["timestamp"] do
      t when is_number(t) -> round(t)
      _ -> 0
    end
  end

  # LiveView keys repeated children on their id, so the row has to be
  # named after the message rather than its position in the page.
  defp post_dom_id(msg) do
    case msg["key"] do
      key when is_binary(key) -> "profile-post-" <> Base.url_encode64(key, padding: false)
      _ -> "profile-post-anon-" <> Integer.to_string(:erlang.phash2(msg))
    end
  end

  defp heading(%{name: name}) when is_binary(name), do: name
  defp heading(_profile), do: nil

  # A missing about falls back to the id itself: the whole handle when
  # it is short enough to read (dev-era ids like @name.ed25519), a
  # nine-character stub when it is a full base64 feed id — a stub of a
  # short id just cuts the readable part off.
  defp fallback_name("@" <> handle = id) do
    if String.length(handle) > 15, do: Ident.short_id(id), else: handle
  end

  defp fallback_name(id) when is_binary(id), do: Ident.short_id(id)

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="profile-root"
      phx-hook="TabActivity"
      class="flex h-screen overflow-hidden bg-app text-ink"
    >
      <Nav.rail gossip={@gossip}>
        <Nav.rail_label>Profile</Nav.rail_label>

        <div :if={@id} class="px-4 pb-4">
          <Avatar.avatar
            id={@id}
            size={40}
            image={@profile && @profile.image}
            rev={@blob_rev}
          />
          <p class="mt-2 truncate text-sm font-medium text-paper">
            {heading(@profile) || fallback_name(@id)}
          </p>
          <p class="mt-0.5 break-all font-mono text-[10px] text-dim">{@id}</p>

          <%!-- A blocked feed is not offered the follow control: the two
          edges are independent in the protocol, but "following" a feed
          you block is a contradiction the reader should not have to
          resolve. Unblock first, then decide. --%>
          <%!-- Both controls below hold themselves down by rendering the
          pending state, not through phx-disable-with: that attribute
          restores the pre-click label over the reply that carries the
          outcome, and here the label is the outcome. --%>
          <button
            :if={@id != @self_id and @status != :disabled and @id not in @blocked}
            type="button"
            phx-click="toggle-follow"
            phx-value-id={@id}
            disabled={MapSet.member?(@follow_pending, @id)}
            class={["btn mt-3 w-full", @id in @follows and "btn-primary"]}
          >
            {cond do
              MapSet.member?(@follow_pending, @id) ->
                if @id in @follows, do: "Unfollowing…", else: "Following…"

              @id in @follows ->
                "Following"

              true ->
                "Follow"
            end}
          </button>

          <button
            :if={@id != @self_id and @status != :disabled}
            type="button"
            phx-click="toggle-block"
            phx-value-id={@id}
            disabled={MapSet.member?(@block_pending, @id)}
            class={["btn mt-2 w-full", @id not in @blocked and "text-bad"]}
          >
            {cond do
              MapSet.member?(@block_pending, @id) ->
                if @id in @blocked, do: "Unblocking…", else: "Blocking…"

              @id in @blocked ->
                "Unblock"

              true ->
                "Block"
            end}
          </button>

          <p :if={@action_error} role="alert" class="mt-2 text-xs text-bad">
            {@action_error}
          </p>
        </div>

        <p :if={@id == nil} class="px-4 pb-4 text-xs italic text-faint">
          Open a profile from the timeline to see it here.
        </p>
      </Nav.rail>

      <section class="flex-1 overflow-y-auto">
        <div :if={@id} class="mx-auto max-w-2xl px-6 py-10">
          <div class="flex items-start gap-5">
            <div class="shrink-0">
              <Avatar.avatar
                id={@id}
                size={96}
                image={@profile && @profile.image}
                rev={@blob_rev}
              />
            </div>

            <div class="min-w-0 flex-1">
              <div class="flex items-start justify-between gap-3">
                <h1 class="min-w-0 text-xl font-bold text-paper">
                  {heading(@profile) || fallback_name(@id)}
                </h1>

                <%!-- The about info is edited where it reads: the press
                opens the two fields this header shows, and saving
                publishes our word for this feed. --%>
                <button
                  :if={@status != :disabled and not @about_editing?}
                  type="button"
                  phx-click="edit-about"
                  class="btn shrink-0 text-xs"
                >
                  Edit
                </button>
              </div>

              <p class="mt-1 break-all font-mono text-xs text-dim">{@id}</p>

              <div
                :if={@profile && @profile.description && !@about_editing?}
                class="md-body mt-3 text-sm text-ink"
              >
                {raw(Markdown.to_html(@profile.description, blob_rev: @blob_rev))}
              </div>

              <form
                :if={@about_editing?}
                id="about-form"
                phx-submit="save-about"
                class="mt-3 space-y-3"
              >
                <div class="flex items-center gap-3">
                  <Avatar.avatar id={@id} size={56} image={@about_image} rev={@blob_rev} />

                  <div class="flex flex-col gap-1">
                    <%!-- The picture is staged, not published: the file
                    goes to /blob through the hook, and the save below
                    publishes the ref with the name and bio — or the
                    clear, when Remove pressed it out. Remove sits
                    outside the ignored div so it re-renders with the
                    staged picture: the control goes with the picture it
                    takes back. --%>
                    <div
                      id="avatar-attach"
                      phx-hook="AvatarAttach"
                      phx-update="ignore"
                      class="flex flex-wrap items-center gap-2"
                    >
                      <label class="btn cursor-pointer text-xs">
                        Choose image
                        <input type="file" accept="image/*" data-avatar-input class="hidden" />
                      </label>
                    </div>

                    <div class="flex flex-wrap items-center gap-2">
                      <button
                        :if={@about_image != nil}
                        type="button"
                        phx-click="avatar-clear"
                        class="btn text-xs text-bad"
                      >
                        Remove
                      </button>

                      <p :if={@avatar_busy?} role="status" class="text-xs text-dim">
                        Uploading…
                      </p>
                    </div>
                  </div>
                </div>

                <div>
                  <label
                    for="about-name"
                    class="block text-xs font-semibold uppercase tracking-wide text-sub"
                  >
                    Name
                  </label>
                  <input
                    id="about-name"
                    type="text"
                    name="name"
                    value={@about_name}
                    placeholder={fallback_name(@id)}
                    class="mt-1 w-full rounded border border-edge bg-input px-3 py-2 text-sm text-paper placeholder:text-dim focus:border-focus focus:outline-none"
                  />
                </div>

                <div>
                  <label
                    for="about-bio"
                    class="block text-xs font-semibold uppercase tracking-wide text-sub"
                  >
                    Bio
                  </label>
                  <textarea
                    id="about-bio"
                    name="description"
                    rows="3"
                    class="mt-1 w-full resize-none rounded border border-edge bg-input px-3 py-2 text-sm text-paper placeholder:text-dim focus:border-focus focus:outline-none"
                  >{@about_bio}</textarea>
                </div>

                <%!-- Both controls hold themselves down by rendering the
                pending state, the way Follow and Block do: the verb in
                flight is the answer the press gets. --%>
                <div class="flex gap-2">
                  <button type="submit" class="btn btn-primary" disabled={@about_pending?}>
                    {(@about_pending? && "Saving…") || "Save"}
                  </button>

                  <button
                    type="button"
                    phx-click="cancel-about"
                    class="btn"
                    disabled={@about_pending?}
                  >
                    Cancel
                  </button>
                </div>
              </form>

              <%!-- The refusal stands outside the form, where a
              cancelled form cannot hide it. --%>
              <p :if={@about_error} role="alert" class="mt-2 text-xs text-bad">
                {@about_error}
              </p>

              <%!-- The relationship, not the engine: an engine status
              here read as a personal status ("alanz — Ok"), and the
              rail already carries the Follow control. --%>
              <div class="mt-3 flex gap-4 text-xs text-dim">
                <span :if={@id == @self_id}>you</span>
                <span :if={@id != @self_id and @id in @follows}>Following</span>
                <span :if={@id != @self_id and @id in @blocked} class="text-bad">Blocked</span>
              </div>
            </div>
          </div>

          <h2 class="mt-10 border-b border-edge pb-2 text-sm font-semibold uppercase tracking-wide text-sub">
            Posts
          </h2>

          <%!-- Three ways this list starts, and they are different
          claims: a page still on its way, a feed with nothing in it,
          and a page that never came. The first is the static render
          before the socket opens — it asks for nothing and says so,
          rather than passing for the second while the posts are still
          owed. The last says so and carries the press that asks again:
          read as the second, a failed load would pass for a silent
          feed. --%>
          <div
            :if={@messages == [] and @posts_loading?}
            id="profile-posts-loading"
            class="py-8 text-sm italic text-faint"
          >
            Loading posts…
          </div>

          <div
            :if={@messages == [] and not @posts_loading? and @posts_error}
            id="profile-posts-error"
            class="py-8 text-sm"
          >
            <p role="status" class="text-bad">{@posts_error}</p>
            <button type="button" phx-click="retry-posts" class="btn mt-3">
              Try again
            </button>
          </div>

          <div
            :if={@messages == [] and not @posts_loading? and @posts_error == nil}
            class="py-8 text-sm italic text-faint"
          >
            No posts yet.
          </div>

          <div
            :for={msg <- @messages}
            id={post_dom_id(msg)}
            phx-hook="OpenPost"
            data-key={msg["key"]}
            class="cursor-pointer border-b border-edge-soft py-3 text-sm odd:bg-panel hover:bg-active"
          >
            <div class="md-body text-ink">
              {raw(Markdown.to_html(text(msg), blob_rev: @blob_rev))}
            </div>
            <div class="mt-1 text-xs text-faint"><.age ts={ts(msg)} /></div>
          </div>

          <p
            :if={@loading_more}
            id="profile-loading"
            role="status"
            class="py-3 text-sm text-info"
          >
            Loading more…
          </p>

          <div :if={@more} id="profile-sentinel" phx-hook="InfiniteScroll" class="h-px"></div>
        </div>

        <div :if={@id == nil} class="mx-auto max-w-2xl px-6 py-10 text-sm italic text-faint">
          No feed selected.
        </div>
      </section>
    </div>
    """
  end
end
