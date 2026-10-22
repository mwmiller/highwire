# config/test.exs minted this run's store directory before the app
# started, so every index and store already points here. The dir goes
# away when the suite exits. A caller that has already set a home (a
# wrapper, or CI) keeps it — the mint below short-circuits on the env var.
test_home =
  System.get_env("HIGHWIRE_TEST_HOME") ||
    Path.join(
      System.tmp_dir!(),
      "highwire-test-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    )

System.put_env("HIGHWIRE_TEST_HOME", test_home)
Application.put_env(:highwire, :application_dir, test_home)

# The blob store is read from config — repoint it too.
Application.put_env(:highwire, :blob_store, Path.join(test_home, ".ssberl/blobs"))

File.mkdir_p!(test_home)

System.at_exit(fn _status ->
  File.rm_rf(test_home)
end)

ExUnit.start()
