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

  # -- staging ------------------------------------------------------------

  @staged_dir "import-log"
  @chunk 4_194_304
  @record_start "{\"key\":\"%"

  defp rewrite(src, dest) do
    with {:ok, input} <-
           :file.open(String.to_charlist(src), [:read, :binary, :raw, {:read_ahead, @chunk}]),
         {:ok, output} <- :file.open(String.to_charlist(dest), [:write, :binary, :raw]) do
      :ok = :file.truncate(output)
      result = copy_records(input, output, "", 0)
      :file.close(output)
      :file.close(input)
      result
    end
  end

  defp copy_records(input, output, buf, count) do
    case :binary.match(buf, @record_start) do
      :nomatch ->
        read_more(input, output, keep_tail(buf), count)

      {pos, _} ->
        stage_record(input, output, binary_part(buf, pos, byte_size(buf) - pos), count)
    end
  end

  # The start marker can straddle a chunk boundary, so its length minus
  # one byte of tail survives into the next read; anything shorter is
  # kept whole.
  defp keep_tail(buf) do
    keep = byte_size(@record_start) - 1

    if byte_size(buf) > keep,
      do: binary_part(buf, byte_size(buf) - keep, keep),
      else: buf
  end

  defp read_more(input, output, buf, count) do
    case :file.read(input, @chunk) do
      {:ok, chunk} -> copy_records(input, output, buf <> chunk, count)
      _ -> {:ok, count}
    end
  end

  # A frame is length, record, length again (the converter's integrity
  # check), then four bytes it skips. All three have to be there: without
  # the spacer every record after the first starts four bytes too early.
  defp stage_record(input, output, rest, count) do
    case record_end(rest, 0, 0, false) do
      {:ok, len} ->
        bin = binary_part(rest, 0, len)
        :ok = :file.write(output, <<len::32, bin::binary, len::32, 0::32>>)
        copy_records(input, output, binary_part(rest, len, byte_size(rest) - len), count + 1)

      :incomplete ->
        # Either the record runs past this buffer, or the bytes here are
        # not a record at all; the next chunk (or the next byte) decides
        # which.
        read_more(input, output, rest, count)
    end
  end

  defp record_end(bin, idx, _depth, _in_string) when idx >= byte_size(bin), do: :incomplete

  defp record_end(bin, idx, depth, in_string) do
    case :binary.match(bin, ["\"", "{", "}"], scope: {idx, byte_size(bin) - idx}) do
      :nomatch -> :incomplete
      {pos, 1} -> record_step(bin, pos, depth, in_string)
    end
  end

  # One structural byte: a quote toggles the string state (an escaped one
  # leaves it alone), a brace opens a level, and a closing brace ends the
  # record at the outer level or steps back in.
  defp record_step(bin, pos, depth, in_string) do
    case :binary.at(bin, pos) do
      ?" -> quote_step(bin, pos, depth, in_string)
      _ when in_string -> record_end(bin, pos + 1, depth, in_string)
      ?{ -> record_end(bin, pos + 1, depth + 1, in_string)
      ?} -> close_step(bin, pos, depth, in_string)
    end
  end

  defp quote_step(bin, pos, depth, in_string) do
    next = if escaped?(bin, pos), do: in_string, else: not in_string
    record_end(bin, pos + 1, depth, next)
  end

  defp close_step(_bin, pos, 1, _in_string), do: {:ok, pos + 1}
  defp close_step(bin, pos, depth, in_string), do: record_end(bin, pos + 1, depth - 1, in_string)

  defp escaped?(bin, pos), do: escaped?(bin, pos - 1, 0)
  defp escaped?(_bin, pos, slashes) when pos < 0, do: rem(slashes, 2) == 1

  defp escaped?(bin, pos, slashes) do
    if :binary.at(bin, pos) == ?\\,
      do: escaped?(bin, pos - 1, slashes + 1),
      else: rem(slashes, 2) == 1
  end

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
    # ssb-server, Patchwork and the other JS clients keep the log under
    # flume/; only very old layouts put it at the store root. Checking
    # both is what makes an existing history importable at all — a store
    # with a real log read as "identity only" and nothing converted.
    [Path.join([js_home(), "flume", "log.offset"]), Path.join(js_home(), "log.offset")]
    |> Enum.find(&File.regular?/1)
  end

  @doc """
  A clean copy of the JS log, ready for the converter.

  The log a long-lived JS client leaves behind is not always a tidy
  sequence of length-prefixed records: preallocated regions, torn writes
  and mixed framing leave runs of bytes that are not a record at all.
  erlbutt's converter stops at the first one, so the history reads as
  empty. This walks the file, picks out each `{"key":"%…` record by its
  braces, and rewrites the ones that are whole JSON into the framing the
  converter expects. Bytes that are not a record are skipped.

  The copy lives under `HIGHWIRE_HOME` and is removed once the import
  finishes; the JS store is only ever read.
  """
  @spec stage_log(Path.t() | nil) :: {:ok, Path.t(), non_neg_integer()} | {:error, term()}
  def stage_log(nil), do: {:error, :no_log}

  def stage_log(src) do
    dir = Path.join(HighWire.home_dir(), @staged_dir)
    out = Path.join(dir, "log.offset")
    tmp = out <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         {:ok, records} <- rewrite(src, tmp),
         :ok <- File.rename(tmp, out) do
      {:ok, out, records}
    end
  end

  @doc "Drop the staged log; the store holds the result now."
  @spec cleanup_staged() :: :ok
  def cleanup_staged do
    _ = File.rm_rf(Path.join(HighWire.home_dir(), @staged_dir))
    :ok
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
