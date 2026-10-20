defmodule HighWire.WebSecret do
  @moduledoc """
  The web layer's signing key: session cookies and CSRF tokens are
  signed with it, so it is minted per install rather than shipped.

  Kept at `<home>/web_secret` (mode 0600) and minted on first boot, the
  same way the engine's secret is: the key appears in neither the
  repository nor the binary, and one install's copy forges nothing on
  another install. A home that cannot hold the file (read-only, full,
  unwritable) falls back to a per-boot key, which costs only cookie
  continuity across restarts — the local UI has no login to lose.
  """

  # Plug's cookie store signs sessions with this base and refuses
  # one under 64 bytes the first time a request touches the session,
  # so a stored key shorter than that was never one we minted —
  # mint over it.
  @min_bytes 64

  @doc """
  The install's web secret — reading the stored one, or minting and
  persisting a fresh one when the file is absent or too short to sign
  with.
  """
  @spec fetch(Path.t()) :: String.t()
  def fetch(home) do
    path = Path.join(home, "web_secret")

    case stored(path) do
      nil -> mint(path)
      secret -> secret
    end
  end

  defp stored(path) do
    with {:ok, body} <- File.read(path),
         secret when byte_size(secret) >= @min_bytes <- String.trim(body) do
      secret
    else
      _ -> nil
    end
  end

  defp mint(path) do
    secret = :crypto.strong_rand_bytes(64) |> Base.url_encode64()

    # Persistence is best-effort: an unwritable home degrades to a
    # per-boot key rather than keeping the app from starting. Temp
    # file + chmod + rename, so the stored key is whole and 0600.
    try do
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".tmp"
      File.write!(tmp, secret)
      File.chmod!(tmp, 0o600)
      File.rename!(tmp, path)
    rescue
      _ -> :ok
    end

    secret
  end
end
