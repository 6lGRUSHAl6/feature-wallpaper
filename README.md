# fw

`fw` (feature wallpaper) — Linux-инструмент для управления обоями рабочего стола через Elixir/OTP и C-рендерер.

## Что уже есть

- CLI с подкомандами
- daemon на Elixir с TCP IPC
- Port-обвязка для `priv/fw_renderer`
- сохранение состояния в `priv/fw.state.json`
- сборка C-бинарника через `mix compile`
- рабочий backend для KDE Plasma Wayland через DBus

## Требования

- Elixir 1.20+
- Erlang/OTP 29+
- C-компилятор: `cc`, `clang` или `gcc`
- Linux

## Сборка

```bash
mix compile
```

При компиляции автоматически собирается C-бинарник `priv/fw_renderer`.

Проверка тестов:

```bash
mix test
```

## Использование

Запуск daemon-а:

```bash
mix fw start
```

После старта daemon остаётся работать в текущем терминале. В другом окне можно отправлять команды:

```bash
mix fw status
mix fw ping
mix fw config log-level debug
mix fw apply /path/to/wallpaper.jpg
mix fw stop
```

На KDE Plasma Wayland команда `fw apply` меняет обои через Plasma DBus API.
Если backend не поддерживается, команда вернёт понятную ошибку.

## Команды CLI

- `fw start` — запуск daemon-а.
- `fw stop` — остановка daemon-а.
- `fw status` — состояние daemon-а, настроек и renderer-а.
- `fw ping` — быстрая проверка связи.
- `fw config log-level <debug|info|warn|error>` — смена уровня логирования.
- `fw apply <path>` — применить новые обои.
- `fw --help` — вывести справку.
- `fw --version` — показать версию.

## Конфигурация и состояние

Текущее состояние хранится в `priv/fw.state.json`.

Там сохраняются:

- путь к текущим обоям
- параметры масштабирования и перехода
- список мониторов
- настройки daemon-а и renderer-а

Если файла нет, проект использует значения по умолчанию.

## Сборка релиза

```bash
mix release
```

Релиз включает собранный `fw_renderer` для Unix/Linux-сценариев.

## Дальше

Сейчас это рабочий каркас с daemon-архитектурой, IPC и работающим wallpaper backend для KDE Plasma Wayland. Следующий шаг — заменить текущую интеграцию на более низкоуровневую Wayland/Cairo/DMA-BUF реализацию и добавить полноценное управление несколькими мониторами.

