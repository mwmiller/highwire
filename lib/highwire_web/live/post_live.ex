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
     |> assign(
       page_title: "Post",
       root: nil,
       replies: [],
       not_found: false,
       profiles: %{},
       like_counts: %{},
       self_id: nil,
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
    {:noreply,
     assign(socket,
       blob_rev: Map.get(payload, :blob_rev, 0),
       profiles: Map.get(payload, :profiles, socket.assigns.profiles)
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load(socket, raw_key) do
    {_status, payload} = Timeline.snapshot()
    post = Timeline.post(raw_key)

    socket
    |> assign(
      root: post && post.root,
      replies: (post && post.replies) || [],
      not_found: post == nil,
      profiles: Map.get(payload, :profiles, %{}),
      like_counts: Map.get(payload, :like_counts, %{}),
      self_id: Map.get(payload, :self_id),
      blob_rev: Map.get(payload, :blob_rev, 0)
    )
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

    assigns = assign(assigns, likes: likes)

    ~H"""
    <div class="flex h-screen overflow-hidden bg-app text-ink">
      <Nav.rail />
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
                    <span class="text-xs text-faint">{rel_time(ts(@root))}</span>
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
                    <span :if={@likes > 0}>❤ {@likes}</span>
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
                  <span class="text-xs text-faint">{rel_time(ts(reply))}</span>
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
              </div>
            </div>

            <p :if={@replies == []} class="mt-6 text-sm italic text-faint">
              No replies in the local store.
            </p>
          </div>
        </div>
      </section>
    </div>
    """
  end
end
