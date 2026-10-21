defmodule HighWire.MarkdownTest do
  use ExUnit.Case, async: true

  alias HighWire.Markdown

  defp blob_ref(seed) do
    "&" <> Base.encode64(:crypto.hash(:sha256, seed)) <> ".sha256"
  end

  defp hex(seed) do
    Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
  end

  test "the Patchwork markdown variant: headings, emphasis, lists, code" do
    html =
      Markdown.to_html("## [erlbutt](https://github.com/cmoid/erlbutt)\n\n**b** *i* ~~x~~ `c`")

    assert html =~
             ~s(<h2><a target="_blank" rel="noopener" href="https://github.com/cmoid/erlbutt">erlbutt</a></h2>)

    assert html =~ "<strong>b</strong>"
    assert html =~ "<em>i</em>"
    assert html =~ "<del>x</del>"
    assert html =~ "<code>c</code>"
  end

  test "single newlines become hard line breaks (SSB posts are line-broken)" do
    assert Markdown.to_html("one\ntwo") =~ "one<br />"
  end

  test "tables and strikethrough are on" do
    html = Markdown.to_html("| a | b |\n|---|---|\n| 1 | 2 |")
    assert html =~ "<table>"
    assert html =~ "<td>1</td>"
  end

  test "markdown images resolve blob refs with the blob revision" do
    ref = blob_ref("img")
    html = Markdown.to_html("![](#{ref})", blob_rev: 9)

    assert html =~ ~s(src="/blob/#{hex("img")}?v=9")
    assert html =~ ~s(loading="lazy")
    assert html =~ ~s|onerror="this.remove()"|
  end

  test "remote images pass through; invalid image targets fall back to alt text" do
    assert Markdown.to_html("![](https://x.test/a.png)") =~ ~s(src="https://x.test/a.png")
    assert Markdown.to_html("![](/not-a-scheme)") =~ ~s(src="/not-a-scheme")
    refute Markdown.to_html("![gone](javascript:alert(1))") =~ "<img"
    refute Markdown.to_html("![gone](nope)") =~ "<img"
  end

  test "a blob that is a recording becomes a player, not a broken picture" do
    hex = put_blob("song", <<0xFF, 0xFB, "frame">>)
    html = Markdown.to_html("![audio:song.mp3](#{blob_ref("song")})", blob_rev: 4)

    assert html =~ ~s(<audio controls preload="none" src="/blob/#{hex}?v=4"></audio>)
    assert html =~ ~s(<a href="/blob/#{hex}?v=4">audio:song.mp3</a>)
    refute html =~ "<img"
  end

  test "a blob that is a film becomes a player" do
    hex = put_blob("clip", <<0x1A, 0x45, 0xDF, 0xA3, "bytes">>)
    html = Markdown.to_html("![the clip](#{blob_ref("clip")})", blob_rev: 2)

    assert html =~ ~s(<video controls preload="none" src="/blob/#{hex}?v=2"></video>)
    refute html =~ "<img"
  end

  test "a blob that is neither picture nor recording is a link to the file" do
    hex = put_blob("form", "%PDF-1.4 rest")
    html = Markdown.to_html("![the form](#{blob_ref("form")})", blob_rev: 1)

    assert html =~ ~s(<a href="/blob/#{hex}?v=1">the form</a>)
    refute html =~ "<img"
  end

  test "a picture stays a picture" do
    hex = put_blob("photo", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "bytes">>)
    html = Markdown.to_html("![a photo](#{blob_ref("photo")})", blob_rev: 1)

    assert html =~ ~s(src="/blob/#{hex}?v=1")
    refute html =~ "<audio"
  end

  test "a recording with no name is still named after its reference" do
    hex = put_blob("nameless", <<0xFF, 0xFB, "frame">>)
    html = Markdown.to_html("![](#{blob_ref("nameless")})", blob_rev: 1)

    assert html =~ ~s(<a href="/blob/#{hex}?v=1">)
    # the reference is the label, escaped the way text is
    assert html =~ ~s(>#{String.replace(blob_ref("nameless"), "&", "&amp;")}</a>)
  end

  test "the marker a preview shows names what the media is" do
    put_blob("marker-audio", <<0xFF, 0xFB, "frame">>)
    put_blob("marker-image", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "bytes">>)

    assert Markdown.marker(blob_ref("marker-audio")) == "[audio]"
    assert Markdown.marker(blob_ref("marker-image")) == "[image]"
    assert Markdown.marker(blob_ref("marker-gone")) == "[image]"
  end

  # A blob on disk, so the renderer can tell what its bytes are.
  defp put_blob(seed, bytes) do
    hex = hex(seed)
    path = Path.join(HighWire.Blob.cache_root(), hex)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    hex
  end

  test "bare blob refs become local blob links" do
    ref = blob_ref("bare")
    html = Markdown.to_html("see #{ref}")

    assert html =~ ~s(<a href="/blob/#{hex("bare")}">)
  end

  test "@feed-id mentions link to the identity view" do
    id = "@DgsA6kZleyiuliE8SeUDtF3Slw3f92tUaT2xjH5cNg8=.ed25519"
    html = Markdown.to_html("hi #{id}")

    assert html =~ ~s(<a href="/profile?id=#{URI.encode_www_form(id)}">)
  end

  test "composer markdown mentions render the user's sigil inside the link" do
    id = "@DgsA6kZleyiuliE8SeUDtF3Slw3f92tUaT2xjH5cNg8=.ed25519"
    href = ~s(href="/profile?id=#{URI.encode_www_form(id)}")

    # The sigil rides inside the brackets: [@Name](@id) and
    # [~Name](@id) link the whole "sigil + name" text to the profile.
    assert Markdown.to_html("[@Alice](#{id})") =~ ~s(<a #{href}>@Alice</a>)
    assert Markdown.to_html("[~Alice](#{id})") =~ ~s(<a #{href}>~Alice</a>)

    # A paragraph full of ~ mentions never opens ~…~ strikethrough.
    html = Markdown.to_html("[~Alice](#{id}) and [~Bob](#{id})")
    assert html =~ ">~Bob</a>"
    refute html =~ "<del>"

    # A display name with a bracket survives the link text intact
    # (the composer escapes it before it reaches the draft).
    assert Markdown.to_html("[@A\\]B](#{id})") =~ ">@A]B</a>"
  end

  test "%message refs resolve to the post viewer, bare or as link targets" do
    key = "%" <> Base.encode64(:crypto.hash(:sha256, "post")) <> ".sha256"
    path = "/post/" <> Base.url_encode64(key, padding: false)

    assert Markdown.to_html("[see this](#{key})") =~ ~s(href="#{path}")
    assert Markdown.to_html("see #{key}") =~ ~s(href="#{path}")
    refute Markdown.to_html("[see this](#{key})") =~ "target"
  end

  test "message refs whose slash got percent-escaped still resolve" do
    key = "%" <> Base.encode64(:crypto.hash(:sha256, "slash/key")) <> ".sha256"
    escaped = String.replace(key, "/", "%2F")
    path = "/post/" <> Base.url_encode64(key, padding: false)

    assert Markdown.to_html("[see](#{escaped})") =~ ~s(href="#{path}")
  end

  test "raw HTML never renders; javascript: links are unwrapped" do
    refute Markdown.to_html("<script>alert(1)</script>") =~ "<script"
    refute Markdown.to_html("[x](javascript:alert(1))") =~ "javascript:"
    assert Markdown.to_html("[x](javascript:alert(1))") =~ "x"
  end

  test "external links open in a new tab; local links stay in-app" do
    assert Markdown.to_html("[a](https://x.test)") =~ ~s(target="_blank")
    assert Markdown.to_html("[a](http://x.test)") =~ ~s(target="_blank")
    refute Markdown.to_html("[a](/profile?id=%40x)") =~ "target"
  end

  test "emoji shortcodes render" do
    assert Markdown.to_html(":smile:") =~ "😄"
  end
end
