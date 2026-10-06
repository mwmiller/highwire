defmodule HighWire.SSB.SHS do
  @moduledoc """
  Secret Handshake (client side), clean-room from the public spec and
  verified against erlbutt's `shs.erl`.

  Both sides end up with four values: the box-stream encrypt key/nonce
  and decrypt key/nonce. The hello messages double as the initial
  box-stream nonces (first 24 bytes of each side's hello MAC).
  """

  @shs_nonce <<0::192>>

  @type keypair :: %{public: binary(), secret: binary()}

  @spec handshake(
          (binary() -> :ok),
          (non_neg_integer() -> binary()),
          binary(),
          binary(),
          keypair()
        ) ::
          {:ok, %{enc_key: binary(), enc_nonce: binary(), dec_key: binary(), dec_nonce: binary()}}
  def handshake(send!, recv!, remote_pk, net_id, %{public: our_pk, secret: our_sk}) do
    {eph_sk, hello, dec_nonce} = gen_hello(net_id)
    :ok = send!.(hello)

    server_hello = recv!.(64)
    {serv_eph, enc_nonce} = check_hello!(server_hello, net_id)

    shared_ab = :enacl.curve25519_scalarmult(eph_sk, serv_eph)
    shared_aeph_bkey = :enacl.curve25519_scalarmult(eph_sk, to_curve_pk(remote_pk))
    sha_ab = :crypto.hash(:sha256, shared_ab)

    sig_a = :enacl.sign_detached(net_id <> remote_pk <> sha_ab, our_sk)
    auth_key = :crypto.hash(:sha256, net_id <> shared_ab <> shared_aeph_bkey)
    :ok = send!.(:enacl.secretbox(sig_a <> our_pk, @shs_nonce, auth_key))

    shared_akey_beph =
      :enacl.curve25519_scalarmult(
        :enacl.crypto_sign_ed25519_secret_to_curve25519(our_sk),
        serv_eph
      )

    server_auth = recv!.(80)
    resp_key = :crypto.hash(:sha256, net_id <> shared_ab <> shared_aeph_bkey <> shared_akey_beph)
    sig_b = open!(server_auth, @shs_nonce, resp_key)

    true =
      :enacl.sign_verify_detached(sig_b, net_id <> sig_a <> our_pk <> sha_ab, remote_pk)

    session =
      :crypto.hash(
        :sha256,
        :crypto.hash(:sha256, net_id <> shared_ab <> shared_aeph_bkey <> shared_akey_beph)
      )

    {:ok,
     %{
       dec_key: :crypto.hash(:sha256, session <> our_pk),
       dec_nonce: dec_nonce,
       enc_key: :crypto.hash(:sha256, session <> remote_pk),
       enc_nonce: enc_nonce
     }}
  end

  defp gen_hello(net_id) do
    %{public: eph_pk, secret: eph_sk} = :enacl.box_keypair()
    mac = :enacl.auth(eph_pk, net_id)
    <<nonce::binary-size(24), _::binary-size(8)>> = mac
    {eph_sk, mac <> eph_pk, nonce}
  end

  defp check_hello!(<<mac::binary-size(32), eph_pk::binary-size(32)>>, net_id) do
    if :enacl.auth_verify(mac, eph_pk, net_id) do
      <<nonce::binary-size(24), _::binary-size(8)>> = mac
      {eph_pk, nonce}
    else
      raise "network id mismatch (hello did not verify)"
    end
  end

  defp open!(box, nonce, key) do
    case :enacl.secretbox_open(box, nonce, key) do
      {:ok, plain} -> plain
      {:error, reason} -> raise "SHS auth rejected: #{inspect(reason)}"
    end
  end

  defp to_curve_pk(<<_::binary-size(32)>> = pk),
    do: :enacl.crypto_sign_ed25519_public_to_curve25519(pk)
end
