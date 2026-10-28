defmodule HighWire.SSB.PeerAddressTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.PeerAddress

  @key :enacl.sign_keypair().public
  @b64 Base.encode64(@key)

  describe "parse/1" do
    test "reads the multiserver address the address book keys on" do
      assert {:ok, peer} = PeerAddress.parse("net:pub.example.org:8008~shs:#{@b64}")
      assert peer.host == "pub.example.org"
      assert peer.port == 8008
      assert peer.key == @key
    end

    test "accepts the bare address without the net: prefix" do
      assert {:ok, peer} = PeerAddress.parse("pub.example.org:8008~shs:#{@b64}")
      assert peer.host == "pub.example.org"
      assert peer.port == 8008
    end

    test "accepts an unpadded key" do
      unpadded = String.trim_trailing(@b64, "=")
      assert {:ok, peer} = PeerAddress.parse("pub.example.org:8008~shs:#{unpadded}")
      assert peer.key == @key
    end

    test "accepts the URL-safe alphabet" do
      urlsafe = @b64 |> String.replace("+", "-") |> String.replace("/", "_")
      assert {:ok, peer} = PeerAddress.parse("pub.example.org:8008~shs:#{urlsafe}")
      assert peer.key == @key
    end

    test "trims surrounding whitespace" do
      assert {:ok, peer} = PeerAddress.parse("  net:pub.example.org:8008~shs:#{@b64}  ")
      assert peer.host == "pub.example.org"
    end

    test "reads the port off the end of a host that carries colons" do
      assert {:ok, peer} = PeerAddress.parse("net:::1:8008~shs:#{@b64}")
      assert peer.host == "::1"
      assert peer.port == 8008
    end

    test "rejects a missing host" do
      assert PeerAddress.parse("net::8008~shs:#{@b64}") == {:error, :bad_address}
    end

    test "rejects a port outside the valid range" do
      assert PeerAddress.parse("net:pub.example.org:0~shs:#{@b64}") == {:error, :bad_address}
      assert PeerAddress.parse("net:pub.example.org:70000~shs:#{@b64}") == {:error, :bad_address}
    end

    test "rejects a non-numeric port" do
      assert PeerAddress.parse("net:pub.example.org:http~shs:#{@b64}") == {:error, :bad_address}
    end

    test "rejects a key that is not 32 bytes" do
      short = Base.encode64(:crypto.strong_rand_bytes(16))
      assert PeerAddress.parse("net:pub.example.org:8008~shs:#{short}") == {:error, :bad_address}
    end

    test "rejects a key that is not base64" do
      assert PeerAddress.parse("net:pub.example.org:8008~shs:not!base64") ==
               {:error, :bad_address}
    end

    test "rejects an address with no key at all" do
      assert PeerAddress.parse("net:pub.example.org:8008") == {:error, :bad_address}
    end

    test "rejects an empty address" do
      assert PeerAddress.parse("") == {:error, :bad_address}
      assert PeerAddress.parse("   ") == {:error, :bad_address}
    end

    test "rejects a non-binary" do
      assert PeerAddress.parse(nil) == {:error, :bad_address}
      assert PeerAddress.parse(8008) == {:error, :bad_address}
    end
  end

  describe "address/1" do
    test "renders the spelling the address book keys on" do
      {:ok, peer} = PeerAddress.parse("pub.example.org:8008~shs:#{@b64}")

      assert PeerAddress.address(peer) == "net:pub.example.org:8008~shs:#{@b64}"
    end

    test "round-trips through parse/1" do
      {:ok, peer} = PeerAddress.parse("net:pub.example.org:8008~shs:#{@b64}")

      assert {:ok, ^peer} = peer |> PeerAddress.address() |> PeerAddress.parse()
    end
  end

  describe "add/2" do
    test "announces the address and kicks the dialer" do
      parent = self()
      {:ok, peer} = PeerAddress.parse("net:pub.example.org:8008~shs:#{@b64}")

      assert :ok =
               PeerAddress.add(peer,
                 announce: fn announced ->
                   send(parent, {:announced, announced})
                   :ok
                 end,
                 trigger: fn ->
                   send(parent, :triggered)
                   :ok
                 end
               )

      assert_received {:announced, announced}
      assert announced.host == "pub.example.org"
      assert announced.port == 8008
      assert_received :triggered
    end

    test "an announce failure is reported and the dialer is not kicked" do
      parent = self()
      {:ok, peer} = PeerAddress.parse("net:pub.example.org:8008~shs:#{@b64}")

      assert {:error, {:announce, :offline}} =
               PeerAddress.add(peer,
                 announce: fn _ -> {:error, :offline} end,
                 trigger: fn ->
                   send(parent, :triggered)
                   :ok
                 end
               )

      refute_received :triggered
    end
  end
end
