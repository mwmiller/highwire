defmodule HighWire.SSB.Client do
  @moduledoc """
  A muxrpc client over SHS: connects to the local erlbutt sidecar,
  completes the Secret Handshake, then speaks box-stream + muxrpc.

  `call/3` performs sync/async requests (one reply). `stream/3` opens a
  source stream; items arrive as `{HighWire.SSB.Client, req, {:item, term}}`
  messages to the subscriber, terminated by `:done` or `{:error, term}`.
  `sink/4` is the other direction: it pushes a whole body at the engine
  (`blobs.add`) and answers with the engine's one end frame.
  `req` is unique across connections, not per connection, so a
  subscriber holding streams from more than one of them can tell the
  two apart.

  Authenticating with the account's own keypair makes the sidecar treat
  this connection as `owner` class (publish, createUserStream, …);
  a fresh ephemeral keypair is `anyone` class.
  """

  use GenServer, restart: :temporary

  alias HighWire.SSB.{BoxStream, Muxrpc, SHS}

  defstruct [
    :sock,
    :enc_key,
    :enc_nonce,
    :dec_key,
    :dec_nonce,
    box_buf: <<>>,
    rpc_buf: <<>>,
    calls: %{}
  ]

  # -- API ---------------------------------------------------------------

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @spec call(pid(), [String.t()], term(), timeout()) :: {:ok, term()} | {:error, term()}
  def call(client, name, args, timeout \\ 5_000) do
    GenServer.call(client, {:call, name, args}, timeout)
  end

  @spec stream(pid(), [String.t()], term(), pid()) :: {:ok, non_neg_integer()}
  def stream(client, name, args, subscriber \\ self()) do
    GenServer.call(client, {:stream, name, args, subscriber})
  end

  @doc """
  Push `body` at the engine as the muxrpc sink `name` and wait for it to
  finish.

  Nothing comes back until every frame has gone out, so this call blocks
  for as long as the upload takes — that is what its own timeout is for,
  not the sync-call default. `{:ok, true}` means the engine stored the
  body; `{:error, reason}` means it refused it (over its blob cap, or
  bytes that do not hash to the id the sink was opened with).
  """
  @spec sink(pid(), [String.t()], term(), binary(), timeout()) ::
          {:ok, term()} | {:error, term()}
  def sink(client, name, args, body, timeout \\ 30_000) do
    GenServer.call(client, {:sink, name, args, body}, timeout)
  end

  @spec stop(pid()) :: :ok
  def stop(client), do: GenServer.stop(client)

  # -- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    host = Keyword.get(opts, :host, ~c"127.0.0.1")
    port = Keyword.fetch!(opts, :port)
    remote_pk = Keyword.fetch!(opts, :remote_pk)
    net_id = Keyword.fetch!(opts, :net_id)
    keys = Keyword.fetch!(opts, :keys)

    {:ok, sock} = :gen_tcp.connect(host, port, [:binary, active: false, packet: :raw], 5_000)

    send! = fn data ->
      case :gen_tcp.send(sock, data) do
        :ok -> :ok
        {:error, reason} -> raise "SHS send failed: #{inspect(reason)}"
      end
    end

    recv! = fn n ->
      case :gen_tcp.recv(sock, n, 5_000) do
        {:ok, data} -> data
        {:error, reason} -> raise "SHS receive failed: #{inspect(reason)}"
      end
    end

    {:ok, %{enc_key: ek, enc_nonce: en, dec_key: dk, dec_nonce: dn}} =
      SHS.handshake(send!, recv!, remote_pk, net_id, keys)

    :ok = :inet.setopts(sock, active: :once)

    {:ok,
     %__MODULE__{
       sock: sock,
       enc_key: ek,
       enc_nonce: en,
       dec_key: dk,
       dec_nonce: dn
     }}
  end

  @impl true
  def handle_call({:call, name, args}, from, state) do
    req = next_req_id()
    state = send_packet(state, Muxrpc.encode_request(req, name, args, "sync", 0))
    {:noreply, Map.put(state, :calls, Map.put(state.calls, req, {:call, from}))}
  end

  def handle_call({:stream, name, args, subscriber}, _from, state) do
    req = next_req_id()
    state = send_packet(state, Muxrpc.encode_request(req, name, args, "source", 1))
    state = Map.put(state, :calls, Map.put(state.calls, req, {:stream, subscriber}))
    {:reply, {:ok, req}, state}
  end

  # Every frame of the sink goes out now, each as its own boxed packet —
  # the same shape as any other request, and the only way the box layer's
  # 4 KiB plaintext frame can carry 5 MiB without a separate buffer.
  def handle_call({:sink, name, args, body}, from, state) do
    req = next_req_id()

    state =
      Enum.reduce(Muxrpc.encode_sink(req, name, args, body), state, fn frame, acc ->
        send_packet(acc, frame)
      end)

    {:noreply, Map.put(state, :calls, Map.put(state.calls, req, {:sink, from}))}
  end

  @impl true
  def handle_info({:tcp, sock, data}, state) do
    :inet.setopts(sock, active: :once)
    {:noreply, pump(%{state | box_buf: state.box_buf <> data})}
  end

  def handle_info({:tcp_closed, sock}, state) when sock == state.sock do
    {:stop, :normal, fail_all(state, :closed)}
  end

  def handle_info({:tcp_error, _sock, reason}, state) do
    {:stop, :normal, fail_all(state, reason)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = fail_all(state, :closed)
    :ok
  end

  # -- box-stream / muxrpc pump -----------------------------------------

  defp pump(state) do
    case BoxStream.unbox(state.box_buf, state.dec_nonce, state.dec_key) do
      {:frame, payload, nonce, rest} ->
        state = %{state | dec_nonce: nonce, box_buf: rest, rpc_buf: state.rpc_buf <> payload}
        state |> pump_rpc() |> pump()

      {:end, _nonce} ->
        fail_all(state, :peer_closed)

      :partial ->
        state
    end
  end

  defp pump_rpc(state) do
    case Muxrpc.decode(state.rpc_buf) do
      {:packet, meta, body, rest} ->
        %{state | rpc_buf: rest} |> route(meta, body) |> pump_rpc()

      {:rpc_end, _rest} ->
        fail_all(state, :peer_closed)

      :partial ->
        state
    end
  end

  # Server-initiated request (EBT, wants, …): this client opens none
  # and answers none.
  defp route(state, %{req: req}, _body) when req > 0, do: state

  defp route(state, %{req: neg} = meta, body) when neg < 0 do
    req = -neg

    case Map.fetch(state.calls, req) do
      {:ok, {:call, from}} ->
        GenServer.reply(from, decode_reply(body))
        %{state | calls: Map.delete(state.calls, req)}

      {:ok, {:stream, subscriber}} ->
        deliver(subscriber, req, meta, decode_reply(body))

        if meta.end == 1 do
          %{state | calls: Map.delete(state.calls, req)}
        else
          state
        end

      {:ok, {:sink, from}} ->
        # A sink answers exactly once, on its end frame: JSON `true` when
        # the engine took the bytes, an error body when it refused them.
        if meta.end == 1 do
          GenServer.reply(from, decode_reply(body))
          %{state | calls: Map.delete(state.calls, req)}
        else
          state
        end

      :error ->
        state
    end
  end

  defp deliver(sub, req, %{end: 1, stream: 1}, {:ok, true}) do
    send(sub, {__MODULE__, req, :done})
  end

  defp deliver(sub, req, %{end: 1}, {:error, body}) do
    send(sub, {__MODULE__, req, {:error, body}})
  end

  defp deliver(sub, req, _meta, {:ok, body}) do
    send(sub, {__MODULE__, req, {:item, body}})
  end

  # Muxrpc encodes errors two ways. A structured error — `{"error": …}`
  # — is caught here. But some "not found" / failure replies arrive as a
  # *successful* body that is itself an error-shaped map: erlang's
  # `{error, {name, message, stack}}` marshalled as
  # `{"name": "Error", "message": …, "stack": …}`. Treating those as data
  # (the old behavior) let a missing message render as a truthy ghost and
  # starve every downstream fallback. Recognize that shape and fail it
  # too, so every call site sees a uniform `{:error, …}` instead of
  # having to re-learn the engine's two failure encodings.
  @doc false
  def decode_reply(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => err}} -> {:error, err}
      {:ok, decoded} -> classify_body(decoded)
      {:error, _} -> {:ok, body}
    end
  end

  defp classify_body(%{"name" => name, "message" => message} = err)
       when is_binary(name) and is_binary(message) do
    if error_name?(name), do: {:error, err}, else: {:ok, err}
  end

  defp classify_body(decoded), do: {:ok, decoded}

  # An erlang-style error term marshalled by erlbutt uses the name "Error".
  # A real data map never pairs a top-level "name" with a "message" string,
  # so this only fires on the failure shape we have hard evidence for.
  defp error_name?("Error"), do: true
  defp error_name?(_), do: false

  defp send_packet(state, packet) do
    {bytes, nonce} = BoxStream.box(packet, state.enc_nonce, state.enc_key)
    :ok = :gen_tcp.send(state.sock, bytes)
    %{state | enc_nonce: nonce}
  end

  # Every req id is drawn fresh from the VM's unique source — never a
  # per-process counter. One subscriber listens on several connections at
  # once (the Timeline runs the contact and about drains on a dedicated
  # connection beside the main one) and dispatches on req alone: two
  # connections that count from their own starting number hand the same
  # handle to both streams, and the wrong handler swallows the other's
  # items and `:done` — which is how the about pass was starved into
  # never landing and the rail stayed blank.
  defp next_req_id, do: System.unique_integer([:positive, :monotonic])

  defp fail_all(state, reason) do
    Enum.each(state.calls, fn
      {req, {:call, from}} ->
        _ = req
        GenServer.reply(from, {:error, reason})

      {req, {:stream, sub}} ->
        send(sub, {__MODULE__, req, {:error, reason}})

      {req, {:sink, from}} ->
        _ = req
        GenServer.reply(from, {:error, reason})
    end)

    %{state | calls: %{}}
  end
end
