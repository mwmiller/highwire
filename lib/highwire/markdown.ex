defmodule HighWire.Markdown do
  @moduledoc """
  The Patchwork/marky-markdown variant: CommonMark + the GFM bits SSB
  posts use (tables, strikethrough, bare-URL autolinks, emoji shortcodes),
  rendered with MDEx (comrak), plus the SSB conventions comrak lacks:

    * bare `&<base64>.sha256` refs and `![](&…)` / `[](&…)` targets
      resolve to local blob URLs (`/blob/<hex>`, cache-busted with `?v=`
      when a blob revision is given)
    * a blob in an image slot rides as what its bytes say: a picture
      stays a picture, a recording or a film becomes a player, anything
      else a link to the file
    * `@<feed-id>.ed25519` mentions link to that feed's identity view
    * `%<base64>.sha256` message refs — bare or `[](…)` targets — link
      to the post viewer at `/post/<url-safe key>`
    * unsafe URL schemes are unwrapped to plain text
    * external links open in a new tab (`target="_blank" rel="noopener"`)
    * raw HTML never renders (comrak `unsafe: false`)

  Output is safe by construction (comrak escapes all text), so callers
  can `raw/1` it.
  """

  use Memoize

  alias HighWire.Blob
  alias MDEx.{Code, CodeBlock, Document, HtmlBlock, Image, Link, Raw, Text}

  # 31 minutes, in milliseconds.
  @ttl_ms 1_860_000

  @extension [table: true, strikethrough: true, autolink: true, shortcodes: true]
  @render [unsafe: false, hardbreaks: true]

  # 32 digest bytes → 43 base64 data chars + optional '=' padding.
  @blob_re ~r/&[A-Za-z0-9+\/]{43}={0,2}\.sha256/
  @mention_re ~r/@[A-Za-z0-9+\/]{43}={0,2}\.ed25519/
  @msg_re ~r/%[A-Za-z0-9+\/]{43}={0,2}\.sha256/
  @msg_id_re ~r/\A%[A-Za-z0-9+\/]{43}={0,2}\.sha256\z/

  @doc """
  Render a post body to safe HTML. Options: `blob_rev` (integer) busts
  `?v=` caches on local blob image URLs.
  """
  @spec to_html(String.t(), keyword()) :: String.t()
  def to_html(body, opts \\ []) when is_binary(body) do
    render(body, Keyword.get(opts, :blob_rev))
  end

  @doc """
  The marker a preview shows for a media reference: what the bytes are.

  A preview says what a reply is about, so the media it carries is named
  rather than shown.
  """
  @spec marker(binary()) :: binary()
  def marker(ref) when is_binary(ref) do
    case Blob.media_type(ref) do
      :audio -> "[audio]"
      :video -> "[video]"
      :file -> "[file]"
      _kind -> "[image]"
    end
  end

  # Pure in (body, rev) and re-run on every timeline render, so memoize
  # it: the feed rebuilds rows it has already drawn on nearly every
  # broadcast, and the comrak pass is the expensive part. The cache is
  # bounded by bytes and entries expire, so a stale `rev`'d body does
  # not linger.
  defmemop render(body, rev), expires_in: @ttl_ms do
    ctx = %{rev: rev, in_link: false}

    body
    |> MDEx.parse_document!(extension: @extension)
    |> walk_document(ctx)
    |> MDEx.to_html!(render: @render)
    |> String.replace("<!-- raw HTML omitted -->", "")
    |> String.replace("<img ", ~s|<img loading="lazy" onerror="this.remove()" |)
    |> media_players(rev)
    # comrak drops node attrs on links, so target/rel are injected on
    # render. http(s) only: mailto and local links stay in-app.
    |> String.replace(~s|<a href="https://|, ~s|<a target="_blank" rel="noopener" href="https://|)
    |> String.replace(~s|<a href="http://|, ~s|<a target="_blank" rel="noopener" href="http://|)
  end

  defp walk_document(%Document{nodes: nodes} = doc, ctx) do
    %{doc | nodes: flat_walk(nodes, ctx)}
  end

  defp flat_walk(nodes, ctx), do: Enum.flat_map(nodes, &List.wrap(walk(&1, ctx)))

  # Never descend into code: its literal is not markdown.
  defp walk(%Code{} = node, _ctx), do: node
  defp walk(%CodeBlock{} = node, _ctx), do: node
  defp walk(%HtmlBlock{} = node, _ctx), do: node
  defp walk(%Raw{} = node, _ctx), do: node

  defp walk(%Text{literal: lit} = node, %{in_link: false}) do
    if lit =~ @blob_re or lit =~ @mention_re or lit =~ @msg_re, do: linkify(lit), else: node
  end

  defp walk(%Text{} = node, _ctx), do: node

  defp walk(%Link{url: url, nodes: children} = node, ctx) do
    child_ctx = %{ctx | in_link: true}

    case resolve_href(url) do
      {:ok, href, _external?} ->
        %{node | url: href, nodes: flat_walk(children, child_ctx)}

      :error ->
        flat_walk(children, child_ctx)
    end
  end

  defp walk(%Image{url: url, nodes: children} = node, ctx) do
    case image_src(url, ctx.rev) do
      {:image, src} ->
        %{node | url: src}

      {:player, kind, hex} ->
        %Link{url: media_href(kind, hex), nodes: media_label(children, url)}

      {:file, src} ->
        %Link{url: src, nodes: media_label(children, url)}

      :error ->
        flat_walk(children, ctx)
    end
  end

  defp walk(%{nodes: children} = node, ctx), do: %{node | nodes: flat_walk(children, ctx)}
  defp walk(node, _ctx), do: node

  # SSB-specific linkification of text nodes (bare refs / mentions).
  defp linkify(text) do
    @blob_re
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn piece ->
      if Regex.match?(@blob_re, piece), do: blob_node(piece), else: mentions(piece)
    end)
  end

  defp mentions(text) do
    @mention_re
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn
      "" ->
        []

      piece ->
        if Regex.match?(@mention_re, piece) do
          [%Link{url: profile_href(piece), nodes: [%Text{literal: piece}]}]
        else
          message_refs(piece)
        end
    end)
  end

  defp message_refs(text) do
    @msg_re
    |> Regex.split(text, include_captures: true)
    |> Enum.flat_map(fn
      "" ->
        []

      piece ->
        if Regex.match?(@msg_re, piece) do
          [%Link{url: post_href(piece), nodes: [%Text{literal: piece}]}]
        else
          [%Text{literal: piece}]
        end
    end)
  end

  defp blob_node(ref) do
    case Blob.url(ref) do
      nil -> [%Text{literal: ref}]
      href -> [%Link{url: href, nodes: [%Text{literal: ref}]}]
    end
  end

  defp profile_href(id), do: "/profile?id=" <> URI.encode_www_form(id)

  # The route takes the raw key url-safe base64'd: message ids contain
  # "/" and cannot ride in a path as-is (same encoding as open-post).
  defp post_href(key), do: "/post/" <> Base.url_encode64(key, padding: false)

  defp resolve_href(url) do
    cond do
      msg = message_id(url) ->
        {:ok, post_href(msg), false}

      Regex.match?(~r/\A@[A-Za-z0-9+\/]{43}={0,2}\.ed25519\z/, url) ->
        {:ok, profile_href(url), false}

      String.starts_with?(url, "&") and match?({:ok, _}, Blob.ref_to_hex(url)) ->
        {:ok, Blob.url(url), false}

      url in ["", "#"] or String.starts_with?(url, "/") ->
        {:ok, url, false}

      scheme = url_scheme(url) ->
        resolve_scheme(url, scheme)

      true ->
        {:ok, url, false}
    end
  end

  # http(s) opens externally, mailto stays a plain mailto, anything
  # else with a scheme (javascript:, data:, ftp:) is unwrapped to text.
  defp resolve_scheme(url, scheme) do
    if scheme in ["http", "https", "mailto"] do
      {:ok, url, scheme != "mailto"}
    else
      :error
    end
  end

  # SSB posts put media in the image slot: `![alt](&<blob>)`. What the
  # bytes are decides how it rides — a picture stays a picture, a
  # recording or a film becomes a player, anything else a link to the
  # file. A blob whose bytes have not arrived stays a picture: the
  # route answers those with a placeholder.
  defp image_src(url, rev) do
    case Blob.ref_to_hex(url) do
      {:ok, hex} -> blob_src(hex, url, rev)
      :error -> other_src(url, rev)
    end
  end

  defp blob_src(hex, url, rev) do
    case Blob.media_type(url) do
      :audio -> {:player, "audio", hex}
      :video -> {:player, "video", hex}
      :file -> {:file, bust("/blob/" <> hex, rev)}
      _kind -> {:image, bust("/blob/" <> hex, rev)}
    end
  end

  defp other_src(url, rev) do
    case resolve_src(url, rev) do
      {:ok, src} -> {:image, src}
      :error -> :error
    end
  end

  defp resolve_src(url, _rev) when url in ["", nil], do: :error

  defp resolve_src(url, rev) do
    cond do
      String.starts_with?(url, "/") ->
        {:ok, bust(url, rev)}

      url_scheme(url) in ["http", "https"] ->
        {:ok, url}

      true ->
        :error
    end
  end

  # The sentinel the walk leaves behind for a player: comrak renders it
  # as an ordinary link, and the render pass swaps it for the player
  # element with the file's own link beside it.
  defp media_href(kind, hex), do: "blobmedia:" <> kind <> ":" <> hex

  # A post that names no file still gets a label: the reference itself.
  defp media_label(children, ref) do
    case children do
      [%Text{literal: ""}] -> [%Text{literal: ref}]
      [] -> [%Text{literal: ref}]
      _ -> children
    end
  end

  # A blob that is not a picture cannot ride in an <img>: the browser
  # would fail to decode it and the reference would vanish with it.
  defp media_players(html, rev) do
    Regex.replace(
      ~r/<a href="blobmedia:(audio|video):([0-9a-f]{64})"([^>]*)>/,
      html,
      fn _match, kind, hex, rest ->
        url = bust("/blob/" <> hex, rev)

        ~s(<#{kind} controls preload="none" src="#{url}"></#{kind}><a href="#{url}"#{rest}>)
      end
    )
  end

  defp bust(path, nil), do: path
  defp bust(path, rev), do: path <> "?v=" <> Integer.to_string(rev)

  defp url_scheme(url) do
    case Regex.run(~r{\A([a-zA-Z][a-zA-Z0-9+.-]*):}, url) do
      [_, scheme] -> String.downcase(scheme)
      nil -> nil
    end
  end

  # Accept the id raw or percent-escaped (comrak may normalize "/" in a
  # link destination to %2F); anything else is not a message ref.
  defp message_id(url) do
    if Regex.match?(@msg_id_re, url) do
      url
    else
      decoded = URI.decode(url)
      if decoded != url and Regex.match?(@msg_id_re, decoded), do: decoded
    end
  end
end
