defmodule HighWire.AvatarTest do
  use ExUnit.Case, async: true

  alias HighWire.Avatar

  # (id, expected) vectors verified against color-hash v1.0.3 running
  # on Node — HighWire must be pixel-identical to Poncho Wonky's tiles.
  @vectors [
    {"@DgsA6kZleyiuliE8SeUDtF3Slw3f92tUaT2xjH5cNg8=.ed25519", "#6c83e0"},
    {"@ASFlv8MHXcuHeRMruDnUPZwMkFTx+t1fYvoP7xWkXRo=.ed25519", "#21931f"},
    {"@sYXOD+IrwXf52z2AE6+ZynR1vLEX4t9uuC1xlCp4Ok4=.ed25519", "#71bf40"},
    {"@Sur8RwcDh6kBjub8pLZpHNWDfuuRpYVyCHrVo+TdA/4=.ed25519", "#82d279"},
    {"a", "#966ce0"},
    {"@0W1ekqmNIN4e1", "#53ac99"}
  ]

  test "hex/1 matches color-hash v1.0.3 byte for byte" do
    for {id, expected} <- @vectors do
      assert Avatar.hex(id) == expected, "hex(#{inspect(id)})"
    end
  end

  test "short_id/1 is Patchwork's shortFeedId (id.slice(1, 10))" do
    assert Avatar.short_id("@DgsA6kZleyiuliE8SeUDtF3Slw3f92tUaT2xjH5cNg8=.ed25519") ==
             "DgsA6kZle"
  end

  test "identicon_url/1 hex-encodes the feed id" do
    assert Avatar.identicon_url("@ab=.ed25519") ==
             "/identicon/" <> Base.encode16("@ab=.ed25519", case: :lower)
  end

  test "avatar_src/1 prefers the blob and falls back to the identicon" do
    digest = :crypto.strong_rand_bytes(32)
    ref = "&" <> Base.encode64(digest) <> ".sha256"
    hex = Base.encode16(digest, case: :lower)

    assert Avatar.avatar_src("@id", ref) == "/blob/" <> hex
    assert Avatar.avatar_src("@id", nil) == Avatar.identicon_url("@id")
    assert Avatar.avatar_src("@id", "not-a-ref") == Avatar.identicon_url("@id")
  end

  test "rev_query/1 only busts caches for a positive revision" do
    assert Avatar.rev_query(nil) == ""
    assert Avatar.rev_query(0) == ""
    assert Avatar.rev_query(7) == "?v=7"
  end
end
