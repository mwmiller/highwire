defmodule HighWire.SSB.KeysTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Keys

  test "loads a comment-wrapped ssb-keys secret" do
    pub = Base.encode64(:crypto.strong_rand_bytes(32))
    priv = Base.encode64(:crypto.strong_rand_bytes(64))

    secret = """
    # SSB-KEYS-JSON
    # comment line
    %comment too
    {
      "curve": "ed25519",
      "public": "#{pub}.ed25519",
      "private": "#{priv}.ed25519",
      "id": "@#{pub}.ed25519"
    }
    """

    path = Path.join(System.tmp_dir!(), "hw-keys-#{:erlang.unique_integer([:positive])}")
    File.write!(path, secret)

    keys = Keys.load!(path)
    File.rm(path)

    assert keys.id == "@#{pub}.ed25519"
    assert byte_size(keys.public) == 32
    assert byte_size(keys.secret) == 64
    assert keys.public == Keys.id_to_public(keys.id)
  end
end
