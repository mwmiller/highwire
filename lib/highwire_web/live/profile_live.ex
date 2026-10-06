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
     |> assign(:self_id, nil)
     |> assign(:more, false)}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) when is_binary(id) and id != "" do
    {:noreply, load(socket, id)}
  end

  def handle_params(_params, _uri, socket) do
    {_status, payload} = Timeline.snapshot()

    case payload.self_id do
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
       self_id: Map.get(payload, :self_id, socket.assigns.self_id)
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("load-more", _params, socket) do
    id = socket.assigns.id

    if socket.assigns.more and is_binary(id) do
      %{rows: rows, resume: resume, more: more} =
        Timeline.profile_feed(id, socket.assigns.resume)

      new = Enum.filter(rows, &post?/1)

      {:noreply,
       assign(socket,
         messages: socket.assigns.messages ++ new,
         resume: resume,
         more: more
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle-follow", %{"id" => id}, socket) do
    result = if id in socket.assigns.follows, do: Timeline.unfollow(id), else: Timeline.follow(id)

    case result do
      {:error, reason} -> Logger.warning("profile: follow publish failed: #{inspect(reason)}")
      _ok -> :ok
    end

    {:noreply, socket}
  end

  defp load(socket, id) do
    {status, payload} = Timeline.snapshot()
    %{rows: rows, resume: resume, more: more} = Timeline.profile_feed(id)
    posts = Enum.filter(rows, &post?/1)

    socket
    |> assign(
      status: status,
      id: id,
      profile: Timeline.profile(id),
      messages: posts,
      resume: resume,
      more: more,
      follows: Map.get(payload, :follows, []),
      self_id: Map.get(payload, :self_id),
      blob_rev: Map.get(payload, :blob_rev, 0)
    )
  end

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

  defp heading(%{name: name}) when is_binary(name), do: name
  defp heading(_profile), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail />

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
                {heading(@profile) || Ident.short_id(@id)}
              </h1>

              <p class="mt-1 break-all font-mono text-xs text-dim">{@id}</p>

              <button
                :if={@id != @self_id and @status != :disabled}
                type="button"
                phx-click="toggle-follow"
                phx-value-id={@id}
                class={["btn mt-3", @id in @follows and "btn-primary"]}
              >
                {if @id in @follows, do: "Following", else: "Follow"}
              </button>

              <div
                :if={@profile && @profile.description}
                class="md-body mt-3 text-sm text-ink"
              >
                {raw(Markdown.to_html(@profile.description, blob_rev: @blob_rev))}
              </div>

              <div class="mt-3 flex gap-4 text-xs text-dim">
                <span>{length(@messages)} posts</span>
                <span class="capitalize">{@status}</span>
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
            class="border-b border-edge-soft py-3 text-sm hover:bg-panel"
          >
            <div class="md-body text-ink">
              {raw(Markdown.to_html(text(msg), blob_rev: @blob_rev))}
            </div>
            <div class="mt-1 text-xs text-faint">{rel_time(ts(msg))}</div>
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
