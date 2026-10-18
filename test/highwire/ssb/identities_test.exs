defmodule HighWire.SSB.IdentitiesTest do
  # Not async: the cases point :application_dir at a temp home.
  use ExUnit.Case, async: false

  alias HighWire.SSB.{Identities, Keys}

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "hw-identities-#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    previous = Application.get_env(:highwire, :application_dir)
    Application.put_env(:highwire, :application_dir, tmp)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:highwire, :application_dir, previous),
        else: Application.delete_env(:highwire, :application_dir)

      File.rm_rf!(tmp)
    end)

    {:ok, home: tmp}
  end

  defp secret_path(home), do: Path.join([home, ".ssberl", "secret"])
  defp registry_path(home), do: Path.join(home, "identities.json")

  # A hand-rolled ssb-keys secret, the shape any predating install (or
  # a fresh engine) leaves behind.
  defp mint_secret!(home) do
    %{public: public, secret: private} = :enacl.sign_keypair()
    id = "@" <> Base.encode64(public) <> ".ed25519"

    body =
      Jason.encode!(%{
        "curve" => "ed25519",
        "public" => Base.encode64(public) <> ".ed25519",
        "private" => Base.encode64(private) <> ".ed25519",
        "id" => id
      })

    File.mkdir_p!(Path.dirname(secret_path(home)))
    File.write!(secret_path(home), "# a secret\n" <> body <> "\n")
    id
  end

  describe "adoption" do
    test "a predating install's running secret joins the registry untouched", %{home: home} do
      id = mint_secret!(home)
      before = File.read!(secret_path(home))

      assert :ok = Identities.ensure_boot()

      assert [row] = Identities.list()
      assert row["id"] == id
      assert row["label"] == "Primary"
      assert row["active"]
      refute row["disabled"]

      # The secret itself is never rewritten — only read.
      assert File.read!(secret_path(home)) == before
      assert Identities.active_id() == id
    end

    test "adoption is idempotent", %{home: home} do
      _id = mint_secret!(home)

      assert :ok = Identities.ensure_boot()
      assert :ok = Identities.ensure_boot()
      assert [_row] = Identities.list()
    end

    test "active_id trusts the secret without writing a registry", %{home: home} do
      id = mint_secret!(home)

      assert Identities.active_id() == id
      refute File.exists?(registry_path(home))
    end

    test "a vanished secret is restored from the registry's active row", %{home: home} do
      {:ok, id} = Identities.create("Main")
      File.rm!(secret_path(home))

      assert :ok = Identities.ensure_boot()
      assert Keys.load!(secret_path(home)).id == id
      assert Identities.active_id() == id
    end

    test "a corrupt registry degrades to the secret and heals on boot", %{home: home} do
      id = mint_secret!(home)
      File.write!(registry_path(home), "{not json")

      assert Identities.list() == []
      assert Identities.active_id() == id

      assert :ok = Identities.ensure_boot()
      assert [row] = Identities.list()
      assert row["id"] == id
    end
  end

  describe "create" do
    test "the first identity becomes active and writes the secret", %{home: home} do
      assert {:ok, id} = Identities.create("Main")

      assert Identities.active_id() == id
      assert Keys.load!(secret_path(home)).id == id
      assert [row] = Identities.list()
      assert row["active"]
      assert row["label"] == "Main"
    end

    test "later identities are enabled but not active", %{home: _home} do
      {:ok, _first} = Identities.create("Main")
      {:ok, second} = Identities.create("Bot")

      assert Identities.active_id() != second

      rows = Identities.list()
      assert Enum.sort(Enum.map(rows, & &1["label"])) == ["Bot", "Main"]
      assert Enum.find(rows, &(&1["id"] == second))["active"] == false
    end

    test "a blank label falls back, and labels are trimmed", %{home: _home} do
      {:ok, _} = Identities.create("   ")
      assert [%{"label" => "Identity"}] = Identities.list()

      {:ok, _} = Identities.create("  Pub account  ")
      labels = Enum.map(Identities.list(), & &1["label"])
      assert "Pub account" in labels
    end

    test "list rows never carry private key material", %{home: _home} do
      {:ok, _} = Identities.create("Main")

      assert [row] = Identities.list()
      refute Map.has_key?(row, "private")
    end
  end

  describe "switching" do
    test "activate writes the target's keypair and marks it active", %{home: home} do
      {:ok, _first} = Identities.create("Main")
      {:ok, second} = Identities.create("Bot")

      assert :ok = Identities.activate(second)
      assert Identities.active_id() == second
      assert Keys.load!(secret_path(home)).id == second

      assert [active] = Enum.filter(Identities.list(), & &1["active"])
      assert active["id"] == second
    end

    test "activate refuses unknown and disabled identities", %{home: _home} do
      {:ok, _first} = Identities.create("Main")
      {:ok, second} = Identities.create("Bot")

      assert Identities.activate("@nope=.ed25519") == {:error, :unknown_identity}
      assert :ok = Identities.disable(second)
      assert Identities.activate(second) == {:error, :disabled_identity}
    end
  end

  describe "disable, enable, destroy" do
    test "the active identity cannot be disabled", %{home: _home} do
      {:ok, id} = Identities.create("Main")

      assert Identities.disable(id) == {:error, :active_identity}
    end

    test "disable is reversible and drops the id off the switch list", %{home: _home} do
      {:ok, _first} = Identities.create("Main")
      {:ok, second} = Identities.create("Bot")

      assert :ok = Identities.disable(second)
      assert Enum.find(Identities.list(), &(&1["id"] == second))["disabled"]
      assert Identities.activate(second) == {:error, :disabled_identity}

      assert :ok = Identities.enable(second)
      refute Enum.find(Identities.list(), &(&1["id"] == second))["disabled"]
      assert :ok = Identities.activate(second)
    end

    test "destroy is refused until the identity is disabled", %{home: _home} do
      {:ok, _first} = Identities.create("Main")
      {:ok, second} = Identities.create("Bot")

      assert Identities.destroy(second) == {:error, :not_disabled}

      assert :ok = Identities.disable(second)
      assert :ok = Identities.destroy(second)
      refute Enum.any?(Identities.list(), &(&1["id"] == second))

      # Gone for good: not in the registry, not re-adoptable.
      assert Identities.destroy(second) == {:error, :unknown_identity}
    end

    test "unknown ids are refused everywhere", %{home: _home} do
      {:ok, _} = Identities.create("Main")

      assert Identities.disable("@nope=.ed25519") == {:error, :unknown_identity}
      assert Identities.enable("@nope=.ed25519") == {:error, :unknown_identity}
      assert Identities.export("@nope=.ed25519") == {:error, :unknown_identity}
    end
  end

  describe "export" do
    test "round-trips through the ssb-keys reader", %{home: _home} do
      {:ok, id} = Identities.create("Main")

      assert {:ok, text} = Identities.export(id)
      assert text =~ "# WARNING: Never show this to anyone."

      tmp = Path.join(System.tmp_dir!(), "hw-export-#{:erlang.unique_integer([:positive])}")
      File.write!(tmp, text)
      keys = Keys.load!(tmp)
      File.rm!(tmp)

      assert keys.id == id
    end
  end
end
