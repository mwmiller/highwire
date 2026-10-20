defmodule HighWire.WebSecretTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias HighWire.WebSecret

  @moduletag :tmp_dir

  describe "fetch/1" do
    test "mints the install's key and persists it at mode 0600", %{tmp_dir: home} do
      secret = WebSecret.fetch(home)

      assert byte_size(secret) >= 64

      path = Path.join(home, "web_secret")
      assert File.read!(path) == secret
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "returns the stored key on later boots", %{tmp_dir: home} do
      first = WebSecret.fetch(home)

      assert WebSecret.fetch(home) == first
    end

    test "adopts a stored key, trimming a trailing newline", %{tmp_dir: home} do
      stored = String.duplicate("a", 88)
      File.write!(Path.join(home, "web_secret"), stored <> "\n")

      assert WebSecret.fetch(home) == stored
    end

    test "replaces a stored key too short to sign with", %{tmp_dir: home} do
      path = Path.join(home, "web_secret")
      File.write!(path, String.duplicate("a", 63))

      minted = WebSecret.fetch(home)

      assert byte_size(minted) >= 64
      assert File.read!(path) == minted
    end

    test "a home that cannot hold the file still yields a key", %{tmp_dir: home} do
      # A directory where the file belongs: the write fails, the key
      # is minted anyway, and the app keeps its boot.
      File.mkdir_p!(Path.join(home, "web_secret"))

      assert byte_size(WebSecret.fetch(home)) >= 64
    end
  end
end
