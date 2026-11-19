defmodule HighWireWeb.BlobsLive do
  @moduledoc """
  The engine's blob store, read through the posts that carried it.

  A blob has no name of its own — the bytes are content-addressed, and
  the only thing that ever described one is the post it arrived in. So
  the page lists posts, not blobs: each one with its author and opening
  words, and the blobs it carried beside them. Blobs no post carried
  come last, in a strip of their own, where a digest is all there is to
  go on. A blob with a post links to that post; only a blob without one
  leads to its bytes.

  The list comes from `HighWire.BlobIndex`, which crawls the store in the
  background and keeps what it learned, so opening this page is a lookup
  rather than a sweep — the indexer's own pace is the only price. Kind,
  size, "with a post" and a ref search narrow the list without hiding
  anything the store has, and the order can follow age or size.
  """

  use HighWireWeb, :live_view

  alias HighWire.BlobIndex
  alias HighWire.SSB.Profile
  alias HighWireWeb.Components.{Nav, Shell}
  import HighWireWeb.Components.Time, only: [age: 1, rel_time: 1]

  # Tens of thousands of blobs live here, but they arrive in a few
  # thousand posts: one page of posts at a time keeps the page usable,
  # and the rail carries the totals.
  @page 20

  # A post carrying a hundred pictures would otherwise push every later
  # post off the page: three across, two rows, and the rest one press
  # away. The loose strip is paged the same shape.
  @tiles 6
  @loose_page 18

  @kinds [:all, :image, :audio, :video, :file]
  @bands [:any, :small, :medium, :large]
  @sorts [:newest, :oldest, :largest]

  @impl true
  def mount(_params, _session, socket) do
    _ = BlobIndex.ensure_started()

    if connected?(socket), do: Phoenix.PubSub.subscribe(HighWire.PubSub, BlobIndex.topic())

    {:ok,
     socket
     |> assign(:page_title, "Blobs")
     |> assign(:shown, @page)
     |> assign(:loose_shown, @loose_page)
     |> assign(:expanded, MapSet.new())
     |> assign(:kind, :all)
     |> assign(:post_only, false)
     |> assign(:band, :any)
     |> assign(:sort, :newest)
     |> assign(:query, "")
     |> load()}
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    case Enum.find(@kinds, &(Atom.to_string(&1) == kind)) do
      nil -> {:noreply, socket}
      kind -> {:noreply, socket |> assign(kind: kind, shown: @page) |> visible()}
    end
  end

  def handle_event("more", _params, socket) do
    {:noreply, assign(socket, :shown, socket.assigns.shown + @page)}
  end

  def handle_event("more-loose", _params, socket) do
    {:noreply, assign(socket, :loose_shown, socket.assigns.loose_shown + @loose_page)}
  end

  # A post with more blobs than the strip shows opens in place.
  def handle_event("expand-post", %{"key" => key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("toggle-post", _params, socket) do
    post_only = not socket.assigns.post_only
    {:noreply, socket |> assign(post_only: post_only, shown: @page) |> visible()}
  end

  def handle_event("band", %{"band" => band}, socket) do
    case Enum.find(@bands, &(Atom.to_string(&1) == band)) do
      nil -> {:noreply, socket}
      band -> {:noreply, socket |> assign(band: band, shown: @page) |> visible()}
    end
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    case Enum.find(@sorts, &(Atom.to_string(&1) == sort)) do
      nil -> {:noreply, socket}
      sort -> {:noreply, socket |> assign(sort: sort, shown: @page) |> visible()}
    end
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, socket |> assign(query: String.trim(query), shown: @page) |> visible()}
  end

  @impl true
  def handle_info(:updated, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The indexer publishes whole lists when a sweep ends; nothing here
  # reads the store or the search index.
  defp load(socket) do
    rows = BlobIndex.rows()
    parents = BlobIndex.parents()
    post_count = Enum.count(rows, &Map.has_key?(parents, &1.ref))
    band_counts = rows |> Enum.frequencies_by(&band_of(&1.size)) |> Map.put(:any, length(rows))

    socket
    |> assign(rows: rows)
    |> assign(parents: parents)
    |> assign(counts: BlobIndex.counts())
    |> assign(status: BlobIndex.status())
    |> assign(post_count: post_count)
    |> assign(band_counts: band_counts)
    |> visible()
  end

  defp visible(socket) do
    rows = socket.assigns.rows
    kind = socket.assigns.kind
    parents = socket.assigns.parents
    post_only = socket.assigns.post_only
    band = socket.assigns.band
    query = socket.assigns.query
    lowered = String.downcase(query)

    filtered =
      Enum.filter(rows, fn row ->
        (kind == :all or row.kind == kind) and
          (not post_only or Map.has_key?(parents, row.ref)) and
          (band == :any or band_of(row.size) == band) and
          (query == "" or matches?(row, lowered, query))
      end)

    %{bundles: bundles, loose: loose} = bundle(sort(filtered, socket.assigns.sort), parents)

    assign(socket, visible: filtered, bundles: bundles, loose: loose)
  end

  # The posted blobs are gathered under the post that carried them, in the
  # order the sort put their first blob; everything else falls through to
  # the loose strip. One pass over the filtered rows, and each bundle's
  # rows keep the sort's order.
  defp bundle(rows, parents) do
    acc =
      Enum.reduce(rows, %{order: [], bundles: %{}, loose: []}, fn row, acc ->
        case parent(parents, row.ref) do
          nil ->
            %{acc | loose: [row | acc.loose]}

          post ->
            place(acc, post, row)
        end
      end)

    %{
      bundles:
        acc.order
        |> Enum.reverse()
        |> Enum.map(&Map.fetch!(acc.bundles, &1))
        |> Enum.map(&%{&1 | rows: Enum.reverse(&1.rows)}),
      loose: Enum.reverse(acc.loose)
    }
  end

  # A blob's post already has a bundle: add to it. The first one makes
  # the bundle and takes its place in the order.
  defp place(acc, post, row) do
    case Map.fetch(acc.bundles, post.key) do
      {:ok, bundle} ->
        %{acc | bundles: Map.put(acc.bundles, post.key, add(bundle, row))}

      :error ->
        %{
          acc
          | order: [post.key | acc.order],
            bundles: Map.put(acc.bundles, post.key, add(new(post, row), row))
        }
    end
  end

  defp new(post, row) do
    %{
      key: post.key,
      author: post.author,
      text: post.text,
      ts: post.ts,
      rows: [],
      size: 0,
      id: row.hex
    }
  end

  defp add(bundle, row), do: %{bundle | rows: [row | bundle.rows], size: bundle.size + row.size}

  # A ref in a post is base64; the store file is its digest in hex, so a
  # query is matched against both and the reader can paste either. Hex is
  # stored lowercase, so that half compares against the lowered query.
  defp matches?(row, lowered, query) do
    String.contains?(row.hex, lowered) or String.contains?(row.ref, query)
  end

  defp sort(rows, :newest), do: rows
  defp sort(rows, :oldest), do: Enum.reverse(rows)
  defp sort(rows, :largest), do: Enum.sort_by(rows, &(-&1.size))

  defp band_of(size) when size < 100 * 1024, do: :small
  defp band_of(size) when size < 1024 * 1024, do: :medium
  defp band_of(_size), do: :large

  defp count(counts, kind), do: Map.get(counts, kind, 0)

  # `{@kinds}` in a template is an assign lookup, not the module attribute.
  defp kinds, do: @kinds

  defp kind_label(:all), do: "All"
  defp kind_label(:image), do: "Images"
  defp kind_label(:audio), do: "Audio"
  defp kind_label(:video), do: "Video"
  defp kind_label(:file), do: "Files"

  # One blob's own kind, for the line under its words.
  defp kind_word(:image), do: "Image"
  defp kind_word(:audio), do: "Sound"
  defp kind_word(:video), do: "Film"
  defp kind_word(:file), do: "File"

  defp band_label(:any), do: "Any"
  defp band_label(:small), do: "Small"
  defp band_label(:medium), do: "Medium"
  defp band_label(:large), do: "Large"

  defp band_title(:any), do: "Any size"
  defp band_title(:small), do: "Under 100 KB"
  defp band_title(:medium), do: "100 KB to 1 MB"
  defp band_title(:large), do: "1 MB and up"

  defp sort_label(:newest), do: "Newest"
  defp sort_label(:oldest), do: "Oldest"
  defp sort_label(:largest), do: "Largest"

  defp bands, do: @bands
  defp sorts, do: @sorts
  defp tiles, do: @tiles

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp size(bytes) when bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  # The post that carried a blob, as the index recorded it. A map is what
  # a current sweep writes; a bare key is what one wrote before rows said
  # anything about their post, and reads as a post with nothing to add.
  defp parent(parents, ref) do
    case Map.get(parents, ref) do
      %{} = post -> post
      key when is_binary(key) -> %{key: key, author: nil, text: nil, ts: nil}
      _none -> nil
    end
  end

  defp name(author) when is_binary(author), do: Profile.display_name(author)
  defp name(_author), do: "someone"

  defp profile_href(id), do: "/profile?id=" <> URI.encode_www_form(id)

  # Post routes carry the message id base64-encoded, the same way the
  # timeline and profile links do.
  defp post_path(key), do: "/post/" <> Base.url_encode64(key, padding: false)

  # A tile says what the blob is on hover, and which post it belongs to
  # when the reader wants the whole thing.
  defp tile_title(blob) do
    "#{kind_word(blob.kind)} · #{size(blob.size)} · arrived #{rel_time(blob.mtime * 1000)}"
  end

  defp bundle_tiles(bundle, expanded) do
    if MapSet.member?(expanded, bundle.key), do: bundle.rows, else: Enum.take(bundle.rows, @tiles)
  end

  defp summary(bundles, loose, shown) do
    posts = length(bundles)
    blobs = Enum.reduce(bundles, length(loose), &(length(&1.rows) + &2))

    if posts == 0 do
      "#{blobs} blobs"
    else
      "#{min(shown, posts)} of #{posts} posts · #{blobs} blobs"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Shell.app gossip={@gossip}>
      <:rail>
        <Nav.rail_label>Blobs</Nav.rail_label>
        <div class="pb-4">
          <p :if={@status == :indexing} class="px-4 text-xs text-muted">
            Indexing the blob store…
          </p>
          <p :if={@status != :indexing} class="px-4 text-xs text-muted">
            {count(@counts, :all)} blobs indexed
          </p>
          <p class="px-4 pt-1 text-xs text-faint">
            Read from this machine's blob store. Each post reads with the blobs it
            carried; a blob no post carried stands on its own.
          </p>
        </div>

        <form
          :if={count(@counts, :all) > 0}
          phx-change="search"
          phx-submit="search"
        >
          <Nav.rail_label>Find</Nav.rail_label>
          <div class="px-4 pb-4">
            <input
              type="text"
              name="q"
              value={@query}
              phx-debounce="200"
              placeholder="Ref or digest"
              autocomplete="off"
              class="w-full rounded border border-edge bg-app px-2 py-0.5 text-xs text-paper transition placeholder:text-faint focus:border-dim focus:outline-none"
            />
          </div>
        </form>

        <div :if={count(@counts, :all) > 0}>
          <Nav.rail_label>Kind</Nav.rail_label>
          <div class="flex flex-wrap gap-1 px-4 pb-4">
            <button
              :for={kind <- kinds()}
              type="button"
              phx-click="filter"
              phx-value-kind={kind}
              class={[
                "rounded border px-2 py-0.5 text-xs transition",
                @kind == kind && "border-ink bg-raised text-paper",
                @kind != kind && "border-edge text-muted hover:text-paper"
              ]}
            >
              {kind_label(kind)} ({count(@counts, kind)})
            </button>
            <button
              type="button"
              phx-click="toggle-post"
              class={[
                "rounded border px-2 py-0.5 text-xs transition",
                @post_only && "border-ink bg-raised text-paper",
                not @post_only && "border-edge text-muted hover:text-paper"
              ]}
            >
              With a post ({@post_count})
            </button>
          </div>
        </div>

        <div :if={count(@counts, :all) > 0}>
          <Nav.rail_label>Size</Nav.rail_label>
          <div class="flex flex-wrap gap-1 px-4 pb-4">
            <button
              :for={band <- bands()}
              type="button"
              phx-click="band"
              phx-value-band={band}
              title={band_title(band)}
              class={[
                "rounded border px-2 py-0.5 text-xs transition",
                @band == band && "border-ink bg-raised text-paper",
                @band != band && "border-edge text-muted hover:text-paper"
              ]}
            >
              {band_label(band)} ({Map.get(@band_counts, band, 0)})
            </button>
          </div>
        </div>

        <div :if={count(@counts, :all) > 0}>
          <Nav.rail_label>Order</Nav.rail_label>
          <div class="flex flex-wrap gap-1 px-4 pb-4">
            <button
              :for={order <- sorts()}
              type="button"
              phx-click="sort"
              phx-value-sort={order}
              class={[
                "rounded border px-2 py-0.5 text-xs transition",
                @sort == order && "border-ink bg-raised text-paper",
                @sort != order && "border-edge text-muted hover:text-paper"
              ]}
            >
              {sort_label(order)}
            </button>
          </div>
        </div>
      </:rail>

      <section class="flex-1 overflow-y-auto">
        <div class="mx-auto max-w-4xl px-6 py-10">
          <h1 class="text-xl font-bold text-paper">Blobs</h1>
          <p class="mt-2 text-sm text-dim">
            Everything in this machine's blob store — images, sound, film and files —
            read with the post that carried each one.
          </p>

          <p
            :if={@status == :indexing and count(@counts, :all) == 0}
            id="blobs-loading"
            class="mt-6 text-sm text-faint"
          >
            The store is being indexed in the background; this list fills as it goes.
          </p>

          <p :if={@status == :ready and count(@counts, :all) == 0} class="mt-6 text-sm text-faint">
            The blob store is empty.
          </p>

          <p :if={count(@counts, :all) > 0} id="blobs-summary" class="mt-4 text-xs text-faint">
            {summary(@bundles, @loose, @shown)}
          </p>

          <div
            :if={@bundles != []}
            id="blob-posts"
            class="mt-2 divide-y divide-edge border-y border-edge"
          >
            <article
              :for={bundle <- Enum.take(@bundles, @shown)}
              id={"blob-post-" <> bundle.id}
              class="py-4"
            >
              <div class="flex items-baseline justify-between gap-3 text-xs">
                <div class="flex min-w-0 items-baseline gap-1.5 text-faint">
                  <a
                    :if={bundle.author}
                    href={profile_href(bundle.author)}
                    title={bundle.author}
                    class="truncate text-muted transition hover:text-paper"
                  >
                    {name(bundle.author)}
                  </a>
                  <span :if={!bundle.author}>someone</span>
                  <span :if={bundle.ts}>· <.age ts={bundle.ts} /></span>
                </div>

                <.link
                  navigate={post_path(bundle.key)}
                  title="Open the post that carried these blobs"
                  class="shrink-0 text-sub transition hover:text-paper"
                >
                  Post →
                </.link>
              </div>

              <p :if={bundle.text} class="mt-1 text-sm leading-snug text-paper">
                {bundle.text}
              </p>
              <p :if={!bundle.text} class="mt-1 text-sm italic text-faint">
                A post with no words.
              </p>

              <div class="mt-2 grid grid-cols-3 gap-2">
                <a
                  :for={blob <- bundle_tiles(bundle, @expanded)}
                  href={post_path(bundle.key)}
                  title={tile_title(blob)}
                  class="flex aspect-square items-center justify-center overflow-hidden rounded border border-edge bg-raised text-[10px] uppercase text-faint transition hover:border-dim"
                >
                  <img
                    :if={blob.kind == :image}
                    src={"/blob/" <> blob.hex}
                    alt=""
                    loading="lazy"
                    class="h-full w-full object-cover"
                  />
                  <span :if={blob.kind != :image}>{blob.kind}</span>
                </a>
              </div>

              <button
                :if={length(bundle.rows) > tiles()}
                type="button"
                phx-click="expand-post"
                phx-value-key={bundle.key}
                class="mt-2 text-xs text-sub transition hover:text-paper"
              >
                {if MapSet.member?(@expanded, bundle.key),
                  do: "Show fewer",
                  else: "Show all " <> Integer.to_string(length(bundle.rows))}
              </button>
            </article>
          </div>

          <div :if={@loose != []} id="blob-loose" class="mt-8">
            <p class="text-[11px] uppercase tracking-wider text-faint">
              No post carried these ({length(@loose)})
            </p>

            <div class="mt-2 grid grid-cols-3 gap-2">
              <a
                :for={blob <- Enum.take(@loose, @loose_shown)}
                href={"/blob/" <> blob.hex}
                title={tile_title(blob) <> " — open the bytes"}
                class="flex aspect-square items-center justify-center overflow-hidden rounded border border-edge bg-raised text-[10px] uppercase text-faint transition hover:border-dim"
              >
                <img
                  :if={blob.kind == :image}
                  src={"/blob/" <> blob.hex}
                  alt=""
                  loading="lazy"
                  class="h-full w-full object-cover"
                />
                <span :if={blob.kind != :image}>{blob.kind}</span>
              </a>
            </div>

            <button
              :if={length(@loose) > @loose_shown}
              type="button"
              phx-click="more-loose"
              class="mt-3 rounded-md border border-edge px-3 py-1.5 text-xs text-sub transition hover:bg-raised hover:text-paper"
            >
              Show more ({length(@loose) - @loose_shown} to go)
            </button>
          </div>

          <button
            :if={length(@bundles) > @shown}
            type="button"
            phx-click="more"
            class="mt-6 rounded-md border border-edge px-3 py-1.5 text-sm text-sub transition hover:bg-raised hover:text-paper"
          >
            Show more ({length(@bundles) - @shown} posts to go)
          </button>
        </div>
      </section>
    </Shell.app>
    """
  end
end
