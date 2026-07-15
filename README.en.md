<div align="center">

# fw — feature wallpaper

[ru Русский](README.md) · [en English](README.en.md)

**A native wallpaper manager for Linux / Wayland, written in Elixir + C.**

An OTP daemon, a lightweight CLI, and a renderer built on top of `wlr-layer-shell` — no Python, no GTK wrapping, no unnecessary bloat.

</div>

---

## Features

- 🖥 **Native Wayland rendering** via `wlr-layer-shell` — wallpapers are drawn directly, without a layer like `swaybg`/`swww`.
- 🧠 **Elixir/OTP daemon** with TCP IPC — commands execute instantly, and state survives CLI restarts.
- 🔌 **Port-based architecture**: the C renderer (`priv/fw_renderer`) communicates with the daemon over a port, so a renderer crash doesn't bring down the daemon.
- 💾 **Persistent state** in `priv/fw.state.json` — wallpaper path, scaling mode, list of monitors.
- 🖼 **Scaling modes**: fit, fill, stretch, center, tile.
- 🖥🖥 **Multi-monitor support out of the box** — wallpapers are applied to all connected outputs simultaneously.
- 🧩 **Compatible with wlroots compositors**: Niri, Sway, Wayfire, Hyprland, and other implementations of `wlr-layer-shell-unstable-v1`.

---

## Requirements

| Component | Version |
|---|---|
| Elixir | 1.20+ |
| Erlang/OTP | 29+ |
| C compiler | `cc`, `clang`, or `gcc` |
| OS | Linux (a Wayland compositor supporting `wlr-layer-shell`) |

System dependencies for building the C renderer (Arch example):

```bash
sudo pacman -S cairo gdk-pixbuf2 wayland wayland-protocols
```

For Debian/Ubuntu:

```bash
sudo apt install libcairo2-dev libgdk-pixbuf-2.0-dev libwayland-dev wayland-protocols
```

---

## Installation and building

```bash
git clone https://github.com/6lGRUSHAl6/feature-wallpaper.git
cd feature-wallpaper
mix deps.get
mix compile
```

During the build, the following happens automatically:

1. client bindings for the `wlr-layer-shell` and `xdg-shell` protocols are generated via `wayland-scanner`;
2. the native renderer `priv/fw_renderer` is compiled and linked.

Run the tests:

```bash
mix test
```

---

## Quick start

Run the daemon as a systemd user service (recommended):

```bash
mix release
systemctl --user start fw
```

Or run it in the current terminal without building a release:

```bash
mix fw start
```

In another window — control it via the CLI:

```bash
fw status                          # daemon and renderer status
fw ping                            # quick connectivity check
fw apply ~/Pictures/wallpaper.jpg  # apply wallpaper to all monitors
fw config log-level debug          # change the logging level
fw stop                            # stop the daemon
```

---

## CLI commands

| Command | Description |
|---|---|
| `fw start` | Start the daemon |
| `fw stop` | Stop the daemon |
| `fw status` | Show daemon, config, and renderer status |
| `fw ping` | Quick connectivity check with the daemon |
| `fw config log-level <debug\|info\|warn\|error>` | Change the logging level |
| `fw apply <path>` | Apply a wallpaper from a file path |
| `fw --help` | Show help |
| `fw --version` | Show version |

---

## How it works

```
┌─────────────┐      TCP IPC       ┌──────────────┐      Port      ┌────────────────┐
│   fw CLI    │ ─────────────────▶ │  fw daemon   │ ─────────────▶│  fw_renderer   │
│ (mix fw ..) │                    │  (Elixir/OTP)│               │  (C, wl-client) │
└─────────────┘                    └──────────────┘                └────────────────┘
                                          │                                  │
                                          ▼                                  ▼
                                  priv/fw.state.json                 wlr-layer-shell
                                  (path, mode, monitor)               (Wayland compositor)
```

- The **CLI** sends a command to the daemon over TCP and prints the JSON response.
- The **daemon** stores state, validates commands, and manages the renderer's lifecycle via a `Port`.
- The **renderer** is a separate C process that connects to the Wayland display, creates a `layer_surface` on each monitor (`ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND`), and draws the image via `wl_shm` + Cairo/gdk-pixbuf.

If the compositor doesn't support `wlr-layer-shell`, `fw apply` returns a clear error instead of crashing.

---

## Configuration and state

State is stored in `priv/fw.state.json` and includes:

- the path to the current wallpaper;
- scaling and transition parameters;
- the list of detected monitors;
- daemon and renderer settings (IPC host/port, binary path, logging level).

If the file doesn't exist, default values are used — no manual configuration is required.

---

## Building a release

```bash
mix release
```

The release includes the compiled `fw_renderer` and (if configured) a systemd user-unit template for autostart.

---

## Contributing

PRs and issues are welcome. Before submitting a PR:

```bash
mix format
mix test
```

---

## License

See the `LICENSE` file in the repository.
