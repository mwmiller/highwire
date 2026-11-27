defmodule HighWire.FirstRunTest do
  @moduledoc """
  The two markers that make the welcome page once-only: a fresh identity
  raises it, an answered page retires it, and nothing raises it again.
  """

  use ExUnit.Case, async: false

  alias HighWire.FirstRun

  setup do
    enabled = Application.get_env(:highwire, :first_run)
    Application.put_env(:highwire, :first_run, enabled: true)

    on_exit(fn ->
      if enabled,
        do: Application.put_env(:highwire, :first_run, enabled),
        else: Application.delete_env(:highwire, :first_run)

      File.rm(FirstRun.welcome_path())
      File.rm(FirstRun.welcomed_path())
    end)

    :ok
  end

  test "a home with no markers has nothing to show" do
    refute FirstRun.pending?()
  end

  test "marking a fresh identity offers the page" do
    assert FirstRun.mark() == :ok

    assert FirstRun.pending?()
    assert File.regular?(FirstRun.welcome_path())
  end

  test "dismissing retires the page and it stays retired" do
    FirstRun.mark()

    assert FirstRun.dismiss() == :ok
    refute FirstRun.pending?()
    refute File.exists?(FirstRun.welcome_path())
    assert File.regular?(FirstRun.welcomed_path())

    # A later launch that finds no secret marks again; the answer holds.
    FirstRun.mark()
    refute FirstRun.pending?()
  end
end
