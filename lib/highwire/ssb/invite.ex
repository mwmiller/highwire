defmodule HighWire.SSB.Invite do
  @moduledoc """
  Pub invite redemption — the client half of erlbutt's `invite` flow.

  An invite code (`host:port:@key.ed25519~seed`) names a pub and a
  one-time keypair the pub will trust. Redeeming it connects to the pub
  *as that keypair*, hands over this identity's feed id (`invite.use`),
  and the pub follows the new feed back. Back home, the feed publishes
  the follow and a `pub` announce; the engine's own ingest turns the
  announce into an `conn.json` entry, so the dialer keeps the
  connection alive afterwards without any manual address entry.

  Nothing here signs as this identity: the handshake runs under the
  invite's own ephemeral keys — never the identity's, which is what the
  pub checks the invite against — and the two messages go out through
  the local engine's `publish` RPC, the same chokepoint every other
  outbound message uses.

  This is one of the two ways a fresh identity meets the network; the
  other is importing an old store. Without one of them the address book
  only fills from pubs that announce themselves, and a brand-new feed
  has no connection open to hear any announcement from.
  """

  require Logger

  alias HighWire.SSB.{Admin, Client, Identities, Network}
  alias HighWire.Timeline

  # A dial plus one round-trip to a pub that is busy following back and
  # refreshing its replication set before it answers.
  @timeout 20_000

  @type t :: %{
          host: String.t(),
          port: pos_integer(),
          pub_key: binary(),
          pub_id: String.t(),
          seed: binary()
        }

  @typedoc "Why a redemption failed, in the shape the UI words for a reader."
  @type error ::
          :bad_invite
          | :no_identity
          | {:connect, term()}
          | {:refused, term()}
          | {:announce, term()}
          | {:exit, term()}
          | :timeout

  @doc """
  Parse an invite code into its parts, or `{:error, :bad_invite}` for
  anything that is not one. The code's key and seed are base64 in the
  wild with or without padding, so both spellings decode; the parsed
  `pub_id` is the engine's own display form, whatever the code wrote.
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, :bad_invite}
  def parse(code) when is_binary(code) do
    with [addr_part, seed_b64] <- String.split(String.trim(code), "~", parts: 2),
         [host, port_str, key_disp] <- String.split(addr_part, ":"),
         {port, ""} <- Integer.parse(String.trim(port_str)),
         true <- port >= 1 and port <= 65_535,
         key_body = key_disp |> String.trim() |> String.trim_leading("@"),
         key_body = String.replace_suffix(key_body, ".ed25519", ""),
         {:ok, pub_key} <- base64(key_body),
         true <- byte_size(pub_key) == 32,
         {:ok, seed} <- base64(seed_b64),
         true <- byte_size(seed) == 32 do
      {:ok,
       %{
         host: String.trim(host),
         port: port,
         pub_key: pub_key,
         pub_id: display_id(pub_key),
         seed: seed
       }}
    else
      _ -> {:error, :bad_invite}
    end
  end

  def parse(_code), do: {:error, :bad_invite}

  @doc """
  The multiserver address a parsed invite dials as — the same
  `net:host:port~shs:key` spelling the engine's address book keys on.
  """
  @spec address(t()) :: binary()
  def address(%{host: host, port: port, pub_key: pub_key}),
    do: "net:#{host}:#{port}~shs:#{Base.encode64(pub_key)}"

  @doc """
  Redeem an invite code: dial the pub under the invite's own keys, hand
  it this identity's feed id, then publish the follow and the `pub`
  announce through the local engine and kick a dial round.

  `{:ok, invite}` on the full flow. Once `use` succeeds the code is
  spent at the pub whatever comes after, so an announce failure is
  reported as its own case rather than as something to retry.

  `opts` exist for tests: `:announce` overrides the engine publish step
  and `:trigger` the dialer kick, both receiving the parsed invite.
  """
  @spec redeem(binary() | t(), keyword()) :: {:ok, t()} | {:error, error()}
  def redeem(code_or_invite, opts \\ [])

  def redeem(code, opts) when is_binary(code) do
    case parse(code) do
      {:ok, invite} -> redeem(invite, opts)
      {:error, _} = error -> error
    end
  end

  def redeem(%{} = invite, opts) do
    announce = Keyword.get(opts, :announce, &announce_via_engine/1)
    trigger = Keyword.get(opts, :trigger, &trigger_dialer/0)

    with :ok <- consume(invite),
         :ok <- announce.(invite) do
      _ = trigger.()
      {:ok, invite}
    end
  end

  # -- the pub round-trip -------------------------------------------------

  # Everything below runs in a throwaway process that traps exits —
  # Client.start_link links, and a refused connect or a pub that dies
  # mid-call must not take the caller down — and always answers
  # `:ok | {:error, reason}`, never raises, never hangs past the timeout.
  defp consume(%{host: host, port: port, pub_id: pub_id} = invite) do
    case Identities.active_id() do
      nil ->
        {:error, :no_identity}

      our_id ->
        Logger.info("invite: redeeming for #{host}:#{port} (following #{pub_id})")

        caller = self()

        {worker, ref} =
          spawn_monitor(fn ->
            Process.flag(:trap_exit, true)
            send(caller, {:invite_use, self(), do_consume(invite, our_id)})
          end)

        receive do
          {:invite_use, ^worker, result} ->
            Process.demonitor(ref, [:flush])
            result

          {:DOWN, ^ref, :process, ^worker, reason} ->
            {:error, {:exit, reason}}
        after
          @timeout + 1_000 ->
            Process.exit(worker, :kill)
            Process.demonitor(ref, [:flush])
            {:error, :timeout}
        end
    end
  end

  defp do_consume(%{host: host, port: port, pub_key: pub_key, seed: seed}, our_id) do
    with {:ok, client} <- start_client(host, port, pub_key, seed) do
      result =
        try do
          Client.call(client, ["invite", "use"], [%{"feed" => our_id}], @timeout)
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      _ =
        try do
          Client.stop(client)
        catch
          _, _ -> :ok
        end

      case result do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          {:error, {:refused, reason}}
      end
    end
  end

  # The client authenticates as the invite's own keypair — the keys the
  # pub matches against its issued invite — never as this identity.
  defp start_client(host, port, pub_key, seed) do
    case Client.start_link(
           host: String.to_charlist(host),
           port: port,
           remote_pk: pub_key,
           net_id: Base.decode64!(Network.current_id()),
           keys: :enacl.sign_seed_keypair(seed)
         ) do
      {:ok, client} ->
        {:ok, client}

      # A refused connect or a handshake failure comes back as a linked
      # init error rather than a raise; name it as the connect it is.
      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  rescue
    e -> {:error, {:connect, e}}
  catch
    kind, reason -> {:error, {:connect, {kind, reason}}}
  end

  # -- the announce -------------------------------------------------------

  # The follow first, then the pub message: the engine ingests both on
  # publish, and social_msg's dispatch of the announce is what writes
  # the address into conn.json — the pub is dialable from the next
  # pass onward with nothing else to do here.
  defp announce_via_engine(%{host: host, port: port, pub_id: pub_id}) do
    case Timeline.follow(pub_id) do
      {:error, reason} ->
        {:error, {:announce, reason}}

      {:ok, _} ->
        case Timeline.announce_pub(host, port, pub_id) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:announce, reason}}
        end
    end
  end

  # Best effort: a failed kick leaves the pub for the next pass, which
  # the announce has already queued it for.
  defp trigger_dialer do
    _ = Admin.dialer_trigger()
    :ok
  end

  # "@<b64>.ed25519" in the engine's spelling — padded standard base64,
  # the form keys:pub_key_disp and every published message use.
  defp display_id(pub_key), do: "@" <> Base.encode64(pub_key) <> ".ed25519"

  defp base64(str) do
    str = String.trim(str)
    padded = str <> String.duplicate("=", rem(4 - rem(byte_size(str), 4), 4))

    case Base.decode64(padded) do
      {:ok, bin} -> {:ok, bin}
      :error -> Base.url_decode64(padded)
    end
  end
end
