# Interop spike: connect to a running erlbutt node over SHS+box-stream+muxrpc,
# then whoami → publish → read the feed back via createHistoryStream.
#
# Requires a spike node: see docs/spike-node.md. Defaults: port 8899,
# dev network id (config/default.vars), account keys from the test store.

defmodule HighWire.Spike do
  alias HighWire.SSB.{Client, Keys}

  def run do
    keys = Keys.load!(System.get_env("SPIKE_SECRET", "/tmp/highwire-pwtest/.ssberl/secret"))
    remote_pk = Keys.id_to_public(keys.id)
    net_id = Base.decode64!("1KHLiKZvAvjbY1ziZEHMXawbCEIM6qwjCDm3VYnaR/s=")

    {:ok, client} =
      Client.start_link(
        port: String.to_integer(System.get_env("SPIKE_PORT", "8899")),
        remote_pk: remote_pk,
        net_id: net_id,
        keys: keys
      )

    {:ok, who} = Client.call(client, ["whoami"], [])
    IO.puts("whoami: #{inspect(who)}")

    {:ok, post} =
      Client.call(
        client,
        ["publish"],
        [%{"type" => "post", "text" => "highwire interop spike #{:os.system_time(:second)}"}],
        10_000
      )

    IO.puts("publish: #{inspect(post)}")

    {:ok, ref} =
      Client.stream(client, ["createHistoryStream"], [
        %{"id" => who["id"], "limit" => 5, "reverse" => true}
      ])

    case collect(client, ref, []) do
      {:ok, msgs} ->
        IO.puts("history (#{length(msgs)} msgs):")

        Enum.each(msgs, fn m ->
          IO.puts("  ##{m["sequence"]} #{m["value"]["content"]["type"]} #{m["value"]["content"]["text"] || ""}")
        end)

        IO.puts("SPIKE OK")

      {:error, reason} ->
        IO.puts("SPIKE FAILED: #{inspect(reason)}")
        System.halt(1)
    end

    Client.stop(client)
  end

  defp collect(client, ref, acc) do
    receive do
      {Client, ^ref, {:item, msg}} -> collect(client, ref, [msg | acc])
      {Client, ^ref, :done} -> {:ok, Enum.reverse(acc)}
      {Client, ^ref, {:error, reason}} -> {:error, reason}
    after
      10_000 -> {:error, {:timeout, acc}}
    end
  end
end

HighWire.Spike.run()
