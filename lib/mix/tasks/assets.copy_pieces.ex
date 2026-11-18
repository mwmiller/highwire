defmodule Mix.Tasks.Assets.CopyPieces do
  @shortdoc "Copies the chess piece SVGs into priv/static/assets/chess"

  @moduledoc """
  Copies the chess piece SVGs into the served static directory.

  The board draws its pieces as images under `/assets/chess/`, so they
  have to sit beneath `priv/static` for the endpoint to serve them in
  development and in the release. `assets/` itself is a source tree and
  is never served.

  This is a task rather than a `cmd cp` in the alias because the `cmd`
  task runs its program directly instead of through a shell: a redirect
  or `||` would arrive at `cp` as another argument, and `cp` is not on
  the path the Windows build spawns into.
  """

  use Mix.Task

  @source "assets/chess"
  @dest "priv/static/assets/chess"

  @impl Mix.Task
  def run(_args) do
    unless File.dir?(@source) do
      Mix.raise("#{@source} not found — run `mix setup` from the project root")
    end

    files =
      @source
      |> Path.join("**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    Enum.each(files, fn path ->
      dest = Path.join(@dest, Path.relative_to(path, @source))
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(path, dest)
    end)

    Mix.shell().info("Copied #{length(files)} piece images to #{@dest}")
  end
end
