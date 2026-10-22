defmodule HighWireWeb.ProfileLive do
  @moduledoc """
  An identity's profile page: avatar, resolved name, about text and
  their threads — paged from the sidecar so the history scrolls without
  bound. The same view renders for every feed id —
  nothing here treats the viewer's own identity specially; `/profile`
  without a param simply defaults to the signed-in feed.
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
    if connected?(socket), do: Phoenix.PubSub.subscribe(HighWire.PubSub, Timeline.topic())

    {:ok,
     socket
     |> assign(:page_title, "Profile")
     |> assign(:blob_rev, 0)
     |> assign(:status, :disabled)
     |> assign(:id, nil)
     |> assign(:profile, nil)
     |> assign(:messages, [])
     |> assign(:resume, nil)
     |> assign(:follows, [])
     |> assign(:blocked, [])
     |> assign(:self_id, nil)
     |> assign(:more, false)
     |> assign(:follow_pending, MapSet.new())
     |> assign(:block_pending, MapSet.new())
     |> assign(:action_error, nil)}
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

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("load-more", _params, socket) do
    id = socket.assigns.id

    if socket.assigns.more and is_binary(id) do
      case Timeline.profile_feed(id, socket.assigns.resume) do
        {:ok, %{rows: rows, resume: resume, more: more}} ->
          new = Enum.filter(rows, &post?/1)

          {:noreply,
           assign(socket,
             messages: socket.assigns.messages ++ new,
             resume: resume,
             more: more
           )}

        {:error, _reason} ->
          {:noreply, socket}
      end
    else
      {:noreply, socket}
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

  # Clicking a post opens its thread — the same journey as the timeline
  # row: PostLive carries the reply composer and the like toggle.
  def handle_event("open-post", %{"key" => key}, socket) when is_binary(key) do
    {:noreply, push_navigate(socket, to: "/post/" <> Base.url_encode64(key, padding: false))}
  end

  # The publish has landed, and the rail reads as the press. The payload
  # that carries the new relationship comes back with the next index
  # refresh — five seconds away at best — and until it does the button
  # the reader pressed would still show the state the press undid, as if
  # the click had done nothing. The next payload confirms this, or
  # corrects it.
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

    {status, messages, resume, more} =
      case Timeline.profile_feed(id) do
        {:ok, %{rows: rows, resume: resume, more: more}} ->
          {viewer.status, Enum.filter(rows, &post?/1), resume, more}

        {:error, _reason} ->
          {viewer.status, [], nil, false}
      end

    assign(socket,
      status: status,
      id: id,
      profile: Timeline.profile(id),
      messages: messages,
      resume: resume,
      more: more,
      follows: viewer.follows,
      blocked: viewer.blocked,
      self_id: viewer.self_id,
      blob_rev: viewer.blob_rev,
      follow_pending: MapSet.new(),
      block_pending: MapSet.new(),
      action_error: nil
    )
  end

  # A publish the engine refuses says so under the buttons: the working
  # state goes with the reply, so without these lines a click that did
  # not take reads as a click that did nothing.
  defp follow_error(:offline), do: "Not connected yet. Try again in a moment."
  defp follow_error(_reason), do: "Follow didn't go through. Try again."

  defp block_error(:offline), do: "Not connected yet. Try again in a moment."
  defp block_error(_reason), do: "Block didn't go through. Try again."

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
    <div class="flex h-screen overflow-hidden bg-app text-ink">
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
              <h1 class="text-xl font-bold text-paper">
                {heading(@profile) || fallback_name(@id)}
              </h1>

              <p class="mt-1 break-all font-mono text-xs text-dim">{@id}</p>

              <div
                :if={@profile && @profile.description}
                class="md-body mt-3 text-sm text-ink"
              >
                {raw(Markdown.to_html(@profile.description, blob_rev: @blob_rev))}
              </div>

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

          <div :if={@messages == []} class="py-8 text-sm italic text-faint">
            No posts yet.
          </div>

          <div
            :for={msg <- @messages}
            id={post_dom_id(msg)}
            phx-hook="OpenPost"
            data-key={msg["key"]}
            class="cursor-pointer border-b border-edge-soft py-3 text-sm hover:bg-panel"
          >
            <div class="md-body text-ink">
              {raw(Markdown.to_html(text(msg), blob_rev: @blob_rev))}
            </div>
            <div class="mt-1 text-xs text-faint"><.age ts={ts(msg)} /></div>
          </div>

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
