defmodule HighWire.SSB.Network do
  @moduledoc """
  The networks HighWire can join, and the single switch point between them.

  The engine decides what to dial and accept from its network id, read at
  boot from `.ssberl/overrides.cfg` and layered over the rendered
  `ssb.cfg` — erlbutt's own persistence file for settings that must
  survive a redeploy. Writing `{network_id, ...}` there is the whole
  switch: the next engine boot joins that network, and nothing else
  changes (feeds, blobs and views are network-agnostic).

  HighWire's own muxrpc client (the readiness probe, the dialer RPC, the
  timeline client) reads the same file through `current_id/0`, so
  loopback SHS always matches whatever the engine was last told.

  Two profiles exist on purpose. erlbutt's development id is a
  transposition of the real one, so a dev build can never reach mainnet
  by accident; joining is meant to be a deliberate act, and
  `set/1` is that act. The other id rides along as
  `{extra_network_ids, ...}`: outbound dials always use the primary, but
  the server side accepts either, so flipping back never loses inbound
  contact mid-transition.

  Posting is only permitted on the development network. Until the
  one-writer situation on mainnet is resolved (Patchwork still publishes
  this identity), `publishable?/0` stays false there and every publish
  path in the app refuses.
  """

  require Logger

  @dev_id "1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYnaR/s="
  @mainnet_id "1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYRan/s="

  @profiles [
    dev: {"Development", @dev_id},
    mainnet: {"Mainnet", @mainnet_id}
  ]

  @type profile :: :dev | :mainnet | :custom
  @type selectable :: :dev | :mainnet

  @doc "Every profile as `{atom, label}`, in menu order."
  @spec profiles() :: [{selectable(), String.t()}]
  def profiles, do: Enum.map(@profiles, fn {key, {label, _id}} -> {key, label} end)

  @spec id(selectable()) :: String.t()
  def id(:dev), do: @dev_id
  def id(:mainnet), do: @mainnet_id

  @spec label(profile()) :: String.t()
  def label(:dev), do: "Development"
  def label(:mainnet), do: "Mainnet"
  def label(:custom), do: "Other"

  @doc "The profile the overrides file (or app config) currently selects."
  @spec current() :: profile()
  def current do
    case current_id() do
      @mainnet_id -> :mainnet
      @dev_id -> :dev
      _other -> :custom
    end
  end

  @doc """
  Base64 network id — what the engine boots with and what the local
  muxrpc client must present over loopback.
  """
  @spec current_id() :: String.t()
  def current_id do
    overrides_network_id() || app_env_id() || @dev_id
  end

  @doc """
  Publishing is allowed only on the development network. On mainnet the
  identity still has a second writer (Patchwork), and two writers fork
  the feed for good — refuse until that is resolved.
  """
  @spec publishable?() :: boolean()
  def publishable?, do: current() == :dev

  @doc """
  Switch the primary network in `overrides.cfg`, keeping the other
  profile as an accepted `extra_network_ids` entry.

  The write preserves every other term already in the file (the peer
  dialer setting and friends), matching how erlbutt itself rewrites the
  file. Returns `:ok`, or `{:error, reason}` with the file untouched.
  """
  @spec set(selectable()) :: :ok | {:error, term()}
  def set(profile) when profile in [:dev, :mainnet] do
    chosen = id(profile)
    other = id(other(profile))

    terms =
      read_terms()
      |> Enum.reject(fn
        {key, _value} when key in [:network_id, :extra_network_ids] -> true
        _term -> false
      end)
      |> Enum.concat([
        {:network_id, String.to_charlist(chosen)},
        {:extra_network_ids, [String.to_charlist(other)]}
      ])

    path = path()
    body = [header(), Enum.map(terms, &:io_lib.format("~p.~n", [&1]))]

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case :file.write_file(String.to_charlist(path), body) do
          :ok ->
            Logger.info("network: primary is now #{label(profile)} (#{chosen})")
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  First boot: while no overrides file selects a network, seed it from
  the configured startup default — the app env's `net_id`, falling back
  to the development id. The engine reads the same file, so this keeps
  engine and local clients on one network from the very first spawn;
  later switches rewrite the file as before.
  """
  @spec ensure_default() :: :ok | {:error, term()}
  def ensure_default do
    if overrides_network_id() == nil do
      seed(current())
    else
      :ok
    end
  end

  defp seed(profile) when profile in [:dev, :mainnet] do
    case set(profile) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("network: could not seed overrides.cfg: #{inspect(reason)}")
    end
  end

  defp seed(_unknown), do: :ok

  @spec path() :: String.t()
  def path, do: Path.join([HighWire.home_dir(), ".ssberl", "overrides.cfg"])

  defp other(:dev), do: :mainnet
  defp other(:mainnet), do: :dev

  # Same header erlbutt's own persist writes, so files stay interchangeable
  # when the engine rewrites them at runtime.
  defp header do
    "%% Written by erlbutt at runtime.  Layered on top of ssb.cfg; " <>
      "survives a redeploy because it lives with the data.\n"
  end

  # {:network_id, v} from the overrides file, normalised to the base64
  # string form. Erlang consults give charlists for "..." terms and
  # binaries for <<"...">> terms; both are valid, accept both.
  defp overrides_network_id do
    case Enum.find_value(read_terms(), fn
           {:network_id, value} -> normalize(value)
           _other -> nil
         end) do
      nil -> nil
      "" -> nil
      id -> id
    end
  end

  defp normalize(value) when is_binary(value), do: value
  defp normalize(value) when is_list(value), do: List.to_string(value)
  defp normalize(_other), do: nil

  # A corrupt overrides file must not take the app down: the engine
  # ignores it too, so fall back to app config exactly as boot does.
  defp read_terms do
    case :file.consult(String.to_charlist(path())) do
      {:ok, terms} ->
        terms

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("network: ignoring unreadable #{path()}: #{inspect(reason)}")
        []
    end
  end

  defp app_env_id do
    :highwire
    |> Application.get_env(:ssb, [])
    |> Keyword.get(:net_id)
  end
end
