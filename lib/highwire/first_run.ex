defmodule HighWire.FirstRun do
  @moduledoc """
  The welcome page a fresh identity sees once.

  A new install holds an identity and nothing else: no peers, no
  history, an empty timeline. The network reaches a new feed through a
  pub, so the first page the reader reaches says that and offers the
  invite form, instead of leaving an empty feed to explain it alone.

  Two markers in the app home make the offer once, and only once:

    * `.welcome` is written when this install starts a fresh identity —
      at the first boot with no secret to take over, or when the import
      offer is declined. The gate reads it, so every app route leads to
      `/welcome` until the page is answered.

    * `.welcomed` is written the first time the reader leaves that page,
      either by joining a pub or by choosing to look around first. It
      retires the offer for good, and `mark/0` will not raise it again.

  Installations that predate this page already hold a secret, so they
  never write `.welcome` and their first launch after an upgrade shows
  nothing new. The markers live in the app home rather than the
  engine's repo: they describe what this install has shown its reader,
  not anything the engine signs or replicates.
  """

  @pending ".welcome"
  @welcomed ".welcomed"

  @doc """
  Whether this configuration greets a new identity at all.

  On by default; the test configuration turns it off, the same way it
  turns the contact drain off, so a test that boots an engine on the
  shared test home cannot leave a marker behind that redirects pages
  in other modules.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, true)

  @doc "The file that offers the welcome page."
  @spec welcome_path() :: Path.t()
  def welcome_path, do: Path.join(HighWire.home_dir(), @pending)

  @doc "The file that records the page as answered."
  @spec welcomed_path() :: Path.t()
  def welcomed_path, do: Path.join(HighWire.home_dir(), @welcomed)

  @doc """
  Offer the welcome page, unless it has already been retired.

  Best effort: an app home that cannot be written has larger problems
  than a missing greeting, and no page should fail to mount over it.
  """
  @spec mark() :: :ok
  def mark do
    if enabled?() and not File.exists?(welcomed_path()) do
      _ = File.mkdir_p(HighWire.home_dir())
      _ = File.write(welcome_path(), "new identity\n")
    end

    :ok
  end

  @doc "Is the welcome page still waiting to be answered?"
  @spec pending?() :: boolean()
  def pending? do
    enabled?() and File.exists?(welcome_path()) and not File.exists?(welcomed_path())
  end

  @doc """
  Retire the page: the reader joined a pub or chose to look around
  first. Writing the answer outlives the pending marker, so a marker
  left behind by an interrupted launch cannot raise the page again.
  """
  @spec dismiss() :: :ok | {:error, term()}
  def dismiss do
    _ = File.rm(welcome_path())

    if enabled?() do
      _ = File.mkdir_p(HighWire.home_dir())

      case File.write(welcomed_path(), "welcomed\n") do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp config, do: Application.get_env(:highwire, :first_run, [])
end
