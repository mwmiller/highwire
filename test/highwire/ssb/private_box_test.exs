defmodule HighWire.SSB.PrivateBoxTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.PrivateBox

  defp keypair, do: :enacl.crypto_sign_ed25519_keypair()

  defp feed_id(%{public: pk}), do: "@" <> Base.encode64(pk) <> ".ed25519"

  defp decryptable?(box, %{secret: sk}), do: match?({:ok, _}, PrivateBox.decrypt(box, sk))

  test "round-trips a message addressed to us" do
    kp = keypair()
    plaintext = ~s({"type":"post","text":"just between us"})

    box = PrivateBox.encrypt(plaintext, [feed_id(kp)])

    assert PrivateBox.private?(box)
    assert {:ok, ^plaintext} = PrivateBox.decrypt(box, kp.secret)
  end

  test "every recipient opens the box, and nobody else can" do
    [me, them, other] = [keypair(), keypair(), keypair()]
    plaintext = ~s({"type":"post","recps":"two"})

    box = PrivateBox.encrypt(plaintext, [feed_id(me), feed_id(them)])

    assert {:ok, ^plaintext} = PrivateBox.decrypt(box, me.secret)
    assert {:ok, ^plaintext} = PrivateBox.decrypt(box, them.secret)
    refute decryptable?(box, other)
  end

  test "which slot is ours does not matter" do
    [me, them] = [keypair(), keypair()]
    plaintext = ~s({"type":"vote"})

    # Addressed second: our header sits at slot 1, so the reader has to
    # try past the first slot to find us.
    box = PrivateBox.encrypt(plaintext, [feed_id(them), feed_id(me)])

    assert {:ok, ^plaintext} = PrivateBox.decrypt(box, me.secret)
  end

  test "the wire layout matches the engine's format byte for byte" do
    kp = keypair()
    plaintext = ~s({"type":"post","text":"x"})
    box = PrivateBox.encrypt(plaintext, [feed_id(kp)])

    assert String.ends_with?(box, ".box")
    {:ok, data} = box |> String.trim_trailing(".box") |> Base.decode64()

    # nonce 24 | header_pk 32 | 49-byte header per recipient |
    # secretbox body (plaintext + 16-byte tag)
    assert byte_size(data) == 24 + 32 + 49 + byte_size(plaintext) + 16

    # The recipient count lives in the first header slot's first byte,
    # encrypted — it opens with a recipient's key and equals 1 here.
    assert {:ok, <<1, _body_key::binary-size(32)>>} =
             :enacl.secretbox_open(
               binary_part(data, 24 + 32, 49),
               binary_part(data, 0, 24),
               :enacl.curve25519_scalarmult(
                 :enacl.crypto_sign_ed25519_secret_to_curve25519(kp.secret),
                 binary_part(data, 24, 32)
               )
             )
  end

  test "seven recipients is the format's ceiling" do
    kps = for _ <- 1..7, do: keypair()
    plaintext = ~s({"type":"post"})

    box = PrivateBox.encrypt(plaintext, Enum.map(kps, &feed_id/1))

    # Every one of the seven opens it — the last slot is reachable too.
    for kp <- kps, do: assert({:ok, ^plaintext} = PrivateBox.decrypt(box, kp.secret))
  end

  test "a box needs at least one recipient and at most seven" do
    plaintext = ~s({"type":"post"})

    assert_raise ArgumentError, fn -> PrivateBox.encrypt(plaintext, []) end

    assert_raise ArgumentError, fn ->
      PrivateBox.encrypt(plaintext, for(_ <- 1..8, do: feed_id(keypair())))
    end
  end

  test "a recipient that is not a feed id is refused" do
    assert_raise ArgumentError, fn -> PrivateBox.encrypt(~s({}), ["not-a-feed-id"]) end
  end

  test "anything that is not our box reads as not for us" do
    kp = keypair()
    plaintext = ~s({"type":"post"})

    refute decryptable?(PrivateBox.encrypt(plaintext, [feed_id(keypair())]), kp)
    assert PrivateBox.decrypt("plain text, not a box", kp.secret) == :not_for_me
    assert PrivateBox.decrypt("", kp.secret) == :not_for_me
    assert PrivateBox.decrypt("AAAA.box", kp.secret) == :not_for_me
    assert PrivateBox.decrypt("not base64!!.box", kp.secret) == :not_for_me

    good = PrivateBox.encrypt(plaintext, [feed_id(kp)])
    assert PrivateBox.decrypt("x" <> good, kp.secret) == :not_for_me
  end

  test "private? recognizes only a .box string" do
    assert PrivateBox.private?("whatever.box")
    refute PrivateBox.private?("%somepublickey.sha256")
    refute PrivateBox.private?(%{"type" => "post"})
    refute PrivateBox.private?(nil)
  end
end
