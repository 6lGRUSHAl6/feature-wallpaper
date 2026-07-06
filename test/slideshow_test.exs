defmodule FW.SlideshowTest do
  use ExUnit.Case

  # FW.Slideshow is a singleton GenServer started by the application (like
  # FW.Settings/FW.Control), and every start/1 call persists to the real
  # FW.Settings state file — so these tests are not async, same reasoning
  # as FW.SettingsTest.
  #
  # Applying a wallpaper normally goes through FW.Control.apply_wallpaper/1,
  # which talks to the real fw_renderer over a Port — requiring a live
  # Wayland compositor. That's out of scope for unit tests in CI (see
  # FW.ControlTest's module doc for the same constraint). FW.Slideshow
  # supports swapping that call out via the `:slideshow_apply_fun` app env,
  # so here we stub it to a fake that always succeeds, letting us test the
  # actual scheduling/state-machine logic (ticking, wraparound, replace,
  # stop) for real instead of skipping it entirely.

  @tmp_dir Path.join(System.tmp_dir!(), "fw_slideshow_test")

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    original_settings = FW.Settings.get()
    Application.put_env(:fw, :slideshow_apply_fun, fn _payload -> {:ok, %{}} end)

    on_exit(fn ->
      FW.Slideshow.stop()
      FW.Settings.update(original_settings)
      Application.delete_env(:fw, :slideshow_apply_fun)
      File.rm_rf!(@tmp_dir)
    end)

    %{dir: @tmp_dir}
  end

  defp write_images(dir, names) do
    Enum.each(names, fn name -> File.write!(Path.join(dir, name), "") end)
  end

  defp stub_apply(fun) do
    Application.put_env(:fw, :slideshow_apply_fun, fun)
  end

  test "start/1 rejects a directory with no supported images", %{dir: dir} do
    write_images(dir, ["notes.txt", "readme.md"])

    assert {:error, message} =
             FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})

    assert message =~ "no supported images found"
    assert FW.Slideshow.status() == %{active: false}
  end

  test "start/1 rejects a directory that doesn't exist" do
    missing = Path.join(@tmp_dir, "does_not_exist")

    assert {:error, message} =
             FW.Slideshow.start(%{"dir" => missing, "interval_ms" => 60_000, "shuffle" => false})

    assert message =~ "cannot read directory"
  end

  test "start/1 rejects a missing or non-positive interval_ms", %{dir: dir} do
    write_images(dir, ["a.jpg"])

    assert {:error, message} = FW.Slideshow.start(%{"dir" => dir, "shuffle" => false})
    assert message =~ "invalid slideshow interval_ms"

    assert {:error, message} =
             FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 0, "shuffle" => false})

    assert message =~ "invalid slideshow interval_ms"
  end

  test "start/1 only picks up supported image extensions, sorted, and ignores others", %{dir: dir} do
    write_images(dir, ["b.png", "a.jpg", "notes.txt", "c.WEBP"])

    assert {:ok, status} =
             FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})

    assert status.active == true
    assert status.image_count == 3
    assert status.current_index == 0
    assert status.current_path == Path.join(dir, "a.jpg")
  end

  test "start/1 applies the first image through the injected apply function and persists slideshow settings",
       %{dir: dir} do
    write_images(dir, ["a.jpg"])
    test_pid = self()

    stub_apply(fn payload ->
      send(test_pid, {:applied, payload})
      {:ok, %{}}
    end)

    assert {:ok, _status} =
             FW.Slideshow.start(%{
               "dir" => dir,
               "interval_ms" => 90_000,
               "shuffle" => false,
               "scaling" => "fill",
               "transition" => "fade"
             })

    expected_path = Path.join(dir, "a.jpg")

    assert_received {:applied,
                     %{"path" => ^expected_path, "scaling" => "fill", "transition" => "fade"}}

    settings = FW.Settings.get()
    assert settings["slideshow"]["active"] == true
    assert settings["slideshow"]["dir"] == dir
    assert settings["slideshow"]["interval_ms"] == 90_000
    assert settings["slideshow"]["scaling"] == "fill"
    assert settings["slideshow"]["transition"] == "fade"
  end

  test "when the first image fails to apply, start/1 reports the error (like a plain fw apply would)",
       %{dir: dir} do
    write_images(dir, ["a.jpg"])
    stub_apply(fn _payload -> {:error, :renderer_not_running} end)

    assert {:error, reason} =
             FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})

    assert reason == :renderer_not_running
    assert FW.Slideshow.status() == %{active: false}
  end

  test "once running, a single tick's apply failure is logged and does not stop the slideshow", %{
    dir: dir
  } do
    write_images(dir, ["a.jpg", "b.jpg"])
    test_pid = self()

    stub_apply(fn payload ->
      send(test_pid, {:applied, payload})
      {:ok, %{}}
    end)

    {:ok, _} = FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})
    assert_received {:applied, _}

    # Now make every subsequent apply fail (e.g. renderer briefly down) and
    # confirm the slideshow keeps advancing instead of getting stuck or
    # crashing.
    stub_apply(fn _payload -> {:error, :renderer_not_running} end)

    send(Process.whereis(FW.Slideshow), :tick)
    assert FW.Slideshow.status().current_index == 1
    assert Process.alive?(Process.whereis(FW.Slideshow))
  end

  test "a :tick advances to the next image and wraps around at the end", %{dir: dir} do
    write_images(dir, ["a.jpg", "b.jpg", "c.jpg"])

    {:ok, _} = FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})
    assert FW.Slideshow.status().current_index == 0

    send(Process.whereis(FW.Slideshow), :tick)
    assert FW.Slideshow.status().current_index == 1

    send(Process.whereis(FW.Slideshow), :tick)
    assert FW.Slideshow.status().current_index == 2

    # wraps back to the first image after the last one
    send(Process.whereis(FW.Slideshow), :tick)
    assert FW.Slideshow.status().current_index == 0
  end

  test "stop/0 halts the slideshow, is reflected in status/Settings, and is idempotent", %{
    dir: dir
  } do
    write_images(dir, ["a.jpg"])
    {:ok, _} = FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})

    assert :ok = FW.Slideshow.stop()
    assert FW.Slideshow.status() == %{active: false}
    assert FW.Settings.get()["slideshow"]["active"] == false

    # calling stop again with nothing running must not raise
    assert :ok = FW.Slideshow.stop()
  end

  test "a stray :tick after stop is a harmless no-op and the process stays alive", %{dir: dir} do
    write_images(dir, ["a.jpg", "b.jpg"])
    {:ok, _} = FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})
    FW.Slideshow.stop()

    pid = Process.whereis(FW.Slideshow)
    send(pid, :tick)
    # give a genuinely async, unsynchronizable message a moment to land
    Process.sleep(20)

    assert Process.alive?(pid)
    assert FW.Slideshow.status() == %{active: false}
  end

  test "start/1 called again replaces the previous slideshow instead of running both", %{dir: dir} do
    dir_a = Path.join(dir, "a")
    dir_b = Path.join(dir, "b")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)
    write_images(dir_a, ["1.jpg"])
    write_images(dir_b, ["2.jpg", "3.jpg"])

    {:ok, _} = FW.Slideshow.start(%{"dir" => dir_a, "interval_ms" => 60_000, "shuffle" => false})

    {:ok, status} =
      FW.Slideshow.start(%{"dir" => dir_b, "interval_ms" => 30_000, "shuffle" => false})

    assert status.dir == dir_b
    assert status.image_count == 2
    assert FW.Slideshow.status().dir == dir_b

    # the old dir_a timer must not still be ticking against the new state
    send(Process.whereis(FW.Slideshow), :tick)
    assert FW.Slideshow.status().current_index == 1
  end

  test "replacing a running slideshow cancels the old timer instead of leaving it to fire later",
       %{
         dir: dir
       } do
    dir_a = Path.join(dir, "a")
    dir_b = Path.join(dir, "b")
    File.mkdir_p!(dir_a)
    File.mkdir_p!(dir_b)
    write_images(dir_a, ["1.jpg", "2.jpg"])
    write_images(dir_b, ["3.jpg"])

    {:ok, _} = FW.Slideshow.start(%{"dir" => dir_a, "interval_ms" => 60_000, "shuffle" => false})
    {:ok, _} = FW.Slideshow.start(%{"dir" => dir_b, "interval_ms" => 60_000, "shuffle" => false})

    # dir_b has a single image, so a tick must keep index at 0, not advance
    # past it — proving the process is reacting against current (dir_b)
    # state, not some stale leftover from dir_a.
    send(Process.whereis(FW.Slideshow), :tick)
    assert FW.Slideshow.status().dir == dir_b
    assert FW.Slideshow.status().current_index == 0
  end

  test "a rejected start/1 (e.g. bad directory) does not disturb an already-running slideshow", %{
    dir: dir
  } do
    write_images(dir, ["a.jpg"])
    {:ok, _} = FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => false})

    missing = Path.join(dir, "does_not_exist")

    assert {:error, _reason} =
             FW.Slideshow.start(%{"dir" => missing, "interval_ms" => 60_000, "shuffle" => false})

    # still the original slideshow, untouched
    assert FW.Slideshow.status().dir == dir
  end

  test "shuffle: true still applies exactly one of the supported images first", %{dir: dir} do
    write_images(dir, ["a.jpg", "b.jpg", "c.jpg"])

    {:ok, status} =
      FW.Slideshow.start(%{"dir" => dir, "interval_ms" => 60_000, "shuffle" => true})

    assert status.shuffle == true
    assert status.image_count == 3

    assert status.current_path in [
             Path.join(dir, "a.jpg"),
             Path.join(dir, "b.jpg"),
             Path.join(dir, "c.jpg")
           ]
  end

  test "status/0 with nothing running returns %{active: false}" do
    assert FW.Slideshow.status() == %{active: false}
  end
end
