defmodule HighWire.SSB.PrivateBoxInteropTest do
  @moduledoc """
  Interop between HighWire.SSB.PrivateBox and the engine's own
  `private_box` module.

  The format module is a port of the engine's, so its unit tests only ever
  prove it agrees with itself. These tests put the real erlbutt release on
  the other side: the engine's `private_box:encrypt/2` writes a box this
  suite opens, and the engine's own `private_box:decrypt/1` opens a box
  this suite wrote. Both run the same libsodium through the same enacl, so
  a layout drift shows up here and nowhere else.

  The engine side is a bare `erl` against the release's ebin directories —
  the same `-pa`/`-boot` shape the sidecar uses. Nothing starts the `ssb`
  application, opens a store, or binds a port. The decrypt direction does
  boot the engine's real `config` and `keys` processes, which read a secret
  the test wrote to its own temp home, so the engine's decrypt path runs
  unmodified rather than a reimplementation of it.

  Skipped when the engine release is absent (`mix engine.build`).
  """

  use ExUnit.Case, async: false

  alias HighWire.SSB.PrivateBox

  @engine_rel System.get_env("ERLBUTT_REL") ||
                Path.expand("../../../deps/erlbutt/_build/default/rel/ssb", __DIR__)

  unless File.dir?(@engine_rel) do
    @moduletag skip: "erlbutt engine not built at #{@engine_rel} — run mix engine.build"
  end

  defp keypair, do: :enacl.crypto_sign_ed25519_keypair()

  defp feed_id(%{public: pk}), do: "@" <> Base.encode64(pk) <> ".ed25519"

  # A secret file in the shape ssb-keys writes, so the engine's own keys
  # process adopts this identity and private_box can derive the DH key.
  # `config:ssb_repo_loc/0` is `<ssb_home>/.ssberl/`, and that is where
  # keys looks for `secret`.
  defp write_secret!(home, %{public: pk, secret: sk}) do
    dir = Path.join(home, ".ssberl")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "secret"),
      :json.encode(%{
        "curve" => "ed25519",
        "public" => Base.encode64(pk) <> ".ed25519",
        "private" => Base.encode64(sk) <> ".ed25519",
        "id" => "@" <> Base.encode64(pk) <> ".ed25519"
      })
    )
  end

  # Run Erlang inside the engine's release. The eval must return either a
  # binary or the atom `not_for_me`; the result crosses the process
  # boundary as base64 so Elixir never has to parse Erlang term syntax.
  # `home` (when given) is where the release looks for `secret`; the ssb
  # app is not started, so only config/keys touch it.
  defp engine_eval(code, home) do
    erl = System.find_executable("erl")
    args = ["-noshell"] ++ boot_args(@engine_rel) ++ ebin_args() ++ ["-eval", eval(code, home)]

    {out, _status} = System.cmd(erl, args)
    read_result(out)
  end

  defp ebin_args do
    Path.wildcard(Path.join(@engine_rel, "lib/*/ebin")) |> Enum.flat_map(&["-pa", &1])
  end

  # `-ssb ssb_home <dir>` does not take: the app env must be set after the
  # app record is loaded, which init does not do for a bare erl. Doing it
  # in the eval is what makes config and keys read `home`.
  defp eval(code, home) do
    "try " <>
      preamble(home) <>
      code <>
      " of <<B0/binary>> -> io:format(\"HW_OK_BIN ~s~n\", [base64:encode(B0)]); " <>
      "not_for_me -> io:format(\"HW_NOT_FOR_ME~n\"); " <>
      "R1 -> io:format(\"HW_OTHER ~0p~n\", [R1]) " <>
      "catch C:E:St -> io:format(\"HW_ERROR ~0p~n\", [{C, E, St}]) end, halt(0)."
  end

  defp preamble(nil), do: ""

  defp preamble(dir) do
    "application:load(ssb), application:set_env(ssb, ssb_home, " <> inspect(dir) <> "), "
  end

  defp read_result(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.find_value(&parse_line/1)
    |> case do
      nil -> flunk("engine eval printed nothing usable:\n#{out}")
      {:binary, b64} -> Base.decode64!(b64)
      {:atom, atom} -> atom
      {:other, term} -> Code.eval_string(term) |> elem(0)
    end
  end

  defp parse_line("HW_OK_BIN " <> b64), do: {:binary, b64}
  defp parse_line("HW_NOT_FOR_ME"), do: {:atom, :not_for_me}
  defp parse_line("HW_OTHER " <> term), do: {:other, term}
  defp parse_line("HW_ERROR " <> err), do: flunk("engine eval failed: #{err}")
  defp parse_line(_), do: nil

  defp boot_args(rel) do
    if Path.wildcard(Path.join(rel, "erts-*")) != [] do
      case Path.wildcard(Path.join(rel, "releases/*/start_clean.boot")) do
        [bootfile | _] -> ["-boot", String.trim_trailing(bootfile, ".boot")]
        [] -> []
      end
    else
      []
    end
  end

  test "the engine opens a box this module wrote" do
    kp = keypair()
    id = feed_id(kp)
    home = Path.join(System.tmp_dir!(), "hw-box-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    write_secret!(home, kp)

    plaintext = ~s({"type":"post","text":"written by the app"})
    box = PrivateBox.encrypt(plaintext, [id])

    opened =
      engine_eval(
        "begin " <>
          "{ok, _} = config:start_link(\"no-such-cfg\"), " <>
          "{ok, _} = keys:start_link(), " <>
          "Result = case private_box:decrypt(<<" <>
          inspect(box) <>
          ">>) of {ok, P} -> P; Other -> Other end, " <>
          "gen_server:stop(keys), gen_server:stop(config), Result end",
        home
      )

    assert opened == plaintext
  end

  test "this module opens a box the engine wrote" do
    kp = keypair()
    id = feed_id(kp)
    plaintext = ~s({"type":"post","text":"written by the engine"})

    box =
      engine_eval(
        "private_box:encrypt(<<" <>
          inspect(plaintext) <>
          ">>, [<<" <> inspect(id) <> ">>])",
        nil
      )

    assert String.ends_with?(box, ".box")
    assert {:ok, ^plaintext} = PrivateBox.decrypt(box, kp.secret)
  end

  test "the engine's is_private and ours agree" do
    kp = keypair()

    for content <- [
          PrivateBox.encrypt(~s({"type":"post"}), [feed_id(kp)]),
          "%abc=.sha256",
          "plain text"
        ] do
      theirs = engine_eval("private_box:is_private(<<" <> inspect(content) <> ">>)", nil)

      assert theirs == PrivateBox.private?(content)
    end
  end

  test "the engine does not open a box addressed only to someone else" do
    addressee = keypair()
    reader = keypair()
    home = Path.join(System.tmp_dir!(), "hw-box-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(home) end)
    write_secret!(home, reader)

    box = PrivateBox.encrypt(~s({"type":"post","text":"not for you"}), [feed_id(addressee)])

    assert engine_eval(
             "begin " <>
               "{ok, _} = config:start_link(\"no-such-cfg\"), " <>
               "{ok, _} = keys:start_link(), " <>
               "Result = private_box:decrypt(<<" <>
               inspect(box) <>
               ">>), " <>
               "gen_server:stop(keys), gen_server:stop(config), Result end",
             home
           ) == :not_for_me
  end
end
