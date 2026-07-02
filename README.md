<div align="center">

# fw — feature wallpaper

**Нативный менеджер обоев для Linux / Wayland, написанный на Elixir + C.**

Daemon на OTP, лёгкий CLI и рендерер поверх `wlr-layer-shell` — без Python, без GTK-обвязки, без лишнего веса.

</div>

---

## Возможности

- 🖥 **Нативный Wayland-рендеринг** через `wlr-layer-shell` — обои рисуются напрямую, без прослойки вроде `swaybg`/`swww`.
- 🧠 **Daemon на Elixir/OTP** с TCP IPC — команды выполняются мгновенно, состояние переживает перезапуски CLI.
- 🔌 **Port-архитектура**: C-рендерер (`priv/fw_renderer`) общается с daemon-ом через порт, падение рендерера не роняет daemon.
- 💾 **Персистентное состояние** в `priv/fw.state.json` — путь к обоям, режим масштабирования, список мониторов.
- 🖼 **Режимы масштабирования**: fit, fill, stretch, center, tile.
- 🖥🖥 **Мультимониторность из коробки** — обои применяются на все подключённые выходы одновременно.
- 🧩 **Совместимость с wlroots-композиторами**: Niri, Sway, Wayfire, Hyprland и другие реализации `wlr-layer-shell-unstable-v1`.

---

## Требования

| Компонент | Версия |
|---|---|
| Elixir | 1.20+ |
| Erlang/OTP | 29+ |
| C-компилятор | `cc`, `clang` или `gcc` |
| ОС | Linux (Wayland-композитор с поддержкой `wlr-layer-shell`) |

Системные зависимости для сборки C-рендерера (пример для Arch):

```bash
sudo pacman -S cairo gdk-pixbuf2 wayland wayland-protocols
```

Для Debian/Ubuntu:

```bash
sudo apt install libcairo2-dev libgdk-pixbuf-2.0-dev libwayland-dev wayland-protocols
```

---

## Установка и сборка

```bash
git clone https://github.com/6lGRUSHAl6/feature-wallpaper.git
cd feature-wallpaper
mix deps.get
mix compile
```

При сборке автоматически:

1. генерируются клиентские биндинги протоколов `wlr-layer-shell` и `xdg-shell` через `wayland-scanner`;
2. компилируется и линкуется нативный рендерер `priv/fw_renderer`.

Прогнать тесты:

```bash
mix test
```

---

## Быстрый старт

Запустить daemon как systemd user-сервис (рекомендуется):

```bash
mix release
systemctl --user start fw
```

Или запустить в текущем терминале, не собирая релиз:

```bash
mix fw start
```

В другом окне — управлять через CLI:

```bash
fw status                          # состояние daemon-а и renderer-а
fw ping                            # быстрая проверка связи
fw apply ~/Pictures/wallpaper.jpg  # применить обои на все мониторы
fw config log-level debug          # сменить уровень логирования
fw stop                            # остановить daemon
```

---

## Команды CLI

| Команда | Описание |
|---|---|
| `fw start` | Запуск daemon-а |
| `fw stop` | Остановка daemon-а |
| `fw status` | Состояние daemon-а, настроек и renderer-а |
| `fw ping` | Быстрая проверка связи с daemon-ом |
| `fw config log-level <debug\|info\|warn\|error>` | Смена уровня логирования |
| `fw apply <path>` | Применить обои по пути к файлу |
| `fw --help` | Справка |
| `fw --version` | Версия |

---

## Как это работает

```
┌─────────────┐      TCP IPC       ┌──────────────┐      Port      ┌────────────────┐
│   fw CLI    │ ─────────────────▶ │  fw daemon    │ ─────────────▶ │  fw_renderer     │
│ (mix fw ..) │                    │  (Elixir/OTP) │                │  (C, wl-client)  │
└─────────────┘                    └──────────────┘                └────────────────┘
                                          │                                  │
                                          ▼                                  ▼
                                  priv/fw.state.json                 wlr-layer-shell
                                  (путь, режим, монитор)              (Wayland compositor)
```

- **CLI** отправляет команду daemon-у по TCP и печатает JSON-ответ.
- **Daemon** хранит состояние, валидирует команды и управляет жизненным циклом рендерера через `Port`.
- **Renderer** — отдельный C-процесс, подключается к Wayland-дисплею, создаёт `layer_surface` на каждом мониторе (`ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND`) и отрисовывает изображение через `wl_shm` + Cairo/gdk-pixbuf.

Если композитор не поддерживает `wlr-layer-shell`, `fw apply` вернёт понятную ошибку вместо падения.

---

## Конфигурация и состояние

Состояние хранится в `priv/fw.state.json` и включает:

- путь к текущим обоям;
- параметры масштабирования и перехода;
- список обнаруженных мониторов;
- настройки daemon-а и renderer-а (хост/порт IPC, путь к бинарнику, уровень логирования).

Файла нет — используются значения по умолчанию, ничего настраивать вручную не нужно.

---

## Сборка релиза

```bash
mix release
```

Релиз включает собранный `fw_renderer` и (если настроено) шаблон systemd user-unit-а для автозапуска.

---


## Вклад в проект

PR и issues приветствуются. Перед отправкой PR:

```bash
mix format
mix test
```

---

## Лицензия

См. файл `LICENSE` в репозитории.