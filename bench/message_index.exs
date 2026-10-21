# Compares the two read backings the MessageIndex has had: the DETS
# file the render path reads today, and the ETS mirror that used to sit
# in front of it. Every message the timeline is about to show asks the
# index one question, so what matters is per-lookup latency at realistic
# row counts, per-lookup allocation, and how each backing behaves when
# several readers ask at once.
#
# Rows carry the real shapes: a tombstone row maps a deleted message's
# key to the author who deleted it, an edit row maps an edited target to
# its thread root, and every third row is an edit. Both backings are
# filled from the same row list, so the comparison is like for like.
#
#   mix run bench/message_index.exs

defmodule MessageIndexBench do
  @dets :bench_message_index
  @probes 1_000

  defp hex(n), do: :crypto.strong_rand_bytes(n) |> Base.encode16(case: :lower)
  defp msg_key, do: "%" <> hex(32) <> ".sha256"
  defp feed_id, do: "@" <> hex(32) <> ".ed25519"

  defp rows(n) do
    for i <- 1..n do
      if rem(i, 3) == 0,
        do: {{:edit, msg_key()}, {:edit, msg_key()}},
        else: {{:deleted, msg_key()}, {:deleted, feed_id()}}
    end
  end

  # Probes are pregenerated and walked in a fixed cycle, so nothing but
  # the lookup itself sits inside a measured invocation. Hits and misses
  # get their own cursors; a miss probe is a key no row carries.
  defp probe_cursor(probes) do
    counter = :atomics.new(1, [])

    fn ->
      i = :atomics.add_get(counter, 1, 1)
      Enum.at(probes, rem(i, length(probes)))
    end
  end

  defp probes(keys, n), do: for(_ <- 1..n, do: Enum.at(keys, :rand.uniform(length(keys)) - 1))
  defp miss_probes(n), do: for(_ <- 1..n, do: {:deleted, msg_key()})

  defp open_dets(rows) do
    path = "tmp/bench_message_index.dets"
    File.rm_rf!(path)

    {:ok, @dets} =
      :dets.open_file(@dets,
        file: String.to_charlist(path),
        type: :set,
        keypos: 1,
        repair: true,
        access: :read_write
      )

    :dets.insert(@dets, rows)
    :dets.sync(@dets)
    path
  end

  defp open_ets(rows) do
    tid = :ets.new(:bench_message_index_mirror, [:set, :protected, read_concurrency: true])
    :ets.insert(tid, rows)
    tid
  end

  defp report_footprint(n, path, tid) do
    dets_kb = File.stat!(path).size / 1024
    ets_kb = :ets.info(tid, :memory) * :erlang.system_info(:wordsize) / 1024

    IO.puts("""
    \n== #{n} rows: resident footprint ==
    dets file  #{Float.round(dets_kb, 1)} KB
    ets mirror #{Float.round(ets_kb, 1)} KB
    """)
  end

  defp bench_size(n) do
    rows = rows(n)
    keys = Enum.map(rows, &elem(&1, 0))
    path = open_dets(rows)
    tid = open_ets(rows)
    report_footprint(n, path, tid)

    next_hit = probe_cursor(probes(keys, @probes))
    next_miss = probe_cursor(miss_probes(@probes))

    IO.puts("== #{n} rows: single reader ==")

    Benchee.run(
      %{
        "dets.lookup hit" => fn -> :dets.lookup(@dets, next_hit.()) end,
        "dets.lookup miss" => fn -> :dets.lookup(@dets, next_miss.()) end,
        "ets.lookup hit" => fn -> :ets.lookup(tid, next_hit.()) end,
        "ets.lookup miss" => fn -> :ets.lookup(tid, next_miss.()) end
      },
      warmup: 1,
      time: 3
    )

    IO.puts("== #{n} rows: 8 concurrent readers (hits) ==")

    Benchee.run(
      %{
        "dets.lookup hit" => fn -> :dets.lookup(@dets, next_hit.()) end,
        "ets.lookup hit" => fn -> :ets.lookup(tid, next_hit.()) end
      },
      warmup: 1,
      time: 3,
      parallel: 8
    )

    :dets.close(@dets)
    :ets.delete(tid)
  end

  def run do
    IO.puts("wordsize #{:erlang.system_info(:wordsize)} bytes")
    Enum.each([1_000, 10_000, 100_000], &bench_size/1)
  end
end

MessageIndexBench.run()
