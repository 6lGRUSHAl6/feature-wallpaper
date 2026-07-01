defmodule Mix.Tasks.Fw.Install do
  use Mix.Task

  @shortdoc "Install fw daemon unit files for the detected init system"

  @moduledoc """
  Installs the fw daemon service unit for the detected init system.

  ## Usage

      mix fw.install [--dry-run] [--force] [--user USERNAME]

  ## Options

    * `--dry-run`  — Print what would be done without changing anything.
    * `--force`    — Overwrite existing unit files without prompting.
    * `--user`     — Username to embed in runit/s6 scripts (default: `$USER`).

  ## What it does

  1. Detects the running init system (systemd, runit, s6).
  2. Locates the release root (the directory containing `bin/fw`).
  3. Copies/installs unit files from `releases/<vsn>/init/<manager>/`
     into the correct system paths for the detected manager.
  4. Runs the activation command (e.g. `systemctl --user daemon-reload`).

  ### systemd

  Installs `fw.service` to `~/.config/systemd/user/fw.service`, then runs:

      systemctl --user daemon-reload
      systemctl --user enable fw
      systemctl --user start fw

  ### runit

  Copies the `fw/` service directory to `/etc/sv/fw` (requires sudo),
  creates the `/var/service/fw` symlink, and starts it via `sv`.

  ### s6

  Copies `fw/` and `fw-log/` to `/etc/s6/sv/` (requires sudo).
  Activation (symlinking into the scan dir) is printed as instructions
  since s6 scan dir paths vary by distribution.
  """

  @switches [dry_run: :boolean, force: :boolean, user: :string]
  @aliases [n: :dry_run, f: :force, u: :user]

  @impl true
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    dry_run? = Keyword.get(opts, :dry_run, false)
    force? = Keyword.get(opts, :force, false)
    username = Keyword.get(opts, :user, System.get_env("USER") || System.get_env("LOGNAME") || "nobody")

    release_root = find_release_root()
    vsn = find_version(release_root)
    init_dir = Path.join([release_root, "releases", vsn, "init"])
    init = FW.Release.InitUnits.detect_init()

    info("release root : #{release_root}")
    info("version      : #{vsn}")
    info("init system  : #{init}")
    info("user         : #{username}")
    dry_run? && info("[DRY RUN — no changes will be made]")
    info("")

    case init do
      :unknown ->
        Mix.shell().error(
          "Could not detect a supported init system (systemd/runit/s6).\n" <>
            "Install manually from #{init_dir}/"
        )
        exit({:shutdown, 1})

      :systemd ->
        install_systemd(init_dir, release_root, username, dry_run?, force?)

      :runit ->
        install_runit(init_dir, username, dry_run?, force?)

      :s6 ->
        install_s6(init_dir, username, dry_run?, force?)
    end
  end

  # ---------------------------------------------------------------------------
  # systemd
  # ---------------------------------------------------------------------------

  defp install_systemd(init_dir, release_root, _username, dry_run?, force?) do
    src = Path.join([init_dir, "systemd", "fw.service"])
    dest_dir = Path.expand("~/.config/systemd/user")
    dest = Path.join(dest_dir, "fw.service")
    bin = Path.join([release_root, "bin", "fw"])

    ensure_src!(src)

    if File.exists?(dest) and not force? do
      info("Unit already exists at #{dest}")
      info("Use --force to overwrite.")
    else
      do_cmd(dry_run?, "mkdir -p #{dest_dir}", fn -> File.mkdir_p!(dest_dir) end)

      # Read, substitute bin path and user, write
      do_cmd(dry_run?, "install #{src} -> #{dest}", fn ->
        src
        |> File.read!()
        |> String.replace(~r/^ExecStart=.*$/m, "ExecStart=#{bin} start")
        |> String.replace(~r/^ExecStop=.*$/m, "ExecStop=#{bin} stop")
        |> then(&File.write!(dest, &1))
      end)
    end

    do_cmd(dry_run?, "systemctl --user daemon-reload", fn ->
      {_, 0} = System.cmd("systemctl", ["--user", "daemon-reload"], into: IO.stream())
    end)

    do_cmd(dry_run?, "systemctl --user enable fw", fn ->
      {_, 0} = System.cmd("systemctl", ["--user", "enable", "fw"], into: IO.stream())
    end)

    do_cmd(dry_run?, "systemctl --user start fw", fn ->
      {_, 0} = System.cmd("systemctl", ["--user", "start", "fw"], into: IO.stream())
    end)

    info("")
    info("✓ fw is now managed by systemd.")
    info("  journalctl --user -u fw -f")
  end

  # ---------------------------------------------------------------------------
  # runit
  # ---------------------------------------------------------------------------

  defp install_runit(init_dir, username, dry_run?, force?) do
    src = Path.join([init_dir, "runit", "fw"])
    dest = "/etc/sv/fw"
    symlink = "/var/service/fw"

    ensure_src!(src)

    if File.exists?(dest) and not force? do
      info("Service dir already exists at #{dest}")
      info("Use --force to overwrite.")
    else
      uid = uid_for(username)

      do_cmd(dry_run?, "sudo cp -r #{src} #{dest}", fn ->
        {_, 0} = System.cmd("sudo", ["cp", "-r", src, dest], into: IO.stream())
      end)

      # Substitute YOURUSER in the installed run script
      run_path = Path.join(dest, "run")
      do_cmd(dry_run?, "patch #{run_path}: set FW_USER=#{username} FW_UID=#{uid}", fn ->
        {_, 0} = System.cmd("sudo", ["sed", "-i",
          "s/FW_USER=YOURUSER/FW_USER=#{username}/g", run_path], into: IO.stream())
      end)
    end

    unless File.exists?(symlink) do
      do_cmd(dry_run?, "sudo ln -s #{dest} #{symlink}", fn ->
        {_, 0} = System.cmd("sudo", ["ln", "-s", dest, symlink], into: IO.stream())
      end)
    end

    do_cmd(dry_run?, "sv start fw", fn ->
      {_, 0} = System.cmd("sv", ["start", "fw"], into: IO.stream())
    end)

    info("")
    info("✓ fw is now managed by runit.")
    info("  sv status fw")
  end

  # ---------------------------------------------------------------------------
  # s6
  # ---------------------------------------------------------------------------

  defp install_s6(init_dir, username, dry_run?, force?) do
    src_fw = Path.join([init_dir, "s6", "fw"])
    src_log = Path.join([init_dir, "s6", "fw-log"])
    dest_base = "/etc/s6/sv"
    dest_fw = Path.join(dest_base, "fw")
    dest_log = Path.join(dest_base, "fw-log")

    ensure_src!(src_fw)

    if File.exists?(dest_fw) and not force? do
      info("Service dir already exists at #{dest_fw}")
      info("Use --force to overwrite.")
    else
      for {src, dest} <- [{src_fw, dest_fw}, {src_log, dest_log}] do
        do_cmd(dry_run?, "sudo cp -r #{src} #{dest}", fn ->
          {_, 0} = System.cmd("sudo", ["cp", "-r", src, dest], into: IO.stream())
        end)
      end

      run_path = Path.join(dest_fw, "run")
      do_cmd(dry_run?, "patch #{run_path}: replace YOURUSER -> #{username}", fn ->
        {_, 0} = System.cmd("sudo", ["sed", "-i",
          "s/YOURUSER/#{username}/g", run_path], into: IO.stream())
      end)
    end

    info("")
    info("✓ fw s6 service files installed.")
    info("  Activation depends on your distro. Common next steps:")
    info("  Symlink into your scan dir:  sudo ln -s #{dest_fw} /run/s6/current-service/fw")
    info("  Or add to s6-rc source db and run: s6-rc-compile + s6-rc change fw")
  end

  # ---------------------------------------------------------------------------
  # Release root / version discovery
  # ---------------------------------------------------------------------------

  # When running from `mix fw.install` in the project dir, locate the latest
  # assembled release under _build/prod/rel/fw.
  defp find_release_root do
    candidates = [
      Path.expand("_build/prod/rel/fw"),
      Path.expand("_build/dev/rel/fw")
    ]

    case Enum.find(candidates, &File.exists?/1) do
      nil ->
        Mix.shell().error("No assembled release found. Run `mix release` first.")
        exit({:shutdown, 1})

      path ->
        path
    end
  end

  defp find_version(release_root) do
    releases_dir = Path.join(release_root, "releases")

    releases_dir
    |> File.ls!()
    |> Enum.filter(&File.dir?(Path.join(releases_dir, &1)))
    |> Enum.sort(:desc)
    |> List.first()
    |> case do
      nil ->
        Mix.shell().error("No release version found under #{releases_dir}")
        exit({:shutdown, 1})

      vsn ->
        vsn
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp ensure_src!(path) do
    unless File.exists?(path) do
      Mix.shell().error("Expected init source not found: #{path}\nRun `mix release` first.")
      exit({:shutdown, 1})
    end
  end

  defp uid_for(username) do
    case System.cmd("id", ["-u", username], stderr_to_stdout: true) do
      {uid, 0} -> String.trim(uid)
      _ -> "1000"
    end
  end

  defp do_cmd(false, label, fun) do
    info("  → #{label}")
    fun.()
  end

  defp do_cmd(true, label, _fun) do
    info("  [dry-run] #{label}")
  end

  defp info(msg), do: Mix.shell().info(msg)
end
