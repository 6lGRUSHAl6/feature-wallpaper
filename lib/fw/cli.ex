defmodule FW.CLI do
  @moduledoc """
  Command-line interface for fw.
  """

  alias FW.IPC.Client

  @commands ~w(start stop status ping config apply help version)

  def main(argv) when is_list(argv) do
    case parse(argv) do
      {:ok, %{command: "start"} = parsed} -> start_daemon(parsed)
      {:ok, %{command: command} = parsed} when command in @commands -> run_remote(parsed)
      {:help, message} -> IO.puts(message)
      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  def parse(argv) do
    {options, rest, invalid} =
      OptionParser.parse(argv,
        strict: [host: :string, port: :integer, help: :boolean, version: :boolean],
        aliases: [h: :help, v: :version]
      )

    case invalid do
      [{flag, _} | _] ->
        {:error, "unknown option: #{flag}"}

      [] ->
        cond do
          Keyword.get(options, :help, false) -> {:help, help_text()}
          Keyword.get(options, :version, false) -> {:help, version_text()}
          rest == [] -> {:help, help_text()}
          true ->
            [command | args] = rest

            if command in @commands do
              {:ok,
               %{
                 command: command,
                 args: args,
                 host: Keyword.get(options, :host),
                 port: Keyword.get(options, :port)
               }}
            else
              {:error, "unknown command: #{command}"}
            end
        end
    end
  end

  defp start_daemon(parsed) do
    {:ok, _} = Application.ensure_all_started(:fw)
    state = FW.Settings.get()
    host = parsed.host || display_host(state.daemon.host)
    port = parsed.port || state.daemon.port

    IO.puts("fw daemon is running on #{host}:#{port}")
    wait_forever()
  end

  defp run_remote(%{command: "version"}) do
    IO.puts(version_text())
  end

  defp run_remote(%{command: "help"}) do
    IO.puts(help_text())
  end

  defp run_remote(%{command: "start"} = parsed) do
    start_daemon(parsed)
  end

  defp run_remote(%{command: command, args: args, host: host, port: port}) do
    payload = parse_payload(command, args)

    case Client.request(command, payload, host: host, port: port) do
      {:ok, response} -> IO.puts(FW.JSON.encode!(response))
      {:error, reason} ->
        IO.puts(:stderr, format_error(reason))
        System.halt(1)
    end
  end

  defp parse_payload("config", ["log-level", level]), do: %{level: level}
  defp parse_payload("apply", [path | rest]), do: %{path: path, options: rest}
  defp parse_payload(_command, args), do: %{args: args}

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  defp help_text do
    [
      "fw - feature wallpaper",
      "",
      "usage:",
      "  fw start",
      "  fw stop",
      "  fw status",
      "  fw ping",
      "  fw config log-level <debug|info|warn|error>",
      "  fw apply <path> [options...]",
      "  fw --help",
      "  fw --version"
    ]
    |> Enum.join("\n")
  end

  defp version_text do
    "fw #{Application.spec(:fw, :vsn)}"
  end

  defp wait_forever do
    receive do
      :stop -> :ok
    end
  end

  defp display_host(host) when is_tuple(host), do: host |> Tuple.to_list() |> Enum.join(".")
  defp display_host(host) when is_list(host), do: host |> Enum.join(".")
  defp display_host(host), do: to_string(host)
end