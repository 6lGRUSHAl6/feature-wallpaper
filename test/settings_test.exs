defmodule FW.SettingsTest do
  use ExUnit.Case

  # FW.Settings is a singleton GenServer (name: __MODULE__) started by the
  # application, and it persists to a real file on every update/1 call, so
  # these tests run against the live process rather than an isolated
  # instance. They are intentionally structural (shape of the returned map)
  # rather than exact-value assertions, and each test restores the wallpaper
  # key it touched so the tests don't leak state into each other.
  #
  # NOTE: because persist/0 writes to disk on every update, these tests are
  # not `async: true`.

  setup do
    original = FW.Settings.get()
    on_exit(fn -> FW.Settings.update(original) end)
    %{original: original}
  end

  test "get/0 always returns a map with string keys, including nested maps" do
    state = FW.Settings.get()

    assert is_map(state)
    assert Enum.all?(Map.keys(state), &is_binary/1)
    assert Enum.all?(Map.keys(state["daemon"]), &is_binary/1)
    assert Enum.all?(Map.keys(state["wallpaper"]), &is_binary/1)
    assert Enum.all?(Map.keys(state["renderer"]), &is_binary/1)
  end

  test "update/1 with a string-keyed payload (the normal JSON-decoded shape) merges cleanly" do
    updated = FW.Settings.update(%{"wallpaper" => %{"path" => "/tmp/settings_test_a.png", "scaling" => "fill"}})

    assert updated["wallpaper"]["path"] == "/tmp/settings_test_a.png"
    assert updated["wallpaper"]["scaling"] == "fill"
    # transition must survive the merge untouched (deep_merge, not overwrite)
    assert updated["wallpaper"]["transition"] in ["none", "fade"]

    # No stray atom keys anywhere in the merged map.
    refute Map.has_key?(updated, :wallpaper)
    refute Map.has_key?(updated["wallpaper"], :path)
    refute Map.has_key?(updated["wallpaper"], :scaling)
  end

  test "update/1 with an atom-keyed payload does not create duplicate atom/string keys" do
    # Regression test for the exact bug found on 2026-07-01: passing an
    # atom-keyed map (as the old CLI code used to build) used to leave both
    # `:path` (stale, from the default state) and `"path"` (from the new
    # payload) present side by side in the merged map, because Map.merge/3
    # treats atom and string keys as distinct.
    updated = FW.Settings.update(%{wallpaper: %{path: "/tmp/settings_test_b.png"}})

    assert updated["wallpaper"]["path"] == "/tmp/settings_test_b.png"
    refute Map.has_key?(updated, :wallpaper)
    refute Map.has_key?(updated["wallpaper"], :path)

    # Exactly the three known wallpaper fields, nothing extra left behind.
    assert Enum.sort(Map.keys(updated["wallpaper"])) == ["path", "scaling", "transition"]
  end

  test "update/1 preserves unrelated top-level settings" do
    before = FW.Settings.get()
    updated = FW.Settings.update(%{"wallpaper" => %{"path" => "/tmp/settings_test_c.png"}})

    assert updated["daemon"] == before["daemon"]
    assert updated["renderer"] == before["renderer"]
  end

  test "set_log_level/1 with a valid level updates state and does not raise" do
    updated = FW.Settings.set_log_level("debug")
    assert updated["log_level"] == "debug"
  after
    FW.Settings.set_log_level("info")
  end

  test "set_log_level/1 with an unknown level does not crash the GenServer" do
    # Before today's fix this called String.to_existing_atom/1 unconditionally
    # and would raise ArgumentError for any level not already loaded as an atom.
    updated = FW.Settings.set_log_level("not_a_real_level")
    assert updated["log_level"] == "not_a_real_level"

    # process must still be alive and answering afterwards
    assert is_pid(Process.whereis(FW.Settings))
    assert %{} = FW.Settings.get()
  after
    FW.Settings.set_log_level("info")
  end
end
