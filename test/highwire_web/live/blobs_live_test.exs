defmodule HighWireWeb.BlobsLiveTest do
  use HighWireWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias HighWire.BlobIndex

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

  defp publish(rows) do
    :persistent_term.put({BlobIndex, :rows}, rows)
    :persistent_term.put({BlobIndex, :counts}, %{all: length(rows)})
    :persistent_term.put({BlobIndex, :status}, :ready)
  end

  defp count(html, needle), do: length(String.split(html, needle)) - 1

  defp pos(html, needle) do
    {at, _length} = :binary.match(html, needle)
    at
  end
end
