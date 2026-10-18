defmodule HighWire.SSB.ConnSuppressTest do
  # Not async: the apply/1 cases point :application_dir at a temp home,
  # which is process-global state other suites also read.
  use ExUnit.Case, async: false

  alias HighWire.SSB.ConnSuppress

  defp peer(addr, extra \\ %{}) do
    Map.merge(%{"address" => addr, "autoconnect" => true}, extra)
  end

  describe "classify/2" do
    test "flags addresses that can never be dialed from here" do
      peers = [
        peer("net:127.0.0.1:8020~shs:key"),
        peer("net:10.1.2.3:8008~shs:key"),
        peer("net:192.168.0.5:8008~shs:key"),
        peer("net:172.20.1.1:8008~shs:key"),
        peer("net:foo.onion:8008~shs:key"),
        peer("net:2001:db8::1:8008~shs:key"),
        peer("ws://localhost:8999~shs:key"),
        peer("ws://pub.example.com:8999~shs:key"),
        peer("net:example.com:99999~shs:key")
      ]

      {addrs, counts} = ConnSuppress.classify(peers, %{})

      assert length(addrs) == 9
      # The host decides first: ws://localhost is loopback, scheme or
      # not — and a non-loopback ws:// address is still wrong scheme.
      assert counts[:loopback] == 2
      assert counts[:rfc1918] == 3
      assert counts[:onion] == 1
      assert counts[:ipv6] == 1
      assert counts[:scheme] == 1
      assert counts[:port] == 1
      assert counts[:total] == 9
    end

    test "localhost is a loopback whichever way the address spells it" do
      for addr <- ["net:localhost:32772~shs:key", "ws://localhost:8999~shs:key"] do
        {addrs, counts} = ConnSuppress.classify([peer(addr)], %{})

        assert addrs == [addr]
        assert counts[:loopback] == 1, addr
      end
    end

    test "flags an address with repeated failures and no handshake on record" do
      addr = "net:dead.example:8008~shs:key"
      meta = %{addr => %{"dial_attempts" => 5, "dial_ok_at" => 0}}

      {addrs, counts} = ConnSuppress.classify([peer(addr)], meta)

      assert addrs == [addr]
      assert counts[:no_reply] == 1
    end

    test "keeps an address that has ever answered, even while failing" do
      addr = "net:flap.example:8008~shs:key"
      meta = %{addr => %{"dial_attempts" => 9, "dial_ok_at" => 1_000}}

      {addrs, _counts} = ConnSuppress.classify([peer(addr)], meta)

      assert addrs == []
    end

    test "keeps a live public address" do
      {addrs, counts} = ConnSuppress.classify([peer("net:room.example:8008~shs:key")], %{})

      assert addrs == []
      assert counts[:total] == 0
    end

    test "skips entries already marked manual" do
      peer = peer("net:127.0.0.1:8020~shs:key", %{"autoconnect" => false})

      assert {[], counts} = ConnSuppress.classify([peer], %{})
      assert counts[:total] == 0
    end
  end

  describe "apply/1" do
    setup do
      home = Path.join(System.tmp_dir!(), "conn_suppress_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(home, ".ssberl"))

      conn = """
      {
          "net:127.0.0.1:8020~shs:key": {
              "announcers": 1,
              "autoconnect": true,
              "host": "127.0.0.1",
              "port": 8020
          },
          "net:room.example:8008~shs:key2": {
              "announcers": 1,
              "autoconnect": true,
              "host": "room.example",
              "port": 8008
          }
      }
      """

      File.write!(Path.join([home, ".ssberl", "conn.json"]), conn)

      previous = Application.get_env(:highwire, :application_dir)
      Application.put_env(:highwire, :application_dir, home)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:highwire, :application_dir, previous),
          else: Application.delete_env(:highwire, :application_dir)

        File.rm_rf!(home)
      end)

      {:ok, home: home}
    end

    test "flips only the selected entry and keeps a backup", %{home: home} do
      assert {:ok, 1, backup} = ConnSuppress.apply(["net:127.0.0.1:8020~shs:key"])

      assert File.exists?(backup)
      text = File.read!(Path.join([home, ".ssberl", "conn.json"]))

      # The suppressed line flipped; the other entry is untouched.
      assert text =~ ~r/"net:127\.0\.0\.1:8020~shs:key": \{[^}]*"autoconnect": false/s
      assert text =~ ~r/"net:room\.example:8008~shs:key2": \{[^}]*"autoconnect": true/s

      # A backup holds the original.
      assert File.read!(backup) =~
               ~r/"net:127\.0\.0\.1:8020~shs:key": \{[^}]*"autoconnect": true/s
    end

    test "applying an empty set changes nothing" do
      assert {:ok, 0, _backup} = ConnSuppress.apply([])
    end

    test "Sidecar.apply_conn_suppression writes directly when the engine is disabled",
         %{home: home} do
      previous = Application.get_env(:highwire, :ssb)
      Application.put_env(:highwire, :ssb, Keyword.put(previous || [], :enabled, false))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:highwire, :ssb, previous),
          else: Application.delete_env(:highwire, :ssb)
      end)

      # No sidecar runs in tests, so the engine is disabled: the change is
      # just the file write, with no stop/start.
      assert {:ok, 1, _backup} =
               HighWire.SSB.Sidecar.apply_conn_suppression(["net:127.0.0.1:8020~shs:key"])

      text = File.read!(Path.join([home, ".ssberl", "conn.json"]))
      assert text =~ ~r/"net:127\.0\.0\.1:8020~shs:key": \{[^}]*"autoconnect": false/s
    end

    test "book_peers reads the address book off disk", %{home: _home} do
      assert ConnSuppress.book_peers() == [
               %{"address" => "net:127.0.0.1:8020~shs:key", "autoconnect" => true},
               %{"address" => "net:room.example:8008~shs:key2", "autoconnect" => true}
             ]

      assert {:ok, 1, _backup} = ConnSuppress.apply(["net:127.0.0.1:8020~shs:key"])

      # A re-read reflects the flip: the shared classifier never considers
      # an already-suppressed entry again.
      assert [
               %{"address" => "net:127.0.0.1:8020~shs:key", "autoconnect" => false},
               %{"address" => "net:room.example:8008~shs:key2", "autoconnect" => true}
             ] = ConnSuppress.book_peers()
    end
  end
end
