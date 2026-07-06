# fw — справочник команд и флагов

## Глобальные флаги

Указываются перед именем команды.

| Флаг | Алиас | Описание |
|---|---|---|
| `--host <ip>` | — | Адрес daemon'а, к которому подключается CLI. По умолчанию — из `priv/fw.state.json` (обычно `127.0.0.1`) |
| `--port <n>` | — | Порт daemon'а. По умолчанию — из `priv/fw.state.json` (обычно `47788`) |
| `--help` | `-h` | Показать справку и выйти |
| `--version` | `-v` | Показать версию и выйти |

Пример: `fw --host 10.0.0.5 --port 47788 status`

---

## Команды

### `fw start`

Запускает daemon в текущем терминале (без демонизации — процесс держит терминал открытым).

```bash
fw start
```

Для фонового запуска — через systemd user-сервис:
```bash
systemctl --user start fw
```

---

### `fw stop`

Останавливает запущенный daemon.

```bash
fw stop
```

---

### `fw status`

Показывает текущее состояние daemon'а: настройки, статус renderer'а, текущие обои, мониторы.

```bash
fw status
```

---

### `fw ping`

Быстрая проверка связи с daemon'ом (`pong` в ответ).

```bash
fw ping
```

---

### `fw config log-level <уровень>`

Меняет уровень логирования daemon'а на лету.

| Аргумент | Допустимые значения |
|---|---|
| `<уровень>` | `debug`, `info`, `warn`, `error` |

```bash
fw config log-level debug
```

---

### `fw apply <path>` — статичные обои

Применяет одну картинку как обои на все подключённые мониторы.

| Аргумент/флаг | Обязателен | Значения | Описание |
|---|---|---|---|
| `<path>` | да | путь к файлу | Путь к изображению (абсолютный или относительный — будет расширен через `Path.expand`) |
| `--scaling <режим>` (алиас `--mode`) | нет | `fit`, `fill`, `stretch`, `center`, `tile` | Режим масштабирования картинки |
| `--transition <тип>` | нет | `none`, `fade` | Тип перехода при смене обоев |

```bash
fw apply ~/Pictures/wallpaper.jpg
fw apply ~/Pictures/wallpaper.jpg --scaling fill --transition fade
fw apply ~/Pictures/wallpaper.jpg --mode tile
```

---

### `fw apply --dir <path> --slideshow-interval <N>s|m|h` — слайд-шоу

Запускает автоматическую смену обоев по расписанию из папки с картинками.

| Флаг | Обязателен | Значения | Описание |
|---|---|---|---|
| `--dir <path>` | да (запускает режим слайд-шоу) | путь к папке | Папка с картинками. Поддерживаемые расширения: `.jpg`, `.jpeg`, `.png`, `.webp`, `.bmp`, `.gif`. Не-изображения игнорируются |
| `--slideshow-interval <N><s\|m\|h>` | да, если указан `--dir` | напр. `30s`, `10m`, `2h` | Интервал смены картинки. Минимум — 1 минута (после конвертации; `59s` будет отклонён) |
| `--shuffle` | нет | флаг без значения | Перемешать порядок показа картинок. Без флага — по алфавиту |
| `--scaling <режим>` (алиас `--mode`) | нет | `fit`, `fill`, `stretch`, `center`, `tile` | Режим масштабирования, применяется ко всем картинкам слайд-шоу |
| `--transition <тип>` | нет | `none`, `fade` | Тип перехода при каждой смене картинки |

```bash
fw apply --dir ~/Pictures/wallpapers --slideshow-interval 30m
fw apply --dir ~/Pictures/wallpapers --slideshow-interval 5m --shuffle
fw apply --dir ~/Pictures/wallpapers --slideshow-interval 1h --shuffle --scaling fill --transition fade
```

Повторный вызов `fw apply --dir ...` с другой папкой/настройками заменяет текущее слайд-шоу новым (без необходимости сначала останавливать старое).

Слайд-шоу переживает перезапуск daemon'а — состояние (папка, интервал, shuffle, scaling, transition) сохраняется и восстанавливается автоматически.

---

### `fw slideshow stop`

Останавливает текущее слайд-шоу. Последняя показанная картинка остаётся как статичные обои. Безопасно вызывать, даже если слайд-шоу не запущено.

```bash
fw slideshow stop
```

---

### `fw slideshow status`

Показывает состояние слайд-шоу.

```bash
fw slideshow status
```

Пример ответа, когда активно:
```json
{
  "active": true,
  "dir": "/home/user/Pictures/wallpapers",
  "interval_ms": 1800000,
  "shuffle": false,
  "scaling": null,
  "transition": null,
  "image_count": 12,
  "current_index": 3,
  "current_path": "/home/user/Pictures/wallpapers/d.jpg"
}
```

Когда неактивно: `{"active": false}`

---

### `fw --help`

Показывает краткую справку по всем командам.

```bash
fw --help
```

---

### `fw --version`

Показывает версию `fw`.

```bash
fw --version
```

---

## Сводная таблица

| Команда | Флаги | Что делает |
|---|---|---|
| `fw start` | `--host`, `--port` | Запустить daemon в текущем терминале |
| `fw stop` | — | Остановить daemon |
| `fw status` | — | Показать состояние daemon'а |
| `fw ping` | — | Проверить связь с daemon'ом |
| `fw config log-level <lvl>` | — | Сменить уровень логирования |
| `fw apply <path>` | `--scaling`/`--mode`, `--transition` | Применить статичные обои |
| `fw apply --dir <path> --slideshow-interval <N>s\|m\|h` | `--shuffle`, `--scaling`/`--mode`, `--transition` | Запустить слайд-шоу обоев из папки |
| `fw slideshow stop` | — | Остановить слайд-шоу |
| `fw slideshow status` | — | Показать состояние слайд-шоу |
| `fw --help` / `-h` | — | Справка |
| `fw --version` / `-v` | — | Версия |
