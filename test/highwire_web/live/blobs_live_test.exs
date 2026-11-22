defmodule HighWireWeb.BlobsLiveTest do
  use HighWireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HighWire.BlobIndex
  alias HighWire.SSB.Profile

  setup do
    # The page reads the index out of `:persistent_term`, and the real
    # indexer would publish over whatever a test puts there. A dozing
    # process under its name keeps `ensure_started/0` satisfied, so the
    # rows a test publishes are the rows the page reads.
    :ok = Supervisor.terminate_child(HighWire.Supervisor, BlobIndex)

    start_supervised!(%{
      id: :blob_index_idle,
      start: {Agent, :start_link, [fn -> :ok end, [name: BlobIndex]]}
    })

    on_exit(fn -> Supervisor.restart_child(HighWire.Supervisor, BlobIndex) end)

    :ok
  end

  describe "filters in the URL" do
    test "a kind and an order in the URL pick the rows and their order", %{conn: conn} do
      publish([
        blob(1, kind: :image, size: 3_000),
        blob(2, kind: :image, size: 1_000),
        blob(3, kind: :image, size: 2_000),
        blob(4, kind: :file, size: 9_000)
      ])

      {:ok, _view, html} = live(conn, "/blobs?kind=image&sort=largest")

      assert html =~ ~s(id="blobs-filters")
      refute html =~ hex(4)

      # largest first, and the sort is the one the URL named
      assert pos(html, hex(1)) < pos(html, hex(3))
      assert pos(html, hex(3)) < pos(html, hex(2))
    end

    test "an arrival window cuts the list and says so", %{conn: conn} do
      publish([
        blob(1, ago: 60),
        blob(2, ago: 3 * 86_400)
      ])

      {:ok, _view, html} = live(conn, "/blobs?age=day")

      assert html =~ "Arrived in the last 24 hours"
      assert html =~ hex(1)
      refute html =~ hex(2)
    end

    test "a filter click rewrites the URL, and clearing leaves only the defaults", %{conn: conn} do
      publish([
        blob(1, size: 500),
        blob(2, size: 500_000),
        blob(3, size: 5_000_000)
      ])

      {:ok, view, html} = live(conn, "/blobs")

      # the plain page keeps its defaults out of the URL
      refute html =~ ~s(id="blobs-filters")

      render_click(view, "sort", %{"sort" => "smallest"})
      assert_patch(view, "/blobs?sort=smallest")

      html = render_click(view, "band", %{"band" => "small"})
      assert_patch(view, "/blobs?size=small&sort=smallest")

      # one blob in the band, and only that one
      assert html =~ hex(1)
      refute html =~ hex(2)

      render_click(view, "clear", %{})
      assert_patch(view, "/blobs")
      refute render(view) =~ ~s(id="blobs-filters")
    end
  end

  describe "paging the loose strip" do
    test "only the drawn slice crosses the wire, and more arrives on request", %{conn: conn} do
      publish(for i <- 1..40, do: blob(i))

      {:ok, view, html} = live(conn, "/blobs")

      # The store's forty loose blobs are sliced to the page's own size,
      # and the rest are only a button — nothing counts them.
      assert count(html, ~s(href="/blob/)) == 36
      assert html =~ "Show more"
      refute html =~ "to go"

      html = render_click(view, "more-loose", %{})
      assert count(html, ~s(href="/blob/)) == 40
      refute html =~ "Show more"
    end
  end

  describe "the author filter" do
    test "typing a few letters narrows to that writer, and the URL keeps them", %{conn: conn} do
      alice = blob(1)
      bob = blob(2)

      publish(
        [alice, bob],
        %{
          alice.ref => post_row("%alice#1.sha256", "@alice.local"),
          bob.ref => post_row("%bob#1.sha256", "@bob.local")
        }
      )

      {:ok, view, html} = live(conn, "/blobs?author=alice")

      assert html =~ "blob-post-" <> hex(1)
      refute html =~ "blob-post-" <> hex(2)

      render_change(view, "author", %{"author" => "bob"})
      assert_patch(view, "/blobs?author=bob")

      html = render(view)
      assert html =~ "blob-post-" <> hex(2)
      refute html =~ "blob-post-" <> hex(1)
    end

    test "the suggestions open with the writers who brought the most blobs", %{conn: conn} do
      alice = blob(1)
      bob_one = blob(2)
      bob_two = blob(3)

      publish(
        [alice, bob_one, bob_two],
        %{
          alice.ref => post_row("%alice#1.sha256", "@alice.local"),
          bob_one.ref => post_row("%bob#1.sha256", "@bob.local"),
          bob_two.ref => post_row("%bob#1.sha256", "@bob.local")
        }
      )

      {:ok, _view, html} = live(conn, "/blobs")

      assert html =~ ~s(id="blob-authors")

      # Bob carried two of the three blobs, so his name comes first.
      assert pos(html, ~s(value="#{Profile.display_name("@bob.local")}")) <
               pos(html, ~s(value="#{Profile.display_name("@alice.local")}"))
    end
  end

  describe "tiles" do
    test "a blob without a picture says what it is", %{conn: conn} do
      publish([blob(1, kind: :audio)])

      {:ok, _view, html} = live(conn, "/blobs")

      assert html =~ "Sound"
      refute html =~ ">audio<"
    end
  end

  describe "ordering" do
    test "posted order follows each post's own date, not when the bytes arrived", %{conn: conn} do
      arrived_first = blob(1)
      posted_newer = blob(2)

      publish(
        [arrived_first, posted_newer],
        %{
          arrived_first.ref => post_row("%old#1.sha256", "@a.local", ts: 1_600_000_000_000),
          posted_newer.ref => post_row("%new#1.sha256", "@a.local", ts: 1_700_000_000_000)
        }
      )

      {:ok, _view, html} = live(conn, "/blobs?sort=posted")

      assert pos(html, "blob-post-" <> hex(2)) < pos(html, "blob-post-" <> hex(1))
    end

    test "author order files posts under the name they are shown by", %{conn: conn} do
      zoe = blob(1)
      amy = blob(2)

      publish(
        [zoe, amy],
        %{
          zoe.ref => post_row("%zoe#1.sha256", "@zoe.local"),
          amy.ref => post_row("%amy#1.sha256", "@amy.local")
        }
      )

      {:ok, _view, html} = live(conn, "/blobs?sort=author")

      assert pos(html, "blob-post-" <> hex(2)) < pos(html, "blob-post-" <> hex(1))
    end
  end

  # A store row: minimal hex digest, its ref, what it is, how big, and how
  # long ago it reached the machine.
  defp blob(index, opts \\ []) do
    %{
      hex: hex(index),
      ref: "&blob#{index}.sha256",
      kind: Keyword.get(opts, :kind, :image),
      size: Keyword.get(opts, :size, 1_000),
      mtime: System.system_time(:second) - Keyword.get(opts, :ago, 0)
    }
  end

  defp hex(index), do: index |> Integer.to_string() |> String.pad_leading(64, "0")

  defp publish(rows, parents \\ %{}) do
    :persistent_term.put({BlobIndex, :rows}, rows)
    :persistent_term.put({BlobIndex, :parents}, parents)
    :persistent_term.put({BlobIndex, :counts}, %{all: length(rows)})
    :persistent_term.put({BlobIndex, :status}, :ready)
  end

  # The post that carried a blob, as the index records it.
  defp post_row(key, author, opts \\ []) do
    %{
      key: key,
      author: author,
      text: Keyword.get(opts, :text, "words"),
      ts: Keyword.get(opts, :ts, 1_700_000_000_000)
    }
  end

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  defp pos(html, needle) do
    {at, _length} = :binary.match(html, needle)
    at
  end
end
