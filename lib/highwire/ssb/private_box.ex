defmodule HighWire.SSB.PrivateBox do
  @moduledoc """
  The SSB private-box format: `.box` strings the engine stores, replicates,
  and decrypts on its private views.

  The Elixir twin of erlbutt's `private_box` module — same wire format,
  byte for byte, so a box written here decrypts in the engine and a box
  written there decrypts here:

      nonce      24 random bytes
      header_pk  32 bytes, ephemeral curve25519 public key
      headers    49 bytes × N recipients (max 7)
        each = secretbox(num_recipients ‖ body_key, nonce,
                         scalarmult(header_sk, recipient_curve25519_pk))
      body       secretbox(plaintext, nonce, body_key)

  The whole is base64-encoded with a `.box` suffix — the suffix is how
  readers tell a private message from a public one without parsing it.

  Encryption needs only the recipients' public keys, converted from their
  feed ids; the sender's own key never enters the box. That is why the app
  can write a private message itself instead of asking the engine to —
  the sender's secret key is needed only to *read* one back, which is the
  engine's job on its private views.
  """

  @max_recipients 7
  @nonce_bytes 24
  @header_pk_bytes 32
  @body_key_bytes 32
  @header_bytes 49

  @typedoc "A feed id like `\"@base64key.ed25519\"`."
  @type feed_id :: binary()

  @doc """
  Boxes `plaintext` for `recipient_ids` (1–7 feed ids), returning a
  `".box"` string ready to publish as an ordinary message content.

  The plaintext is what every recipient will read back — callers encode
  JSON before boxing so `recps` travels *inside* the ciphertext like the
  rest of the message.
  """
  @spec encrypt(binary(), [feed_id()]) :: binary()
  def encrypt(plaintext, recipient_ids) when is_binary(plaintext) and is_list(recipient_ids) do
    count = length(recipient_ids)

    if count < 1 or count > @max_recipients do
      raise ArgumentError,
            "private messages need 1-#{@max_recipients} recipients, got: #{inspect(recipient_ids)}"
    end

    nonce = :enacl.randombytes(@nonce_bytes)
    body_key = :enacl.randombytes(@body_key_bytes)
    %{public: header_pk, secret: header_sk} = :enacl.box_keypair()

    headers =
      Enum.map(recipient_ids, fn id ->
        shared = :enacl.curve25519_scalarmult(header_sk, recipient_curve25519_pk(id))
        :enacl.secretbox(<<count, body_key::binary>>, nonce, shared)
      end)

    body = :enacl.secretbox(plaintext, nonce, body_key)
    ciphertext = IO.iodata_to_binary([nonce, header_pk, headers, body])

    Base.encode64(ciphertext) <> ".box"
  end

  @doc """
  Opens a `.box` with our own ed25519 secret key (the 64-byte key from
  the identity, not a feed id).

  Returns `{:ok, plaintext}` or `:not_for_me` — for a box addressed to
  someone else, a corrupted box, or a `.box` that is not one. Mirrors
  erlbutt's `decrypt/1` result so both sides read alike.
  """
  @spec decrypt(binary(), binary()) :: {:ok, binary()} | :not_for_me
  def decrypt(box, my_ed25519_sk) when is_binary(box) and is_binary(my_ed25519_sk) do
    with true <- private?(box),
         b64_size when b64_size > 0 <- byte_size(box) - 4,
         <<b64::binary-size(^b64_size), ".box">> <- box,
         {:ok, data} <- Base.decode64(b64) do
      open(data, my_ed25519_sk)
    else
      _ -> :not_for_me
    end
  rescue
    _ -> :not_for_me
  end

  @doc """
  True when the content is a private box — the `.box` suffix, same test
  the engine uses to route a message to its private views.
  """
  @spec private?(term()) :: boolean()
  def private?(content) when is_binary(content), do: String.ends_with?(content, ".box")
  def private?(_), do: false

  # -- decrypt (mirrors private_box.erl's try_decrypt/try_headers) ---------

  defp open(data, my_ed25519_sk) do
    case data do
      <<nonce::binary-size(@nonce_bytes), header_pk::binary-size(@header_pk_bytes),
        headers_and_body::binary>> ->
        my_sk = :enacl.crypto_sign_ed25519_secret_to_curve25519(my_ed25519_sk)
        try_headers(headers_and_body, nonce, :enacl.curve25519_scalarmult(my_sk, header_pk), 0)

      _ ->
        :not_for_me
    end
  end

  # Which header slot holds ours depends on where we stood in the sender's
  # recipient list, so try them in turn. The recipient count inside our
  # header says where the body starts.
  defp try_headers(headers_and_body, nonce, my_key, slot) when slot < @max_recipients do
    offset = slot * @header_bytes

    with <<_::binary-size(^offset), header::binary-size(@header_bytes), _::binary>> <-
           headers_and_body,
         {:ok, <<count, body_key::binary-size(@body_key_bytes)>>} <-
           :enacl.secretbox_open(header, nonce, my_key),
         body_offset when body_offset <= byte_size(headers_and_body) <-
           count * @header_bytes,
         <<_::binary-size(^body_offset), enc_body::binary>> <- headers_and_body,
         {:ok, plaintext} <- :enacl.secretbox_open(enc_body, nonce, body_key) do
      {:ok, plaintext}
    else
      _ -> try_headers(headers_and_body, nonce, my_key, slot + 1)
    end
  end

  defp try_headers(_headers_and_body, _nonce, _my_key, _slot), do: :not_for_me

  # -- recipients ----------------------------------------------------------

  # Feed id -> curve25519 public key: keys on disk are ed25519 and the
  # box's DH needs curve25519, so convert — the engine converts the same
  # way in both directions.
  defp recipient_curve25519_pk(<<"@", rest::binary>>) do
    rest
    |> String.replace(".ed25519", "", global: false)
    |> Base.decode64!()
    |> then(&:enacl.crypto_sign_ed25519_public_to_curve25519/1)
  end

  defp recipient_curve25519_pk(id) do
    raise ArgumentError, "not a feed id: #{inspect(id)}"
  end
end
