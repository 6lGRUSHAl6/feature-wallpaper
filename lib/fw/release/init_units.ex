defmodule FW.Release.InitUnits do
  @moduledoc """
  Custom Mix release step that detects the running init system and
  writes service unit files into the assembled release.

  Runs **after** `:assemble` (so the release binary already exists)
  and **before** `:tar` (so the units are included in the tarball).

  Configure in `mix.exs`:

      releases: [
        fw: [
          include_executables_for: [:unix],
          steps: [:assemble, &FW.Release.InitUnits.run/1, :tar]
        ]
      ]

  ## Generated files

  All files are written under `<release_root>/releases/<vsn>/init/`:

    - `systemd/fw.service`
    - `runit/fw/run`, `runit/fw/finish`, `runit/fw/log/run`
    - `s6/fw/run`, `s6/fw/finish`, `s6/fw/type`
    - `s6/fw-log/run`, `s6/fw-log/type`
    - `README.md`

  ## Detection order

  1. **systemd** — `/run/systemd/private` exists, or `INVOCATION_ID`
     env var is set, or PID-1 (`/proc/1/comm`) is `systemd`.
  2. **runit** — `/run/runit` exists, `/sbin/runit-init` exists,
     or PID-1 is `runit`.
  3. **s6** — `/run/s6` exists, `s6-svscan` in PATH, or PID-1 is `s6`.
  4. **unknown** — warning printed, all templates still written.
  """

  @doc """
  Entry point called by the Mix release pipeline.
  Receives and returns the `%Mix.Release{}` struct unchanged.
  """
  def run(%Mix.Release{} = release) do
    init_dir = init_dir(release)
    :ok = File.mkdir_p(init_dir)

    init = detect_init()
    log("detected init system: #{init}")

    write_readme(init_dir, release)
    write_for(init, init_dir, release)

    log("unit files written to #{Path.relative_to_cwd(init_dir)}/")
    log("run `mix fw.install` to install and activate automatically")
    release
  end

  @doc """
  Detects the running init system. Returns `:systemd`, `:runit`, `:s6`,
  or `:unknown`. Public so `Mix.Tasks.Fw.Install` can reuse it.
  """
  def detect_init do
    cond do
      systemd?() -> :systemd
      runit?() -> :runit
      s6?() -> :s6
      true -> :unknown
    end
  end

  # ---------------------------------------------------------------------------
  # Release path helpers
  # ---------------------------------------------------------------------------

  defp init_dir(%Mix.Release{version: vsn, path: root}) do
    Path.join([root, "releases", vsn, "init"])
  end

  @doc "Absolute path to the release binary. Public for use in fw.install."
  def bin_path(%Mix.Release{name: name, path: root}) do
    Path.join([root, "bin", to_string(name)])
  end

  # ---------------------------------------------------------------------------
  # Init detection (private helpers)
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

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp write_for(:unknown, init_dir, release) do
    log(
      "WARNING: could not detect a supported init system (systemd/runit/s6). " <>
        "Writing all templates anyway. " <>
        "See #{Path.join(init_dir, "README.md")} for install instructions."
    )

    write_systemd(init_dir, release)
    write_runit(init_dir, release)
    write_s6(init_dir, release)
  end

  defp write_for(init, init_dir, release) do
    write_systemd(init_dir, release)
    write_runit(init_dir, release)
    write_s6(init_dir, release)
    log("detected #{init} — see init/#{init}/ for the recommended unit files")
  end

  # ---------------------------------------------------------------------------
  # systemd
  # ---------------------------------------------------------------------------

  defp write_systemd(init_dir, release) do
    dir = Path.join(init_dir, "systemd")
    :ok = File.mkdir_p(dir)
    write_file(Path.join(dir, "fw.service"), systemd_unit(release))
  end

  defp systemd_unit(release) do
    bin = bin_path(release)

    """
    # ~/.config/systemd/user/fw.service
    # Installed automatically by `mix fw.install`.
    # Manual install: see releases/#{release.version}/init/README.md

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

  # ---------------------------------------------------------------------------
  # runit
  # ---------------------------------------------------------------------------

  defp write_runit(init_dir, release) do
    base = Path.join([init_dir, "runit", "fw"])
    log_dir = Path.join(base, "log")
    :ok = File.mkdir_p(log_dir)

    write_file(Path.join(base, "run"), runit_run(release), mode: 0o755)
    write_file(Path.join(base, "finish"), runit_finish(), mode: 0o755)
    write_file(Path.join(log_dir, "run"), runit_log_run(), mode: 0o755)
  end

  defp runit_run(release) do
    bin = bin_path(release)

    """
    #!/bin/sh
    # Installed to /etc/sv/fw/run by `mix fw.install`.
    # YOURUSER is replaced with the real username at install time.

    FW_USER=YOURUSER
    FW_UID=$(id -u "${FW_USER}" 2>/dev/null || echo 1000)

    exec chpst -u "${FW_USER}:${FW_USER}" \\
      env WAYLAND_DISPLAY=wayland-1 \\
          XDG_RUNTIME_DIR=/run/user/${FW_UID} \\
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

  # ---------------------------------------------------------------------------
  # s6
  # ---------------------------------------------------------------------------

  defp write_s6(init_dir, release) do
    base = Path.join([init_dir, "s6", "fw"])
    log_dir = Path.join([init_dir, "s6", "fw-log"])
    :ok = File.mkdir_p(base)
    :ok = File.mkdir_p(log_dir)

    write_file(Path.join(base, "run"), s6_run(release), mode: 0o755)
    write_file(Path.join(base, "finish"), s6_finish(), mode: 0o755)
    write_file(Path.join(base, "type"), "longrun\n")
    write_file(Path.join(log_dir, "run"), s6_log_run(), mode: 0o755)
    write_file(Path.join(log_dir, "type"), "longrun\n")
  end

  defp s6_run(release) do
    bin = bin_path(release)

    """
    #!/bin/execlineb -P
    # Installed to /etc/s6/sv/fw/run by `mix fw.install`.
    # YOURUSER is replaced with the real username at install time.

    importas -D "wayland-1" WAYLAND_DISPLAY WAYLAND_DISPLAY
    importas -D "/run/user/1000" XDG_RUNTIME_DIR XDG_RUNTIME_DIR

    s6-setuidgid YOURUSER

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
  # README
  # ---------------------------------------------------------------------------

  defp write_readme(init_dir, release) do
    write_file(Path.join(init_dir, "README.md"), readme(release))
  end

  defp readme(release) do
    vsn = release.version

    """
    # fw — Init Unit Files (v#{vsn})

    Generated by `mix release` via `FW.Release.InitUnits`.

    ## Automatic install (recommended)

        mix fw.install

    Detects your init system, copies unit files to the right place,
    and starts the daemon. Use `--dry-run` to preview first.

    ## Manual install

    ### systemd

        mkdir -p ~/.config/systemd/user
        cp releases/#{vsn}/init/systemd/fw.service ~/.config/systemd/user/fw.service
        systemctl --user daemon-reload
        systemctl --user import-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR
        systemctl --user enable --now fw

    ### runit

        # Edit run: set FW_USER=<youruser>
        sudo cp -r releases/#{vsn}/init/runit/fw /etc/sv/fw
        sudo ln -s /etc/sv/fw /var/service/fw

    ### s6

        # Edit run: replace YOURUSER
        sudo cp -r releases/#{vsn}/init/s6/fw /etc/s6/sv/fw
        sudo cp -r releases/#{vsn}/init/s6/fw-log /etc/s6/sv/fw-log
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp write_file(path, content, opts \\ []) do
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = File.write(path, content)

    if mode = Keyword.get(opts, :mode) do
      File.chmod!(path, mode)
    end
  end

  defp log(msg), do: Mix.shell().info("* [fw_init_units] #{msg}")
end
