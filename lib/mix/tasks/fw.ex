defmodule Mix.Tasks.Fw do
  use Mix.Task

  @shortdoc "Runs the fw CLI"

  # "start" is the only subcommand that needs the full :fw Application
  # (Settings, PortServer, Control, IPC.Server) running in this OS process,
  # because it *is* the daemon. Every other subcommand (apply, status, ping,
  # stop, config, ...) is a thin client that only needs to speak the TCP
  # protocol to an already-running daemon — starting the full Application
  # for those would try to bind the same IPC port a second time and crash
  # with :eaddrinuse whenever a daemon (e.g. the systemd service) is
  # already up, which is the common case during normal use.
  @impl true
  def run(args) do
    # FW.CLI.parse/1 is a pure function (no OTP needed to call it), so we
    # can inspect the parsed command before deciding whether to boot the
    # supervision tree. This is more robust than checking the raw argv,
    # since options like `--port` can legitimately precede the subcommand
    # (`mix fw --port 1234 start`).
    case FW.CLI.parse(args) do
      {:ok, %{command: "start"}} ->
        Mix.Task.run("app.start")

      _other ->
        # Load :fw's compiled modules onto the code path WITHOUT starting
        # its OTP application, so FW.IPC.Server never tries to bind the
        # port a second time.
        Mix.Task.run("app.start", ["--no-start"])
    end

    FW.CLI.main(args)
  end
end
