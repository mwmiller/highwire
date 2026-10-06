defmodule HighWire.Markdown do
  @moduledoc """
  The Patchwork/marky-markdown variant: CommonMark + the GFM bits SSB
  posts use (tables, strikethrough, bare-URL autolinks, emoji shortcodes),
  rendered with MDEx (comrak), plus the SSB conventions comrak lacks:

    * bare `&<base64>.sha256` refs and `![](&…)` / `[](&…)` targets
      resolve to local blob URLs (`/blob/<hex>`, cache-busted with `?v=`
      when a blob revision is given)
    * `@<feed-id>.ed25519` mentions link to that feed's identity view
    * `%<base64>.sha256` message refs — bare or `[](…)` targets — link
      to the post viewer at `/post/<url-safe key>`
    * unsafe URL schemes are unwrapped to plain text
    * external links open in a new tab (`target="_blank" rel="noopener"`)
    * raw HTML never renders (comrak `unsafe: false`)

  Output is safe by construction (comrak escapes all text), so callers
  can `raw/1` it.
  """

  alias HighWire.Blob
  alias MDEx.{Code, CodeBlock, Document, HtmlBlock, Image, Link, Raw, Text}

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
    ctx = %{rev: Keyword.get(opts, :blob_rev), in_link: false}

    body
    |> MDEx.parse_document!(extension: @extension)
    |> walk_document(ctx)
    |> MDEx.to_html!(render: @render)
    |> String.replace("<!-- raw HTML omitted -->", "")
    |> String.replace("<img ", ~s|<img loading="lazy" onerror="this.remove()" |)
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
    case resolve_src(url, ctx.rev) do
      {:ok, src} ->
        %{node | url: src}

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

  defp resolve_src(url, _rev) when url in ["", nil], do: :error

  defp resolve_src(url, rev) do
    cond do
      String.starts_with?(url, "&") and match?({:ok, _}, Blob.ref_to_hex(url)) ->
        {:ok, Blob.url(url) |> bust(rev)}

      String.starts_with?(url, "/") ->
        {:ok, bust(url, rev)}

      url_scheme(url) in ["http", "https"] ->
        {:ok, url}

      true ->
        :error
    end
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
