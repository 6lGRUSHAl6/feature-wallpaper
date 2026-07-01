defmodule FW.ControlTest do
  use ExUnit.Case

  # route/1 talks to the real FW.Settings and FW.PortServer singletons
  # started by the application (see FW.SettingsTest for why these tests are
  # not async). Only "ping"/"status"/error-path clauses are exercised here
  # without depending on fw_renderer actually applying a wallpaper, since
  # that requires a live Wayland compositor and is out of scope for unit
  # tests running in CI.

  test "ping returns ok/pong without touching Settings or PortServer" do
    assert %{status: "ok", data: %{message: "pong"}} = FW.Control.route(%{"command" => "ping"})
  end

  test "status returns the current settings plus port status" do
    result = FW.Control.route(%{"command" => "status"})

    assert %{status: "ok", data: data} = result
    assert Map.has_key?(data, :daemon)
    assert Map.has_key?(data, :wallpaper)
    assert Map.has_key?(data, :monitors)
    assert Map.has_key?(data, :renderer)
    assert Map.has_key?(data, :port)
  end

  test "config with a valid level updates the log level" do
    result = FW.Control.route(%{"command" => "config", "payload" => %{"level" => "debug"}})
    assert %{status: "ok", data: %{log_level: "debug"}} = result
  after
    FW.Control.route(%{"command" => "config", "payload" => %{"level" => "info"}})
  end

  test "config with an invalid level returns an error and does not crash" do
    result = FW.Control.route(%{"command" => "config", "payload" => %{"level" => "not_a_level"}})
    assert %{status: "error", error: message} = result
    assert message =~ "unsupported log level"
  end

  test "apply without a path returns an error instead of forwarding to the renderer" do
    result = FW.Control.route(%{"command" => "apply"})
    assert %{status: "error", error: message} = result
    assert message =~ "missing or empty 'path'"
  end

  test "apply with an empty path is rejected before reaching the renderer" do
    result = FW.Control.route(%{"command" => "apply", "payload" => %{"path" => ""}})
    assert %{status: "error", error: message} = result
    assert message =~ "missing or empty 'path'"
  end

  test "apply with a non-string path is rejected before reaching the renderer" do
    result = FW.Control.route(%{"command" => "apply", "payload" => %{"path" => 123}})
    assert %{status: "error", error: message} = result
    assert message =~ "missing or empty 'path'"
  end

  test "an unsupported command returns a descriptive error" do
    result = FW.Control.route(%{"command" => "not-a-real-command"})
    assert %{status: "error", error: message} = result
    assert message =~ "unsupported command"
    assert message =~ "not-a-real-command"
  end

  test "a request with no command at all is rejected as invalid" do
    result = FW.Control.route(%{"nonsense" => "value"})
    assert %{status: "error", error: "invalid request"} = result
  end
end
