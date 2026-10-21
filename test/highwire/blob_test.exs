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

  describe "media_type/1" do
    test "a picture is a picture" do
      hex = put_blob("png", <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "bytes">>)

      assert Blob.media_type(ref_for(hex)) == :image
    end

    test "a recording is a recording" do
      hex = put_blob("mp3", <<0xFF, 0xFB, "frame">>)

      assert Blob.media_type(ref_for(hex)) == :audio
    end

    test "a film is a film" do
      hex = put_blob("webm", <<0x1A, 0x45, 0xDF, 0xA3, "bytes">>)

      assert Blob.media_type(ref_for(hex)) == :video
    end

    test "anything else is a file" do
      hex = put_blob("pdf", "%PDF-1.4 rest")

      assert Blob.media_type(ref_for(hex)) == :file
    end

    test "bytes that have not arrived are missing" do
      hex = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

      assert Blob.media_type(ref_for(hex)) == :missing
    end

    test "a reference that is not a blob is missing" do
      assert Blob.media_type("not-a-blob") == :missing
      assert Blob.media_type("&nope=.sha256") == :missing
    end
  end

  describe "content_type/1" do
    test "the type comes from the bytes, not from a name" do
      hex = put_blob("mp3-type", <<0xFF, 0xFB, "frame">>)
      path = Path.join(Blob.cache_root(), hex)

      assert Blob.content_type(path) == {:ok, "audio/mpeg"}
    end

    test "an unreadable file has no type" do
      assert Blob.content_type(Path.join(Blob.cache_root(), "nothing-here")) ==
               {:error, :unreadable}
    end
  end

  # A blob on disk, so the renderer and the route can see its bytes.
  defp put_blob(seed, bytes) do
    hex = Base.encode16(:crypto.hash(:sha256, seed), case: :lower)
    path = Path.join(Blob.cache_root(), hex)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    hex
  end

  describe "ref/1" do
    test "is the id the engine hashes back: &<standard base64 sha256>.sha256" do
      # erlbutt's hash_id/1 is "&" ++ base64:encode(sha256(Blob)) ++
      # ".sha256", and blobs.add verifies the streamed bytes against the
      # id its opening frame carried — so this exact string is what the
      # add must be given, or every blob would come back hash_mismatch.
      assert Blob.ref("hello") == "&LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ=.sha256"

      assert Blob.ref("") ==
               "&" <> Base.encode64(:crypto.hash(:sha256, "")) <> ".sha256"
    end

    test "ref_to_hex/1 reads it back as the digest hex the store is keyed by" do
      hex = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
      assert Blob.ref_to_hex(Blob.ref("hello")) == {:ok, hex}
    end
  end
end
