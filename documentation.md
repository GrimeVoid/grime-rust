# Документация по API ядра GRIME (Grime-RS)

Данный документ содержит полное техническое описание нативного Lua API, предоставляемого ядром GRIME (`grime_pj`) для разработки декларативных модулей и расширений.

---

## 1. Архитектура и принципы работы

GRIME построен по принципу **чистого модульного микроядра**:
- **Ядро на Rust (`grime-rust`):** отвечает за разбор конвейера (`:`), управление фоновым демоном (`grimed`), пулом изолированных виртуальных машин LuaJIT, потоками ввода-вывода (PTY/stdin/stdout), шиной состояния (`StateBus`) и централизованным выводом ошибок (`[Grime Error]`). Ядро не содержит прикладной логики отдельных модулей.
- **Декларативные модули LuaJIT (`~/.config/grime/modules/*.lua`):** содержат всю прикладную бизнес-логику (управление проектами, контейнерами, пакетами, средами Nix, Git и AI). Модули взаимодействуют с операционной системой и ядром исключительно через глобальную таблицу `grime.*` и контекст `grime.ctx`.

### Жизненный цикл выполнения модуля
1. Ядро считывает конвейер шагов (например, `grime project -path App : git -status : bus -set ok 1`).
2. Для каждого шага инициализируется изолированное состояние и контекст `grime.ctx`.
3. Загружается соответствующий `.lua` файл модуля.
4. Вызывается точка входа модуля `main()`.
5. Модуль возвращает результат через `ctx.module_return(data)` или завершается с ошибкой через `ctx.fail(msg)`.
6. При завершении шага гарантированно вызываются зарегистрированные хуки очистки `cleanup()`.

---

## 2. Модуль контекста шага: `grime.ctx`

Объект `grime.ctx` предоставляет доступ к аргументам, рабочей директории, потокам данных конвейера и методам управления жизненным циклом шага.

### Поля объекта `grime.ctx`

| Поле | Тип | Описание |
| :--- | :--- | :--- |
| `ctx.args` | `table` | Массив аргументов текущего шага (`string[]`), очищенный от глобальных флагов ядра. |
| `ctx.target_dir` | `string` | Текущая рабочая директория шага конвейера. |
| `ctx.pipeline_input` | `string \| nil` | Данные, переданные предыдущим шагом через `ctx.module_return()` (или `nil`, если это первый шаг). |
| `ctx.has_next_step` | `boolean` | `true`, если за текущим шагом следует следующий шаг конвейера через `:`. |

### Методы управления жизненным циклом и передачи данных

#### `ctx.parse_args(spec, [raw_args]) -> table`
Удобная обёртка над нативным парсером аргументов ядра `grime.args.parse`. Если `raw_args` не передан, автоматически разбирает `ctx.args`. Подробное описание структуры `spec` приведено в разделе 3.

#### `ctx.set_target_dir(dir: string)`
Устанавливает рабочую директорию для текущего и последующих шагов конвейера.
```lua
ctx.set_target_dir("/home/user/Projects/my_app")
```

#### `ctx.module_return(data: string)`
Передаёт текстовые данные следующему шагу конвейера (попадают в `next_step.pipeline_input`). Если текущий шаг последний в конвейере, клиент GRIME выводит эти данные в стандартный вывод `stdout`.
```lua
ctx.module_return("/home/user/Projects/my_app")
```

#### `ctx.success([msg: string])`
Успешно завершает выполнение текущего шага модуля с кодом возврата `0`.
```lua
ctx.success("Операция успешно завершена")
```

#### `ctx.fail(msg: string)`
Завершает выполнение текущего шага с ошибкой и останавливает конвейер. Ядро перехватывает сообщение и выводит его ровно один раз в формате `[Grime Error] <msg>`.
```lua
if not ctx.exists(target_path) then
    ctx.fail("Файл или каталог не найден: " .. target_path)
end
```

#### `ctx.log(msg: string)`
Выводит информационное сервисное сообщение в `stdout` с префиксом `[Grime]`.
```lua
ctx.log("Компиляция проекта через Cargo...")
```

---

### Системные функции и запуск процессов в `grime.ctx`

#### `ctx.run_process(cmd: table, [cwd: string]) -> integer`
Выполняет процесс в пакетном режиме с пробросом вывода в терминал. Возвращает код выхода процесса (`0` при успехе).
```lua
local code = ctx.run_process({ "cargo", "build", "--release" }, ctx.target_dir)
if code ~= 0 then
    ctx.fail("Сборка завершилась с ошибкой (код " .. code .. ")")
end
```

#### `ctx.run_interactive(cmd: table, [cwd: string]) -> integer`
Запускает интерактивный процесс с подключением к псевдотерминалу (PTY), сохраняя поддержку курсорных клавиш, ncurses и интерактивного ввода пользователя.
```lua
local code = ctx.run_interactive({ "yay", "-S", "neovim" })
```

#### `ctx.capture(cmd: table, [cwd: string]) -> table`
Выполняет процесс скрытно и перехватывает его стандартные потоки вывода.
- **Возвращает:** таблицу `{ code = integer, stdout = string, stderr = string }`.
```lua
local res = ctx.capture({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, ctx.target_dir)
if res.code == 0 then
    local branch = res.stdout:gsub("%s+$", "")
    print("Текущая ветка: " .. branch)
end
```

#### Проверки путей и окружения
- `ctx.exists(path: string) -> boolean` — проверяет существование пути на диске.
- `ctx.is_dir(path: string) -> boolean` — проверяет, является ли путь каталогом.
- `ctx.is_file(path: string) -> boolean` — проверяет, является ли путь регулярным файлом.
- `ctx.normalize_path(path: string) -> string` — нормализует путь, разрешая относительные ссылки `.` и `..`.
- `ctx.mkdir_p(path: string)` — рекурсивно создаёт каталог (аналог `mkdir -p`).
- `ctx.delete(path: string)` — удаляет файл или каталог со всем содержимым (аналог `rm -rf`).
- `ctx.config_dir() -> string` — возвращает путь к каталогу конфигурации GRIME (`~/.config/grime`).
- `ctx.needs_rebuild(src_dir: string, target_bin: string) -> boolean` — сравнивает время последней модификации (`mtime`) исходников и бинарника. Возвращает `true`, если исходники новее и требуется пересборка.

---

## 3. Нативный парсер аргументов: `grime.args`

Единый движок парсинга, реализованный в ядре Rust (`src/args_engine.rs`). Обеспечивает единый стандарт флагов (`-` и `--`), разделителей проброса аргументов (`//` и `--`), нечёткого сопоставления (`fuzzy`) и автоматического определения каталогов.

### Методы `grime.args`

#### `grime.args.parse(spec: table, [raw_args: table], [default_target_dir: string]) -> table`
(Алиас в контексте: `ctx.parse_args(spec, [raw_args])`)

Разбирает массив токенов по декларативной спецификации `spec`.

##### Параметры спецификации `spec`:
```lua
local spec = {
    -- Таблица действий и их синонимов (СТРОГО со знаком минус: '-' или '--')
    actions = {
        ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["-l"] = "list",
        ["-init"] = "init", ["--init"] = "init", ["-new"] = "init", ["-i"] = "init",
        ["-build"] = "build", ["--build"] = "build", ["-b"] = "build",
        ["-run"] = "run", ["--run"] = "run", ["-r"] = "run",
        ["-path"] = "path", ["--path"] = "path", ["-p"] = "path",
    },
    
    -- Действие по умолчанию (если ни одно действие со знаком минус не распознано в аргументах)
    default_action = "list",
    
    -- Булевы флаги (сопоставляются строго со знаком '-' и '--')
    flags = {
        force = { "-f", "--force", "-force" },
        all   = { "-a", "--all", "-all" },
        help  = { "-h", "--help", "-help" },
        path  = { "-p", "--path", "-path" },
    },
    
    -- Флаги со значением (поддерживают синтаксис: --lang=rust, --lang rust, -l rust)
    value_flags = {
        lang  = { "-l", "--lang", "-lang" },
        limit = { "-n", "--limit", "-limit" },
    },
    
    -- Словари категорий (сопоставляются строго со знаком минус: '-rust', '--rust')
    categories = {
        language = {
            ["-cpp"] = "cpp", ["--cpp"] = "cpp", ["-c++"] = "cpp",
            ["-rust"] = "rust", ["--rust"] = "rust", ["-rs"] = "rust",
            ["-python"] = "python", ["--python"] = "python", ["-py"] = "python",
            ["-java"] = "java", ["--java"] = "java",
            ["-lua"] = "lua", ["--lua"] = "lua",
        },
    },
    
    -- Автоматически определять существующую директорию среди аргументов
    detect_dir = true,
    
    -- Порог нечёткого сопоставления флагов Jaro-Winkler (по умолчанию 0.75)
    fuzzy_threshold = 0.75,
    
    -- Разрешать неизвестным флагам попадать в args (по умолчанию false: изолируются в unknown_flags)
    allow_unknown_flags = false,
    
    -- Список действий, для которых последующие флаги пробрасываются в args (по умолчанию: run, exec, export, create)
    passthrough_actions = { "run", "exec" },
}
```

##### Структура возвращаемой таблицы `parsed`:
```lua
local parsed = ctx.parse_args(spec)

-- parsed.action: string|nil   Каноническое имя выбранного действия ("init")
-- parsed.flags: table         Таблица флагов ({ force = true, all = false, lang = "rust" })
-- parsed.categories: table    Таблица категорий ({ language = "rust" })
-- parsed.target_dir: string   Найденный путь к существующей директории (если detect_dir = true)
-- parsed.command_tokens: table Массив токенов, переданных после разделителя '//' или '--'
-- parsed.unknown_flags: table Массив неизвестных флагов, начинающихся с '-'
-- parsed.has_separator: bool  Присутствовал ли разделитель '//' или '--'
```

##### Строгий дефисный стандарт (Strict Dash Standard):
- **Императив:** Любые действия (`actions`), категории (`categories`) и флаги (`flags`, `value_flags`) распознаются **ТОЛЬКО** если переданный токен начинается со знака дефиса (`-` или `--`).
- **Позиционные аргументы:** Любой токен без дефиса безоговорочно трактуется как позиционный аргумент (название проекта, путь, текст сообщения, поисковый фильтр) и попадает в `parsed.args`. Это полностью исключает случайный перехват пользовательских имён (например, проектов или микроприложений с именами `test`, `build`, `run`, `list`, `help`, `status`).
- **Приоритизация флага `-path`:** Флаги пути (`-path`, `--path`, `-p`) обладают умной семантикой. Если в шаге конвейера не указано основное действие со знаком минус, флаг `-path` автоматически становится действием (`parsed.action = "path"`), а также устанавливает `parsed.flags.path = true`. Если же основное действие указано (например, `-build -path`), основное действие сохраняется, а флаг `parsed.flags.path` остаётся активным.

#### `grime.args.split_passthrough([raw_args: table]) -> table, table, boolean`
(Алиас: `grime.args.split`)

Разделяет массив токенов по первому разделителю `//` или `--`.
- **Возвращает:** `tokens_before, command_tokens, has_separator`.
```lua
local before, cmd_tokens, has_sep = grime.args.split_passthrough(ctx.args)
-- grime cmd // echo -n "test"
-- before:      { "cmd" }
-- cmd_tokens:  { "echo", "-n", "test" }
-- has_sep:     true
```

#### Вспомогательные функции
- `grime.args.strip_dashes(token: string) -> string` — срезает ведущие дефисы и переводит строку в нижний регистр (`"--Update"` $\rightarrow$ `"update"`).
- `grime.args.is_flag(token: string) -> boolean` — возвращает `true`, если токен начинается с `-` (и не равен `"-"`, `"--"` или `"//"`).
- `grime.args.is_separator(token: string) -> boolean` — возвращает `true`, если токен равен `"--"` или `"//"`.
- `grime.args.new(spec: table) -> table` — возвращает объект парсера с методом `:parse(args, default_dir)` (для обратной совместимости).

---

## 4. Файловые операции ядра: `grime.fs`

Нативный модуль безопасных файловых операций в обход ограничений Lua:

- `grime.fs.read(path: string) -> string|nil` — читает всё содержимое файла в строку (или `nil` при ошибке).
- `grime.fs.write(path: string, content: string) -> boolean` — атомарно записывает строку в файл.
- `grime.fs.list(dir: string) -> table` — возвращает массив имён файлов и подкаталогов в указанной директории (`string[]`).
- `grime.fs.mkdir(path: string) -> boolean` — рекурсивно создаёт каталог (аналог `mkdir -p`).
- `grime.fs.remove(path: string) -> boolean` — рекурсивно удаляет файл или каталог.
- `grime.fs.copy(src: string, dst: string) -> boolean` — рекурсивно копирует файл или каталог с сохранением символических ссылок.
- `grime.fs.move_safe(src: string, dst: string) -> boolean` — атомарно перемещает файл или каталог с защитой от перезаписи целевой директории.
- `grime.fs.exists(path: string) -> boolean` — проверяет существование пути.
- `grime.fs.is_dir(path: string) -> boolean` — проверяет, является ли путь каталогом.
- `grime.fs.is_file(path: string) -> boolean` — проверяет, является ли путь файлом.

---

## 5. Шина состояния и события: `grime.bus`

Позволяет сохранять разделяемое состояние между разными шагами конвейера и разными вызовами CLI. Состояние атомарно сохраняется на диск в `~/.config/grime/state.json`.

- **Авто-нормализация ключей:** ключи без точки автоматически помещаются в пространство имён `user.<key>` (например, `"my_key"` сохраняется как `"user.my_key"`).
- `grime.bus.set(key: string, value: any) -> boolean` — сохраняет значение в шину состояния.
- `grime.bus.get(key: string) -> any` — считывает значение по ключу.
- `grime.bus.has(key: string) -> boolean` — проверяет наличие ключа в шине.
- `grime.bus.remove(key: string) -> boolean` — удаляет ключ из шины состояния.
- `grime.bus.list([prefix: string]) -> table` — возвращает таблицу всех ключей и их значений (с опциональной фильтрацией по префиксу пространства имён).

---

## 6. Пользовательский интерфейс и таблицы: `grime.ui`

- `grime.ui.info(msg: string)` — выводит сообщение цвета `CYAN`.
- `grime.ui.ok(msg: string)` — выводит подтверждающее сообщение цвета `GREEN`.
- `grime.ui.warn(msg: string)` — выводит предупреждающее сообщение цвета `YELLOW`.
- `grime.ui.error(msg: string)` — регистрирует ошибку в контексте шага (без дублирования в `stderr`, если далее следует `ctx.fail`).
- `grime.ui.header(title: string)` — выводит акцентный заголовок секции.
- `grime.ui.print_table(rows: table, headers: table)` — выводит красиво отформатированную таблицу с авто-выравниванием колонок по ширине:
  ```lua
  local headers = { "Модуль", "Версия", "Статус" }
  local rows = {
      { "project", "1.4.0", "Активен" },
      { "pkg",     "2.1.0", "Активен" },
  }
  grime.ui.print_table(rows, headers)
  ```

---

## 7. Нечёткий поиск (Fuzzy Matching): `grime.fuzzy`

Использует нативный высокопроизводительный алгоритм Jaro-Winkler в Rust:

- `grime.fuzzy.similarity(s1: string, s2: string) -> number` — возвращает коэффициент схожести двух строк в диапазоне от `0.0` до `1.0`.
- `grime.fuzzy.find_best_match(query: string, candidates: table, [threshold: number]) -> string|nil, number` — находит среди массива строк наилучшее совпадение выше заданного порога.
- `grime.fuzzy.match_flag(arg: string, patterns: table, [threshold: number]) -> string|nil` — проверяет схожесть переданного CLI-флага со списком допустимых шаблонов.

---

## 8. Строковые утилиты: `grime.str`

- `grime.str.trim(s: string) -> string` — удаляет пробельные символы с начала и конца строки.
- `grime.str.split(s: string, sep: string) -> table` — разделяет строку на массив подстрок по разделителю.
- `grime.str.starts_with(s: string, prefix: string) -> boolean` — проверяет префикс строки.
- `grime.str.ends_with(s: string, suffix: string) -> boolean` — проверяет суффикс строки.
- `grime.str.to_snake_case(s: string) -> string` — преобразует `CamelCase` строку в `snake_case`.
- `grime.str.shell_escape(s: string) -> string` — безопасно экранирует строку для передачи в командную оболочку.

---

## 9. Стандарт создания декларативного модуля GRIME

Каждый модуль GRIME представляет собой файл `~/.config/grime/modules/<name>.lua` и обязан соответствовать следующим правилам:

1. **Декларативные метаданные в начале файла:**
   ```lua
   -- Summary: Краткое назначение модуля
   -- Description: Полное описание возможностей модуля для реестра
   description = "Краткое назначение модуля для команды grime list"
   ```
2. **Использование нативного `ctx.parse_args`:**
   Парсинг аргументов должен выполняться через нативный движок ядра, а не через сторонние библиотеки.
3. **Строгий запрет на `os.exit` и `io.popen`:**
   - Вызов `os.exit()` аварийно завершает рабочий процесс. Для завершения шага используйте `ctx.fail(msg)` или `ctx.success(msg)`.
   - Вместо `io.popen()` используйте безопасный `ctx.capture({...})` или `ctx.run_process({...})`.
4. **Гарантированная очистка ресурсов:**
   Если модуль создаёт временные файлы или открывает дескрипторы, зарегистрируйте функцию очистки в `_G.cleanup`:
   ```lua
   _G.cleanup = function()
       if temp_file and ctx.exists(temp_file) then
           ctx.delete(temp_file)
       end
   end
   ```
5. **Экспорт точки входа:**
   Файл модуля обязан возвращать таблицу с полями `main` и `description`:
   ```lua
   return {
       main = main,
       description = description,
   }
   ```

---

## 10. Пример эталонного модуля (`custom_tool.lua`)

```lua
-- Summary: Пример пользовательского модуля GRIME
-- Description: Демонстрационный модуль для обработки проектов
description = "Демонстрационный модуль для обработки проектов"

local utils = require("languages.utils")
local ctx = grime.ctx
local ANSI = utils.ANSI

local function print_help()
    print(string.format([[
%s%sGrime Custom Tool%s — Пример пользовательского модуля

ИСПОЛЬЗОВАНИЕ:
    grime custom_tool [-list] [-run] [-name <имя>] [директория]

ФЛАГИ:
    -l, --list, list     Показать список элементов
    -r, --run, run       Выполнить обработку
    -n, --name <знач>    Указать имя задачи
    -f, --force          Принудительное выполнение
    -h, --help           Показать эту справку
]], ANSI.BOLD, ANSI.GREEN, ANSI.RESET))
end

function main()
    local parsed = ctx.parse_args({
        actions = {
            list = "list", ls = "list",
            run  = "run", r = "run",
            help = "help",
        },
        default_action = "list",
        flags = {
            force = { "-f", "--force" },
            help  = { "-h", "--help" },
        },
        value_flags = {
            name = { "-n", "--name" },
        },
        detect_dir = true,
    })

    if parsed.flags.help or parsed.action == "help" then
        print_help()
        return
    end

    local target = parsed.target_dir or ctx.target_dir or "."

    if parsed.action == "list" then
        ctx.log("Сканирование каталога: " .. target)
        local files = grime.fs.list(target)
        local rows = {}
        for _, f in ipairs(files) do
            local is_d = ctx.is_dir(target .. "/" .. f) and "Каталог" or "Файл"
            table.insert(rows, { f, is_d })
        end
        grime.ui.print_table(rows, { "Элемент", "Тип" })
        
        -- Передача количества элементов следующему шагу конвейера
        if ctx.has_next_step then
            ctx.module_return(tostring(#files))
        end
    elseif parsed.action == "run" then
        local task_name = parsed.flags.name or "безымянная"
        ctx.log(string.format("Запуск задачи '%s' в директории %s...", task_name, target))
        
        -- Пример сохранения состояния в StateBus
        grime.bus.set("custom_tool.last_task", task_name)
        ctx.success("Задача успешно выполнена")
    end
end

return {
    main = main,
    description = description,
}
```
