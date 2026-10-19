defmodule HighWire.SuggesterTest do
  use ExUnit.Case, async: false

  alias HighWire.Suggester

  @me "@me=.ed25519"
  @a "@aaa=.ed25519"
  @b "@bbb=.ed25519"
  @xxx "@xxx=.ed25519"

  defp tmp_cache_path do
    dir = Path.join(System.tmp_dir!(), "suggester-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "suggestions.json")
  end

  defp follow(from, to, following \\ true) do
    %{
      "key" => "c-#{from}-#{to}-#{following}",
      "value" => %{
        "author" => from,
        "content" => %{"type" => "contact", "contact" => to, "following" => following}
      }
    }
  end

  defp wait_until(fun, tries \\ 200) do
    cond do
      fun.() -> true
      tries <= 0 -> false
      true -> Process.sleep(5) && wait_until(fun, tries - 1)
    end
  end

  defp start(cache, opts \\ []) do
    start_supervised!(
      {Suggester, Keyword.merge([name: :test_suggester, cache_path: cache], opts)}
    )
  end

  test "loads the persisted cache at startup, dropping rows with no id" do
    cache = tmp_cache_path()

    File.write!(
      cache,
      Jason.encode!([
        %{"id" => "@saved=.ed25519", "followers" => 5},
        %{"followers" => 3}
      ])
    )

    start(cache)

    assert Suggester.get_suggestions(:test_suggester) == [
             %{"id" => "@saved=.ed25519", "followers" => 5}
           ]
  end

  test "ranks handed inputs and writes the result to the disk cache" do
    cache = tmp_cache_path()
    start(cache)

    assert Suggester.get_suggestions(:test_suggester) == []

    # @xxx (whom we follow) endorses @a; @b has no endorsement.
    contacts = [follow(@xxx, @a), follow(@xxx, @b, false)]
    Suggester.cast_inputs(contacts, [@me, @xxx], @me, nil, :test_suggester)

    assert wait_until(fn -> Suggester.get_suggestions(:test_suggester) != [] end)

    assert Suggester.get_suggestions(:test_suggester) == [
             %{"id" => @a, "followers" => 1}
           ]

    assert wait_until(fn -> File.exists?(cache) end)
    assert {:ok, [%{"id" => @a}]} = cache |> File.read!() |> Jason.decode()
  end

  test "regenerates only when the inputs change" do
    cache = tmp_cache_path()
    start(cache)

    Suggester.cast_inputs([follow(@xxx, @a)], [@me, @xxx], @me, nil, :test_suggester)

    assert wait_until(fn ->
             Suggester.get_suggestions(:test_suggester) == [
               %{"id" => @a, "followers" => 1}
             ]
           end)

    # Following @b removes @b's endorsement weight only if we no longer
    # follow @xxx; here we instead start following @a itself, so @a is no
    # longer a candidate.
    Suggester.cast_inputs([follow(@xxx, @a)], [@me, @xxx, @a], @me, nil, :test_suggester)
    assert wait_until(fn -> Suggester.get_suggestions(:test_suggester) == [] end)

    # A brand-new graph surfaces a fresh candidate.
    Suggester.cast_inputs([follow(@a, @b)], [@me, @a], @me, nil, :test_suggester)

    assert wait_until(fn ->
             Suggester.get_suggestions(:test_suggester) == [
               %{"id" => @b, "followers" => 1}
             ]
           end)
  end

  test "the store's about set narrows the rail, and a new set re-ranks" do
    cache = tmp_cache_path()
    start(cache)

    contacts = [follow(@xxx, @a), follow(@xxx, @b)]

    Suggester.cast_inputs(contacts, [@me, @xxx], @me, nil, :test_suggester)
    assert wait_until(fn -> length(Suggester.get_suggestions(:test_suggester)) == 2 end)

    # The about pass lands: only @b survives the filter — and the new
    # snapshot re-ranks even though the graph itself did not move.
    Suggester.cast_inputs(contacts, [@me, @xxx], @me, MapSet.new([@b]), :test_suggester)

    assert wait_until(fn ->
             Suggester.get_suggestions(:test_suggester) == [%{"id" => @b, "followers" => 1}]
           end)
  end

  test "refresh serves the reserved set, then a freshly ranked pair" do
    cache = tmp_cache_path()
    start(cache)

    # Nine candidates behind one follower: the ranking draws five of
    # nine, shuffled, so consecutive sets differ.
    candidates = for i <- 1..9, do: "@f#{i}=.ed25519"
    contacts = Enum.map(candidates, &follow(@xxx, &1))
    Suggester.cast_inputs(contacts, [@me, @xxx], @me, nil, :test_suggester)

    assert wait_until(fn -> length(Suggester.get_suggestions(:test_suggester)) == 5 end)
    first = Suggester.get_suggestions(:test_suggester)

    # Reads are pure — the reserved set does not rotate in on its own.
    assert Suggester.get_suggestions(:test_suggester) == first

    # The first refresh swaps in the set the initial ranking held in
    # reserve, without waiting on any task.
    assert :ok = Suggester.refresh(:test_suggester)
    assert wait_until(fn -> Suggester.get_suggestions(:test_suggester) != first end)
    second = Suggester.get_suggestions(:test_suggester)
    assert length(second) == 5

    # The queue is dry now, so the next refresh is owed a set from the
    # background ranking it kicks; it lands the same way.
    assert :ok = Suggester.refresh(:test_suggester)
    assert wait_until(fn -> Suggester.get_suggestions(:test_suggester) != second end)
    third = Suggester.get_suggestions(:test_suggester)

    assert Enum.uniq_by(third, & &1["id"]) |> length() == 5
    assert Enum.all?(third, &(&1["id"] in candidates))
  end

  test "the prefetched reserve does not grow without bound" do
    cache = tmp_cache_path()
    start(cache)

    candidates = for i <- 1..9, do: "@f#{i}=.ed25519"
    contacts = Enum.map(candidates, &follow(@xxx, &1))

    # Every snapshot that differs from the last ranks again, and a
    # ranking that needs no serve appends its spare set to the reserve.
    # Nothing consumes it here (a refresh is what does), so without a cap
    # it would grow for as long as the app runs.
    for i <- 1..6 do
      Suggester.cast_inputs(
        contacts,
        [@me, @xxx],
        @me,
        MapSet.new(["@k#{i}=.ed25519"]),
        :test_suggester
      )

      assert wait_until(fn ->
               st = :sys.get_state(:test_suggester)
               st.task_ref == nil and st.pending == nil
             end)
    end

    assert length(:sys.get_state(:test_suggester).ready) <= 2
  end

  test "a ranking that dies while a refresh is owed is retried, not dropped" do
    cache = tmp_cache_path()
    start(cache, retry_ms: 20)

    contacts = [follow(@xxx, @a)]
    Suggester.cast_inputs(contacts, [@me, @xxx], @me, nil, :test_suggester)
    assert wait_until(fn -> Suggester.get_suggestions(:test_suggester) != [] end)

    # The moment a failed ranking leaves behind: no task, a refresh
    # still owed. New inputs only arrive by cast, so if this debt is not
    # retried the click is never served. A stand-in ref keeps the case
    # deterministic (the previous ranking has already landed).
    ref = make_ref()
    :sys.replace_state(:test_suggester, fn st -> %{st | task_ref: ref, wants_serve: true} end)

    send(:test_suggester, {:DOWN, ref, :process, self(), :boom})

    assert wait_until(fn -> :sys.get_state(:test_suggester).wants_serve == false end)
  end
end
