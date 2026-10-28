defmodule HighWire.SSB.InviteTest do
  # Not async: the cases point :application_dir at a temp home to mint a
  # running identity, and the integration cases bind a loopback port.
  use ExUnit.Case, async: false

  alias HighWire.SSB.{BoxStream, Invite, Muxrpc, Network}

  @moduletag :capture_log

  # A minimal SSB pub: accepts one connection, runs the server-side SHS
  # handshake (ported from erlbutt's `do_server_shake_hands`), then reads
  # one box-stream frame and answers the muxrpc request inside it. This
  # lets the real client round-trip be exercised end to end without a
  # running engine. Returns the loopback port it listens on; the observed
  # request is sent back to the test process as {:fake_pub_request, …}.
  defmodule FakePub do
    @moduledoc false
    @shs_nonce <<0::192>>

    def start(opts) do
      parent = self()
      net_id = Keyword.fetch!(opts, :net_id)
      keys = Keyword.fetch!(opts, :keys)
      client_pk = Keyword.fetch!(opts, :client_pk)
      feed = Keyword.fetch!(opts, :feed)

      {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
      {:ok, port} = :inet.port(lsock)

      spawn(fn ->
        {:ok, sock} = :gen_tcp.accept(lsock)
        :ok = :gen_tcp.close(lsock)

        {:ok, state, authed_pk} = handshake(sock, net_id, keys)
        request = serve(sock, state, authed_pk, client_pk, feed)
        send(parent, {:fake_pub_request, request})
      end)

      port
    end

    # -- SHS server handshake (ported from erlbutt shs.erl) ---------------

    # A valid SHS client always completes this; anything off (wrong
    # network id, a non-SSB peer) raises and the spawned pub dies, which
    # the client sees as a failed connect — exactly what a real pub's
    # refusal at this layer looks like.
    defp handshake(sock, net_id, %{public: long_pk, secret: long_sk}) do
      {:ok, <<mac::binary-size(32), cl_eph_pk::binary-size(32)>>} =
        :gen_tcp.recv(sock, 64, 5_000)

      <<enc_nonce::binary-size(24), _::binary-size(8)>> = mac
      true = :enacl.auth_verify(mac, cl_eph_pk, net_id)

      {eph_sk, server_hello, dec_nonce} = gen_hello(net_id)
      :ok = :gen_tcp.send(sock, server_hello)

      shared_ab = :enacl.curve25519_scalarmult(eph_sk, cl_eph_pk)

      shared_aB =
        :enacl.curve25519_scalarmult(
          :enacl.crypto_sign_ed25519_secret_to_curve25519(long_sk),
          cl_eph_pk
        )

      {:ok, serv_data} = :gen_tcp.recv(sock, 112, 5_000)
      sha_ab = :crypto.hash(:sha256, shared_ab)
      auth_key = :crypto.hash(:sha256, net_id <> shared_ab <> shared_aB)
      {:ok, msg_plain} = :enacl.secretbox_open(serv_data, @shs_nonce, auth_key)
      <<det_sig_a::binary-size(64), cl_long_pk::binary-size(32)>> = msg_plain
      true = :enacl.sign_verify_detached(det_sig_a, net_id <> long_pk <> sha_ab, cl_long_pk)

      shared_Ab =
        :enacl.curve25519_scalarmult(
          eph_sk,
          :enacl.crypto_sign_ed25519_public_to_curve25519(cl_long_pk)
        )

      det_sig_b = :enacl.sign_detached(net_id <> det_sig_a <> cl_long_pk <> sha_ab, long_sk)
      resp_key = :crypto.hash(:sha256, net_id <> shared_ab <> shared_aB <> shared_Ab)
      :ok = :gen_tcp.send(sock, :enacl.secretbox(det_sig_b, @shs_nonce, resp_key))

      session =
        :crypto.hash(
          :sha256,
          :crypto.hash(:sha256, net_id <> shared_ab <> shared_aB <> shared_Ab)
        )

      state = %{
        sock: sock,
        dec_key: :crypto.hash(:sha256, session <> long_pk),
        dec_nonce: dec_nonce,
        enc_key: :crypto.hash(:sha256, session <> cl_long_pk),
        enc_nonce: enc_nonce
      }

      {:ok, state, cl_long_pk}
    end

    defp gen_hello(net_id) do
      %{public: eph_pk, secret: eph_sk} = :enacl.box_keypair()
      mac = :enacl.auth(eph_pk, net_id)
      <<nonce::binary-size(24), _::binary-size(8)>> = mac
      {eph_sk, mac <> eph_pk, nonce}
    end

    # -- box-stream + muxrpc serve ----------------------------------------

    # Reads frames until it can decode one muxrpc request, checks it is a
    # valid `invite.use` for the expected feed and that the caller
    # authenticated as the invite's own key, and boxes a reply: JSON
    # `true` when honoured, the invalid-invite error body when not.
    defp serve(sock, state, authed_pk, client_pk, feed) do
      await_frame(sock, state, <<>>, authed_pk, client_pk, feed)
    end

    defp await_frame(sock, state, buf, authed_pk, client_pk, feed) do
      case BoxStream.unbox(buf, state.dec_nonce, state.dec_key) do
        {:frame, payload, nonce, _rest} ->
          handle_payload(sock, %{state | dec_nonce: nonce}, payload, authed_pk, client_pk, feed)

        {:end, _} ->
          :peer_closed

        :partial ->
          case :gen_tcp.recv(sock, 0, 5_000) do
            {:ok, data} -> await_frame(sock, state, buf <> data, authed_pk, client_pk, feed)
            {:error, _} -> :closed
          end
      end
    end

    defp handle_payload(sock, state, payload, authed_pk, client_pk, feed) do
      {:packet, meta, body, _rest} = Muxrpc.decode(payload)
      %{"name" => name, "args" => args} = Jason.decode!(body)

      # The pub honours the invite only when the caller authenticated as
      # the invite's own key and `use` carries the expected feed.
      honoured? = name == ["invite", "use"] and authed_pk == client_pk and feed_of(args) == feed

      reply =
        if honoured? do
          Jason.encode!(true)
        else
          Jason.encode!(%{
            "name" => "Error",
            "message" => "invalid or expired invite",
            "stack" => "_"
          })
        end

      framed = Muxrpc.encode(%{stream: 0, end: 1, req: -meta.req}, reply)
      {bytes, _enc_nonce} = BoxStream.box(framed, state.enc_nonce, state.enc_key)
      :ok = :gen_tcp.send(sock, bytes)

      {name, args}
    end

    defp feed_of([%{"feed" => feed} | _]) when is_binary(feed), do: feed
    defp feed_of(_args), do: nil
  end

  # -- parse ---------------------------------------------------------------

  describe "parse/1" do
    test "a padded code decodes into its parts" do
      pub_key = :enacl.randombytes(32)
      seed = :enacl.randombytes(32)

      code = "pub.example.org:8008:@#{Base.encode64(pub_key)}.ed25519~#{Base.encode64(seed)}"

      assert {:ok, invite} = Invite.parse(code)
      assert invite.host == "pub.example.org"
      assert invite.port == 8008
      assert invite.pub_key == pub_key
      assert invite.seed == seed
      assert invite.pub_id == "@" <> Base.encode64(pub_key) <> ".ed25519"
    end

    test "unpadded base64 decodes the same as padded" do
      pub_key = :enacl.randombytes(32)
      seed = :enacl.randombytes(32)

      code =
        "10.0.0.5:8008:@#{Base.encode64(pub_key) |> String.trim_trailing("=")}.ed25519~" <>
          "#{Base.encode64(seed) |> String.trim_trailing("=")}"

      assert {:ok, invite} = Invite.parse(code)
      assert invite.host == "10.0.0.5"
      assert invite.pub_key == pub_key
      assert invite.seed == seed
    end

    test "surrounding whitespace is trimmed" do
      pub_key = :enacl.randombytes(32)
      seed = :enacl.randombytes(32)

      code = "  pub.example.org:8008:@#{Base.encode64(pub_key)}.ed25519~#{Base.encode64(seed)}\n"

      assert {:ok, _invite} = Invite.parse(code)
    end

    test "malformed codes are rejected" do
      assert Invite.parse("") == {:error, :bad_invite}
      assert Invite.parse("no-tilde-here") == {:error, :bad_invite}
      assert Invite.parse("host:notaport:@key.ed25519~seed") == {:error, :bad_invite}
      assert Invite.parse("host:0:@key.ed25519~seed") == {:error, :bad_invite}
      assert Invite.parse("host:70000:@key.ed25519~seed") == {:error, :bad_invite}
      assert Invite.parse("host:8008:@notbase64!!.ed25519~alsobad!!") == {:error, :bad_invite}
      assert Invite.parse(:not_a_binary) == {:error, :bad_invite}
    end

    test "keys and seeds of the wrong size are rejected" do
      short_key = Base.encode64(:enacl.randombytes(16))
      seed = Base.encode64(:enacl.randombytes(32))
      assert Invite.parse("h:1:@#{short_key}.ed25519~#{seed}") == {:error, :bad_invite}

      pub_key = Base.encode64(:enacl.randombytes(32))
      short_seed = Base.encode64(:enacl.randombytes(16))
      assert Invite.parse("h:1:@#{pub_key}.ed25519~#{short_seed}") == {:error, :bad_invite}
    end
  end

  describe "address/1" do
    test "is the multiserver spelling the address book keys on" do
      pub_key = :enacl.randombytes(32)
      seed = :enacl.randombytes(32)

      {:ok, invite} =
        Invite.parse(
          "pub.example.org:8008:@#{Base.encode64(pub_key)}.ed25519~#{Base.encode64(seed)}"
        )

      assert Invite.address(invite) == "net:pub.example.org:8008~shs:#{Base.encode64(pub_key)}"
    end
  end

  # -- redemption against a fake pub ---------------------------------------

  describe "redeem/2 against a fake pub" do
    setup :mint_identity

    test "a valid invite dials the pub, sends the feed id, and announces", ctx do
      # The invite's own keypair (derived from the seed) — what the pub
      # checks the caller against. The code's `@` field is the pub's
      # long-term key, which the client uses as the SHS remote.
      seed = :enacl.randombytes(32)
      %{public: invite_pk} = :enacl.sign_seed_keypair(seed)
      pub_keys = :enacl.sign_keypair()

      port =
        FakePub.start(
          net_id: net_id(),
          keys: pub_keys,
          client_pk: invite_pk,
          feed: ctx.feed_id
        )

      code = "127.0.0.1:#{port}:@#{Base.encode64(pub_keys.public)}.ed25519~#{Base.encode64(seed)}"
      parent = self()

      assert {:ok, invite} =
               Invite.redeem(code,
                 announce: fn inv ->
                   send(parent, {:announced, inv})
                   :ok
                 end,
                 trigger: fn ->
                   send(parent, :triggered)
                   :ok
                 end
               )

      # The announce saw the same parsed invite (following the pub's own
      # long-term id), and the dialer was kicked.
      assert_received {:announced, announced}
      assert announced.pub_id == invite.pub_id
      assert announced.pub_id == "@" <> Base.encode64(pub_keys.public) <> ".ed25519"
      assert_received :triggered

      # And the pub got the ["invite","use"] call carrying our feed id.
      assert_received {:fake_pub_request, {["invite", "use"], args}}
      assert args == [%{"feed" => ctx.feed_id}]
    end

    test "a pub that refuses the invite surfaces a refusal and skips the announce", ctx do
      seed = :enacl.randombytes(32)
      pub_keys = :enacl.sign_keypair()

      # A pub that will not honour this invite: it expects a different
      # client key (the invite identity never matches), so it answers
      # with the invalid-invite error.
      port =
        FakePub.start(
          net_id: net_id(),
          keys: pub_keys,
          client_pk: :enacl.randombytes(32),
          feed: ctx.feed_id
        )

      code = "127.0.0.1:#{port}:@#{Base.encode64(pub_keys.public)}.ed25519~#{Base.encode64(seed)}"
      parent = self()

      assert {:error, {:refused, reason}} =
               Invite.redeem(code,
                 announce: fn _inv ->
                   send(parent, :announced)
                   :ok
                 end,
                 trigger: fn ->
                   send(parent, :triggered)
                   :ok
                 end
               )

      # The error body the pub sent back.
      assert %{"name" => "Error", "message" => message} = reason
      assert message =~ "invalid or expired invite"

      # A refusal means the code was not spent, so nothing is announced
      # and the dialer is not kicked.
      refute_received :announced
      refute_received :triggered
    end

    test "an unreachable pub fails to connect without announcing" do
      pub_keys = :enacl.sign_keypair()
      seed = :enacl.randombytes(32)

      # Bind then immediately close a port so nothing is listening on it.
      {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw])
      {:ok, port} = :inet.port(lsock)
      :ok = :gen_tcp.close(lsock)

      code = "127.0.0.1:#{port}:@#{Base.encode64(pub_keys.public)}.ed25519~#{Base.encode64(seed)}"
      parent = self()

      assert {:error, {:connect, _}} =
               Invite.redeem(code,
                 announce: fn _inv ->
                   send(parent, :announced)
                   :ok
                 end,
                 trigger: fn ->
                   send(parent, :triggered)
                   :ok
                 end
               )

      refute_received :announced
      refute_received :triggered
    end
  end

  describe "redeem/2 without an identity" do
    test "reports :no_identity before touching the network" do
      # An empty home: no secret, no registry row, so active_id is nil.
      with_empty_home()

      code =
        "pub.example.org:8008:@#{Base.encode64(:enacl.randombytes(32))}.ed25519~#{Base.encode64(:enacl.randombytes(32))}"

      assert {:error, :no_identity} = Invite.redeem(code)
    end
  end

  # -- helpers --------------------------------------------------------------

  defp net_id, do: Base.decode64!(Network.current_id())

  # A temp home with one running identity, so active_id/0 answers with a
  # real feed id for the round-trip to hand the pub.
  defp mint_identity(_ctx) do
    home = Path.join(System.tmp_dir!(), "hw-invite-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(home, ".ssberl"))
    set_home!(home)

    %{public: public, secret: private} = :enacl.sign_keypair()
    id = "@" <> Base.encode64(public) <> ".ed25519"

    body =
      Jason.encode!(%{
        "curve" => "ed25519",
        "public" => Base.encode64(public) <> ".ed25519",
        "private" => Base.encode64(private) <> ".ed25519",
        "id" => id
      })

    File.write!(Path.join([home, ".ssberl", "secret"]), body <> "\n")

    assert :ok = HighWire.SSB.Identities.ensure_boot()
    assert HighWire.SSB.Identities.active_id() == id

    {:ok, feed_id: id}
  end

  defp with_empty_home do
    home = Path.join(System.tmp_dir!(), "hw-invite-empty-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(home)
    set_home!(home)
    home
  end

  defp set_home!(home) do
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, home)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :application_dir, previous),
        else: Application.delete_env(:highwire, :application_dir)

      File.rm_rf!(home)
    end)
  end
end
