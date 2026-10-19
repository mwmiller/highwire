defmodule HighWire.SSB.Identities do
  @moduledoc """
  The local identity registry: every feed this install can sign as,
  kept in `<home>/identities.json` (mode 0600), with the active one
  mirrored into `<home>/.ssberl/secret` — the file the engine and
  every muxrpc client authenticate with. Switching identities rewrites
  that mirror; the store (`store.db`, feeds, blobs) never moves.

  Lifecycle: an identity is born enabled. `disable/1` is reversible
  and takes it out of the switch list; only a disabled identity can
  be `destroy/1`ed, and that is permanent — the registry copy of the
  private key is dropped, so `export/1` it first if it still matters.
  Deleting leaves published history in the store, which is shared
  rather than owned.

  Installs that predate the registry (and engines that just minted a
  secret of their own) adopt into it via `ensure_boot/0`, called at
  sidecar boot and when the identity page opens. `active_id/0` trusts
  the secret over the registry, because the secret is what is actually
  running — a crash between the two writes therefore heals itself on
  the next `ensure_boot/0`.

  Reads never write: the rail's avatar path (`active_id/0`) is a pure
  lookup. Mutations — `create/1`, `activate/1`, `disable/1`,
  `enable/1`, `destroy/1` — persist atomically (temp file + rename,
  0600, since the private keys live here).
  """

  alias HighWire.SSB.Keys

  @registry "identities.json"
  @secret ".ssberl/secret"

  defp registry_path, do: Path.join(HighWire.home_dir(), @registry)
  defp secret_path, do: Path.join(HighWire.home_dir(), @secret)

  @doc """
  Public metadata for every identity in the registry — id, label,
  created_at, disabled — with the active one flagged and listed first.
  Never carries private key material.
  """
  @spec list() :: [map()]
  def list do
    active = active_id()

    load()["identities"]
    |> Enum.filter(&(is_map(&1) and is_binary(&1["id"])))
    |> Enum.map(fn row ->
      row
      |> Map.drop(["private"])
      |> Map.put("active", row["id"] == active)
    end)
    |> Enum.sort_by(fn row -> {not row["active"], -timestamp(row["created_at"])} end)
  end

  # created_at is written as a unix second, but a hand-edited or older
  # registry can carry null or a string; sorting must not raise on it.
  defp timestamp(n) when is_number(n), do: n
  defp timestamp(_), do: 0

  @doc """
  The id actually running: the secret's, falling back to the
  registry's active entry (engine disabled, nothing minted yet), and
  `nil` when neither exists. Pure lookup — never writes.
  """
  @spec active_id() :: String.t() | nil
  def active_id do
    case secret_id() do
      nil -> load()["active"]
      id -> id
    end
  end

  @doc "The active identity's public metadata, or nil when there is none."
  @spec active() :: map() | nil
  def active do
    id = active_id()
    if id, do: Enum.find(list(), &(&1["id"] == id))
  end

  @doc """
  Reconcile the registry with the secret: adopt a running identity
  the registry has never seen (a predating install, or an engine that
  minted its own), catch the registry's active entry up to the secret,
  and restore a vanished secret from the registry's active row.
  Idempotent; called at sidecar boot and on the identity page.
  """
  @spec ensure_boot() :: :ok | {:error, term()}
  def ensure_boot do
    reg = load()

    case secret_keys() do
      nil ->
        case registry_row(reg, reg["active"]) do
          nil -> :ok
          row -> write_secret(row)
        end

      keys ->
        updated = reg |> maybe_adopt(keys) |> Map.put("active", keys.id)
        if updated == reg, do: :ok, else: persist(updated)
    end
  end

  @doc """
  Mint a new ed25519 identity with `label`. The first one becomes the
  active identity (there is nothing to switch away from); later ones
  are created enabled but not active — switch to one to post as it.
  """
  @spec create(String.t()) :: {:ok, String.t()} | {:error, term()}
  def create(label) when is_binary(label) do
    %{public: public, secret: private} = :enacl.sign_keypair()
    id = "@" <> Base.encode64(public) <> ".ed25519"

    row = %{
      "id" => id,
      "label" => trim_label(label),
      "created_at" => now(),
      "disabled" => false,
      "public" => Base.encode64(public) <> ".ed25519",
      "private" => Base.encode64(private) <> ".ed25519"
    }

    reg = load()

    if registry_row(reg, id) do
      # Astronomically unlikely (fresh keypair), but the write stays
      # total either way: never silently duplicate a row.
      {:error, :duplicate}
    else
      reg = Map.put(reg, "identities", reg["identities"] ++ [row])

      if active_id() == nil do
        # Nothing is running: the first identity is the one you post
        # as, so it writes the secret too.
        first_identity(reg, row, id)
      else
        created(persist(reg), id)
      end
    end
  end

  def create(_label), do: {:error, :bad_label}

  defp first_identity(reg, row, id) do
    case write_secret(row) do
      :ok -> created(persist(Map.put(reg, "active", id)), id)
      error -> error
    end
  end

  defp created(:ok, id), do: {:ok, id}
  defp created({:error, _reason} = error, _id), do: error

  @doc """
  Whether `activate/1` would take this id: in the registry and not
  disabled.
  """
  @spec ensure_switchable(String.t()) :: :ok | {:error, :unknown_identity | :disabled_identity}
  def ensure_switchable(id) when is_binary(id) do
    row = registry_row(load(), id)

    cond do
      is_nil(row) -> {:error, :unknown_identity}
      row["disabled"] -> {:error, :disabled_identity}
      true -> :ok
    end
  end

  def ensure_switchable(_id), do: {:error, :unknown_identity}

  @doc """
  Write `id`'s keypair into `.ssberl/secret` and mark it active — the
  file-level half of an identity switch; `Sidecar.switch_identity/1`
  wraps it in the engine's stop → write → start. Refuses unknown and
  disabled identities. The registry is written first and the secret
  second, so a crash between them resolves to what was actually
  running (`active_id/0` trusts the secret) and the next
  `ensure_boot/0` catches the registry back up.
  """
  @spec activate(String.t()) :: :ok | {:error, term()}
  def activate(id) when is_binary(id) do
    case ensure_switchable(id) do
      :ok -> do_activate(id)
      error -> error
    end
  end

  def activate(_id), do: {:error, :unknown_identity}

  @doc """
  Take an identity out of the switch list. Reversible with `enable/1`,
  but the active identity must be switched away from first — exactly
  one identity is always able to post.
  """
  @spec disable(String.t()) :: :ok | {:error, term()}
  def disable(id) when is_binary(id) do
    reg = load()

    case registry_row(reg, id) do
      nil ->
        {:error, :unknown_identity}

      row ->
        cond do
          row["id"] == active_id() -> {:error, :active_identity}
          row["disabled"] -> :ok
          true -> set_disabled(reg, id, true)
        end
    end
  end

  def disable(_id), do: {:error, :unknown_identity}

  @doc "Put a disabled identity back on the switch list."
  @spec enable(String.t()) :: :ok | {:error, term()}
  def enable(id) when is_binary(id) do
    reg = load()

    case registry_row(reg, id) do
      nil -> {:error, :unknown_identity}
      row -> set_disabled(reg, id, not row["disabled"])
    end
  end

  def enable(_id), do: {:error, :unknown_identity}

  @doc """
  Permanently drop an identity's keypair from the registry. Only a
  disabled identity qualifies (disable first), and never the active
  one. Whatever it published stays in the store.
  """
  @spec destroy(String.t()) :: :ok | {:error, term()}
  def destroy(id) when is_binary(id) do
    reg = load()

    case registry_row(reg, id) do
      nil ->
        {:error, :unknown_identity}

      row ->
        cond do
          not row["disabled"] -> {:error, :not_disabled}
          row["id"] == active_id() -> {:error, :active_identity}
          true -> persist(Map.put(reg, "identities", reject_row(reg["identities"], id)))
        end
    end
  end

  def destroy(_id), do: {:error, :unknown_identity}

  @doc """
  The identity's keypair as an ssb-keys `secret` file — the escape
  hatch before a delete, and the way to carry an identity to another
  machine (which forks its feed: run one device at a time).
  """
  @spec export(String.t()) :: {:ok, String.t()} | {:error, term()}
  def export(id) when is_binary(id) do
    case registry_row(load(), id) do
      nil -> {:error, :unknown_identity}
      row -> {:ok, secret_text(row)}
    end
  end

  def export(_id), do: {:error, :unknown_identity}

  # -- storage ------------------------------------------------------------

  # A corrupt registry is never an outage: it degrades to "no
  # identities" — the secret still authenticates, the rail still
  # renders — and the damage stays visible on the identity page.
  defp load do
    with {:ok, body} <- File.read(registry_path()),
         {:ok, %{"identities" => rows} = reg} <- Jason.decode(body),
         true <- is_list(rows) do
      reg
    else
      _ -> %{"active" => nil, "identities" => []}
    end
  end

  defp persist(reg), do: write(registry_path(), Jason.encode!(reg))

  defp registry_row(%{"identities" => rows}, id) when is_binary(id),
    do: Enum.find(rows, &(is_map(&1) and &1["id"] == id))

  defp registry_row(_reg, _id), do: nil

  defp reject_row(rows, id), do: Enum.reject(rows, &(is_map(&1) and &1["id"] == id))

  defp set_disabled(reg, id, disabled?) do
    rows =
      Enum.map(reg["identities"], fn row ->
        if is_map(row) and row["id"] == id, do: Map.put(row, "disabled", disabled?), else: row
      end)

    persist(Map.put(reg, "identities", rows))
  end

  # Temp file + rename, so a crash mid-write leaves the previous file
  # intact instead of a half-written one; 0600 — private keys live in
  # both of these files.
  defp write(path, body) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, body)
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, path)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end

  # -- the secret ---------------------------------------------------------

  defp do_activate(id) do
    reg = load()
    row = registry_row(reg, id)

    case persist(Map.put(reg, "active", id)) do
      :ok ->
        case write_secret(row) do
          :ok -> :ok
          error -> revert(reg, error)
        end

      error ->
        error
    end
  end

  # The registry is the plan, the secret is the fact — if the fact
  # could not be written, put the plan back the way it was.
  defp revert(reg, error) do
    _ = persist(reg)
    error
  end

  defp write_secret(row), do: write(secret_path(), secret_text(row))

  # The ssb-keys header Poncho Wonky, Patchwork and erlbutt all write:
  # comment lines around one JSON object (the format HighWire.SSB.Keys
  # reads). Only the header names the public id; the body carries the
  # keypair.
  defp secret_text(row) do
    header = """
    # WARNING: Never show this to anyone.
    # WARNING: Never edit it or use it on multiple devices at once.
    #
    # This is your SECRET, it gives you magical powers. With your secret you can
    # sign your messages so that your friends can verify that the messages came
    # from you. If anyone learns your secret, they can use it to impersonate you.
    #
    # If you use this secret on more than one device you will create a fork and
    # your friends will stop replicating your content.
    #
    #
    # The only part of this file that's safe to share is your public name:
    #
    #   #{row["id"]}
    """

    body =
      Jason.encode!(%{
        "curve" => "ed25519",
        "public" => row["public"],
        "private" => row["private"],
        "id" => row["id"]
      })

    header <> body <> "\n"
  end

  # The running secret, decoded — nil when absent or unreadable (a
  # corrupt secret must not take the rail down with it).
  defp secret_keys do
    if File.exists?(secret_path()) do
      keys = Keys.load!(secret_path())

      if is_binary(keys.id) and is_binary(keys.public) and is_binary(keys.secret) do
        keys
      end
    end
  rescue
    _ -> nil
  end

  defp secret_id do
    case secret_keys() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp maybe_adopt(%{"identities" => rows} = reg, keys) do
    if Enum.any?(rows, &(is_map(&1) and &1["id"] == keys.id)) do
      reg
    else
      Map.put(reg, "identities", rows ++ [adopted_row(keys)])
    end
  end

  # The identity an install was already running before the registry
  # existed — named for what it is, not guessed at.
  defp adopted_row(keys) do
    %{
      "id" => keys.id,
      "label" => "Primary",
      "created_at" => now(),
      "disabled" => false,
      "public" => Base.encode64(keys.public) <> ".ed25519",
      "private" => Base.encode64(keys.secret) <> ".ed25519"
    }
  end

  defp trim_label(label) do
    case String.trim(label) do
      "" -> "Identity"
      trimmed -> trimmed
    end
  end

  defp now, do: System.system_time(:second)
end
