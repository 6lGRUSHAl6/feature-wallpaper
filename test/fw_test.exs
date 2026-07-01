defmodule FWTest do
  use ExUnit.Case

  test "reports the application name" do
    assert FW.name() == "fw"
  end

  test "parses cli commands" do
    assert {:ok, %{command: "status"}} = FW.CLI.parse(["status"])
    assert {:ok, %{command: "config", args: ["log-level", "debug"]}} = FW.CLI.parse(["config", "log-level", "debug"])
  end
end
