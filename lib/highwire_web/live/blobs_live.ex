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
  rather than a sweep — the indexer's own pace is the only price.

  A store can hold tens of thousands of blobs, so the list is narrowed
  rather than scrolled: kind, whether a post carried it, size band and
  age each cut the list, the search matches a digest or the words and
  author of the carrying post, and the order follows arrival or size.
  Every one of those is page state and rides in the URL, so a narrowed
  view survives a reload, the back button and a link. The header says how
  much of the store the current view covers and how many bytes that is.

  Where a blob's post is known, the row carries both dates: when the
  post was published, and when the bytes actually reached this machine.
  They can be years apart — a picture old in the network is often new on
  disk — and the gap is the point of showing them together.
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
  # away. The loose strip is paged the same shape, a little deeper —
  # those have no post to read them through, so the grid is the only way
  # to see what is there.
  @tiles 6
  @loose_page 36

  @kinds [:all, :image, :audio, :video, :file]
  @attachments [:any, :attached, :loose]
  @bands [:any, :small, :medium, :large]
  @ages [:any, :day, :week, :month, :year]
  @sorts [:newest, :oldest, :largest, :smallest]

  @impl true
  def mount(params, _session, socket) do
    _ = BlobIndex.ensure_started()

    if connected?(socket), do: Phoenix.PubSub.subscribe(HighWire.PubSub, BlobIndex.topic())

    {:ok,
     socket
     |> assign(:page_title, "Blobs")
     |> assign(:shown, @page)
     |> assign(:loose_shown, @loose_page)
     |> assign(:expanded, MapSet.new())
     |> assign_filters(filters_from(params))
     |> load()}
  end

  # Filters and order are page state, so they ride in the URL. A patch
  # made from this page arrives with the filters already assigned; a
  # restored URL or a history move arrives with different ones, and the
  # list follows without another trip to the index.
  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters_from(params)

    if filters == current_filters(socket.assigns) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign_filters(filters)
       |> assign(shown: @page, loose_shown: @loose_page)
       |> refresh()}
    end
  end

  @impl true
  def handle_event("filter", %{"kind" => kind}, socket) do
    case find(@kinds, kind) do
      nil ->
        {:noreply, socket}

      kind ->
        {:noreply,
         socket |> assign(:kind, kind) |> assign(:shown, @page) |> refresh() |> push_url()}
    end
  end

  def handle_event("post", %{"post" => post}, socket) do
    case find(@attachments, post) do
      nil ->
        {:noreply, socket}

      post ->
        {:noreply,
         socket |> assign(:post, post) |> assign(:shown, @page) |> refresh() |> push_url()}
    end
  end

  def handle_event("band", %{"band" => band}, socket) do
    case find(@bands, band) do
      nil ->
        {:noreply, socket}

      band ->
        {:noreply,
         socket |> assign(:band, band) |> assign(:shown, @page) |> refresh() |> push_url()}
    end
  end

  def handle_event("age", %{"age" => age}, socket) do
    case find(@ages, age) do
      nil ->
        {:noreply, socket}

      age ->
        {:noreply,
         socket |> assign(:age, age) |> assign(:shown, @page) |> refresh() |> push_url()}
    end
  end

  def handle_event("sort", %{"sort" => sort}, socket) do
    case find(@sorts, sort) do
      nil ->
        {:noreply, socket}

      sort ->
        {:noreply,
         socket |> assign(:sort, sort) |> assign(:shown, @page) |> refresh() |> push_url()}
    end
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply,
     socket
     |> assign(:query, String.trim(query))
     |> assign(:shown, @page)
     |> refresh()
     |> push_url()}
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign_filters(default_filters())
     |> assign(shown: @page, loose_shown: @loose_page)
     |> refresh()
     |> push_url()}
  end

  # Asking for more re-cuts the slices: the list behind the counter is
  # already here, so nothing has to cross the wire to page it.
  def handle_event("more", _params, socket) do
    {:noreply, socket |> assign(:shown, socket.assigns.shown + @page) |> refresh()}
  end

  def handle_event("more-loose", _params, socket) do
    {:noreply,
     socket |> assign(:loose_shown, socket.assigns.loose_shown + @loose_page) |> refresh()}
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

  @impl true
  def handle_info(:updated, socket), do: {:noreply, load(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The indexer publishes whole lists when a sweep ends; nothing here
  # reads the store or the search index.
  defp load(socket) do
    rows = BlobIndex.rows()
    parents = BlobIndex.parents()
    now = System.system_time(:second)
    post_count = Enum.count(rows, &Map.has_key?(parents, &1.ref))

    socket
    |> assign(rows: rows)
    |> assign(parents: parents)
    |> assign(search_text: search_text(parents))
    |> assign(counts: BlobIndex.counts())
    |> assign(status: BlobIndex.status())
    |> assign(post_count: post_count)
    |> assign(loose_count: length(rows) - post_count)
    |> assign(total_size: Enum.reduce(rows, 0, &(&1.size + &2)))
    |> assign(
      band_counts: Enum.frequencies_by(rows, &band_of(&1.size)) |> Map.put(:any, length(rows))
    )
    |> assign(age_counts: age_counts(rows, now))
    |> refresh()
  end

  defp refresh(socket) do
    %{
      rows: rows,
      parents: parents,
      search_text: texts,
      kind: kind,
      post: post,
      band: band,
      age: age,
      sort: sort,
      query: query,
      shown: shown,
      loose_shown: loose_shown
    } = socket.assigns

    now = System.system_time(:second)
    lowered = String.downcase(query)

    filtered =
      Enum.filter(rows, fn row ->
        (kind == :all or row.kind == kind) and
          post_state(post, parents, row) and
          (band == :any or band_of(row.size) == band) and
          (age == :any or now - row.mtime < window(age)) and
          (query == "" or matches?(row, lowered, query, texts))
      end)

    %{bundles: bundles, loose: loose} = filtered |> sort(sort) |> bundle(parents)

    # Only the slice the page draws is an assign, and its edge is where the
    # counting stops: what lies past it is a button, not a number, so the
    # rows the reader never sees are not counted. The match count and its
    # bytes are the one total the header does show.
    {bundles, remaining} = Enum.split(bundles, shown)
    {loose, remaining_loose} = Enum.split(loose, loose_shown)

    {visible_count, visible_size} =
      Enum.reduce(filtered, {0, 0}, fn row, {count, bytes} -> {count + 1, bytes + row.size} end)

    assign(socket,
      bundles: bundles,
      more_bundles?: remaining != [],
      loose: loose,
      more_loose?: remaining_loose != [],
      visible_count: visible_count,
      visible_size: visible_size,
      filtering?: filtering?(socket.assigns)
    )
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
      arrived: row.mtime,
      rows: [],
      size: 0,
      id: row.hex
    }
  end

  # A bundle keeps the newest arrival among its blobs: the post may be
  # years old while the bytes only reached this machine an hour ago, and
  # that gap is the thing the two dates beside each post are for.
  defp add(bundle, row) do
    %{
      bundle
      | rows: [row | bundle.rows],
        size: bundle.size + row.size,
        arrived: max(bundle.arrived, row.mtime)
    }
  end

  # A ref in a post is base64; the store file is its digest in hex, so a
  # query is matched against both and the reader can paste either. Hex is
  # stored lowercase, so that half compares against the lowered query.
  # The words and author of the post that carried the blob are here too:
  # with nothing but digests on offer, "which post had the cat picture"
  # is the question this list is actually asked.
  defp matches?(row, lowered, query, texts) do
    String.contains?(row.hex, lowered) or String.contains?(row.ref, query) or
      String.contains?(Map.get(texts, row.ref, ""), lowered)
  end

  # One lowercase haystack per blob that a post carried, built when the
  # index lands rather than on every keystroke.
  defp search_text(parents) do
    Map.new(parents, fn {ref, value} -> {ref, haystack(normalize_parent(value))} end)
  end

  defp haystack(nil), do: ""

  defp haystack(post) do
    [post.text, display(post.author), post.author]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp display(author) when is_binary(author), do: Profile.display_name(author)
  defp display(_author), do: nil

  defp sort(rows, :newest), do: rows
  defp sort(rows, :oldest), do: Enum.reverse(rows)
  defp sort(rows, :largest), do: Enum.sort_by(rows, & &1.size, :desc)
  defp sort(rows, :smallest), do: Enum.sort_by(rows, & &1.size)

  defp post_state(:any, _parents, _row), do: true
  defp post_state(:attached, parents, row), do: Map.has_key?(parents, row.ref)
  defp post_state(:loose, parents, row), do: not Map.has_key?(parents, row.ref)

  defp band_of(size) when size < 100 * 1024, do: :small
  defp band_of(size) when size < 1024 * 1024, do: :medium
  defp band_of(_size), do: :large

  defp window(:day), do: 86_400
  defp window(:week), do: 7 * 86_400
  defp window(:month), do: 30 * 86_400
  defp window(:year), do: 365 * 86_400

  # The counts beside the time buttons: how many blobs arrived inside
  # each window, so a band that would show nothing says so before it is
  # pressed.
  defp age_counts(rows, now) do
    Enum.reduce(rows, %{any: length(rows), day: 0, week: 0, month: 0, year: 0}, fn row, acc ->
      age = now - row.mtime
      acc = if age < window(:day), do: Map.update!(acc, :day, &(&1 + 1)), else: acc
      acc = if age < window(:week), do: Map.update!(acc, :week, &(&1 + 1)), else: acc
      acc = if age < window(:month), do: Map.update!(acc, :month, &(&1 + 1)), else: acc
      if age < window(:year), do: Map.update!(acc, :year, &(&1 + 1)), else: acc
    end)
  end

  # -- page state --------------------------------------------------------

  defp default_filters do
    %{kind: :all, post: :any, band: :any, age: :any, sort: :newest, query: ""}
  end

  defp filters_from(params) do
    %{
      kind: find(@kinds, Map.get(params, "kind")) || :all,
      post: find(@attachments, Map.get(params, "post")) || :any,
      band: find(@bands, Map.get(params, "size")) || :any,
      age: find(@ages, Map.get(params, "age")) || :any,
      sort: find(@sorts, Map.get(params, "sort")) || :newest,
      query: params |> Map.get("q", "") |> to_string() |> String.trim()
    }
  end

  defp current_filters(assigns), do: Map.take(assigns, Map.keys(default_filters()))

  defp assign_filters(socket, filters), do: assign(socket, filters)

  defp find(values, value), do: Enum.find(values, &(Atom.to_string(&1) == value))

  defp filtering?(assigns) do
    assigns.kind != :all or assigns.post != :any or assigns.band != :any or
      assigns.age != :any or assigns.query != ""
  end

  # A default is left out of the URL, so the plain page is /blobs however
  # the reader got back to it.
  defp blobs_path(assigns) do
    params =
      [
        {"kind", param(assigns.kind, :all)},
        {"post", param(assigns.post, :any)},
        {"size", param(assigns.band, :any)},
        {"age", param(assigns.age, :any)},
        {"sort", param(assigns.sort, :newest)},
        {"q", assigns.query}
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    case params do
      [] -> "/blobs"
      params -> "/blobs?" <> URI.encode_query(params)
    end
  end

  defp param(value, default) when value == default, do: nil
  defp param(value, _default), do: Atom.to_string(value)

  defp push_url(socket), do: push_patch(socket, to: blobs_path(socket.assigns), replace: true)

  # -- labels ------------------------------------------------------------

  defp count(counts, kind), do: Map.get(counts, kind, 0)

  # Store totals run to six figures; grouped digits are read at a glance
  # where a run of them is not.
  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> then(&Regex.replace(~r/(\d{3})(?=\d)/, &1, "\\1,"))
    |> String.reverse()
  end

  # `{@kinds}` in a template is an assign lookup, not the module attribute.
  defp kinds, do: @kinds
  defp attachments, do: @attachments
  defp bands, do: @bands
  defp ages, do: @ages
  defp sorts, do: @sorts
  defp tiles, do: @tiles

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

  defp post_label(:any), do: "Any"
  defp post_label(:attached), do: "With a post"
  defp post_label(:loose), do: "No post"

  defp post_title(:any), do: "Every blob"
  defp post_title(:attached), do: "Only blobs a post carried"
  defp post_title(:loose), do: "Only blobs no post carried"

  defp attachment_count(_post_count, _loose_count, :any, total), do: total
  defp attachment_count(post_count, _loose_count, :attached, _total), do: post_count
  defp attachment_count(_post_count, loose_count, :loose, _total), do: loose_count

  defp band_label(:any), do: "Any"
  defp band_label(:small), do: "Small"
  defp band_label(:medium), do: "Medium"
  defp band_label(:large), do: "Large"

  defp band_title(:any), do: "Any size"
  defp band_title(:small), do: "Under 100 KB"
  defp band_title(:medium), do: "100 KB to 1 MB"
  defp band_title(:large), do: "1 MB and up"

  defp age_label(:any), do: "Any"
  defp age_label(:day), do: "24h"
  defp age_label(:week), do: "Week"
  defp age_label(:month), do: "Month"
  defp age_label(:year), do: "Year"

  defp age_title(:any), do: "Any time"
  defp age_title(:day), do: "Arrived in the last 24 hours"
  defp age_title(:week), do: "Arrived in the last 7 days"
  defp age_title(:month), do: "Arrived in the last 30 days"
  defp age_title(:year), do: "Arrived in the last year"

  defp sort_label(:newest), do: "Newest"
  defp sort_label(:oldest), do: "Oldest"
  defp sort_label(:largest), do: "Largest"
  defp sort_label(:smallest), do: "Smallest"

  defp size(bytes) when bytes < 1024, do: "#{bytes} B"

  defp size(bytes) when bytes < 1024 * 1024,
    do: "#{Float.round(bytes / 1024, 1)} KB"

  defp size(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GB"

  # The post that carried a blob, as the index recorded it. A map is what
  # a current sweep writes; a bare key is what one wrote before rows said
  # anything about their post, and reads as a post with nothing to add.
  defp parent(parents, ref), do: parents |> Map.get(ref) |> normalize_parent()

  defp normalize_parent(%{} = post), do: post
  defp normalize_parent(key) when is_binary(key), do: %{key: key, author: nil, text: nil, ts: nil}
  defp normalize_parent(_none), do: nil

  defp name(author) when is_binary(author), do: Profile.display_name(author)
  defp name(_author), do: "someone"

  defp profile_href(id), do: "/profile?id=" <> URI.encode_www_form(id)

  # Post routes carry the message id base64-encoded, the same way the
  # timeline and profile links do.
  defp post_path(key), do: "/post/" <> Base.url_encode64(key, padding: false)

  # A tile says what the blob is on hover, and which post it belongs to
  # when the reader wants the whole thing. A blob a post carried also
  # says when that post was published, against when the bytes arrived.
  defp tile_title(blob, posted \\ nil) do
    [
      "#{kind_word(blob.kind)} · #{size(blob.size)}",
      "arrived #{rel_time(blob.mtime * 1000)}",
      posted && "posted #{rel_time(posted)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp bundle_tiles(bundle, expanded) do
    if MapSet.member?(expanded, bundle.key), do: bundle.rows, else: Enum.take(bundle.rows, @tiles)
  end

  # What the header says the list covers: the posts shown, how much of the
  # store the filters match, and the bytes behind it.
  defp summary(assigns) do
    total = count(assigns.counts, :all)
    posts = length(assigns.bundles)

    blobs =
      if assigns.filtering?,
        do: "#{number(assigns.visible_count)} of #{number(total)} blobs",
        else: "#{number(total)} blobs"

    [
      if(posts > 0, do: "#{number(posts)} posts"),
      blobs,
      size(assigns.visible_size)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # The active filters, spelled the way the rail labels them, so a
  # narrowed list explains itself instead of looking like a small store.
  defp active_filters(assigns) do
    [
      if(assigns.kind != :all, do: kind_label(assigns.kind)),
      if(assigns.post != :any, do: post_label(assigns.post)),
      if(assigns.band != :any, do: band_title(assigns.band)),
      if(assigns.age != :any, do: age_title(assigns.age)),
      if(assigns.query != "", do: "“" <> assigns.query <> "”")
    ]
    |> Enum.reject(&is_nil/1)
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
            {number(count(@counts, :all))} blobs · {size(@total_size)}
          </p>
          <p class="px-4 pt-1 text-xs text-faint">
            Read from this machine's blob store. Each post reads with the blobs it
            carried; a blob no post carried stands on its own.
          </p>
        </div>

        <form
          :if={count(@counts, :all) > 0}
          id="blobs-search"
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
              placeholder="Digest, words or author"
              autocomplete="off"
              class="w-full rounded border border-edge bg-app px-2 py-0.5 text-xs text-paper transition placeholder:text-faint focus:border-dim focus:outline-none"
            />
            <p class="mt-1 text-[11px] leading-snug text-faint">
              A digest or ref, or the words and author of the post that carried the blob.
            </p>
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
              {kind_label(kind)} ({number(count(@counts, kind))})
            </button>
          </div>
        </div>

        <div :if={count(@counts, :all) > 0}>
          <Nav.rail_label>Post</Nav.rail_label>
          <div class="flex flex-wrap gap-1 px-4 pb-4">
            <button
              :for={post <- attachments()}
              type="button"
              phx-click="post"
              phx-value-post={post}
              title={post_title(post)}
              class={[
                "rounded border px-2 py-0.5 text-xs transition",
                @post == post && "border-ink bg-raised text-paper",
                @post != post && "border-edge text-muted hover:text-paper"
              ]}
            >
              {post_label(post)} ({number(
                attachment_count(@post_count, @loose_count, post, count(@counts, :all))
              )})
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
              {band_label(band)} ({number(Map.get(@band_counts, band, 0))})
            </button>
          </div>
        </div>

        <div :if={count(@counts, :all) > 0}>
          <Nav.rail_label>Arrived</Nav.rail_label>
          <div class="flex flex-wrap gap-1 px-4 pb-4">
            <button
              :for={age <- ages()}
              type="button"
              phx-click="age"
              phx-value-age={age}
              title={age_title(age)}
              class={[
                "rounded border px-2 py-0.5 text-xs transition",
                @age == age && "border-ink bg-raised text-paper",
                @age != age && "border-edge text-muted hover:text-paper"
              ]}
            >
              {age_label(age)} ({number(Map.get(@age_counts, age, 0))})
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

        <div :if={@filtering?} class="px-4 pb-6">
          <button
            type="button"
            phx-click="clear"
            class="w-full rounded border border-edge px-2 py-1 text-xs text-muted transition hover:bg-raised hover:text-paper"
          >
            Clear filters
          </button>
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
            {summary(assigns)}
          </p>

          <p
            :if={@filtering?}
            id="blobs-filters"
            class="mt-2 flex flex-wrap items-center gap-1.5 text-xs text-faint"
          >
            <span>Showing</span>
            <span
              :for={note <- active_filters(assigns)}
              class="rounded-full border border-edge px-2 py-0.5 text-muted"
            >
              {note}
            </span>
            <button
              type="button"
              phx-click="clear"
              class="text-sub underline decoration-dotted underline-offset-2 transition hover:text-paper"
            >
              Clear
            </button>
          </p>

          <p
            :if={count(@counts, :all) > 0 and @visible_count == 0}
            id="blobs-empty"
            class="mt-6 text-sm text-faint"
          >
            Nothing in the store matches these filters.
          </p>

          <div
            :if={@bundles != []}
            id="blob-posts"
            class="mt-2 divide-y divide-edge border-y border-edge"
          >
            <article
              :for={bundle <- @bundles}
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
                  <span :if={bundle.ts} title="When the post was published">
                    · posted <.age ts={bundle.ts} />
                  </span>
                  <span :if={bundle.arrived} title="When the bytes reached this machine">
                    · arrived <.age ts={bundle.arrived * 1000} />
                  </span>
                </div>

                <div class="flex shrink-0 items-baseline gap-2 text-faint">
                  <span>{number(length(bundle.rows))} blobs · {size(bundle.size)}</span>
                  <.link
                    navigate={post_path(bundle.key)}
                    title="Open the post that carried these blobs"
                    class="text-sub transition hover:text-paper"
                  >
                    Post →
                  </.link>
                </div>
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
                  title={tile_title(blob, bundle.ts)}
                  class="flex aspect-square items-center justify-center overflow-hidden rounded border border-edge bg-raised text-[10px] uppercase text-faint transition hover:border-dim"
                >
                  <img
                    :if={blob.kind == :image}
                    src={"/blob/" <> blob.hex}
                    alt=""
                    loading="lazy"
                    class="h-full w-full object-cover"
                  />
                  <span :if={blob.kind != :image} aria-hidden="true">{blob.kind}</span>
                  <span class="sr-only">{tile_title(blob, bundle.ts)}</span>
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
                  else: "Show all " <> number(length(bundle.rows))}
              </button>
            </article>
          </div>

          <div :if={@loose != []} id="blob-loose" class="mt-8">
            <p class="text-[11px] uppercase tracking-wider text-faint">
              No post carried these
            </p>

            <div class="mt-2 grid grid-cols-3 gap-2">
              <a
                :for={blob <- @loose}
                href={"/blob/" <> blob.hex}
                title={tile_title(blob) <> " — open the bytes"}
                class="relative flex aspect-square items-center justify-center overflow-hidden rounded border border-edge bg-raised text-[10px] uppercase text-faint transition hover:border-dim"
              >
                <img
                  :if={blob.kind == :image}
                  src={"/blob/" <> blob.hex}
                  alt=""
                  loading="lazy"
                  class="h-full w-full object-cover"
                />
                <span :if={blob.kind != :image} aria-hidden="true">{blob.kind}</span>
                <span class="sr-only">{tile_title(blob)} — open the bytes</span>
                <span
                  aria-hidden="true"
                  class="absolute bottom-1 right-1 rounded bg-app/90 px-1 text-[10px] normal-case tracking-normal text-paper"
                >
                  {size(blob.size)}
                </span>
              </a>
            </div>

            <button
              :if={@more_loose?}
              type="button"
              phx-click="more-loose"
              class="mt-3 rounded-md border border-edge px-3 py-1.5 text-xs text-sub transition hover:bg-raised hover:text-paper"
            >
              Show more
            </button>
          </div>

          <button
            :if={@more_bundles?}
            type="button"
            phx-click="more"
            class="mt-6 rounded-md border border-edge px-3 py-1.5 text-sm text-sub transition hover:bg-raised hover:text-paper"
          >
            Show more posts
          </button>
        </div>
      </section>
    </Shell.app>
    """
  end
end
