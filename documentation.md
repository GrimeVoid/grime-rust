# Справочник GRIME (Grime-RS)

Технический справочник по ядру GRIME, формату модулей (аннотации `--@grime`), нативному Lua API, конфигурации и встроенным модулям. Обзор проекта и примеры — в [README.md](README.md).

Содержание:
1. [Архитектура](#1-архитектура)
2. [Аннотации модуля `--@grime`](#2-аннотации-модуля---grime)
3. [Как написать собственный модуль](#3-как-написать-собственный-модуль)
4. [Контекст шага: `grime.ctx`](#4-контекст-шага-grimectx)
5. [Файловые операции: `grime.fs`](#5-файловые-операции-grimefs)
6. [Процессы: `grime.process`](#6-процессы-grimeprocess)
7. [Шина состояния и события: `grime.bus`, `grime.events`](#7-шина-состояния-и-события-grimebus-grimeevents)
8. [Реестр модулей: `grime.modules`](#8-реестр-модулей-grimemodules)
9. [Эфемерные ресурсы: `grime.ephemeral`](#9-эфемерные-ресурсы-grimeephemeral)
10. [Парсер аргументов: `grime.args`](#10-парсер-аргументов-grimeargs)
11. [Прочие библиотеки: `json`, `msgpack`, `str`, `table`, `fuzzy`, `ui`, `time`, `config`, `paths`](#11-прочие-библиотеки)
12. [Конфигурация и переменные окружения](#12-конфигурация-и-переменные-окружения)
13. [Кэши и эфемерность](#13-кэши-и-эфемерность)
14. [Встроенные модули](#14-встроенные-модули)
15. [ИИ-подсистема: `ai` и адаптеры агентов](#15-ии-подсистема-ai-и-адаптеры-агентов)
16. [Безопасность](#16-безопасность)
17. [Разработка и тесты](#17-разработка-и-тесты)
18. [Ещё не реализовано](#18-ещё-не-реализовано)

---

## 1. Архитектура

GRIME состоит из **микроядра на Rust** и **модулей на Lua 5.4**.

- Рантайм модулей — **Lua 5.4** (крейт `mlua`, встроенная сборка `vendored`). LuaJIT не используется.
- **Ядро** разбирает командную строку, строит конвейер шагов (разделитель `:`), исполняет модули, ведёт шину состояния (`StateBus`) и шину событий (`EventBus`), единообразно выводит ошибки (`[Grime Error]` ровно один раз). Ядро **не содержит знаний о конкретных модулях**: имена, алиасы, описания, границы сред, переключение сред, пути по умолчанию и зависимости модули объявляют сами аннотациями (раздел 2).
- **Client-first.** Обычные команды выполняются в процессе клиента `grime` (прямой доступ к TTY и сигналам терминала). Клиент использует `current_thread` runtime.
- **Демон** (`grime --daemon-server`; управление — модуль `daemon`) используется для фоновых открепляемых задач (`-d`/`--detach`), hot-reload модулей и общей шины состояния. Клиент запускает его лениво, когда он нужен. Задачи находятся под присмотром супервизора: watchdog отслеживает heartbeat-события, но **не завершает задачу, пока у неё есть живые дочерние процессы**. Сокет демона — `$XDG_RUNTIME_DIR/grime.sock` с правами `0600`.
- Шаги конвейера передают друг другу рабочий каталог (`target_dir`), результат (`pipeline_input`/payload) и данные через `StateBus`.

### Жизненный цикл шага
1. Ядро разбирает аргументы и находит модули по реестру (точное имя, алиас, затем нечёткое совпадение; порог схожести 0.75).
2. До запуска проверяются зависимости `requires:` (отсутствующие обязательные модули, циклы, `bin:` в `$PATH`) — все проблемы сообщаются разом.
3. Для шага создаётся контекст `grime.ctx`, загружается чанк модуля (из кэша байткода, если он актуален).
4. Вызывается `main()` (глобальная функция либо поле возвращаемой таблицы).
5. Результат берётся из `ctx.success`/`ctx.module_return` или `ctx.fail`.
6. Зарегистрированный `cleanup()` вызывается гарантированно: при успехе, ошибке и отмене (Ctrl+C).

### Сквозные принципы интерфейса
- Все флаги, действия и категории начинаются с `-`/`--`; токен без дефиса — позиционный аргумент (имя проекта, путь, текст).
- Разделитель `//` (или `--`) передаёт остаток команды внешней программе без перехвата ядром.
- В конвейерах разделитель — `:`. В оболочке Fish `->` означает перенаправление в файл, поэтому не используйте его.
- Глобальные флаги ядра (перед первым модулем): `-f`/`--force`, `-d`/`--detach`, `-p`/`--path <путь>`, `-h`/`--help`, `-v`/`--version`.

---

## 2. Аннотации модуля `--@grime`

Аннотации — строки-комментарии в **шапке** `.lua`-файла. Реестр читает их без исполнения Lua: разбор идёт построчно от начала файла и останавливается на первой строке, которая не является пустой, `#!`-строкой или комментарием (блочные комментарии `--[[ ... ]]` пропускаются). Формат:

```lua
--@grime <ключ>: <значение>
```

| Ключ | Значение | Назначение |
| :--- | :--- | :--- |
| `description` | текст | Краткое описание (для `grime --help` и `grime list`). Берётся первое |
| `alias` | список через запятую | Дополнительные имена модуля (без учёта регистра) |
| `requires` | список зависимостей | Зависимости модуля (аннотация повторяема, значения объединяются) |
| `boundary` | `true`/`false` | Модуль-рубеж: шаг, который завершает подконвейер другой среды (пример — `host`) |
| `wraps` | `pipeline` | Модуль переключает среду и экспортирует хук `wrap_pipeline` |
| `chain` | `passthrough` | `:` перед неизвестным модулем остаётся аргументом шага, а не разделителем (пример — `app` для цепочек приложений) |
| `default` | `true`/`false` | Модуль по умолчанию для старой формы `grime --args ...` |
| `path.<имя>` | путь | Именованный путь по умолчанию (`path.projects`, `path.apps`, ...) |

Логические значения: `true`, `yes`, `1`, `on` (без учёта регистра).

### `requires:`
Элементы через запятую, вида `[вид:]имя[?]`:

- `module:<имя>` (или просто `<имя>`) — другой Lua-модуль GRIME. Ядро строит транзитивный топологический порядок, находит циклы и отсутствующие модули.
- `bin:<имя>` — исполняемый файл в `$PATH` (проверка без порождения процессов).
- `nix:<имя>` — Nix-пакет; ядро лишь записывает и отдаёт зависимость Lua, материализует пакет модуль `nix`. Если у модуля есть `nix:`-зависимость, отсутствие его `bin:` — лишь предупреждение (бинарь может появиться после входа в окружение Nix).
- Суффикс `?` — необязательная зависимость: её отсутствие — только предупреждение.

```lua
--@grime requires: module:git, bin:gcc, nix:gcc, module:ai?
```

### `path.<имя>`
Объявляет именованный путь по умолчанию. Значение раскрывается (`~`, `$VAR`) и нормализуется. Получить его в модуле: `ctx.get_path("projects", fallback)` или `grime.paths.projects`. Одноимённый ключ в `gproj.conf` переопределяет аннотацию (значение `auto` считается «не задано»). Если несколько модулей объявляют одно имя, побеждает первый по имени модуля.

### `boundary` и `wraps: pipeline`
Модули среды (`box`, `nix`) объявляют `wraps: pipeline` и экспортируют хук:

```lua
function M.wrap_pipeline(args, rest_argv)
    -- args       — аргументы шага модуля среды
    -- rest_argv  — все последующие шаги конвейера (до рубежа или конца)
    return { args = { "-run", "fedora-box", "--", table.unpack(rest_argv) } } -- выполнить этот же модуль с новыми args
    -- return { skip = true }  -- уже в нужной среде: шаг пропускается
    -- return nil              -- шаг не переключает среду (обычное выполнение)
end
```

Если хук вернул `{ args = ... }`, модуль выполняется с этими аргументами, а подконвейер `rest_argv` поглощается. Помощник `utils.wrap_pipeline_run(rest_argv, target_args)` из `languages/utils.lua` собирает типовой вызов `-run <цель> -- <подконвейер>`. Модуль с `boundary: true` (`host`) обозначает точку, где поглощение подконвейера прекращается и выполнение возвращается на хост.

Пример: `grime project -path X : box fedora-box : project -build : host : project -run` — `project -build` выполнится внутри контейнера, `project -run` — на хосте.

### Реестр, индекс и hot-reload
- Реестр собирается из каталогов модулей (порядок поиска — раздел 12). Модуль с тем же именем в более приоритетном каталоге перекрывает остальные.
- Имя модуля — имя файла без `.lua`; подкаталоги (`agents/`, `languages/`) — библиотеки, подключаемые через `require("agents.registry")`, и модулями не считаются.
- Для стандартных каталогов реестр хранит дисковый индекс аннотаций `~/.cache/grime/modules.idx` (валидируется по версии GRIME, `$HOME`, списку каталогов, их mtime и отпечаткам файлов).
- Демон отслеживает каталоги модулей (hot-reload): изменения подхватываются без перезапуска.

---

## 3. Как написать собственный модуль

1. Создайте `<каталог модулей>/mytool.lua` (например, `~/.config/grime/modules/mytool.lua` или любой каталог из `GRIME_MODULES`).
2. Начните файл с аннотаций, затем напишите код. Модуль должен вернуть таблицу с `main` (и, при необходимости, `cleanup`, `wrap_pipeline`).
3. Проверьте: `grime list -modules` и `grime mytool --help`. При разработке из репозитория: `GRIME_MODULES=$PWD/modules grime mytool`.

Эталонный пример:

```lua
--@grime description: Пример пользовательского модуля
--@grime alias: mt
--@grime requires: bin:git, module:log?

local ctx = grime.ctx

local function print_help()
    print([[
Grime MyTool — пример модуля

ИСПОЛЬЗОВАНИЕ:
    grime mytool [-list] [-run] [-name <имя>] [директория]

ФЛАГИ:
    -l, --list         Показать содержимое каталога
    -r, --run          Выполнить задачу
    -n, --name <имя>   Имя задачи
    -h, --help         Справка
]])
end

local M = {}
local scratch -- эфемерный каталог (удаляется ядром автоматически)

function M.main()
    local parsed = ctx.parse_args({
        actions = {
            ["-list"] = "list", ["--list"] = "list", ["-l"] = "list",
            ["-run"] = "run", ["--run"] = "run", ["-r"] = "run",
            ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
        },
        default_action = "list",
        value_flags = { name = { "-n", "--name", "-name" } },
        detect_dir = true,
    })

    if parsed.action == "help" then
        print_help()
        return
    end

    local target = parsed.target_dir or ctx.target_dir

    if parsed.action == "list" then
        local rows = {}
        for _, f in ipairs(grime.fs.list(target)) do
            rows[#rows + 1] = { f, grime.fs.is_dir(grime.fs.join(target, f)) and "каталог" or "файл" }
        end
        grime.ui.print_table(rows, { "Элемент", "Тип" })
        if ctx.has_next_step then ctx.module_return(target) end -- передать путь следующему шагу
    elseif parsed.action == "run" then
        local name = parsed.flags.name or "безымянная"
        scratch = grime.ephemeral.dir("mytool")
        local res = ctx.capture({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, target)
        if res.code ~= 0 then
            ctx.fail("Не git-репозиторий: " .. target)
            return
        end
        grime.bus.set("mytool.last_task", name)
        ctx.success("Задача '" .. name .. "' выполнена")
    end
end

-- Необязательно: вызывается ядром при успехе, ошибке и отмене
function M.cleanup()
    -- освободить внешние ресурсы; эфемерные каталоги ядро удаляет само
end

return M
```

Правила хорошего тона:
- **Не вызывайте `os.exit` и `io.popen`.** Завершайте шаг через `ctx.success`/`ctx.fail`, процессы запускайте через `ctx.capture`/`ctx.run_process`/`grime.process.*`.
- Временные файлы создавайте через `grime.ephemeral`, а не в `/tmp`.
- Парсите аргументы через `ctx.parse_args` (нативный движок ядра) — все флаги со знаком `-`.
- Ошибку выводите один раз через `ctx.fail`; не дублируйте её в `stderr`.
- Хуки: `main` обязателен; `cleanup` — по необходимости; `wrap_pipeline` — только для модулей с `wraps: pipeline`. Модули старого стиля, объявлявшие `main`/`cleanup` глобально, также поддерживаются.

---

## 4. Контекст шага: `grime.ctx`

`grime.ctx` (он же глобальная `ctx`) создаётся заново для каждого шага.

### Поля

| Поле | Тип | Описание |
| :--- | :--- | :--- |
| `ctx.args` | `string[]` | Аргументы шага без глобальных флагов ядра |
| `ctx.target_dir` | `string` | Рабочий каталог шага |
| `ctx.pipeline_input` / `ctx.input` | `string\|nil` | Результат предыдущего шага (`nil` у первого) |
| `ctx.payload` | `userdata\|nil` | Двоичный результат предыдущего шага (`PipelinePayload`) |
| `ctx.step_index`, `ctx.total_steps` | `integer` | Номер шага и их общее число |
| `ctx.has_next_step`, `ctx.is_last_step` | `boolean` | Есть ли следующий шаг / последний ли это шаг |
| `ctx.force` | `boolean` | Глобальный флаг `-f` |
| `ctx.flags` | `table` | Флаги шага (в т. ч. `force`) |
| `ctx.env` | `table` | Переменные окружения для запускаемых процессов (применяются, если `env` не передан явно) |
| `ctx.paths` | `table` | Именованные пути (конфиг и аннотации `path.*`) |

### Управление шагом
- `ctx.parse_args(spec, [raw_args])` — обёртка над `grime.args.parse` (раздел 10); без `raw_args` разбирает `ctx.args`.
- `ctx.set_target_dir(dir)` — задать рабочий каталог для текущего и следующих шагов.
- `ctx.module_return(data)` / `ctx.success([data])` — успешно завершить шаг; `data` (строка) попадёт в `pipeline_input` следующего шага, а у последнего шага будет выведено в `stdout`.
- `ctx.fail(msg)` — завершить шаг ошибкой и остановить конвейер; сообщение выводится один раз как `[Grime Error] <msg>`.
- `ctx.done(ok, val_or_err)` — компактный вариант: `success(val)` либо `fail(err)`.
- `ctx.get_payload()` / `ctx.set_payload(val)` — работа с двоичным результатом шага.
- `ctx.log(msg)`, `ctx.warn(msg)`, `ctx.error(msg)` — служебные сообщения с префиксами `[Grime]`, `[Grime Warning]`, `[Grime Error]` (пишутся в `stderr`, чтобы не засорять данные конвейера).

### Процессы
`cmd` — таблица argv (`{ "cargo", "build" }`). Относительный `cwd` разрешается от `target_dir`, а если он не указан — используется `target_dir`; `env` по умолчанию берётся из `ctx.env`.
- `ctx.run_process(cmd, [cwd], [env]) -> code` (алиас `ctx.run_interactive`) — запуск с пробросом терминала (интерактивные программы, TUI).
- `ctx.run_shell(cmd, [cwd], [env]) -> code` — пакетный запуск с пробросом вывода.
- `ctx.capture(cmd, [cwd], [env], [stdin]) -> { code, stdout, stderr }` — запуск с перехватом потоков.

### Файловые операции
Те же операции, что и `grime.fs` (раздел 5), но **относительные пути разрешаются от `ctx.target_dir`**: `ctx.exists`, `ctx.is_dir`, `ctx.is_file`, `ctx.mkdir_p`, `ctx.delete` (алиас `remove`), `ctx.copy`, `ctx.move` (алиас `rename`), `ctx.read`, `ctx.write`, `ctx.mtime`, `ctx.is_newer` (алиас `needs_rebuild`). Не зависят от `target_dir`: `ctx.normalize_path`/`ctx.normalize`, `ctx.join`/`ctx.path_join`.

### Конфигурация и пути
- `ctx.get_path(name, [fallback])` — именованный путь: ключ конфига, затем аннотация `path.<name>`, иначе `fallback`.
- `ctx.get_config(key, [default])` — значение ключа `gproj.conf`.
- `ctx.config_dir()` — каталог конфигурации GRIME.
- `ctx.json` — псевдоним `grime.json`; `ctx.to_snake_case` — псевдоним `grime.str.to_snake_case`.

```lua
local code = ctx.run_process({ "cargo", "build", "--release" }, ctx.target_dir)
if code ~= 0 then
    ctx.fail("Сборка завершилась с ошибкой (код " .. code .. ")")
    return
end
```

---

## 5. Файловые операции: `grime.fs`

Пути проходят раскрытие `~`; относительные пути трактуются от текущего каталога процесса (в отличие от `ctx.*`, которые разрешают их от `target_dir`).

| Функция | Описание |
| :--- | :--- |
| `exists(p)`, `is_dir(p)`, `is_file(p)` | Проверки типа пути |
| `mkdir_p(p) -> true` | Создать каталог рекурсивно |
| `delete(p, [missing_ok])` (алиас `remove`) | Рекурсивное удаление; `missing_ok = false` — ошибка, если пути нет |
| `copy(src, dst) -> dst` | Рекурсивное копирование с сохранением симлинков |
| `move(src, dst) -> dst` (алиас `rename`) | Перемещение |
| `read(p) -> string\|nil` | Прочитать файл целиком |
| `write(p, content) -> true` | Записать файл |
| `mtime(p) -> number` | Самое позднее время модификации (для каталога — по содержимому) |
| `is_newer(src, target)` (алиас `needs_rebuild`) | `true`, если исходники новее цели |
| `list(dir) -> string[]` | Имена элементов каталога |
| `normalize(p)` | Раскрыть `~` и нормализовать `.`/`..` |
| `join(...)` (алиас `path_join`) | Склеить и нормализовать путь |

**Защита:** `delete`, `copy`, `move` и `write` отказываются работать с системными путями (`/`, `/etc`, `/usr`, `/var`, `/boot`, `/opt`, `/root`, `/nix` и т. п.); ошибка поднимается как исключение Lua.

---

## 6. Процессы: `grime.process`

| Функция | Описание |
| :--- | :--- |
| `run(cmd, [cwd], [env]) -> code` | Пакетный запуск с пробросом вывода |
| `run_interactive(cmd, [cwd], [env]) -> code` | Запуск с пробросом терминала |
| `capture(cmd, [cwd], [env], [stdin]) -> { code, stdout, stderr }` | Запуск с перехватом потоков |
| `which(name) -> path\|nil` | Поиск в `$PATH` без порождения процессов |
| `exe_path() -> string` | Путь к текущему бинарю `grime` (для самозапуска) |
| `daemon_socket() -> string` | Путь Unix-сокета демона (единый источник правды с ядром) |
| `memory_rss_kb() -> integer` | Резидентная память процесса, КБ |

Все запуски отменяемы: при Ctrl+C дочерние процессы шага завершаются. Дополнительно есть `grime.daemon_ping() -> boolean` — проверка отклика демона.

---

## 7. Шина состояния и события: `grime.bus`, `grime.events`

### `grime.bus`
Разделяемое потокобезопасное хранилище ключ-значение (значения — Lua-совместимый JSON: числа, строки, булевы, таблицы). Хранится на диске в `~/.config/grime/state.json` (путь переопределяется `GRIME_STATE_FILE`). Ключ обязан содержать пространство имён через точку (`modules.ai.agent`, `build.ready`); ключ без точки отклоняется. Ключи в пространствах `pipeline.*`, `system.*`, `env.*` на диск не сохраняются (`system.*` и `env.*` заполняются ядром при старте).

| Функция | Описание |
| :--- | :--- |
| `get(key) -> any` | Значение или `nil` |
| `set(key, value) -> true` | Записать значение |
| `set_many({ key = value, ... }) -> true` | Записать несколько значений |
| `has(key) -> boolean` | Есть ли ключ |
| `delete(key) -> boolean` | Удалить ключ |
| `clear_namespace(prefix)` | Удалить все ключи с префиксом |
| `keys([prefix]) -> string[]` | Список ключей (с необязательным фильтром) |

`grime.bus.state` — псевдоним самой таблицы.

### `grime.events`
- `grime.events.on(name, callback)` — подписаться на событие в текущей Lua-машине.
- `grime.events.emit(name, [payload])` — опубликовать событие: оно уходит в общий `EventBus` (его слушает супервизор демона) и диспетчеризируется локальным слушателям.

---

## 8. Реестр модулей: `grime.modules`

- `grime.modules.list() -> table[]` — все модули.
- `grime.modules.get(name) -> table|nil` — модуль по имени или алиасу.
- `grime.modules.resolve(name) -> string|nil` — каноническое имя (точное, алиас или нечёткое совпадение).
- `grime.modules.deps(name) -> order, err` — транзитивный порядок зависимостей `module:`; при ошибке — `nil, "сообщение"`.

Элемент модуля: `name`, `description`, `aliases`, `boundary`, `wraps`, `chain`, `path` (файл), `paths` (объявленные `path.*`), `requires` (массив `{ kind, name, optional }`).

---

## 9. Эфемерные ресурсы: `grime.ephemeral`

Временные ресурсы, исчезающие вместе с сессией; вместо `/tmp` и `os.tmpname`.

- `grime.ephemeral.dir([prefix]) -> path` — новый каталог (права 0700).
- `grime.ephemeral.file([content], [suffix]) -> path` — новый файл (права 0600, запись атомарна), например `grime.ephemeral.file(script, ".sh")`.

Корень — `$XDG_RUNTIME_DIR/grime/eph/<pid>-<session>` (0700, без `XDG_RUNTIME_DIR` — `<кэш grime>/run/<uid>/eph`). Подкаталог сессии создаётся лениво при первом обращении; процесс держит `flock` на `.lock`. Освобождать вручную не нужно: ядро удаляет всё при успехе, ошибке, отмене и панике конвейера, а также при уничтожении сессии (в т. ч. detached-задач). Осиротевшие каталоги (процесс убит, питание потеряно) подметаются при старте `grime` и периодически в демоне: удаляются только каталоги текущего uid, не симлинки, старше 5 секунд, с незанятым `flock`; удаление не следует по симлинкам и не выходит за корень.

---

## 10. Парсер аргументов: `grime.args`

Нативный движок (`src/args_engine.rs`): единый стандарт флагов (`-`/`--`), разделители `//` и `--`, нечёткое сопоставление флагов (Jaro-Winkler), автоопределение каталога.

### `grime.args.parse(spec, [raw_args], [default_target_dir]) -> parsed`
(в модулях — `ctx.parse_args(spec, [raw_args])`)

```lua
local spec = {
    -- Действия и синонимы (строго со знаком минус)
    actions = {
        ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["-l"] = "list",
        ["-run"]  = "run",  ["--run"]  = "run",  ["-r"]  = "run",
    },
    default_action = "list",          -- действие, если ни одно не распознано
    flags = {                         -- булевы флаги
        force = { "-f", "--force", "-force" },
        help  = { "-h", "--help", "-help" },
    },
    value_flags = {                   -- флаги со значением: --lang=rust, --lang rust, -l rust
        lang = { "-l", "--lang", "-lang" },
    },
    categories = {                    -- взаимоисключающие категории
        language = { ["-cpp"] = "cpp", ["-rust"] = "rust", ["-rs"] = "rust" },
    },
    detect_dir = true,                -- искать существующий каталог среди аргументов
    fuzzy_threshold = 0.75,           -- порог нечёткого сопоставления флагов
    allow_unknown_flags = false,      -- неизвестные флаги: в unknown_flags (false) или в args (true)
    passthrough_actions = { "run" },  -- после этих действий остаток передаётся как есть
}
```

Результат:

| Поле | Описание |
| :--- | :--- |
| `parsed.action` | Каноническое имя действия (или `nil`) |
| `parsed.flags` | Таблица флагов и значений `value_flags` |
| `parsed.categories` | Выбранные категории (`{ language = "rust" }`) |
| `parsed.args` | Позиционные аргументы |
| `parsed.target_dir` (`parsed.dir`) | Найденный каталог (при `detect_dir`) |
| `parsed.command_tokens` | Токены после разделителя `//` или `--` |
| `parsed.unknown_flags` | Неизвестные флаги |
| `parsed.has_separator` (`has_passthrough_separator`) | Был ли разделитель |

**Строгий дефисный стандарт.** Действия, категории и флаги распознаются **только** у токенов, начинающихся с `-`/`--`. Остальное — позиционные аргументы, поэтому проекты с именами `test`, `build`, `run`, `list` никогда не принимаются за команды. Флаг `-path`/`-p`, если основное действие не указано, становится действием `path`; при указанном действии (`-build -path`) действие сохраняется, а `flags.path = true`.

### Прочие функции
- `grime.args.split_passthrough([raw_args]) -> before, command_tokens, has_separator` (алиас `split`) — делит токены по первому `//`/`--`.
- `grime.args.strip_dashes(token)` — срезать ведущие дефисы и привести к нижнему регистру.
- `grime.args.is_flag(token)`, `grime.args.is_separator(token)`.
- `grime.args.new(spec)` — объект с методом `:parse(args, default_dir)`.

---

## 11. Прочие библиотеки

### `grime.json`, `grime.msgpack`
- `grime.json.encode(value) -> string`, `grime.json.decode(string) -> value`.
- `grime.msgpack.encode(value) -> payload`, `grime.msgpack.decode(string|payload) -> value`.

### `grime.str`
`trim`, `split(s, sep)`, `starts_with`, `ends_with`, `to_snake_case`, `to_kebab_case`, `pad_left(s, width, [ch])`, `pad_right(s, width, [ch])`.

### `grime.table`
`keys(t)`, `values(t)`, `contains(t, value)`, `merge(a, b)`, `filter(t, fn)`, `map(t, fn)`, `slice(t, from, [to])`.

### `grime.fuzzy`
- `similarity(a, b) -> number` — схожесть Jaro-Winkler, 0.0–1.0.
- `damerau_levenshtein(a, b) -> integer` — расстояние редактирования.
- `match_best(query, candidates) -> string|nil` — лучший кандидат.
- `find_best_match(query, candidates, [threshold]) -> match, score` (алиас `fuzzy_match`).
- `match_flag(token, candidates, [threshold]) -> string|nil` (алиас `fuzzy_match_flag`).
- `normalize_flags(args, known_flags, [threshold]) -> table`.

### `grime.ui`
- `log(msg)` / `info(msg)` — сообщение `[Grime]`.
- `warn(msg)`, `success(msg)`.
- `error(msg)` — регистрирует ошибку шага и печатает её в формате `[Grime Error]`.
- `print_table(rows, [headers])` — таблица с выравниванием колонок.
- `format_columns(items, [max_width]) -> lines` — раскладка списка по колонкам.

### `grime.time`
`now_ns()`, `now_ms()` — текущее время (наносекунды / миллисекунды с эпохи).

### `grime.config`, `grime.paths`
- `grime.config.get(key, [default])`, `grime.config.config_dir()`, `grime.config.get_all()` — значения конфигурации и все именованные пути.
- `grime.paths.<имя>` — таблица именованных путей (конфиг поверх аннотаций `path.*`).

---

## 12. Конфигурация и переменные окружения

### `gproj.conf`
Формат `ключ=значение`; строки с `#` и `;` — комментарии; кавычки вокруг значения снимаются. Шаблон — [config/gproj.conf.example](config/gproj.conf.example).

**Порядок поиска файла** (первый существующий):
1. `$GRIME_CONFIG`;
2. `$PROJECT_CONFIG_PATH` (устаревший);
3. `$XDG_CONFIG_HOME/grime/gproj.conf` (иначе `~/.config/grime/gproj.conf`);
4. `<каталог бинаря>/../share/grime/gproj.conf`.

Если файла нет, а рядом лежит `gproj.conf.example`, читается он.

**Порядок поиска модулей:**
1. `$GRIME_MODULES`;
2. ключ `modules=` из конфига;
3. `<каталог конфигурации>/modules`;
4. `<каталог бинаря>/../share/grime/modules`;
5. `<каталог бинаря>/modules`.

Поиск относительно текущего каталога **отсутствует** — по соображениям безопасности.

**Ключи.** Фиксированные умолчания в ядре только у `config` и `modules`; всё остальное — ключи, которые читают модули, и именованные пути из аннотаций:

| Ключ | Кто использует | Описание |
| :--- | :--- | :--- |
| `config` | ядро | Каталог конфигурации (по умолчанию — каталог файла конфигурации) |
| `modules` | ядро | Каталог модулей |
| `projects` | `project` | Корень проектов (`path.projects`, по умолчанию `~/Projects`) |
| `templates` | `project` | Шаблоны проектов (`path.templates`, по умолчанию `~/.config/grime/templates`) |
| `apps` | `app` | Корень приложений (`path.apps`, по умолчанию `~/.config/grime/apps`) |
| `distrobox_default` | `box` | Контейнер по умолчанию |
| `box_idle_timeout` | `box` | Секунды простоя до автоостановки контейнера (по умолчанию 300) |
| `nix_allow_unfree` | `nix`, `pkg`, `app` | Unfree-пакеты Nix разрешены по умолчанию (`allowUnfree` в генерируемых flake, `--impure` + `NIXPKGS_ALLOW_UNFREE=1` для `nixpkgs#…`); отключить: `false`/`0`/`no`/`off`. Установка в профиль — `nix profile add` |
| `ai_agent` | `ai`, `doctor` | `claude`, `aider` или `auto` |
| `doctor_agent` | `doctor` | Агент для `doctor -fix` |
| `claude`, `aider` | адаптеры агентов | Путь к бинарю агента или `auto` |

Значения, не похожие на путь (`fedora-box`, `300`, `auto`, `claude`), **не нормализуются**; значения-пути (начинаются с `/`, `~`, `$`, `./`, `../` или содержат `/`) раскрываются и нормализуются, относительные — от каталога файла конфигурации. `auto` равносильно «не задано».

### Переменные окружения

| Переменная | Назначение |
| :--- | :--- |
| `GRIME_CONFIG`, `PROJECT_CONFIG_PATH` | Путь к `gproj.conf` |
| `GRIME_MODULES` | Каталог модулей |
| `GRIME_STATE_FILE` | Файл шины состояния |
| `XDG_CONFIG_HOME` | Базовый каталог конфигурации |
| `XDG_CACHE_HOME` | Базовый каталог кэша (`<...>/grime`) |
| `XDG_RUNTIME_DIR` | Сокет демона и эфемерные ресурсы |
| `TERMINAL` | Терминал для `doctor -fix` (по умолчанию `ghostty`) |
| `GRIME_BIN` | Путь к `grime` для самозапуска модуля `ai` (по умолчанию — текущий бинарь) |

---

## 13. Кэши и эфемерность

| Что | Где | Очистка |
| :--- | :--- | :--- |
| Индекс модулей | `~/.cache/grime/modules.idx` | Пересборка при изменении модулей, версии, `$HOME` |
| Байткод Lua | `~/.cache/grime/bc/<хэш>.luac` | Пересборка при изменении исходника или версии сборки |
| Эфемерные flake | `~/.cache/grime/flakes/<kind>/<hash>` | Старше 30 суток (раз в сутки) и `grime nix -gc` |
| Эфемерные ресурсы сессии | `$XDG_RUNTIME_DIR/grime/eph/<pid>-<session>` | Конец сессии; подметание осиротевших |

Корень кэша — `$XDG_CACHE_HOME/grime` (если путь абсолютный), иначе `~/.cache/grime`. Каталог создаётся с правами 0700, файлы — 0600 с атомарной записью (временный файл + `rename`). При чтении проверяются тип файла (обычный, без симлинков), владелец и права; любое несоответствие означает «кэша нет» и тихий пересбор.

---

## 14. Встроенные модули

Актуальная справка — `grime <модуль> --help`. Ниже — краткий обзор (14 модулей).

| Модуль | Алиасы | Назначение |
| :--- | :--- | :--- |
| `project` | `proj` | Проекты на C++, Rust, Python, Java, Lua, Bash, Fish. Модуль по умолчанию |
| `app` | — | Локальные микроприложения (`chain: passthrough`) |
| `pkg` | — | Единый менеджер пакетов |
| `ai` | — | ИИ-оркестратор агентов |
| `nix` | — | Nix Flakes, профили (`wraps: pipeline`) |
| `box` | — | Distrobox (`wraps: pipeline`) |
| `host` | `exit-env`, `unhost`, `host-env` | Рубеж возврата на хост (`boundary: true`) |
| `git` | — | Операции Git |
| `list` | `ls`, `modules` | Реестр модулей, приложений и проектов |
| `log` | — | Централизованный журнал |
| `bus` | — | CLI к шине состояния и событий |
| `daemon` | — | Управление демоном и терминальным контекстом |
| `doctor` | — | Диагностика и ИИ-ремонт |
| `cmd` | `exec` | Внешние команды в каталоге шага |

### `project`
Языки: `cpp` (`-cpp`), `rust` (`-rust`, `-rs`), `python` (`-python`, `-py`), `java`, `lua`, `bash` (`-bash`, `-sh`), `fish`.

```bash
grime project init cpp MyGame       # или: grime project rust Tool -init
grime project -list [язык] [фильтр]
grime project -build MyGame
grime project -run MyGame [-- аргументы]
grime project -path MyGame
grime project --rename Old New
grime project -rm MyGame --yes      # только точное имя; подтверждение или --yes
grime project --clear MyGame --yes  # сброс к чистому шаблону
```
Флаги: `--nix` (сборка/запуск в изолированном Nix Flake), `-f` (перезаписать непустой каталог при инициализации), `-y`/`--yes`.

### `app`
```bash
grime app -list | -ps
grime app -new <имя> [-lang <язык>] [описание…]
grime app -run <имя> [аргументы]      # -d / -detach — в фоне (лог app.log)
grime app -stop <имя> [-9]
grime app -build <имя>
grime app -flake <имя>                # синхронизация flake.nix
grime app -compile <цель|путь|проект> [имя_команды]   # в apps + симлинк в ~/.local/bin
grime app -bundle <имя>               # автономный бинарь в dist/
grime app -path [имя]
grime app -commit|-log|-diff|-snapshot|-status|-rollback <имя> …   # -rollback требует подтверждения (-y)
grime app -rm <имя> [-y]            # подтверждение; без TTY нужен --yes
```
Состояние фоновых приложений хранится в шине (`grime app -ps` показывает PID, память, uptime). Манифест `app.lua` читается в песочнице; допускаются «нулевые» приложения (по shebang или адаптеру языка).

### `pkg`
```bash
grime pkg                          # сводка по активным менеджерам
grime pkg <менеджер> [-l] [-a] [фильтр]
grime pkg <пакет>                  # сквозной нечёткий поиск
grime pkg -i|--install <менеджер> <пакет>
grime pkg -rm|--remove <менеджер> <пакет>
grime pkg -u|--update [менеджер] [пакет]
grime pkg -r|--run <утилита> [args…]   # каскад: локально -> Distrobox -> эфемерный Nix
grime pkg -not-found <команда> [args]  # обработчик command-not-found для оболочки
```
Менеджеры: `host` (`pacman`), `yay`, `flatpak`, `nix`, `distrobox`, `apps`, `cargo`, `pipx`. Установка требует явного указания менеджера. Подробности каскада запуска — `grime pkg run --help`.

### `nix`
`-build`, `-init` (`--flake`; постоянный `flake.nix` с автоопределением тулчейна), `-enter`, `-run`/`--exec` (команда в devShell), `-history`, `-rollback [--to N]`, `-update`, `-bundle`, `-diff`, `-install`, `-uninstall`, `-gc` (с очисткой кэша эфемерных flake), `-optimise`, `-check`. Флаги: `--force`, `--pure`, `-o <путь>`.

### `box`
`-list`, `-enter`, `-run`/`--exec`, `-create [--image …]`, `-stop`, `-rm`, `-export [имя] --app <приложение> | --bin <путь>`. Контейнер по умолчанию — ключ `distrobox_default`; простаивающий контейнер останавливается по `box_idle_timeout`.

### `host`
Рубеж возврата на хост: `grime <шаг_в_контейнере> : host : <шаг_на_хосте>`. Передаёт дальше путь или текущий `target_dir`.

### `git`
`-status`, `-commit [msg]` (в т. ч. из конвейера), `-log [N]`, `-diff [файл]`, `-branch`, `-checkout`, `-ls-files`, `-snapshot [msg]`, `-add`, `-init`.

### `list`
`grime list [-modules | -apps | -projects] [фильтр]`; без аргументов — сводка.

### `log`
`-list [n]`, `-errors [n]`, `-git [n|каталог]`, `-clear`, `-add <уровень> <msg>`, `-n <N>`. Принимает данные из конвейера (`grime doctor : log`).

### `bus`
`-get`, `-set`, `-has`, `-rm`, `-list [префикс]`, `-emit <событие> [json]`.

### `daemon`
`-status`, `-ping`, `-start`, `-stop`, `-restart`, `-feed <cmd> [code] [cwd] [out]` (записать событие терминала в шину), `-dump`, `-clear`.

### `doctor`
`grime doctor` — проверка утилит (git, nix, distrobox, cargo, claude, aider), путей, журнала и недавних сбоев.

`grime doctor -fix [-dry|-n] [-yes|-y] [описание]` — ИИ-ремонт:
1. Сбор контекста (отчёт doctor, ошибки журнала, последняя упавшая команда, `journalctl`, упавшие юниты, состояние `pacman`) с маскированием секретов.
2. Сводка и подтверждение отправки агенту (`doctor_agent` → `ai_agent` → `claude`); `-yes` пропускает **только** это подтверждение.
3. Агент возвращает диагноз и скрипт в теге `<grime_fix>`. Скрипт показывается целиком вместе с SHA-256, списком строк с повышением привилегий и рисками.
4. Запуск **только после интерактивного «y»**, в окне терминала из `$TERMINAL` (по умолчанию `ghostty`; без дисплея — текущий TTY). Пароль запрашивает сама система у обычного `sudo`; GRIME его не видит и не хранит.
5. Скрипт хранится в эфемерном каталоге (0700) и удаляется по `trap` после закрытия окна.

`-dry` — ничего не отправлять и не запускать, только показать сводку.

### `cmd`
`grime cmd <программа> [аргументы]` — запуск в `target_dir` предыдущего шага. Аргумент, совпадающий с относительным файлом каталога, разрешается в путь. Поддерживает ввод из конвейера.

---

## 15. ИИ-подсистема: `ai` и адаптеры агентов

Модуль `ai` оркестрирует CLI-агентов **Claude Code** и **Aider**. Адаптеры лежат в `modules/agents/` (по аналогии с `modules/languages/`):

- `agents/base.lua` (`BaseAgent`) — контракт адаптера (`resolve_binary`, `is_available`, `build_architect_cmd`, `build_headless_cmd`, `build_interactive_cmd`, `clean_output`, `run_headless`, `run_interactive`).
- `agents/claude.lua` — Claude Code (`claude`, алиасы `claude-code`, `cc`; ключ конфига `claude`). Запускается без `--bare`, чтобы сохранялась OAuth-авторизация.
- `agents/aider.lua` — Aider (ключ конфига `aider`). Всегда добавляет `--no-suggest-shell-commands`, если не задано `--suggest-shell-commands` явно: `--yes-always` не должен исполнять shell в обход GRIME.
- `agents/registry.lua` — выбор агента по приоритету: флаг (`-claude`, `-aider`, `-agent <имя>`) → шина `modules.ai.agent` → ключ `ai_agent` → первый доступный (`claude`, затем `aider`).

Режимы: интерактивный, headless (`-m`), создание приложения (`-app <имя> [-lang …]`), создание/доработка модуля GRIME (`-module <имя>`), конвейерный (`<шаг> : ai …`). Ответ агента может содержать служебные теги, которые модуль обрабатывает с проверками безопасности (раздел 16): `<grime_bus>`, `<grime_spawn>`, `<grime_exec>`, `<next_agent_prompt>`.

```ini
# gproj.conf
ai_agent=auto
claude=auto
aider=auto
doctor_agent=claude
```

---

## 16. Безопасность

- **Системные пути.** `grime.fs`/`ctx` `delete`, `copy`, `move`, `write` отказываются работать с системными каталогами.
- **Проекты.** `project -rm` и `--clear` — только по точному имени в каталоге проектов, с подтверждением; без TTY нужен `--yes`.
- **Подтверждения.** Необратимые операции (`app -rm`, `app -rollback`, `box -rm`, `nix -gc`, `log -clear`, `bus rm`, `project -rm/--clear`) спрашивают `[y/N]` через общую `utils.confirm_destructive`; в конвейерах и скриптах (без TTY) обязателен `--yes` (`-y`).
- **ИИ.** Проверка команд перед исполнением выполняется по токенам с учётом кавычек. `<grime_spawn>` разрешён только для модулей `ai`, `cmd`, `app`, `project`, `nix`, `git`, `doctor`, `list`, `log`; разрушительные флаги (`rm`, `clear`, `rollback`, `gc`, `optimise`, `force`, `reset`, `clean`, `delete`, `purge`, `uninstall`, `remove`, `prune`) для порождённых модулей запрещены; глубина вложенности тегов ограничена. Модули `pkg`, `box`, `host`, `daemon`, `bus` ИИ напрямую порождать не может.
- **`doctor -fix`.** Секреты маскируются, скрипт показывается целиком с SHA-256, запускается только после интерактивного «y» в окне терминала; эфемерный каталог 0700, удаление по `trap`.
- **Сокет демона** — права `0600`; размер IPC-сообщений ограничен (32 МБ), чтение — с таймаутом.
- **Манифесты приложений** выполняются в песочнице (доступны `os.getenv`, `string`, `table`, `math` и базовые функции; недоступны `io`, `require`, `load*`, `debug`, `grime`), число инструкций ограничено.
- **Поиск конфигурации и модулей** не использует текущий каталог.
- **SIGPIPE.** Клиент завершается по штатному SIGPIPE (`grime list | head` не паникует); демон игнорирует SIGPIPE.

---

## 17. Разработка и тесты

```bash
cargo build --release
GRIME_MODULES=$PWD/modules target/release/grime list    # запуск из репозитория
cargo test                                              # тесты Rust
lua5.4 tests/lua/valid_name_test.lua                    # Lua-тесты (по файлу из tests/lua/)
```

Тесты изолированы: юнит-тесты ядра используют временный изолированный корень кэша и эфемерных ресурсов, шина состояния в тестовых бинарях живёт в памяти (если не задан `GRIME_STATE_FILE`). Для ручной изоляции:

```bash
GRIME_CONFIG=/tmp/g/gproj.conf GRIME_STATE_FILE=/tmp/g/state.json \
XDG_CACHE_HOME=/tmp/g/cache XDG_RUNTIME_DIR=/tmp/g/run grime doctor
```

`install.sh`: `-s/--symlink` (симлинки на модули и шаблоны вместо копий), `-b/--build` (принудительная сборка), `--bin-dir`, `--config-dir`, `--no-hook` (не настраивать `command_not_found`); в конце запускает `grime doctor`.

---

## 18. Ещё не реализовано

Это направления развития, а не готовые возможности:

- IPC-шина данных между программами на разных языках (типизированные потоки данных).
- Автоперехват `stderr` хуком оболочки (сейчас — ручная передача контекста через `grime daemon -feed`).
- Ленивая регистрация API (сейчас все таблицы `grime.*` создаются при инициализации Lua-состояния).
