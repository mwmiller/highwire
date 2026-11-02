defmodule HighWire.SSB.Erpc do
  @moduledoc """
  One-shot calls to the local engine over distributed Erlang.

  The muxrpc path pays for every request a fresh TCP connection plus a
  Secret Handshake: the local client connects, authenticates, asks one
  question and tears everything down. The engine's half of that exchange
  starts a connection process and an rpc_processor and whatever the
  request touches, then stops them again — the log's bill for the
  control surface was 25,000 connection setups over nine days, each one
  a handshake's worth of crypto for a single map.

  When this VM spawns the engine, both nodes are on loopback and already
  trust each other — the spawn hands the engine this node's cookie — so
  the same question reaches it as an `erpc` call over the one
  distribution connection: no handshake, nothing started for the
  request, one round trip.

  Only the engine's plugin methods are reachable this way. Dispatch for
  the builtins (`whoami`, `publish`, `get`, the full-log streams,
  `blobs.*`) lives inside the engine's muxrpc connection machinery and
  has no callable entry point on its node, so those keep riding
  `HighWire.SSB.Client` — where the callers that need them already hold
  one open, a persistent connection carrying each for the cost of frame
  encoding. It is the one-shot pattern, not the wire, that this module
  removes.

  `call/3` answers the way `HighWire.SSB.Client.call/4` does: `{:ok,
  term}` or `{:error, term}`, with the engine's EJSON decoded to the
  terms Jason would have produced, so call sites cannot tell the
  transport apart. Degradation is total: no node of ours (an attached
  engine, distribution that would not start, the engine gone mid-call)
  answers `{:error, :no_engine}` and callers fall back to the muxrpc
  path; a method no plugin answers `{:error, :unknown_method}` — the
  same reply the muxrpc dispatcher gives, minus the connection; a
  builtin answers `{:error, :builtin}` so a caller holding a client can
  fall back where the wire can serve it.

  A caller holding the distribution cookie is the node's root, so these
  calls run as class `owner` — the same class the one-shot clients get
  by authenticating with the account's own keypair. Owner clears
  `plugin_registry:allowed/2` for every permission (room resolves
  through owner too), so the lattice is reasoned about here rather than
  paid for as a second round trip.
  """

  alias HighWire.SSB.Sidecar

  @type result :: {:ok, term()} | {:error, term()}

  # What the engine's plugin handlers see as the caller. The class is
  # the part that gates; feed_id is the field handlers log, and a local
  # node has no remote feed id to name.
  @owner %{class: :owner, feed_id: :undefined}

  @doc """
  Ask the engine for `name` with `args`, or say why it cannot.

  Answers `{:ok, term}` or `{:error, term}` within `timeout` — never
  raises, never hangs past it.
  """
  @spec call([String.t()], term(), timeout()) :: result()
  def call(name, args, timeout \\ 5_000)

  def call(name, args, timeout) do
    case Sidecar.engine_node() do
      nil -> {:error, :no_engine}
      node -> erpc_call(node, name, args, timeout)
    end
  catch
    # The sidecar went away between naming its node and this call — a
    # GenServer call to a process that just died. There is no engine to
    # ask, which is the same answer as a node that would not answer.
    :exit, _reason -> {:error, :no_engine}
  end

  # The lookup first: it is the dispatch table the muxrpc dispatcher
  # itself reads, so both transports agree on what exists and what it
  # costs. An exception on the distribution path (nodedown, timeout)
  # means the path is unusable and answers :no_engine; an exception
  # raised by the handler itself is the engine's own answer to report.
  defp erpc_call(node, name, args, timeout) do
    case :erpc.call(node, :plugin_registry, :lookup, [name], timeout) do
      {:ok, {mod, _kind, _perm}} -> dispatch(node, mod, name, args, timeout)
      {:builtin, _kind, _perm} -> {:error, :builtin}
      :unknown -> {:error, :unknown_method}
    end
  catch
    :error, {:erpc, _reason} -> {:error, :no_engine}
    :error, :timeout -> {:error, :no_engine}
    kind, reason -> {:error, {:engine, kind, reason}}
  end

  defp dispatch(node, mod, name, args, timeout) do
    case :erpc.call(node, mod, :handle_rpc, [name, args, @owner], timeout) do
      {:reply, ejson} -> {:ok, from_ejson(ejson)}
      # The same answers the muxrpc dispatcher turns into error frames:
      # a binary reason is the handler's own, anything else logged there
      # and reported as "internal error". Callers cannot tell which
      # transport carried the reply.
      {:error, reason} when is_binary(reason) -> {:error, from_ejson(reason)}
      _other -> {:error, "internal error"}
    end
  catch
    :error, {:erpc, _reason} -> {:error, :no_engine}
    :error, :timeout -> {:error, :no_engine}
    kind, reason -> {:error, {:engine, kind, reason}}
  end

  # EJSON decoded to the terms the JSON round trip used to produce:
  # {Props} objects become maps keyed by the same binaries Jason left
  # them with, `null` becomes nil, and everything else — binaries,
  # numbers, booleans — already is what it was. Duplicate keys resolve
  # to the last entry, again as Jason.decode does. Anything unrecognized
  # passes through untouched rather than failing a call the engine
  # successfully answered.
  @doc false
  def from_ejson({props}) when is_list(props) do
    Map.new(props, fn {key, value} -> {key, from_ejson(value)} end)
  end

  def from_ejson(list) when is_list(list), do: Enum.map(list, &from_ejson/1)
  def from_ejson(:null), do: nil
  def from_ejson(other), do: other
end
