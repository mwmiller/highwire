# Every run gets its own store directory, so a stale run's leftovers or
# two suites at once cannot read each other's files. config/test.exs
# reads HIGHWIRE_TEST_HOME (set before this file is evaluated by
# ExUnit.start/1's callers — see below), and the dir goes away when the
# suite exits. A caller that has already set a home (a wrapper, or CI)
# keeps it.
test_home =
  System.get_env("HIGHWIRE_TEST_HOME") ||
    Path.join(
      System.tmp_dir!(),
      "highwire-test-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
    )

System.put_env("HIGHWIRE_TEST_HOME", test_home)
Application.put_env(:highwire, :application_dir, test_home)

# config/test.exs already ran against whatever HIGHWIRE_TEST_HOME held at
# config time (nil on a plain `mix test`, so it fell back to the shared
# dir). Both the app's own paths and the blob store read these keys at
# call time, but :blob_store is read from config — repoint it too.
Application.put_env(:highwire, :blob_store, Path.join(test_home, ".ssberl/blobs"))

File.mkdir_p!(test_home)

System.at_exit(fn _status ->
  File.rm_rf(test_home)
end)

ExUnit.start()
