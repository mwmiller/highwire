defmodule HighWire.Backgammon.ChainTest do
  use ExUnit.Case, async: true

  alias HighWire.Backgammon.Chain

  defp short(n \\ 8), do: %{"length" => n}
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  describe "spec/0" do
    test "carries the chain length and nothing else" do
      assert Chain.spec() == %{"length" => 1024}
    end
  end

  describe "derive/2" do
    test "is SHA-256 of the previous value" do
      prev = :crypto.strong_rand_bytes(32)
      assert Chain.derive(prev) == :crypto.hash(:sha256, prev)
    end

    test "is deterministic and 32 bytes" do
      prev = :crypto.strong_rand_bytes(32)
      assert Chain.derive(prev) == Chain.derive(prev)
      assert byte_size(Chain.derive(prev)) == 32
    end
  end

  describe "seed_for/4" do
    test "is deterministic for the same secret, game and role" do
      secret = :crypto.strong_rand_bytes(32)
      game_id = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      assert Chain.seed_for(secret, game_id, "challenger") ==
               Chain.seed_for(secret, game_id, "challenger")
    end

    test "separates roles and games" do
      secret = :crypto.strong_rand_bytes(32)
      a = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      b = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      seeds =
        [
          Chain.seed_for(secret, a, "challenger"),
          Chain.seed_for(secret, a, "accepter"),
          Chain.seed_for(secret, b, "challenger")
        ]

      assert length(Enum.uniq(seeds)) == 3
    end

    test "is unrecoverable without the secret" do
      secret = :crypto.strong_rand_bytes(32)
      other = :crypto.strong_rand_bytes(32)
      game_id = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      refute Chain.seed_for(secret, game_id, "challenger") ==
               Chain.seed_for(other, game_id, "challenger")
    end
  end

  describe "generate/2" do
    test "produces the requested length, each link deriving the next" do
      chain = Chain.generate(:crypto.strong_rand_bytes(32), short())

      assert length(chain) == 8
      assert Enum.all?(chain, &(byte_size(&1) == 32))

      chain
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [a, b] -> assert Chain.derive(a) == b end)
    end

    test "a fresh-device recovery rebuilds the identical chain" do
      secret = :crypto.strong_rand_bytes(32)
      game_id = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

      first = secret |> Chain.seed_for(game_id, "challenger") |> Chain.generate(short())
      again = secret |> Chain.seed_for(game_id, "challenger") |> Chain.generate(short())

      assert first == again
      assert Chain.commit(first) == Chain.commit(again)
    end
  end

  describe "commit/1 and verification" do
    setup do
      chain = Chain.generate(:crypto.strong_rand_bytes(32), short())
      %{chain: chain, commit: Chain.commit(chain)}
    end

    test "commits to the last link", %{chain: chain, commit: commit} do
      assert commit == :crypto.hash(:sha256, List.last(chain))
    end

    test "the first reveal matches the commitment", %{chain: chain, commit: commit} do
      assert :ok = Chain.verify_first(List.last(chain), commit)
      assert {:error, _} = Chain.verify_first(:crypto.strong_rand_bytes(32), commit)
    end

    test "each later reveal extends the one before", %{chain: chain} do
      # Reveals walk backwards: `prior` was published first, `later` is its
      # preimage, so deriving `later` reproduces `prior`.
      [prior, later | _] = Enum.reverse(chain)

      assert :ok = Chain.verify_next(later, prior)
      assert {:error, _} = Chain.verify_next(:crypto.strong_rand_bytes(32), prior)
    end

    test "a reveal cannot be run forward to the next one", %{chain: chain} do
      [latest, next_one | _] = Enum.reverse(chain)

      # The chain runs seed-first, so hashing a revealed value moves backwards
      # through the chain, never forwards: an opponent holding chain[-1] has
      # nothing to derive chain[-2] from beyond a preimage search.
      refute :crypto.hash(:sha256, latest) == next_one
      assert Chain.derive(next_one) == latest
    end
  end

  describe "reveal_pair/3" do
    test "walks the chain tail-first and honours the remaining count" do
      chain = Chain.generate(:crypto.strong_rand_bytes(32), short())
      [c1, c2 | _] = Enum.reverse(chain)

      assert {c1, c2} == Chain.reveal_pair(chain, 8)
      assert {c2, Enum.at(Enum.reverse(chain), 2)} == Chain.reveal_pair(chain, 7)
    end

    test "refuses to pair below two reveals" do
      chain = Chain.generate(:crypto.strong_rand_bytes(32), short())
      assert_raise FunctionClauseError, fn -> Chain.reveal_pair(chain, 1) end
    end
  end

  describe "dice/3" do
    test "is deterministic, order-sensitive and in range" do
      a = :crypto.strong_rand_bytes(32)
      b = :crypto.strong_rand_bytes(32)

      assert [d1, d2] = Chain.dice(a, b)
      assert d1 in 1..6 and d2 in 1..6
      assert Chain.dice(a, b) == [d1, d2]

      # A fixed pair whose reversed order gives different dice, so the
      # assertion cannot flake on a hash coincidence.
      assert Chain.dice(<<1::256>>, <<7::256>>) != Chain.dice(<<7::256>>, <<1::256>>)
    end

    test "one die mixes one half with one other" do
      a = :crypto.strong_rand_bytes(32)
      b = :crypto.strong_rand_bytes(32)

      assert [d] = Chain.dice(a, b, 1)
      assert d in 1..6
    end

    test "rejection sampling keeps the faces reachable" do
      faces =
        for i <- 1..400 do
          Chain.dice(<<i::256>>, <<i * 7::256>>, 1) |> hd()
        end

      assert Enum.sort(Enum.uniq(faces)) == [1, 2, 3, 4, 5, 6]
    end
  end

  describe "hex helpers used on the wire" do
    test "a commitment round-trips through hex" do
      commit = Chain.commit(Chain.generate(:crypto.strong_rand_bytes(32), short()))
      assert byte_size(hex(commit)) == 64
      assert Base.decode16!(hex(commit), case: :lower) == commit
    end
  end
end
