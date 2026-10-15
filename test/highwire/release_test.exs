defmodule HighWire.ReleaseTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias HighWire.Release

  @tag :tmp_dir
  test "nif_paths finds both the app's and the engine's enacl NIFs", %{tmp_dir: dir} do
    app = Path.join([dir, "lib", "enacl-1.1.1", "priv", "enacl_nif.so"])

    engine =
      Path.join([
        dir,
        "lib",
        "highwire-1.1.7",
        "priv",
        "erlbutt",
        "lib",
        "enacl-1.1.1",
        "priv",
        "enacl_nif.so"
      ])

    for nif <- [app, engine] do
      File.mkdir_p!(Path.dirname(nif))
      File.write!(nif, "")
    end

    assert Enum.sort(Release.nif_paths(dir)) == Enum.sort([app, engine])
  end

  @tag :tmp_dir
  test "bundle_libsodium leaves a release intact when a NIF cannot be read", %{tmp_dir: dir} do
    nif = Path.join([dir, "lib", "enacl-1.1.1", "priv", "enacl_nif.so"])
    File.mkdir_p!(Path.dirname(nif))
    File.write!(nif, "not an object file")

    capture_io(:stderr, fn ->
      assert %{path: ^dir} = Release.bundle_libsodium(%{path: dir})
    end)

    assert File.read!(nif) == "not an object file"
  end
end
