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
end
