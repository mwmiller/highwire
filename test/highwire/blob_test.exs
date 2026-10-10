defmodule HighWire.BlobTest do
  @moduledoc """
  The blob key layout: HighWire addresses blobs the way the engine
  stores them — minimal uppercase hex of the digest, split two
  characters for the directory — and `local?/1` looks only at
  HighWire's own directories.
  """
  use ExUnit.Case, async: true

  alias HighWire.Blob

  describe "store_path/1" do
    test "matches erlbutt's layout: uppercase hex, first two characters are the dir" do
      hex = "0abc9f8e7d6c5b4a39281706f5e4d3c2b1a0f9e8d7c6b5a493827160ffeedd"

      # leading zero nibble stripped first, so the split happens on the
      # minimal form the engine actually wrote
      assert Blob.store_path(hex) ==
               Path.join([
                 Blob.store_root(),
                 "AB",
                 "C9F8E7D6C5B4A39281706F5E4D3C2B1A0F9E8D7C6B5A493827160FFEEDD"
               ])
    end

    test "a key without leading zeros splits as written" do
      hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff00"

      assert Blob.store_path(hex) ==
               Path.join([
                 Blob.store_root(),
                 "A1",
                 "B2C3D4E5F60718293A4B5C6D7E8F90112233445566778899AABBCCDDEEFF00"
               ])
    end

    test "a degenerate all-zero key answers nil — the engine cannot address it" do
      assert Blob.store_path(String.duplicate("0", 64)) == nil
    end
  end

  describe "local?/1" do
    test "true when the engine store holds the blob" do
      hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      store = Blob.store_path(hex)
      File.mkdir_p!(Path.dirname(store))
      File.write!(store, "bytes")
      on_exit(fn -> File.rm(store) end)

      assert Blob.local?(ref_for(hex))
    end

    test "false when neither cache nor store holds it" do
      hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
      refute Blob.local?(ref_for(hex))
    end

    test "unservable refs never generate wants" do
      assert Blob.local?("not-a-blob")
      assert Blob.local?("&nope=.sha256")
    end
  end

  defp ref_for(hex) do
    {:ok, bytes} = Base.decode16(hex, case: :mixed)
    "&" <> Base.encode64(bytes) <> ".sha256"
  end
end
