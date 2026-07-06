defmodule FW.CLITest do
  use ExUnit.Case, async: true

  describe "parse/1" do
    test "parses a simple command with no args" do
      assert {:ok, %{command: "status", args: []}} = FW.CLI.parse(["status"])
    end

    test "parses a command with args" do
      assert {:ok, %{command: "config", args: ["log-level", "debug"]}} =
               FW.CLI.parse(["config", "log-level", "debug"])
    end

    test "parses --host and --port options" do
      assert {:ok, %{command: "status", host: "10.0.0.5", port: 9999}} =
               FW.CLI.parse(["--host", "10.0.0.5", "--port", "9999", "status"])
    end

    test "returns help for no arguments" do
      assert {:help, _text} = FW.CLI.parse([])
    end

    test "returns help for --help" do
      assert {:help, _text} = FW.CLI.parse(["--help"])
    end

    test "returns an error for an unknown command" do
      assert {:error, message} = FW.CLI.parse(["not-a-real-command"])
      assert message =~ "unknown command"
    end

    test "returns an error for an unknown option" do
      assert {:error, message} = FW.CLI.parse(["--bogus-flag", "status"])
      assert message =~ "unknown option"
    end
  end

  describe "parse_payload/2 for apply" do
    test "builds a payload with just a path when no flags are given" do
      assert {:ok, payload} = FW.CLI.parse_payload("apply", ["/tmp/pic.png"])
      assert payload["path"] == "/tmp/pic.png"
      refute Map.has_key?(payload, "scaling")
      refute Map.has_key?(payload, "transition")
    end

    test "expands relative and ~ paths" do
      assert {:ok, payload} = FW.CLI.parse_payload("apply", ["relative/pic.png"])
      assert payload["path"] == Path.expand("relative/pic.png")
      assert String.starts_with?(payload["path"], "/")
    end

    test "includes a valid --scaling flag" do
      assert {:ok, payload} = FW.CLI.parse_payload("apply", ["/tmp/pic.png", "--scaling", "fill"])
      assert payload["scaling"] == "fill"
    end

    test "accepts --mode as an alias for --scaling" do
      assert {:ok, payload} = FW.CLI.parse_payload("apply", ["/tmp/pic.png", "--mode", "tile"])
      assert payload["scaling"] == "tile"
    end

    test "includes a valid --transition flag" do
      assert {:ok, payload} =
               FW.CLI.parse_payload("apply", ["/tmp/pic.png", "--transition", "fade"])

      assert payload["transition"] == "fade"
    end

    test "rejects an invalid --scaling value instead of silently passing it through" do
      assert {:error, message} =
               FW.CLI.parse_payload("apply", ["/tmp/pic.png", "--scaling", "bogus"])

      assert message =~ "invalid --scaling value"
      assert message =~ "bogus"
    end

    test "rejects an invalid --transition value" do
      assert {:error, message} =
               FW.CLI.parse_payload("apply", ["/tmp/pic.png", "--transition", "bogus"])

      assert message =~ "invalid --transition value"
    end

    test "rejects apply with no path" do
      assert {:error, message} = FW.CLI.parse_payload("apply", [])
      assert message =~ "usage: fw apply"
    end

    test "accepts both --scaling and --transition together" do
      assert {:ok, payload} =
               FW.CLI.parse_payload("apply", [
                 "/tmp/pic.png",
                 "--scaling",
                 "fit",
                 "--transition",
                 "none"
               ])

      assert payload["scaling"] == "fit"
      assert payload["transition"] == "none"
      assert payload["path"] == "/tmp/pic.png"
    end
  end

  describe "parse_payload/2 for config" do
    test "builds a payload for a valid log-level command" do
      assert {:ok, %{"level" => "debug"}} = FW.CLI.parse_payload("config", ["log-level", "debug"])
    end

    test "rejects a malformed config command" do
      assert {:error, message} = FW.CLI.parse_payload("config", ["log-level"])
      assert message =~ "usage: fw config"
    end

    test "rejects an unrecognized config subcommand" do
      assert {:error, _message} = FW.CLI.parse_payload("config", ["not-a-thing", "value"])
    end
  end

  describe "parse_payload/2 fallback" do
    test "passes through raw args for commands with no special payload shape" do
      assert {:ok, %{"args" => ["a", "b"]}} = FW.CLI.parse_payload("ping", ["a", "b"])
    end
  end
end
