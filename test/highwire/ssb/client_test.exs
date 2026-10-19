defmodule HighWire.SSB.ClientTest do
  use ExUnit.Case, async: true

  alias HighWire.SSB.Client

  describe "decode_reply/1 shape validation" do
    test "a structured muxrpc error becomes {:error, _}" do
      assert Client.decode_reply(~s({"error":["Error","nope"]})) == {:error, ["Error", "nope"]}
    end

    test "the engine's error-shaped success body becomes {:error, _}" do
      # A "message not found" that arrives as a *successful* reply whose
      # body is an erlang error map. This is the ghost that used to pass
      # through as {:ok, …} and starve every downstream fallback.
      body = ~s({"message":"message not found","name":"Error","stack":"_"})

      assert {:error, %{"name" => "Error", "message" => "message not found"}} =
               Client.decode_reply(body)
    end

    test "a real message value stays {:ok, _}" do
      body = ~s({"author":"@a=.ed25519","content":{"type":"post","text":"hi"},"timestamp":1})
      assert {:ok, %{"author" => "@a=.ed25519"}} = Client.decode_reply(body)
    end

    test "a map with a name but no message is data, not an error" do
      # Guard against over-matching: a data map that happens to carry a
      # "name" (e.g. an about record) is not an error unless it also has
      # a "message" string.
      body = ~s({"name":"mwm","about":"@me=.ed25519"})
      assert {:ok, %{"name" => "mwm"}} = Client.decode_reply(body)
    end

    test "a non-JSON body passes through as {:ok, raw}" do
      assert Client.decode_reply("raw bytes") == {:ok, "raw bytes"}
    end
  end

  # One subscriber listens on several connections at once — the Timeline
  # runs the contact and about drains on a dedicated connection beside the
  # main one — and dispatches on req id alone. Ids therefore have to come
  # from the VM's unique source on every request, never from a counter
  # stepped per connection: two connections counting from their own first
  # number hand the same handle to both streams, and the wrong handler
  # swallows the other's items and `:done`. That is what starved the about
  # pass — it never landed, the empty about set filtered every candidate
  # out, and the rail stayed blank.
  describe "request ids" do
    test "two connections opening a stream are never handed the same id" do
      assert {:reply, {:ok, req1}, _state} = open_stream(stream_state())
      assert {:reply, {:ok, req2}, _state} = open_stream(stream_state())

      refute req1 == req2
    end
  end

  defp open_stream(state) do
    Client.handle_call(
      {:stream, ["messagesByType"], [%{"type" => "about"}], self()},
      {self(), make_ref()},
      state
    )
  end

  # A client wired to a live socket, built the way init/1 builds one after
  # the handshake, so send_packet/2 has somewhere to write the request.
  # init/1 itself is out of reach here: it owns the SHS handshake, and
  # there is no server side of that protocol in the repo to test against.
  defp stream_state do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, sock} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    {:ok, peer} = :gen_tcp.accept(listener)
    :ok = :gen_tcp.close(listener)

    on_exit(fn ->
      _ = :gen_tcp.close(sock)
      _ = :gen_tcp.close(peer)
    end)

    %Client{
      sock: sock,
      enc_key: :crypto.strong_rand_bytes(32),
      enc_nonce: :crypto.strong_rand_bytes(24),
      dec_key: :crypto.strong_rand_bytes(32),
      dec_nonce: :crypto.strong_rand_bytes(24)
    }
  end
end
