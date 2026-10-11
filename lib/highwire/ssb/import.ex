defmodule HighWire.SSB.Import do
  @moduledoc """
  The guided hand-off from a JS-client store (`~/.ssb`) into HighWire's
  own engine home.

  HighWire reads the old store and never writes it. Detection is a few
  `stat`s, conversion runs from the flume directory through erlbutt's
  own converter, and every file that changes lives under
  `HIGHWIRE_HOME`.

  The three steps, and the marker that makes them restart-safe:

    * `detect/0` — a JS `secret` exists *and* (no local secret yet, or
      the `.importing` marker is present) → `{:ok, info}`; anything
      else is `:none`. The marker is what an interrupted import leaves
      behind, so a crash mid-conversion is offered again on the next
      launch rather than half-completing silently. Once HighWire holds
      a secret of its own the offer is gone: an identity that arrived
      some other way is not up for replacement.

    * `prepare/0` — deliberately ordered: write the marker first (no
      destructive step happens until recovery is armed), wipe the
      partial local state, then copy the secret in. The wipe covers
      only what the converter rebuilds — `feeds/`, `store.db` and its
      journals, the ingest journal, the view snapshot, the invite and
      room tables. `blobs/`, `conn.json`, `overrides.cfg` and
      `data_version` are kept: they are not the old identity's, and
      blobs are content-addressed.

    * the sidecar runs the converter and clears the marker only when
      it reports done, so the store never holds a half-import that
      looks finished.

  On completion — or when the user chooses to start fresh — the marker
  goes away and the identity either arrives through the copied secret
  or is minted by the engine's first boot.
  """

  require Logger

  alias HighWire.SSB.Keys

  @marker ".importing"

  @typedoc """
  What `detect/0` found in the JS store: whose identity it is, whether
  a flume log is there to convert (and how big), and whether the JS
  blob store can supply referenced blobs.
  """
  @type info :: %{
          id: String.t(),
          log_path: Path.t() | nil,
          log_size: non_neg_integer() | nil,
          blobs: boolean()
        }

  @config_key :js_home

  @doc """
  The JS client's store directory — `~/.ssb` by default, `%APPDATA%\\ssb`
  on Windows, and whatever the configuration sets otherwise (tests point
  it somewhere that does not exist).
  """
  @spec js_home() :: Path.t()
  def js_home do
    case config()[@config_key] do
      nil -> default_js_home()
      path -> Path.expand(path)
    end
  end

  @doc """
  Offer the import? `{:ok, info}` when the JS store is present and this
  HighWire has no identity of its own yet — or the previous import was
  interrupted, which the marker records.
  """
  @spec detect() :: {:ok, info()} | :none
  def detect do
    secret = js_secret()

    cond do
      not File.regular?(secret) ->
        :none

      not marker?() and File.exists?(local_secret()) ->
        :none

      true ->
        case id_of(secret) do
          nil ->
            Logger.warning("import: cannot read #{secret} — starting fresh instead")
            :none

          id ->
            {:ok, info(id)}
        end
    end
  end

  @doc """
  Arm recovery, clear whatever a previous attempt left behind, and take
  on the JS identity. Called only after the sidecar has stopped every
  engine that could hold the store — one feed, one writer.
  """
  @spec prepare() :: :ok | {:error, term()}
  def prepare do
    with :ok <- precheck(),
         :ok <- File.mkdir_p(repo()),
         :ok <- write_marker(),
         :ok <- wipe() do
      copy_secret()
    end
  end

  @doc "The marker file: present from the moment an import is accepted."
  @spec marker_path() :: Path.t()
  def marker_path, do: Path.join(HighWire.home_dir(), @marker)

  @spec marker?() :: boolean()
  def marker?, do: File.exists?(marker_path())

  @spec clear_marker() :: :ok | {:error, term()}
  def clear_marker do
    case File.rm(marker_path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The flume log to convert, or nil for an identity-only import."
  @spec log_path() :: Path.t() | nil
  def log_path do
    path = Path.join(js_home(), "log.offset")
    if File.regular?(path), do: path
  end

  @doc "The JS blob store to copy referenced blobs from, or nil."
  @spec blobs_src() :: Path.t() | nil
  def blobs_src do
    path = Path.join(js_home(), "blobs")
    if File.dir?(path), do: path
  end

  @spec js_secret() :: Path.t()
  def js_secret, do: Path.join(js_home(), "secret")

  @spec local_secret() :: Path.t()
  def local_secret, do: Path.join([repo(), "secret"])

  @spec repo() :: Path.t()
  def repo, do: Path.join(HighWire.home_dir(), ".ssberl")

  # -- detect -------------------------------------------------------------

  defp info(id) do
    log = log_path()

    %{
      id: id,
      log_path: log,
      log_size: log && file_size(log),
      blobs: blobs_src() != nil
    }
  end

  defp id_of(secret) do
    keys = Keys.load!(secret)
    if is_binary(keys.id), do: keys.id
  rescue
    _ -> nil
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  # -- prepare ------------------------------------------------------------

  # Everything destructive sits behind this: a store that vanished
  # between detection and the click must not be wiped for nothing.
  defp precheck do
    if File.regular?(js_secret()), do: :ok, else: {:error, :no_js_secret}
  end

  # The derived tier only: what the converter rebuilds. Kept as a fixed
  # list rather than a glob so nothing under `.ssberl/` is ever matched
  # by accident (paths may contain glob characters).
  @wiped ["feeds", "views", "invites.tab", "room_members.tab"]

  defp wipe do
    names =
      case File.ls(repo()) do
        {:ok, names} -> names
        {:error, _} -> []
      end

    names
    |> Enum.filter(&derived?/1)
    |> Enum.reduce(:ok, &wipe_one/2)
  end

  defp wipe_one(name, acc) do
    case rm_rf(Path.join(repo(), name)) do
      :ok -> acc
      {:error, _} = err -> if acc == :ok, do: err, else: acc
    end
  end

  # sqlite's sidecars travel as `store.db-wal` and friends, so the two
  # file-backed stores are matched by prefix and the rest by name.
  defp derived?(name) do
    name in @wiped or String.starts_with?(name, "store.db") or
      String.starts_with?(name, "ingest.journal")
  end

  defp rm_rf(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, _file} -> {:error, {path, reason}}
    end
  end

  defp copy_secret do
    with :ok <- File.cp(js_secret(), local_secret()) do
      # The old store's secret is the whole identity: keep it as tight
      # as the engine keeps its own.
      case File.chmod(local_secret(), 0o600) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end
  end

  # -- misc ---------------------------------------------------------------

  defp write_marker do
    File.write(marker_path(), "import accepted #{System.system_time(:second)}\n")
  end

  defp default_js_home do
    case System.get_env("APPDATA") do
      nil -> Path.expand("~/.ssb")
      appdata -> Path.join(appdata, "ssb")
    end
  end

  defp config, do: Application.get_env(:highwire, :ssb, [])
end
