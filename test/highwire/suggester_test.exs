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

  defp start(cache) do
    start_supervised!({Suggester, name: :test_suggester, cache_path: cache})
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
    Suggester.cast_inputs(contacts, [@me, @xxx], @me, :test_suggester)

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

    Suggester.cast_inputs([follow(@xxx, @a)], [@me, @xxx], @me, :test_suggester)

    assert wait_until(fn ->
             Suggester.get_suggestions(:test_suggester) == [
               %{"id" => @a, "followers" => 1}
             ]
           end)

    # Following @b removes @b's endorsement weight only if we no longer
    # follow @xxx; here we instead start following @a itself, so @a is no
    # longer a candidate.
    Suggester.cast_inputs([follow(@xxx, @a)], [@me, @xxx, @a], @me, :test_suggester)
    assert wait_until(fn -> Suggester.get_suggestions(:test_suggester) == [] end)

    # A brand-new graph surfaces a fresh candidate.
    Suggester.cast_inputs([follow(@a, @b)], [@me, @a], @me, :test_suggester)

    assert wait_until(fn ->
             Suggester.get_suggestions(:test_suggester) == [
               %{"id" => @b, "followers" => 1}
             ]
           end)
  end
end
