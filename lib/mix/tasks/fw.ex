defmodule Mix.Tasks.Fw do
  use Mix.Task

  @shortdoc "Runs the fw CLI"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")
    FW.CLI.main(args)
  end
end