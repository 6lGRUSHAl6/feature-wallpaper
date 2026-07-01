defmodule FW.Release.InitUnits do
  @moduledoc """
  Custom Mix release step that:

  1. Detects the running init system (systemd, runit, s6).
  2. Writes unit file templates into `releases/<vsn>/init/` (included in
     the release tarball for reference / manual install on other machines).
  3. **Installs and activates** the unit for the detected init system
     automatically, so `mix release` is the only command needed.

  Configure in `mix.exs`:

      releases: [
        fw: [
          include_executables_for: [:unix],
          steps: [:assemble, &FW.Release.InitUnits.run/1, :tar]
        ]
      ]

  ## Environment variables

    * `FW_INSTALL_USER`  — override the username embedded in runit/s6
      scripts (default: `$USER`).
    * `FW_NO_INSTALL`    — set to any non-empty value to skip the live
      install and only write the template files.

  ## Detection order

  1. **systemd** — `/run/systemd/private`, `INVOCATION_ID` env, or PID-1 name.
  2. **runit**   — `/run/runit`, `/sbin/runit-init`, or PID-1 name.
  3. **s6**      — `/run/s6`, `s6-svscan` in PATH, or PID-1 name.
  4. **unknown** — templates written, install skipped with a warning.
  """

  @doc """
  Entry point called by the Mix release pipeline.
  Receives and returns the `%Mix.Release{}` struct unchanged.
  """
  def run(%Mix.Release{} = release) do
    init_dir = init_dir(release)
    :ok = File.mkdir_p(init_dir)

    init = detect_init()
    username = System.get_env("FW_INSTALL_USER") ||
               System.get_env("USER") ||
               System.get_env("LOGNAME") ||
               "nobody"
    skip_install? = System.get_env("FW_NO_INSTALL") not in [nil, ""]

    log("init system : #{init}")
    log("user        : #{username}")

    # Always write all templates so the tarball is self-contained.
    write_readme(init_dir, release)
    write_systemd(init_dir, release)
    write_runit(init_dir, release)
    write_s6(init_dir, release)
    log("templates written to #{Path.relative_to_cwd(init_dir)}/")

    if skip_install? do
      log("FW_NO_INSTALL set — skipping live install")
    else
      install(init, release, username)
    end

    release
  end

  @doc "Detects the running init system. Public for testing."
  def detect_init do
    cond do
      systemd?() -> :systemd
      runit?()   -> :runit
      s6?()      -> :s6
      true       -> :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Install dispatch
  # ---------------------------------------------------------------------------

  defp install(:unknown, _release, _username) do
    log("WARNING: could not detect a supported init system.")
    log("Install manually from the init/ directory in the release.")
  end

  defp install(:systemd, release, _username) do
    bin   = bin_path(release)
    dest_dir = Path.expand("~/.config/systemd/user")
    dest     = Path.join(dest_dir, "fw.service")

    :ok = File.mkdir_p(dest_dir)

    # Write unit with the real binary path baked in.
    File.write!(dest, systemd_unit(bin))
    log("installed #{dest}")

    cmd!("systemctl", ["--user", "daemon-reload"])
    cmd!("systemctl", ["--user", "enable", "fw"])
    cmd!("systemctl", ["--user", "start",  "fw"])
    log("✓ fw enabled and started via systemd")
    log("  journalctl --user -u fw -f")
  end

  defp install(:runit, release, username) do
    bin  = bin_path(release)
    dest = "/etc/sv/fw"
    symlink = "/var/service/fw"

    # Write run/finish/log scripts to a temp dir, then sudo-copy.
    tmp = Path.join(System.tmp_dir!(), "fw-runit-#{:os.getpid()}")
    :ok = File.mkdir_p(Path.join(tmp, "log"))
    uid = uid_for(username)

    File.write!(Path.join(tmp, "run"),        runit_run(bin, username, uid), [:raw])
    File.write!(Path.join(tmp, "finish"),      runit_finish(), [:raw])
    File.write!(Path.join(Path.join(tmp, "log"), "run"), runit_log_run(), [:raw])
    File.chmod!(Path.join(tmp, "run"),    0o755)
    File.chmod!(Path.join(tmp, "finish"), 0o755)
    File.chmod!(Path.join(Path.join(tmp, "log"), "run"), 0o755)

    cmd!("sudo", ["cp", "-r", tmp, dest])
    log("installed #{dest}")

    unless File.exists?(symlink) do
      cmd!("sudo", ["ln", "-s", dest, symlink])
    end

    cmd!("sv", ["start", "fw"])
    log("✓ fw enabled and started via runit")
    log("  sv status fw")
  after
    File.rm_rf(Path.join(System.tmp_dir!(), "fw-runit-#{:os.getpid()}"))
  end

  defp install(:s6, release, username) do
    bin      = bin_path(release)
    dest_base = "/etc/s6/sv"
    dest_fw   = Path.join(dest_base, "fw")
    dest_log  = Path.join(dest_base, "fw-log")

    tmp = Path.join(System.tmp_dir!(), "fw-s6-#{:os.getpid()}")
    tmp_fw  = Path.join(tmp, "fw")
    tmp_log = Path.join(tmp, "fw-log")
    :ok = File.mkdir_p(tmp_fw)
    :ok = File.mkdir_p(tmp_log)

    File.write!(Path.join(tmp_fw, "run"),    s6_run(bin, username), [:raw])
    File.write!(Path.join(tmp_fw, "finish"), s6_finish(), [:raw])
    File.write!(Path.join(tmp_fw, "type"),   "longrun\n")
    File.write!(Path.join(tmp_log, "run"),   s6_log_run(), [:raw])
    File.write!(Path.join(tmp_log, "type"),  "longrun\n")
    File.chmod!(Path.join(tmp_fw, "run"),    0o755)
    File.chmod!(Path.join(tmp_fw, "finish"), 0o755)
    File.chmod!(Path.join(tmp_log, "run"),   0o755)

    cmd!("sudo", ["cp", "-r", tmp_fw,  dest_fw])
    cmd!("sudo", ["cp", "-r", tmp_log, dest_log])
    log("installed #{dest_fw} and #{dest_log}")
    log("✓ fw s6 service files installed")
    log("  Next: symlink into your scan dir or run s6-rc change fw")
  after
    File.rm_rf(Path.join(System.tmp_dir!(), "fw-s6-#{:os.getpid()}"))
  end

  # ---------------------------------------------------------------------------
  # Path helpers
  # ---------------------------------------------------------------------------

  defp init_dir(%Mix.Release{version: vsn, path: root}),
    do: Path.join([root, "releases", vsn, "init"])

  defp bin_path(%Mix.Release{name: name, path: root}),
    do: Path.join([root, "bin", to_string(name)])

  # ---------------------------------------------------------------------------
  # Init detection
  # ---------------------------------------------------------------------------

  defp systemd? do
    File.exists?("/run/systemd/private") or
      System.get_env("INVOCATION_ID") != nil or
      String.contains?(pid1_comm(), "systemd")
  end

  defp runit? do
    File.exists?("/run/runit") or
      File.exists?("/sbin/runit-init") or
      String.contains?(pid1_comm(), "runit")
  end

  defp s6? do
    File.exists?("/run/s6") or
      System.find_executable("s6-svscan") != nil or
      String.contains?(pid1_comm(), "s6")
  end

  defp pid1_comm do
    case File.read("/proc/1/comm") do
      {:ok, comm} -> String.trim(comm)
      _ -> ""
    end
  end

  defp uid_for(username) do
    case System.cmd("id", ["-u", username], stderr_to_stdout: true) do
      {uid, 0} -> String.trim(uid)
      _ -> "1000"
    end
  end

  # ---------------------------------------------------------------------------
  # Unit file content
  # ---------------------------------------------------------------------------

  defp systemd_unit(bin) do
    """
    # Installed by `mix release` via FW.Release.InitUnits.

    [Unit]
    Description=fw — feature-wallpaper Wayland wallpaper daemon
    Documentation=https://github.com/Skartorion/feature-wallpaper
    After=graphical-session.target
    PartOf=graphical-session.target

    [Service]
    Type=simple
    ExecStart=#{bin} start
    ExecStop=#{bin} stop

    KillSignal=SIGTERM
    KillMode=mixed
    TimeoutStopSec=10

    Restart=on-failure
    RestartSec=3s

    Environment=LANG=en_US.UTF-8

    StandardOutput=journal
    StandardError=journal
    SyslogIdentifier=fw

    [Install]
    WantedBy=graphical-session.target
    """
  end

  defp runit_run(bin, username, uid) do
    """
    #!/bin/sh
    exec chpst -u #{username}:#{username} \\
      env WAYLAND_DISPLAY=wayland-1 \\
          XDG_RUNTIME_DIR=/run/user/#{uid} \\
      #{bin} start
    """
  end

  defp runit_finish do
    """
    #!/bin/sh
    echo "[fw] exited: code=$1 signal=$2" >&2
    """
  end

  defp runit_log_run do
    """
    #!/bin/sh
    exec svlogd -tt /var/log/fw
    """
  end

  defp s6_run(bin, username) do
    """
    #!/bin/execlineb -P
    importas -D "wayland-1" WAYLAND_DISPLAY WAYLAND_DISPLAY
    importas -D "/run/user/1000" XDG_RUNTIME_DIR XDG_RUNTIME_DIR
    s6-setuidgid #{username}
    #{bin} start
    """
  end

  defp s6_finish do
    """
    #!/bin/execlineb
    foreground { s6-echo "[fw] service exited" }
    exit 0
    """
  end

  defp s6_log_run do
    """
    #!/bin/execlineb -P
    s6-log -d3 T /var/log/fw
    """
  end

  # ---------------------------------------------------------------------------
  # Template files (written into release tarball for reference)
  # ---------------------------------------------------------------------------

  defp write_systemd(init_dir, release) do
    dir = Path.join(init_dir, "systemd")
    :ok = File.mkdir_p(dir)
    File.write!(Path.join(dir, "fw.service"), systemd_unit(bin_path(release)))
  end

  defp write_runit(init_dir, release) do
    base    = Path.join([init_dir, "runit", "fw"])
    log_dir = Path.join(base, "log")
    :ok = File.mkdir_p(log_dir)
    bin = bin_path(release)
    write_x(Path.join(base,    "run"),    runit_run(bin, "YOURUSER", "$(id -u YOURUSER)"))
    write_x(Path.join(base,    "finish"), runit_finish())
    write_x(Path.join(log_dir, "run"),    runit_log_run())
  end

  defp write_s6(init_dir, release) do
    base    = Path.join([init_dir, "s6", "fw"])
    log_dir = Path.join([init_dir, "s6", "fw-log"])
    :ok = File.mkdir_p(base)
    :ok = File.mkdir_p(log_dir)
    bin = bin_path(release)
    write_x(Path.join(base,    "run"),    s6_run(bin, "YOURUSER"))
    write_x(Path.join(base,    "finish"), s6_finish())
    File.write!(Path.join(base,    "type"), "longrun\n")
    write_x(Path.join(log_dir, "run"),    s6_log_run())
    File.write!(Path.join(log_dir, "type"), "longrun\n")
  end

  defp write_readme(init_dir, release) do
    File.write!(Path.join(init_dir, "README.md"), readme(release.version))
  end

  defp readme(vsn) do
    """
    # fw — Init Unit Files (v#{vsn})

    These files were written by `mix release` via `FW.Release.InitUnits`.
    The daemon was also installed and started automatically for the
    detected init system.

    Set `FW_NO_INSTALL=1` before `mix release` to skip live install
    and only generate the template files.

    ## Manual install (if needed)

    ### systemd
        mkdir -p ~/.config/systemd/user
        cp releases/#{vsn}/init/systemd/fw.service ~/.config/systemd/user/
        systemctl --user daemon-reload
        systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR
        systemctl --user enable --now fw

    ### runit
        sudo cp -r releases/#{vsn}/init/runit/fw /etc/sv/fw
        sudo ln -s /etc/sv/fw /var/service/fw

    ### s6
        sudo cp -r releases/#{vsn}/init/s6/fw /etc/s6/sv/fw
        sudo cp -r releases/#{vsn}/init/s6/fw-log /etc/s6/sv/fw-log
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_x(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end

  defp cmd!(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true, into: IO.stream()) do
      {_, 0} -> :ok
      {out, code} ->
        Mix.raise("Command failed (exit #{code}): #{bin} #{Enum.join(args, " ")}\n#{out}")
    end
  end

  defp log(msg), do: Mix.shell().info("* [fw_init_units] #{msg}")
end
