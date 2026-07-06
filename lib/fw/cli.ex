defmodule FW.CLI do
  @moduledoc """
  Command-line interface for fw.
  """

  alias FW.IPC.Client

  @commands ~w(start stop status ping config apply slideshow help version)

  def main(argv) when is_list(argv) do
    case parse(argv) do
      {:ok, %{command: "start"} = parsed} ->
        start_daemon(parsed)

      {:ok, %{command: command} = parsed} when command in @commands ->
        run_remote(parsed)

      {:help, message} ->
        IO.puts(message)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  def parse(argv) do
    # `parse_head/2` (not `parse/2`) is required here: it stops scanning for
    # global switches at the first positional argument (the command) and
    # leaves everything after it untouched in `rest`. Using `parse/2` would
    # scan the *entire* argv, including subcommand flags like `apply`'s
    # `--scaling`/`--dir`/`--slideshow-interval`, and reject them as unknown
    # global options since they're not in this `strict` list.
    {options, rest, invalid} =
      OptionParser.parse_head(argv,
        strict: [host: :string, port: :integer, help: :boolean, version: :boolean],
        aliases: [h: :help, v: :version]
      )

    case invalid do
      [{flag, _} | _] ->
        {:error, "unknown option: #{flag}"}

      [] ->
        cond do
          Keyword.get(options, :help, false) ->
            {:help, help_text()}

          Keyword.get(options, :version, false) ->
            {:help, version_text()}

          rest == [] ->
            {:help, help_text()}

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
    host = parsed.host || display_host(state["daemon"]["host"])
    port = parsed.port || state["daemon"]["port"]

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
    case parse_payload(command, args) do
      {:ok, payload} ->
        case Client.request(command, payload, host: host, port: port) do
          {:ok, response} ->
            IO.puts(FW.JSON.encode!(response))

          {:error, reason} ->
            IO.puts(:stderr, format_error(reason))
            System.halt(1)
        end

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(1)
    end
  end

  @doc false
  def parse_payload("config", ["log-level", level]), do: {:ok, %{"level" => level}}

  def parse_payload("config", args) do
    {:error, "usage: fw config log-level <debug|info|warn|error> (got: #{Enum.join(args, " ")})"}
  end

  def parse_payload("slideshow", ["stop"]), do: {:ok, %{"action" => "stop"}}
  def parse_payload("slideshow", ["status"]), do: {:ok, %{"action" => "status"}}

  def parse_payload("slideshow", args) do
    {:error, "usage: fw slideshow stop | fw slideshow status (got: #{Enum.join(args, " ")})"}
  end

  @apply_usage "usage: fw apply <path> [--scaling fit|fill|stretch|center|tile] [--transition none|fade]\n" <>
                 "   or: fw apply --dir <path> --slideshow-interval <N>s|m|h [--shuffle] " <>
                 "[--scaling fit|fill|stretch|center|tile] [--transition none|fade]"

  @min_slideshow_interval_ms 60_000

  # `--dir` marks slideshow mode. Checked before the single-path clause below
  # so that e.g. `fw apply --dir ~/Pictures --slideshow-interval 30m` isn't
  # accidentally matched by `[path | rest]` with "--dir" itself as the path.
  def parse_payload("apply", args) do
    case extract_flag(args, "--dir") do
      nil -> parse_apply_single(args)
      "" -> {:error, "--dir requires a non-empty directory path"}
      dir -> parse_apply_slideshow(dir, args)
    end
  end

  def parse_payload(_command, args), do: {:ok, %{"args" => args}}

  defp parse_apply_single([path | rest]) when path != "" do
    with {:ok, scaling} <- extract_scaling(rest),
         {:ok, transition} <- extract_transition(rest) do
      payload =
        %{"path" => Path.expand(path)}
        |> maybe_put("scaling", scaling)
        |> maybe_put("transition", transition)

      {:ok, payload}
    end
  end

  defp parse_apply_single(_args) do
    {:error, @apply_usage}
  end

  defp parse_apply_slideshow(dir, args) do
    with {:ok, interval_ms} <- extract_interval(args),
         {:ok, scaling} <- extract_scaling(args),
         {:ok, transition} <- extract_transition(args) do
      payload =
        %{
          "dir" => Path.expand(dir),
          "interval_ms" => interval_ms,
          "shuffle" => "--shuffle" in args
        }
        |> maybe_put("scaling", scaling)
        |> maybe_put("transition", transition)

      {:ok, payload}
    end
  end

  defp extract_interval(args) do
    case extract_flag(args, "--slideshow-interval") do
      nil ->
        {:error, "--dir requires --slideshow-interval, e.g. --slideshow-interval 30s|5m|2h"}

      raw ->
        case Regex.run(~r/^(\d+)(s|m|h)\z/, raw) do
          [_, value, unit] ->
            ms = String.to_integer(value) * unit_seconds(unit) * 1000

            if ms < @min_slideshow_interval_ms do
              {:error, "--slideshow-interval must be at least 1 minute (got: #{raw})"}
            else
              {:ok, ms}
            end

          nil ->
            {:error, "invalid --slideshow-interval format: #{raw} (expected e.g. 30s, 5m, 2h)"}
        end
    end
  end

  defp unit_seconds("s"), do: 1
  defp unit_seconds("m"), do: 60
  defp unit_seconds("h"), do: 3600

  @valid_scaling ~w(fit fill stretch center tile)
  @valid_transition ~w(none fade)

  defp extract_scaling(args) do
    case extract_flag(args, "--scaling") || extract_flag(args, "--mode") do
      nil ->
        {:ok, nil}

      value when value in @valid_scaling ->
        {:ok, value}

      other ->
        {:error,
         "invalid --scaling value: #{other} (expected one of: #{Enum.join(@valid_scaling, ", ")})"}
    end
  end

  defp extract_transition(args) do
    case extract_flag(args, "--transition") do
      nil ->
        {:ok, nil}

      value when value in @valid_transition ->
        {:ok, value}

      other ->
        {:error,
         "invalid --transition value: #{other} (expected one of: #{Enum.join(@valid_transition, ", ")})"}
    end
  end

  defp extract_flag(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
      "  fw apply <path> [--scaling fit|fill|stretch|center|tile] [--transition none|fade]",
      "  fw apply --dir <path> --slideshow-interval <N>s|m|h [--shuffle]",
      "                [--scaling fit|fill|stretch|center|tile] [--transition none|fade]",
      "  fw slideshow stop",
      "  fw slideshow status",
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
