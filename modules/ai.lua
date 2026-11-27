-- Summary: Универсальный ИИ-оркестратор агентов (Claude Code, Aider)
-- Description: Универсальный ИИ-оркестратор агентов (Claude Code, Aider)
description = "Универсальный ИИ-оркестратор агентов (Claude Code, Aider)"

local ctx = grime.ctx
local utils = require("languages.utils")
local scanner = require("languages.scanner")
local agents = require("agents.registry")

local GRIME_CONVENTIONS = [[

[GRIME CONVENTIONS & SYSTEM ARCHITECTURE]:
1. СТРОГИЙ КОНТРОЛЬ ЗАПУСКА (ЗАПРЕТ САМОВОЛЬНОГО ИСПОЛНЕНИЯ):
   - Если пользователь задал теоретический вопрос, запросил справку, консультацию, анализ кода или архитектурный совет:
     ОТВЕЧАЙ ТОЛЬКО ТЕКСТОМ В MARKDOWN! КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО генерировать исполняемые теги <grime_exec> или <grime_spawn>!
   - Использование <grime_exec> и <grime_spawn> разрешено ИСКЛЮЧИТЕЛЬНО в двух случаях:
     1) Создание или делегирование задачи специализированному субагенту Grime:
        <grime_spawn module="..." cwd="...">промпт</grime_spawn>
     2) Прямая, явная просьба пользователя выполнить команду/действие (например: "собери проект", "создай файл", "выполни X", "запусти тесты").
2. БЕЗОПАСНОСТЬ:
   - При явной просьбе пользователя команды выполняются через:
     <grime_exec [cwd="..."]>команда</grime_exec>
   - СТРОЖАЙШЕ ЗАПРЕЩЕНЫ sudo, su, doas, pkexec и любые операции за пределами $HOME.
3. ВЫСОКОУРОВНЕВАЯ ЭКОСИСТЕМА GRIME (Grime-RS v1.1.0, High-Level First):
   - Стандарт флагов: все флаги и действия указываются со знаком минус (`-` или `--`), например `-new`, `-build`, `-run`, `-path`, `-list`, `-rm`, `-lang`, `-detach`, `-force`, `-help`. Для передачи флагов внешним утилитам без перехвата ядром используется разделитель `//` или `--`.
   - Модуль ИИ-агентов (`ai`): `grime ai [-claude|-aider|-agent <имя>] [проект] [файлы...] [-m "промпт"]`, `grime ai -app <имя> [-lang <lang>] [промпт]`, `grime ai -module <модуль> [промпт]`.
   - Модуль проектов (`project`): `grime project -init <lang> <name>`, `grime project -build [name]`, `grime project -run [name]`, `grime project -path <name>`, `grime project -list`, `grime project -clear <name>`, `grime project -rm <name>`. Поддерживаются: `cpp`, `rust`, `python`, `java`, `lua`.
   - Модуль приложений (`app`): `grime app -new <name> [-lang <lang>] [промпт]`, `grime app -build <name>`, `grime app -run <name> [-detach]`, `grime app -stop <name>`, `grime app -path [name]`, `grime app -list`, `grime app -ps`, `grime app -bundle <name>`, `grime app -snapshot <name>`, `grime app -rollback <name>`, `grime app -diff <name>`, `grime app -rm <name>`.
   - Модуль пакетов (`pkg`): `grime pkg -search <запрос>`, `grime pkg -list`, `grime pkg -run <утилита> [args]`, `grime pkg pacman -install <pkg>`, `grime pkg nix -install <pkg>`.
   - Модуль Nix (`nix`): `grime nix -init`, `grime nix -build`, `grime nix -run`, `grime nix -history`, `grime nix -rollback`, `grime nix -update`, `grime nix -bundle`, `grime nix -gc`, `grime nix -optimise`.
   - Модуль контейнеров (`box`): `grime box <name> -run <cmd>`, `grime box -list`, `grime box -export bin <path>`.
   - Модуль Git (`git`): `grime git -status`, `grime git -diff`, `grime git -commit <msg>`, `grime git -snapshot [msg]`, `grime git -log`, `grime git -ls-files`.
   - Модули диагностики и инфраструктуры: `grime doctor`, `grime bus -set <k> <v>`, `grime bus -get <k>`, `grime log`, `grime list`, `grime daemon`.
   - Синтаксис конвейеров: шаги разделяются двоеточием `:` (например: `grime project -path MyProj : box fedora-box : project -build : host : project -run`). Модуль `host` возвращает исполнение из контейнера/DevShell обратно на хост.
   - Принцип разделения ответственности (Rust Core vs Lua Modules): нативное ядро Grime на Rust (`src/*.rs`) отвечает ТОЛЬКО за управление модулями, парсинг конвейера, изоляцию потоков и шину состояния (`StateBus`). Вся прикладная логика, команды, сборка и интеграции реализуются ИСКЛЮЧИТЕЛЬНО внутри декларативных Lua-модулей (`modules/*.lua`).
4. ШИНА И КОНВЕЙЕР:
   - Сохранение данных в StateBus (RAM демона):
     <grime_bus key="pipeline.<key>" type="json">{"k":"v"}</grime_bus>
   - Передача промпта следующему шагу конвейера:
     <next_agent_prompt>инструкция</next_agent_prompt>
]]

local GRIME_MODULE_STANDARD = [[

[СТАНДАРТ РАЗРАБОТКИ И ДОРАБОТКИ МОДУЛЕЙ GRIME (LuaJIT + Grime-RS API)]:
При создании нового модуля или доработке существующего модуля в `modules/*.lua` ты ОБЯЗАН строго соблюдать архитектуру GRIME и переиспользовать общий код:
- АРХИТЕКТУРНЫЙ ИМПЕРАТИВ: Ядро Grime на Rust отвечает только за диспетчеризацию модулей, конвейер и шину памяти. Вся логика конкретного функционала должна быть полностью реализована в Lua-модуле без необходимости менять Rust-ядро.

1. ОБЯЗАТЕЛЬНОЕ ПЕРЕИСПОЛЬЗОВАНИЕ НАТИВНОГО ДВИЖКА И БИБЛИОТЕК (`grime.args`, `modules/languages/*.lua`, `modules/agents/*.lua`):
   - Парсинг аргументов и флагов со знаком минус:
     Используй нативный движок ядра: `local parsed = ctx.parse_args({ actions = ..., flags = ..., value_flags = ..., categories = ..., detect_dir = ... })`
     или `local before, cmd, has_sep = grime.args.split_passthrough(ctx.args)`.
     (Модуль `languages/argparse.lua` упразднён и перенесён в нативное ядро).
   - Общие утилиты, цвета, проверка бинарников и путей:
     `local utils = require("languages.utils")`
     Переиспользуй: `utils.ANSI`, `utils.utf8_len`, `utils.pad_utf8`, `utils.has_binary(bin, ctx)`, `utils.shell_escape(s)`, `utils.normalize_path(p, cwd, ctx)`, `utils.classify_paths(cmd, args, cwd, ctx)`, `utils.get_apps_root(ctx)`, `utils.get_projects_root(ctx)`, `utils.generate_flake_nix(...)`, `utils.generate_app_manifest(...)`.
   - Для языковых адаптеров (`modules/languages/<lang>.lua`):
     Наследуйся от `local BaseAdapter = require("languages.base")` через `setmetatable(BaseAdapter.new({...}), LangAdapter)`.
   - Для адаптеров ИИ-агентов (`modules/agents/<agent>.lua`):
     Наследуйся от `local BaseAgent = require("agents.base")` через `BaseAgent.new({...})`.
   - Для логирования и Git при необходимости используй `local log = require("log")` и `local git = require("git")`.

2. НАТИВНОЕ API ЯДРА GRIME-RS (глобальная таблица `grime`):
   - `local ctx = grime.ctx`:
     * `ctx.args` (таблица аргументов шага), `ctx.target_dir` (текущая рабочая папка шага), `ctx.pipeline_input` / `ctx.input` (вход от предыдущего шага конвейера), `ctx.has_next_step` (bool: есть ли следующий шаг в конвейере), `ctx.force` (bool).
     * `ctx.set_target_dir(dir)` — смена рабочей директории для следующих шагов конвейера.
     * `ctx.module_return(val)` / `ctx.success(val)` — возврат результата шага в конвейер.
     * `ctx.fail(msg)` — завершение шага с ошибкой. ВАЖНО: вызывай ТОЛЬКО `ctx.fail(msg)` и `return`! КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО вызывать `grime.ui.error(msg)` или `io.stderr:write(msg)` с тем же текстом перед `ctx.fail(msg)`, так как ядро Grime само выводит сообщение из `ctx.fail`!
     * `ctx.run_process(argv, cwd, env)` -> код возврата (int); `ctx.run_interactive(argv, cwd, env)` -> код возврата (int); `ctx.capture(argv_or_cmd, cwd, env)` -> `{ code, stdout, stderr }`.
     * `ctx.exists(path)`, `ctx.is_dir(path)`, `ctx.is_file(path)`, `ctx.mkdir_p(path)`, `ctx.delete(path, recursive)`, `ctx.copy(src, dst)`, `ctx.move(src, dst)`, `ctx.normalize_path(path)`, `ctx.log(msg)`, `ctx.warn(msg)`.
   - `grime.fs`: `read(path)`, `write(path, content)`, `list(dir)`, `exists(path)`, `is_dir(path)`, `is_file(path)`, `normalize(path)`.
   - `grime.ui`: `info(msg)`, `ok(msg)` / `success(msg)`, `warn(msg)`, `error(msg)`, `step(msg)`, `header(msg)`, `print_table(rows, headers)`.
   - `grime.bus`: `set(key, val)`, `get(key)`, `remove(key)`, `list(prefix)`.
   - `grime.fuzzy`: `find_best_match(query, candidates, threshold)`, `match_flag(tok, flags, threshold)`, `similarity(a, b)`.
   - `grime.str`: `trim(s)`, `split(s, sep)`, `starts_with(s, prefix)`, `ends_with(s, suffix)`, `shell_escape(s)`, `to_snake_case(s)`.
   - ЗАПРЕЩЕНО использовать `os.exit()` и `io.popen()` внутри модулей!

3. СТРУКТУРА ФАЙЛА МОДУЛЯ:
   - Первые строки файла:
     ```lua
     -- Summary: Краткое описание модуля
     -- Description: Полное описание модуля
     description = "Краткое описание модуля"
     ```
   - Все флаги, действия и подкоманды в модуле и в `print_help()` строго обязаны начинаться со знака минус (`-` или `--`), например `-list`, `--list`, `-path`, `--path`, `-p`, `-help`, `--help`, `-h`. Любые токены без минуса трактуются исключительно как позиционные аргументы.
   - В конце файла обязательно возвращать таблицу:
     ```lua
     return {
         main = main,
         description = description,
     }
     ```
]]

local TERMINAL_DIAGNOSTIC_RULES = [[

[ПРАВИЛА АНАЛИЗА ОШИБОК И ТЕРМИНАЛА]:
1. ИССЛЕДОВАНИЕ ФАЙЛОВ (ОБЯЗАТЕЛЬНО): Если в выводе терминала/компилятора есть пути к файлам и номера строк, ты ОБЯЗАН изучить эти файлы и проблемные строки перед внесением правок. Запрещено гадать без проверки реального кода.
2. ЭВРИСТИКА УСПЕХА: Если в истории терминала команда падала, но позже аналогичная команда завершилась успешно (exit code 0), считай проблему уже решенной пользователем и не пытайся её чинить повторно.
]]

--- Определение пути к исполняемому файлу grime
local function resolve_grime_bin()
    local env_bin = os.getenv("GRIME_BIN")
    if env_bin and env_bin ~= "" then
        return env_bin
    end
    local home = os.getenv("HOME") or ""
    if home ~= "" then
        local local_bin = home .. "/.local/bin/grime"
        if ctx.exists(local_bin) then
            return local_bin
        end
    end
    return "grime"
end

--- Приведение строки к нижнему регистру с поддержкой UTF-8 кириллицы (А-Я, Ё) и ASCII (A-Z)
local function utf8_lower(s)
    if type(s) ~= "string" or s == "" then return "" end
    local res = s:lower()
    -- А..П (U+0410..U+041F: \208\144..\208\159) -> а..п (\208\176..\208\191)
    res = res:gsub("\208([\144-\159])", function(c)
        return "\208" .. string.char(c:byte(1) + 32)
    end)
    -- Р..Я (U+0420..U+042F: \208\160..\208\175) -> р..я (\209\128..\209\143)
    res = res:gsub("\208([\160-\175])", function(c)
        return "\209" .. string.char(c:byte(1) - 32)
    end)
    -- Ё (U+0401: \208\129) -> ё (\209\145)
    res = res:gsub("\208\129", "\209\145")
    return res
end

--- Проверка вхождения отдельного слова (или основы слова) с учетом границ UTF-8/ASCII
local function has_word_token(low_text, word)
    local padded = " " .. low_text:gsub("[%p%s]+", " ") .. " "
    return padded:find(" " .. word .. " ", 1, true) ~= nil
end

local function has_word_prefix(low_text, prefix)
    local padded = " " .. low_text:gsub("[.,!?;:\"'%(%)%[%]%{%}/\\|<>]+", " ") .. " "
    for tok in padded:gmatch("%S+") do
        if tok:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

--- Приоритетное извлечение явно указанного языка/стека из текста пользовательского промпта
local function extract_lang_from_prompt(user_prompt)
    if type(user_prompt) ~= "string" or user_prompt == "" then
        return nil
    end

    local low = utf8_lower(user_prompt)
    -- Убираем упоминание служебного манифеста app.lua, чтобы не путать его с выбором языка Lua
    low = low:gsub("app%.lua", " ")

    -- Удаляем конструкции с явным отрицанием ("не на c++", "без python", "not in java", "instead of cpp")
    local negation_patterns = {
        "не на%s+[%S]+",
        "без%s+[%S]+",
        "кроме%s+[%S]+",
        "вместо%s+[%S]+",
        "not%s+in%s+[%S]+",
        "not%s+on%s+[%S]+",
        "not%s+[%S]+",
        "instead%s+of%s+[%S]+",
        "without%s+[%S]+",
    }
    local cleaned = low
    for _, pat in ipairs(negation_patterns) do
        cleaned = cleaned:gsub(pat, " ")
    end

    -- 1. Высший приоритет: явные целевые конструкции ("на питоне", "на python", "на джаве", "in python", "using java", "стек python")
    local explicit_targets = {
        { lang = "python", patterns = {
            "на%s+python", "на%s+pyhon", "на%s+phyton", "на%s+питон", "на%s+пайтон", "на%s+py%f[%A]",
            "in%s+python", "using%s+python", "with%s+python",
            "язык[еа]?%s+python", "язык[еа]?%s+питон", "язык[еа]?%s+пайтон",
            "стек[еа]?%s+python", "стек[еа]?%s+питон", "стек[еа]?%s+пайтон",
        }},
        { lang = "java", patterns = {
            "на%s+java%f[%A]", "на%s+джав", "на%s+яв[еуыой]",
            "in%s+java%f[%A]", "using%s+java%f[%A]", "with%s+java%f[%A]",
            "язык[еа]?%s+java%f[%A]", "язык[еа]?%s+джав", "язык[еа]?%s+яв[аеу]",
            "стек[еа]?%s+java%f[%A]", "стек[еа]?%s+джав",
        }},
        { lang = "rust", patterns = {
            "на%s+rust", "на%s+раст", "на%s+rs%f[%A]",
            "in%s+rust", "using%s+rust", "with%s+rust",
            "язык[еа]?%s+rust", "язык[еа]?%s+раст",
            "стек[еа]?%s+rust", "стек[еа]?%s+раст",
        }},
        { lang = "lua", patterns = {
            "на%s+lua", "на%s+luajit", "на%s+луа",
            "in%s+lua", "using%s+lua", "with%s+lua",
            "язык[еа]?%s+lua", "язык[еа]?%s+луа",
            "стек[еа]?%s+lua", "стек[еа]?%s+луа",
        }},
        { lang = "cpp", patterns = {
            "на%s+c%+%+", "на%s+cpp", "на%s+cxx", "на%s+си%+%+", "на%s+с%+%+", "на%s+плюсах",
            "in%s+c%+%+", "in%s+cpp", "using%s+c%+%+", "using%s+cpp",
            "язык[еа]?%s+c%+%+", "язык[еа]?%s+cpp", "язык[еа]?%s+си%+%+",
            "стек[еа]?%s+c%+%+", "стек[еа]?%s+cpp",
        }},
        { lang = "fish", patterns = {
            "на%s+fish", "на%s+фиш", "in%s+fish", "using%s+fish", "with%s+fish",
            "язык[еа]?%s+fish", "стек[еа]?%s+fish", "скрипт%s+fish", "fish%s+скрипт",
        }},
        { lang = "bash", patterns = {
            "на%s+bash", "на%s+баш", "на%s+sh%f[%A]", "на%s+shell", "на%s+шелл",
            "in%s+bash", "in%s+sh%f[%A]", "using%s+bash", "with%s+bash",
            "язык[еа]?%s+bash", "стек[еа]?%s+bash", "bash%s+скрипт", "shell%s+скрипт",
        }},
    }

    for _, group in ipairs(explicit_targets) do
        for _, pat in ipairs(group.patterns) do
            if cleaned:find(pat) then
                return group.lang
            end
        end
    end

    -- 2. Проверка по прямому упоминанию языков, компиляторов и ключевых фреймворков
    if has_word_prefix(cleaned, "python")
        or has_word_prefix(cleaned, "pyhon")
        or has_word_prefix(cleaned, "phyton")
        or has_word_prefix(cleaned, "piton")
        or has_word_prefix(cleaned, "питон")
        or has_word_prefix(cleaned, "пайтон")
        or has_word_token(cleaned, "py")
        or cleaned:find("%.py%f[%A]")
        or has_word_token(cleaned, "fastapi")
        or has_word_token(cleaned, "flask")
        or has_word_token(cleaned, "django")
        or has_word_token(cleaned, "asyncio")
        or has_word_token(cleaned, "aiohttp")
        or has_word_token(cleaned, "pandas")
        or has_word_token(cleaned, "numpy")
        or has_word_token(cleaned, "pytest")
        or has_word_token(cleaned, "pydantic")
    then
        return "python"
    end

    -- Java (исключая javascript)
    local cleaned_no_js = cleaned:gsub("javascript", " ")
    if has_word_token(cleaned_no_js, "java")
        or has_word_prefix(cleaned_no_js, "джав")
        or has_word_token(cleaned_no_js, "ява")
        or has_word_token(cleaned_no_js, "яве")
        or has_word_token(cleaned_no_js, "яву")
        or has_word_token(cleaned_no_js, "явой")
        or has_word_token(cleaned_no_js, "jvm")
        or has_word_token(cleaned_no_js, "jdk")
        or has_word_token(cleaned_no_js, "javac")
        or has_word_token(cleaned_no_js, "maven")
        or has_word_token(cleaned_no_js, "gradle")
        or has_word_token(cleaned_no_js, "spring")
        or has_word_token(cleaned_no_js, "springboot")
        or cleaned_no_js:find("%.java%f[%A]")
    then
        return "java"
    end

    -- Rust (проверяем точные словоформы, чтобы не срабатывать на "возраст" / "растение")
    if has_word_token(cleaned, "rust")
        or has_word_token(cleaned, "rustc")
        or has_word_token(cleaned, "раст")
        or has_word_token(cleaned, "расте")
        or has_word_token(cleaned, "раста")
        or has_word_token(cleaned, "растом")
        or has_word_token(cleaned, "расту")
        or has_word_token(cleaned, "cargo")
        or has_word_token(cleaned, "tokio")
        or has_word_token(cleaned, "axum")
        or has_word_token(cleaned, "actix")
        or has_word_token(cleaned, "serde")
        or cleaned:find("%.rs%f[%A]")
    then
        return "rust"
    end

    -- Lua
    if has_word_token(cleaned, "lua")
        or has_word_token(cleaned, "luajit")
        or has_word_token(cleaned, "луа")
        or cleaned:find("%.lua%f[%A]")
    then
        return "lua"
    end

    -- C++
    if cleaned:find("c%+%+")
        or cleaned:find("си%+%+")
        or cleaned:find("с%+%+")
        or has_word_token(cleaned, "cpp")
        or has_word_token(cleaned, "cxx")
        or has_word_token(cleaned, "плюсах")
        or has_word_token(cleaned, "плюсы")
        or has_word_token(cleaned, "cmake")
        or has_word_token(cleaned, "g++")
        or has_word_token(cleaned, "clang++")
        or cleaned:find("%.cpp%f[%A]")
        or cleaned:find("%.hpp%f[%A]")
    then
        return "cpp"
    end

    -- Fish
    if has_word_token(cleaned, "fish")
        or has_word_token(cleaned, "фиш")
        or cleaned:find("%.fish%f[%A]")
    then
        return "fish"
    end

    -- Bash / Shell
    if has_word_token(cleaned, "bash")
        or has_word_token(cleaned, "баш")
        or has_word_token(cleaned, "shell")
        or has_word_token(cleaned, "шелл")
        or cleaned:find("%.sh%f[%A]")
        or cleaned:find("%.bash%f[%A]")
    then
        return "bash"
    end

    return nil
end

--- Предметная эвристика выбора стека (когда язык не назван в промпте явно)
local function heuristic_stack_from_prompt(user_prompt)
    if type(user_prompt) ~= "string" or user_prompt == "" then
        return "python"
    end
    local low = utf8_lower(user_prompt)

    local lua_keywords = { "плагин", "plugin", "модуль grime", "grime module", "хук", "hook", "neovim", "nvim" }
    for _, kw in ipairs(lua_keywords) do
        if low:find(kw, 1, true) then return "lua" end
    end

    local cpp_keywords = { "opengl", "vulkan", "raylib", "sdl", "шейдер", "shader", "3d", "рендер", "render", "движок", "игр", "game", "физик", "симуляц" }
    for _, kw in ipairs(cpp_keywords) do
        if low:find(kw, 1, true) then return "cpp" end
    end

    local java_keywords = { "банк", "бухгалтер", "склад", "инвентар", "магазин", "заказ", "платеж", "предприят", "enterprise", "crm", "erp", "реестр", "библиотек" }
    for _, kw in ipairs(java_keywords) do
        if low:find(kw, 1, true) then return "java" end
    end

    local rust_keywords = { "демон", "daemon", "сокет", "socket", "прокси", "proxy", "шифрован", "крипто", "crypto", "бенчмарк", "benchmark", "монитор систем", "сниффер", "многопоточ" }
    for _, kw in ipairs(rust_keywords) do
        if low:find(kw, 1, true) then return "rust" end
    end

    return "python"
end

--- Предметная эвристика определения дополнительных Nix-пакетов (Nixpkgs) по тексту задачи
local function heuristic_nix_packages(user_prompt, lang)
    if type(user_prompt) ~= "string" or user_prompt == "" then
        return {}
    end
    local low = utf8_lower(user_prompt)
    local target_lang = (lang or ""):lower()
    local packages = {}
    local seen = {}

    local function add_pkg(p)
        if p and p ~= "" and not seen[p] then
            seen[p] = true
            table.insert(packages, p)
        end
    end

    -- 1. Графика, 2D/3D и игровой движок
    if low:find("raylib", 1, true) or low:find("рейлиб", 1, true) then
        add_pkg("raylib")
        if target_lang == "cpp" or target_lang == "" then
            add_pkg("pkg-config")
            add_pkg("cmake")
        end
    end
    if low:find("sdl2", 1, true) or low:find("sdl", 1, true) then
        add_pkg("SDL2")
        if target_lang == "cpp" or target_lang == "" then
            add_pkg("pkg-config")
            add_pkg("cmake")
        end
    end
    if low:find("sfml", 1, true) then
        add_pkg("sfml")
        if target_lang == "cpp" or target_lang == "" then
            add_pkg("pkg-config")
            add_pkg("cmake")
        end
    end

    -- 2. Сеть, HTTP, API, TLS и безопасность
    if low:find("curl", 1, true) or low:find("libcurl", 1, true) then
        add_pkg("curl")
        if target_lang == "cpp" or target_lang == "rust" or target_lang == "" then
            add_pkg("pkg-config")
        end
    end
    if low:find("openssl", 1, true) or low:find("ssl", 1, true) or low:find("tls", 1, true) or low:find("крипто", 1, true) then
        add_pkg("openssl")
        if target_lang == "cpp" or target_lang == "rust" or target_lang == "" then
            add_pkg("pkg-config")
        end
    end

    -- 3. TUI и терминальные интерфейсы
    if low:find("ncurses", 1, true) or low:find("curses", 1, true) or low:find("tui", 1, true) then
        add_pkg("ncurses")
        if target_lang == "cpp" or target_lang == "" then
            add_pkg("pkg-config")
        end
    end

    -- 4. Базы данных
    if low:find("sqlite", 1, true) or low:find("sqlite3", 1, true) then
        add_pkg("sqlite")
        if target_lang == "cpp" or target_lang == "rust" or target_lang == "" then
            add_pkg("pkg-config")
        end
    end

    -- 5. C++ специализированные библиотеки
    if target_lang == "cpp" or target_lang == "" then
        if low:find("boost", 1, true) then
            add_pkg("boost")
        end
        if low:find("fmt", 1, true) then
            add_pkg("fmt")
        end
        if low:find("spdlog", 1, true) then
            add_pkg("spdlog")
        end
        if low:find("nlohmann", 1, true) or (low:find("json", 1, true) and target_lang == "cpp") then
            add_pkg("nlohmann_json")
        end
    end

    -- 6. Python специализированные пакеты (Nixpkgs python3Packages)
    if target_lang == "python" or target_lang == "" then
        if low:find("fastapi", 1, true) then
            add_pkg("python3Packages.fastapi")
            add_pkg("python3Packages.uvicorn")
        end
        if low:find("requests", 1, true) then
            add_pkg("python3Packages.requests")
        end
        if low:find("flask", 1, true) then
            add_pkg("python3Packages.flask")
        end
        if low:find("rich", 1, true) then
            add_pkg("python3Packages.rich")
        end
        if low:find("pytest", 1, true) or low:find("тест", 1, true) then
            add_pkg("python3Packages.pytest")
        end
        if low:find("numpy", 1, true) then
            add_pkg("python3Packages.numpy")
        end
        if low:find("pillow", 1, true) or low:find("pil", 1, true) then
            add_pkg("python3Packages.pillow")
        end
        if low:find("pygame", 1, true) then
            add_pkg("python3Packages.pygame")
        end
        if low:find("beautifulsoup", 1, true) or low:find("bs4", 1, true) then
            add_pkg("python3Packages.beautifulsoup4")
        end
    end

    -- 7. Мультимедиа
    if low:find("ffmpeg", 1, true) then
        add_pkg("ffmpeg")
        add_pkg("pkg-config")
    end

    return packages
end

--- Парсинг ответа ИИ-Архитектора в формате <grime_architecture>...</grime_architecture>
local function parse_architect_response(stdout)
    if type(stdout) ~= "string" or stdout == "" then
        return nil
    end

    local allowed = {
        python = "python", py = "python", python3 = "python",
        java = "java",
        rust = "rust", rs = "rust",
        lua = "lua", luajit = "lua",
        cpp = "cpp", ["c++"] = "cpp", cxx = "cpp",
        bash = "bash", sh = "bash", shell = "bash",
        fish = "fish",
    }

    local block = stdout:match("<grime_architecture>(.-)</grime_architecture>")
    if not block then
        block = stdout:match("<grime_architecture>(.*)")
    end

    if block then
        local res = {
            lang = nil,
            special_dependencies = {},
            build = nil,
            run = nil,
            test = nil,
            summary = nil,
        }

        local raw_lang = block:match("LANG:%s*([^\r\n]+)")
        if raw_lang then
            local clean_l = raw_lang:gsub("[`*'\".,!?;:()<>%[%]%{%}]+", " "):match("%S+")
            if clean_l and allowed[clean_l:lower()] then
                res.lang = allowed[clean_l:lower()]
            end
        end

        local raw_pkgs = block:match("NIX_PACKAGES:%s*([^\r\n]+)")
        if raw_pkgs then
            local clean_p = raw_pkgs:gsub("[`*'\"()<>]", " ")
            local pkgs = {}
            local seen = {}
            for tok in clean_p:gmatch("[%w%_%-%.]+") do
                local low_tok = tok:lower()
                if low_tok ~= "none" and low_tok ~= "нет" and low_tok ~= "nil" and low_tok ~= "auto" and low_tok ~= "null" and not seen[tok] then
                    seen[tok] = true
                    table.insert(pkgs, tok)
                end
            end
            res.special_dependencies = pkgs
        end

        local raw_b = block:match("BUILD:%s*([^\r\n]+)")
        if raw_b then
            local tb = raw_b:match("^%s*(.-)%s*$")
            if tb ~= "" and tb:lower() ~= "auto" and tb:lower() ~= "none" and tb:lower() ~= "default" then
                res.build = tb
            end
        end

        local raw_r = block:match("RUN:%s*([^\r\n]+)")
        if raw_r then
            local tr = raw_r:match("^%s*(.-)%s*$")
            if tr ~= "" and tr:lower() ~= "auto" and tr:lower() ~= "none" and tr:lower() ~= "default" then
                res.run = tr
            end
        end

        local raw_t = block:match("TEST:%s*([^\r\n]+)")
        if raw_t then
            local tt = raw_t:match("^%s*(.-)%s*$")
            if tt ~= "" and tt:lower() ~= "auto" and tt:lower() ~= "none" and tt:lower() ~= "default" then
                res.test = tt
            end
        end

        local raw_s = block:match("SUMMARY:%s*([^\r\n]+)")
        if raw_s then
            local ts = raw_s:match("^%s*(.-)%s*$")
            if ts ~= "" and ts:lower() ~= "none" then
                res.summary = ts
            end
        end

        if res.lang or #res.special_dependencies > 0 then
            return res
        end
    end

    -- Fallback: парсинг однословного ответа
    local lines = {}
    for line in stdout:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= ""
            and not trimmed:match("^Tokens:")
            and not trimmed:match("^Cost:")
            and not trimmed:match("^Warning:")
            and not trimmed:match("^Aider ")
            and not trimmed:match("^Model:")
            and not trimmed:match("^Git ")
            and not trimmed:match("^Repo%-map:")
        then
            table.insert(lines, trimmed:lower())
        end
    end

    for i = #lines, 1, -1 do
        local ln = lines[i]:gsub("[`*'\".,!?;:()<>%[%]%{%}]+", " ")
        local first_tok = ln:match("^%s*(%S+)%s*$")
        if first_tok and allowed[first_tok] then
            return { lang = allowed[first_tok], special_dependencies = {} }
        end
        for tok in ln:gmatch("%S+") do
            if allowed[tok] then
                return { lang = allowed[tok], special_dependencies = {} }
            end
        end
    end

    return nil
end

--- Комплексное планирование стека микроприложения Архитектором (язык, зависимости Nixpkgs, команды сборки)
local function plan_app_stack(user_prompt, preferred_lang, app_name, preferred_agent)
    local explicit = preferred_lang
        or (user_prompt and user_prompt ~= "" and extract_lang_from_prompt(user_prompt))
        or (app_name and extract_lang_from_prompt(app_name))

    local target_lang = explicit

    local plan = {
        lang = target_lang,
        special_dependencies = {},
        build = nil,
        run = nil,
        test = nil,
        summary = nil,
    }

    -- Предметная эвристика как надежная база для пакетов
    local heur_pkgs = heuristic_nix_packages(user_prompt or "", target_lang or "python")

    -- Запрос к ИИ-Архитектору через адаптер (в изолированной директории /tmp)
    local agent = agents.resolve(preferred_agent, ctx)
    if agent and agent:is_available(ctx) and user_prompt and user_prompt ~= "" then
        local lang_instruction = explicit
            and string.format("ЯЗЫК УЖЕ ВЫБРАН ПОЛЬЗОВАТЕЛЕМ: %s (ОБЯЗАТЕЛЬНО укажи LANG: %s).\nТвоя задача — точно определить библиотеки Nixpkgs (NIX_PACKAGES) и команды сборки/запуска для данного языка.", explicit, explicit)
            or "Определи наиболее оптимальный базовый язык (python, cpp, rust, java, lua, bash, fish) и необходимые библиотеки Nixpkgs."

        local architect_prompt = string.format([[Ты — ведущий системный архитектор экосистемы GRIME.
Спроектируй стек технологий и зависимости Nix (Nixpkgs) для создания микроприложения по задаче:
"%s"

%s

Доступные базовые языки:
- python : скрипты, CLI-утилиты, веб/API (fastapi, requests), анализ данных.
- cpp    : графика, игры (raylib, sdl2, sfml), CLI/TUI (ncurses), высокопроизводительные сервисы (curl, openssl, sqlite, boost).
- rust   : системные CLI/утилиты, демоны, многопоточность, сетевые протоколы.
- java   : структурированная бизнес-логика, учетные сервисы.
- lua    : легковесные скрипты и расширения Grime.
- bash   : системные shell-скрипты и оркестрация CLI-утилит.
- fish   : скрипты и автоматизация для оболочки Fish.

ТРЕБОВАНИЯ:
1. Выбери базовый язык (LANG).
2. ОБЯЗАТЕЛЬНО определи точный набор библиотек и пакетов Nix (Nixpkgs), которые необходимо подключить в окружение для компиляции, сборки и запуска (например: raylib, curl, openssl, ncurses, sqlite, boost, pkg-config, cmake, python3Packages.requests, python3Packages.fastapi и т.д.).
3. Если сторонние пакеты Nixpkgs не требуются, укажи 'none'.

ФОРМАТ ВЫВОДА (СТРОГО внутри тега, без лишнего текста вокруг):
<grime_architecture>
LANG: <python|cpp|rust|java|lua|bash|fish>
NIX_PACKAGES: <пакет1, пакет2, ... или none>
BUILD: <auto или команда сборки>
RUN: <auto или команда запуска>
TEST: <auto или команда тестов>
SUMMARY: <краткое описание архитектурного решения и библиотек>
</grime_architecture>]], user_prompt, lang_instruction)

        local cmd = agent:build_architect_cmd({ prompt = architect_prompt }, ctx)
        if cmd and #cmd > 0 then
            ctx.log(string.format("%s-Архитектор проектирует стек технологий и Nix-зависимости...", agent.name))
            local cres = ctx.capture(cmd, "/tmp")
            if cres and cres.code == 0 and cres.stdout and cres.stdout ~= "" then
                local cleaned_out = agent:clean_output(cres.stdout, cres.stderr)
                local raw_for_parse = (cleaned_out and cleaned_out ~= "") and cleaned_out or cres.stdout
                local parsed_plan = parse_architect_response(raw_for_parse)
                if parsed_plan then
                    if not plan.lang and parsed_plan.lang then
                        plan.lang = parsed_plan.lang
                    end
                    for _, p in ipairs(parsed_plan.special_dependencies or {}) do
                        table.insert(plan.special_dependencies, p)
                    end
                    plan.build = parsed_plan.build
                    plan.run = parsed_plan.run
                    plan.test = parsed_plan.test
                    plan.summary = parsed_plan.summary
                end
            end
        end
    end

    -- Если язык не определен, применяем эвристику языка
    if not plan.lang or plan.lang == "" then
        plan.lang = explicit or heuristic_stack_from_prompt(user_prompt)
    end

    -- Дедупликация и объединение пакетов
    local seen_pkgs = {}
    local final_pkgs = {}
    for _, p in ipairs(plan.special_dependencies) do
        if not seen_pkgs[p] then
            seen_pkgs[p] = true
            table.insert(final_pkgs, p)
        end
    end
    for _, p in ipairs(heur_pkgs) do
        if not seen_pkgs[p] then
            seen_pkgs[p] = true
            table.insert(final_pkgs, p)
        end
    end
    plan.special_dependencies = final_pkgs

    if not plan.summary or plan.summary == "" then
        if #plan.special_dependencies > 0 then
            plan.summary = string.format("Стек %s с библиотеками Nix: %s", plan.lang, table.concat(plan.special_dependencies, ", "))
        else
            plan.summary = string.format("Стандартный стек %s", plan.lang)
        end
    end

    return plan
end

--- Определение оптимального стека (возвращает lang и объект плана)
local function classify_stack(user_prompt, preferred_lang, preferred_agent)
    local plan = plan_app_stack(user_prompt, preferred_lang, nil, preferred_agent)
    return plan.lang, plan
end

--- Получение текущего дампа терминального контекста из StateBus или state.json
local function get_terminal_dump()
    local val = nil
    if grime and grime.bus and grime.bus.get then
        local ok, res = pcall(grime.bus.get, "daemon.terminal_dump")
        if ok and res ~= nil then
            val = res
        end
    end
    if val == nil then
        local dir = (ctx.config_dir and ctx.config_dir()) or ((os.getenv("HOME") or "") .. "/.config/grime")
        local sfile = dir .. "/state.json"
        if ctx.exists(sfile) then
            local content = grime.fs.read(sfile)
            if content and #content > 0 then
                local ok, data = pcall(grime.json.decode, content)
                if ok and type(data) == "table" and data["daemon.terminal_dump"] ~= nil then
                    val = data["daemon.terminal_dump"]
                end
            end
        end
    end
    if type(val) == "string" and (val:sub(1, 1) == "{" or val:sub(1, 1) == "[") then
        local ok, parsed = pcall(grime.json.decode, val)
        if ok and type(parsed) == "table" then
            val = parsed
        end
    end
    return val
end

--- Проверка актуальности терминального контекста по временной метке
local function is_term_data_fresh(term_data, max_age_seconds)
    if not term_data or type(term_data) ~= "table" then return false end
    local ts = tonumber(term_data.timestamp)
    if not ts then return false end
    max_age_seconds = max_age_seconds or 300
    return (os.time() - ts) <= max_age_seconds
end

--- Форматирование чистого блока контекста активного терминала
local function format_terminal_context(term_data)
    if not term_data or type(term_data) ~= "table" or not term_data.cmd then
        return nil
    end

    local parts = {
        "\n[КОНТЕКСТ АКТИВНОГО ТЕРМИНАЛА ПОЛЬЗОВАТЕЛЯ]:",
        string.format("- Последняя команда: %s", term_data.cmd),
        string.format("- Код возврата: %s%s", tostring(term_data.status or 0), (term_data.status and term_data.status ~= 0) and " [ОШИБКА]" or " [УСПЕХ]"),
        string.format("- Рабочая директория: %s", term_data.cwd or "."),
    }

    if term_data.time_str then
        table.insert(parts, string.format("- Время вызова: %s", term_data.time_str))
    end

    if term_data.resolved and term_data.resolved_target then
        table.insert(parts, string.format("- СТАТУС: Предыдущая ошибка команды '%s' была УСПЕШНО УСТРАНЕНА пользователем в последующем запуске. Проблема закрыта, повторно чинить её не нужно.", term_data.resolved_target))
    end

    if term_data.output and #term_data.output > 0 then
        table.insert(parts, "- Вывод/ошибка терминала:\n```\n" .. term_data.output .. "\n```")
    end

    table.insert(parts, TERMINAL_DIAGNOSTIC_RULES)
    return table.concat(parts, "\n")
end

--- Проверка, является ли директория частью Git-репозитория
local function is_git_repo(dir)
    if not dir or dir == "" then return false end
    if ctx.exists(dir .. "/.git") then
        return true
    end
    local res = ctx.capture({ "git", "-C", dir, "rev-parse", "--is-inside-work-tree" })
    if res.code == 0 and res.stdout and res.stdout:match("true") then
        return true
    end
    return false
end

--- Разрешение пути или проекта по имени
local function resolve_dir_or_project(arg)
    if not arg or arg == "" or arg:match("^%-") then
        return nil
    end

    -- 1. Проверяем, существует ли как директория на диске
    if ctx.is_dir(arg) then
        return arg
    end

    local norm_arg = ctx.normalize_path and ctx.normalize_path(arg)
    if norm_arg and ctx.is_dir(norm_arg) then
        return norm_arg
    end

    -- 2. Проверяем в projects_root
    local projects_root = utils.get_projects_root(ctx)
    if projects_root and ctx.exists(projects_root) then
        for _, lang in ipairs({ "cpp", "python", "rust", "java", "lua", "C++" }) do
            local cand = projects_root .. "/" .. lang .. "/" .. arg
            if ctx.is_dir(cand) then
                return cand
            end
        end
        local direct = projects_root .. "/" .. arg
        if ctx.is_dir(direct) then
            return direct
        end
    end

    -- 3. Проверяем в apps_root
    local apps_root = utils.get_apps_root(ctx)
    if apps_root and ctx.exists(apps_root) then
        local app_cand = apps_root .. "/" .. arg
        if ctx.is_dir(app_cand) then
            return app_cand
        end
    end

    return nil
end

--- Определение основного файла исходного кода по языку
local function get_entry_file_for_lang(lang, app_dir)
    local map = {
        python = "main.py",
        java   = "src/Main.java",
        rust   = "src/main.rs",
        lua    = "main.lua",
        bash   = "main.sh",
        fish   = "main.fish",
        cpp    = "src/main.cpp",
    }
    local cand = map[(lang or "python"):lower()] or "main.py"
    if app_dir and ctx.exists(app_dir .. "/" .. cand) then
        return cand
    end
    local fallbacks = {
        "main.py", "main.lua", "main.sh", "main.fish",
        "src/main.py", "src/Main.java", "src/main.rs", "src/main.lua", "src/main.cpp",
        "src/main.sh", "src/main.fish", "main.rs", "main.cpp", "Main.java",
    }
    for _, f in ipairs(fallbacks) do
        if app_dir and ctx.exists(app_dir .. "/" .. f) then
            return f
        end
    end
    return cand
end

--- Формирование блока требований для промпта ИИ-агента с учетом режима (Zero-Manifest или legacy app.lua)
local function build_app_dev_prompt(prompt, stack_lang, deps_desc, summary_desc, entry_file, app_dir, has_manifest)
    local manifest_block
    if has_manifest then
        manifest_block = string.format(
            "2. СИНХРОНИЗАЦИЯ FLAKE.NIX И APP.LUA (ОБЯЗАТЕЛЬНО):\n" ..
            "   - В манифесте `app.lua` поле `type = %q`, а в массиве `special_dependencies = { ... }` ОБЯЗАТЕЛЬНО должны быть перечислены все используемые библиотеки Nixpkgs.\n" ..
            "   - Проверь и при необходимости актуализируй поля `build`, `run`, `test` в `app.lua`.\n" ..
            "   - В `flake.nix` убедись, что все внешние библиотеки присутствуют в `buildInputs = with pkgs; [ ... ]`, а инструменты сборки — в `nativeBuildInputs = with pkgs; [ ... ]`.\n\n",
            stack_lang
        )
    else
        manifest_block =
            "2. ZERO-MANIFEST СТАНДАРТ И FLAKE.NIX (БЕЗ app.lua):\n" ..
            "   - Это приложение использует Zero-Manifest формат GRIME: НЕ создавай файл `app.lua`!\n" ..
            "   - Для скриптов сохраняй корректный shebang (`#!/usr/bin/env ...`) в первой строке и мета-комментарии `# description: ...` / `# nix: ...` при добавлении новых пакетов.\n" ..
            "   - В `flake.nix` убедись, что все внешние библиотеки присутствуют в `buildInputs = with pkgs; [ ... ]`, а инструменты сборки — в `nativeBuildInputs = with pkgs; [ ... ]`.\n\n"
    end

    return string.format(
        "%s\n\n[АРХИТЕКТУРНЫЙ ПЛАН И ТРЕБОВАНИЯ GRIME]:\n" ..
        "1. СТЕК И NIX-ЗАВИСИМОСТИ:\n" ..
        "   - Основной язык: %s (СТРОГО используй язык %s!).\n" ..
        "   - %s\n" ..
        "   - Архитектурное решение: %s\n\n" ..
        "%s" ..
        "3. РЕАЛИЗАЦИЯ И СБОРКА:\n" ..
        "   - Редактируй существующий исходный файл `%s` в директории `%s` (НЕ создавай дублирующих/лишних файлов!).\n" ..
        "   - Для C++: подключи библиотеки в `CMakeLists.txt` (find_package / pkg_check_modules и target_link_libraries).\n" ..
        "   - Для Rust: подключи зависимости в `Cargo.toml`.\n" ..
        "   - Убедись, что код компилируется и выполняется без ошибок в Nix-окружении (`nix develop`).",
        prompt, stack_lang, stack_lang, deps_desc, summary_desc, manifest_block, entry_file, app_dir
    )
end

--- Запуск ИИ-субагента для реализации приложения
local function run_dev(app_dir, prompt, app_name, lang, stack_plan, preferred_agent)
    local grime_bin = resolve_grime_bin()
    local stack_lang = lang or (stack_plan and stack_plan.lang) or (prompt and extract_lang_from_prompt(prompt)) or (app_name and extract_lang_from_prompt(app_name)) or "python"
    local entry_file = get_entry_file_for_lang(stack_lang, app_dir)

    if not stack_plan and prompt and prompt ~= "" then
        stack_plan = plan_app_stack(prompt, stack_lang, app_name, preferred_agent)
    end
    stack_plan = stack_plan or { lang = stack_lang, special_dependencies = {} }

    local special_deps = stack_plan.special_dependencies or {}
    local deps_desc = (#special_deps > 0)
        and ("Подключенные Nix-пакеты (Nixpkgs): " .. table.concat(special_deps, ", "))
        or "Сторонние Nix-пакеты: не требуются (используется базовый тулчейн)."

    local summary_desc = stack_plan.summary or string.format("Реализация микроприложения '%s' на %s", app_name or "app", stack_lang)
    local has_manifest = ctx.exists(app_dir .. "/app.lua")

    local function append_common_app_files(cmd)
        if preferred_agent and preferred_agent ~= "" then
            table.insert(cmd, "-agent")
            table.insert(cmd, preferred_agent)
        end
        if ctx.exists(app_dir .. "/" .. entry_file) then
            table.insert(cmd, entry_file)
        end
        if has_manifest then
            table.insert(cmd, "app.lua")
        end
        if ctx.exists(app_dir .. "/flake.nix") then
            table.insert(cmd, "flake.nix")
        end
    end

    if prompt and prompt ~= "" then
        local dev_prompt = build_app_dev_prompt(prompt, stack_lang, deps_desc, summary_desc, entry_file, app_dir, has_manifest)
        ctx.log(string.format("Запуск ИИ-субагента для реализации '%s' (стек: %s, файл: %s)...", app_name or "app", stack_lang, entry_file))
        if #special_deps > 0 then
            ctx.log(string.format("Переданы Nix-пакеты субагенту: %s", table.concat(special_deps, ", ")))
        end

        local cmd = { "timeout", "180", grime_bin, "ai" }
        append_common_app_files(cmd)
        local extra_build_files = { "CMakeLists.txt", "Cargo.toml", "pom.xml" }
        for _, bf in ipairs(extra_build_files) do
            if ctx.exists(app_dir .. "/" .. bf) then
                table.insert(cmd, bf)
            end
        end
        table.insert(cmd, "-m")
        table.insert(cmd, dev_prompt)
        local code = ctx.run_process(cmd, app_dir)
        if code ~= 0 then
            ctx.warn(string.format("ИИ-агент завершился с кодом %d (продолжаем с базовым шаблоном)", code))
        end

        pcall(function()
            local to_add = {}
            if ctx.exists(app_dir .. "/flake.nix") then table.insert(to_add, "flake.nix") end
            if ctx.exists(app_dir .. "/" .. entry_file) then table.insert(to_add, entry_file) end
            if ctx.exists(app_dir .. "/app.lua") then table.insert(to_add, "app.lua") end
            if #to_add > 0 then
                local gcmd = { "git", "add", "-N" }
                for _, f in ipairs(to_add) do table.insert(gcmd, f) end
                ctx.capture(gcmd, app_dir)
            end
        end)

        return code
    else
        ctx.log("Запуск интерактивной ИИ-сессии для проектирования приложения...")
        local cmd = { grime_bin, "ai" }
        append_common_app_files(cmd)
        return ctx.run_process(cmd, app_dir)
    end
end

--- Получение корня каталога приложений
local function get_apps_root()
    local root = utils.get_apps_root(ctx)
    if not ctx.exists(root) then
        ctx.mkdir_p(root)
    end
    return root
end

local SCRIPT_SCAFFOLD_PROFILES = {
    python = {
        filename = "main.py",
        shebang = "#!/usr/bin/env python3",
        comment = "#",
        body = [[def main():
    print("Hello from Python app!")


if __name__ == "__main__":
    main()
]],
    },
    lua = {
        filename = "main.lua",
        shebang = "#!/usr/bin/env luajit",
        comment = "--",
        body = [[local function main()
    print("Hello from LuaJIT app!")
end

main()
]],
    },
    bash = {
        filename = "main.sh",
        shebang = "#!/usr/bin/env bash",
        comment = "#",
        body = [[set -euo pipefail

main() {
    echo "Hello from Bash app!"
}

main "$@"
]],
    },
    fish = {
        filename = "main.fish",
        shebang = "#!/usr/bin/env fish",
        comment = "#",
        body = [[function main
    echo "Hello from Fish app!"
end

main $argv
]],
    },
}

--- Скаффолдинг структуры приложения с учетом стека и Nix-зависимостей (Zero-Manifest стандарт без app.lua)
local function scaffold_app(app_dir, app_name, lang, prompt, stack_plan)
    lang = utils.LANG_ALIASES[(lang or "python"):lower()] or (lang or "python"):lower()
    if not ctx.exists(app_dir) then
        ctx.mkdir_p(app_dir)
    end

    local raw_desc = (prompt and prompt ~= "") and prompt or ("Grime application " .. app_name)
    local clean_desc = raw_desc:gsub("[\r\n]+", " ")
    local spec_deps = (stack_plan and stack_plan.special_dependencies) or {}

    local script_prof = SCRIPT_SCAFFOLD_PROFILES[lang]
    if script_prof then
        -- Для скриптовых языков создаём только один главный файл в корне аппа
        local entry_path = app_dir .. "/" .. script_prof.filename
        if not ctx.exists(entry_path) then
            local lines = {
                script_prof.shebang,
                string.format("%s description: %s", script_prof.comment, clean_desc),
            }
            if #spec_deps > 0 then
                table.insert(lines, string.format("%s nix: %s", script_prof.comment, table.concat(spec_deps, ", ")))
            end
            if stack_plan and stack_plan.detached then
                table.insert(lines, string.format("%s detach: true", script_prof.comment))
            end
            table.insert(lines, "")
            table.insert(lines, script_prof.body)
            local f = io.open(entry_path, "w")
            if f then
                f:write(table.concat(lines, "\n"))
                f:close()
            end
        end
        ctx.capture({ "chmod", "+x", entry_path })
    else
        -- Для компилируемых языков (rust, cpp, java) создаём только минимально необходимые для сборки файлы
        ctx.mkdir_p(app_dir .. "/src")
        if lang == "cpp" then
            local cmake_file = app_dir .. "/CMakeLists.txt"
            if not ctx.exists(cmake_file) then
                local content = string.format([[cmake_minimum_required(VERSION 3.15)
project(%s)

set(CMAKE_CXX_STANDARD 20)

add_executable(%s src/main.cpp)
]], app_name, app_name)
                local f = io.open(cmake_file, "w")
                if f then f:write(content); f:close() end
            end
            local main_file = app_dir .. "/src/main.cpp"
            if not ctx.exists(main_file) then
                local content = string.format([[// description: %s
#include <iostream>

int main() {
    std::cout << "Hello from %s!" << std::endl;
    return 0;
}
]], clean_desc, app_name)
                local f = io.open(main_file, "w")
                if f then f:write(content); f:close() end
            end
        else
            local ok_adp, adp = pcall(require, "languages." .. lang)
            if ok_adp and adp and adp.create_default_files then
                adp:create_default_files(app_dir, ctx, clean_desc)
            end
        end
    end

    -- Автогенерация flake.nix с объединением базового тулчейна и специальных библиотек Nixpkgs
    local flake_path = app_dir .. "/flake.nix"
    if not ctx.is_file(flake_path) then
        local scan = scanner.scan_project(app_dir, ctx)
        local all_pkgs = {}
        for _, p in ipairs(scan.toolchain or {}) do
            table.insert(all_pkgs, p)
        end
        for _, p in ipairs(spec_deps) do
            table.insert(all_pkgs, p)
        end
        local native_pkgs, lib_pkgs = utils.split_packages(all_pkgs, scanner)
        local flake_content = utils.generate_flake_nix(app_name, native_pkgs, lib_pkgs)
        local ff = io.open(flake_path, "w")
        if ff then
            ff:write(flake_content)
            ff:close()
        end
    end

    if not ctx.exists(app_dir .. "/.git") then
        ctx.capture({ "git", "init" }, app_dir)
    end
    ctx.capture({ "git", "add", "-N", "." }, app_dir)
end

--- Определение путей к каталогам модулей GRIME (репозиторий, конфиг и dotfiles)
local function get_grime_modules_dirs()
    local home = os.getenv("HOME") or "/home/danny"
    local repo_dir = home .. "/Archive/_Programing_/rust/grime_pj/modules"
    local config_dir = ((ctx.config_dir and ctx.config_dir()) or (home .. "/.config/grime")) .. "/modules"
    local dotfiles_dir = home .. "/dotfiles/grime/modules"
    local primary = ctx.exists(repo_dir) and repo_dir or config_dir
    return primary, repo_dir, config_dir, dotfiles_dir
end

--- Автораспознавание запроса на создание/доработку модуля GRIME из текста промпта
local function detect_module_request(user_prompt, working_dir)
    local _, repo_mods, config_mods, _ = get_grime_modules_dirs()
    if working_dir then
        local norm_wd = utils.normalize_path(working_dir)
        if norm_wd == repo_mods or norm_wd == config_mods
            or norm_wd:find("/grime_pj/modules", 1, true)
            or norm_wd:find("/%.config/grime/modules")
            or norm_wd:find("/dotfiles/grime/modules", 1, true)
        then
            return true, nil
        end
    end

    if type(user_prompt) ~= "string" or user_prompt == "" then
        return false, nil
    end

    local low = utf8_lower(user_prompt)
    local module_triggers = {
        "модуль%s+([%a][%w_%-]*)",
        "модуля%s+([%a][%w_%-]*)",
        "модулю%s+([%a][%w_%-]*)",
        "module%s+([%a][%w_%-]*)",
    }

    local is_mod_intent = low:find("новый модуль")
        or low:find("допиши модуль")
        or low:find("напиши модуль")
        or low:find("создай модуль")
        or low:find("добавь модуль")
        or low:find("обнови модуль")
        or low:find("исправь модуль")
        or low:find("модуль grime")
        or low:find("grime module")

    if is_mod_intent then
        local stop_words = {
            grime = true, ["для"] = true, ["на"] = true, ["в"] = true,
            ["который"] = true, ["с"] = true, ["по"] = true, ["и"] = true,
            lua = true, luajit = true,
        }
        for _, pat in ipairs(module_triggers) do
            for cand in low:gmatch(pat) do
                if not stop_words[cand] then
                    return true, cand:gsub("%.lua$", "")
                end
            end
        end
        return true, nil
    end

    return false, nil
end

--- Генерация стартового каркаса нового модуля GRIME по стандарту (с нативным parse_args и utils)
local function scaffold_grime_module(mod_path, mod_name, prompt)
    if ctx.exists(mod_path) then
        return
    end
    local clean_desc = (prompt and prompt ~= "") and prompt:gsub("\n", " "):gsub('"', '\\"') or ("Модуль расширения Grime: " .. mod_name)
    local template = string.format([[-- Summary: %s
-- Description: %s
description = %q

local utils = require("languages.utils")

local ctx = grime.ctx
local ui = grime.ui
local ANSI = utils.ANSI

local ACTION_SYNONYMS = {
    ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["--ls"] = "list",
    ["-run"] = "run", ["--run"] = "run", ["-r"] = "run",
    ["-path"] = "path", ["--path"] = "path", ["-p"] = "path",
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
}

local function print_help()
    print(string.format(]] .. "[[" .. [[

%%s%%sGrime %s%%s — %s

%%sИСПОЛЬЗОВАНИЕ:%%s
    grime %s [-команда] [аргументы...]

%%sКОМАНДЫ И ФЛАГИ:%%s
    %%s-list, --list, -ls%%s     Показать список элементов
    %%s-run, --run, -r%%s        Выполнить основное действие модуля
    %%s-path, --path, -p%%s      Получить путь (для конвейеров)
    %%s-help, --help, -h%%s      Показать эту справку
]] .. "]]" .. [[,
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET
    ))
end

function main()
    local raw_args = ctx.args or {}
    for _, a in ipairs(raw_args) do
        if a == "-h" or a == "--help" or a == "-help" or a == "help" then
            print_help()
            return
        end
    end

    local parsed = ctx.parse_args({
        actions = ACTION_SYNONYMS,
        default_action = "run",
        flags = {
            help = { "-h", "--help", "-help", "help" },
            path = { "-p", "-path", "--path", "path" },
            force = { "-f", "-force", "--force" },
        },
    })
    if parsed.flags.help or parsed.action == "help" then
        print_help()
        return
    end

    local pipe_in = ctx.pipeline_input or ctx.input
    if parsed.action == "path" or parsed.flags.path then
        local target = ctx.target_dir or "."
        if ctx.set_target_dir then ctx.set_target_dir(target) end
        ctx.module_return(target)
        return
    end

    local result = (#parsed.args > 0 and table.concat(parsed.args, " ")) or pipe_in or "%s: ok"
    if ctx.has_next_step then
        ctx.module_return(result)
    else
        ui.ok(result)
    end
end

return {
    main = main,
    description = description,
}
]], clean_desc, clean_desc, clean_desc, mod_name, clean_desc, mod_name, mod_name)

    local f = io.open(mod_path, "w")
    if f then
        f:write(template)
        f:close()
        ctx.log(string.format("Создан базовый каркас модуля Grime по стандарту: %s", mod_path))
    end
end

--- Синхронизация подпапки *.lua файлов (languages/, agents/) между каталогами модулей
local function sync_lua_subdir(subdir, source_root, target_roots)
    if not source_root or not ctx.is_dir(source_root .. "/" .. subdir) then
        return
    end
    local src_sub = source_root .. "/" .. subdir
    local entries = (grime and grime.fs and grime.fs.list) and grime.fs.list(src_sub) or {}
    for _, fname in ipairs(entries) do
        if fname:match("%.lua$") then
            local src_file = utils.normalize_path(src_sub .. "/" .. fname)
            if ctx.is_file(src_file) then
                for _, dst_root in ipairs(target_roots) do
                    if dst_root and ctx.exists(dst_root) then
                        local dst_sub = utils.normalize_path(dst_root .. "/" .. subdir)
                        local dst_file = utils.normalize_path(dst_sub .. "/" .. fname)
                        if src_file ~= dst_file then
                            pcall(ctx.mkdir_p, dst_sub)
                            pcall(ctx.copy, src_file, dst_file)
                        end
                    end
                end
            end
        end
    end
end

--- Валидация байткода модуля через luajit -bl и синхронизация между репозиторием, ~/.config/grime/modules и ~/dotfiles/grime/modules
local function validate_and_sync_module(mod_path)
    if not mod_path or not ctx.is_file(mod_path) then return true end
    if utils.has_binary("luajit", ctx) then
        local vres = ctx.capture({ "luajit", "-bl", mod_path })
        if vres.code ~= 0 then
            ctx.warn(string.format("Предупреждение: ошибка синтаксиса LuaJIT в %s:\n%s", mod_path, vres.stderr or ""))
            return false
        end
        ctx.log(string.format("✓ Синтаксис модуля '%s' успешно проверен (luajit -bl).", mod_path))
    end

    local primary_mods, repo_mods, config_mods, dotfiles_mods = get_grime_modules_dirs()
    local target_roots = { repo_mods, config_mods, dotfiles_mods }
    local norm_src = utils.normalize_path(mod_path)

    -- Поддержка относительных путей внутри modules/ (включая agents/*.lua и languages/*.lua)
    local rel = norm_src:match("/modules/(.+%.lua)$") or norm_src:match("([^/]+%.lua)$")
    if rel then
        for _, dst_root in ipairs(target_roots) do
            if dst_root and ctx.exists(dst_root) then
                local dst_target = utils.normalize_path(dst_root .. "/" .. rel)
                if norm_src ~= dst_target then
                    local parent_dir = dst_target:match("^(.+)/[^/]+$")
                    if parent_dir and parent_dir ~= "" then
                        pcall(ctx.mkdir_p, parent_dir)
                    end
                    pcall(ctx.copy, norm_src, dst_target)
                end
            end
        end
    end

    -- Синхронизация подпапок languages/*.lua и agents/*.lua
    sync_lua_subdir("languages", primary_mods, target_roots)
    sync_lua_subdir("agents", primary_mods, target_roots)

    return true
end

--- Проверка безопасности команд перед исполнением
local function validate_command_security(cmd_str, target_dir)
    if not cmd_str or cmd_str == "" then
        return false, "[Grime Security] Команда отклонена: пустая команда."
    end

    -- Запрет subshell-инъекций $(...) и `...`
    if cmd_str:find("%$%(") or cmd_str:find("`") then
        return false, "[Grime Security] Команда отклонена: инъекции подоболочек $(...) и `...` запрещены."
    end

    local lower = " " .. cmd_str:lower() .. " "
    local normalized = lower:gsub("[|&;()<>]", " ")

    -- 1. БЕЗУСЛОВНЫЙ ЗАПРЕТ SUDO / ПОВЫШЕНИЯ ПРИВИЛЕГИЙ
    if normalized:match("%s+sudo%s+")
        or normalized:match("%s+su%s+")
        or normalized:match("%s+doas%s+")
        or normalized:match("%s+pkexec%s+")
        or normalized:match("%s+chown%s+.*root")
        or normalized:match("%s+chmod%s+.*%s+/")
        or normalized:match("%s+chmod%s+777") then
        return false, "[Grime Security] Команда отклонена: вызовы с правами суперпользователя (sudo) запрещены."
    end

    -- 2. ЗАПРЕТ ОПАСНЫХ ШАБЛОНОВ
    if normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+/%s*$")
        or normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+/%*")
        or normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+~")
        or normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+%$home")
        or normalized:match("%f[%a]mkfs%f[%A]")
        or normalized:match("%f[%a]fdisk%f[%A]")
        or normalized:match("%f[%a]parted%f[%A]")
        or normalized:match("%f[%a]dd%s+.*of=%s*/dev/")
        or lower:match(">+%s*/dev/[a-z0-9]") then
        return false, "[Grime Security] Команда отклонена: обнаружен опасный деструктивный шаблон."
    end

    -- 3. БЕЗУСЛОВНЫЙ ЗАПРЕТ НА ИЗМЕНЕНИЕ СИСТЕМНЫХ ФАЙЛОВ И PATH TRAVERSAL
    local home = os.getenv("HOME") or "/home/danny"
    local sys_dirs = { "/etc", "/usr", "/var", "/boot", "/opt", "/root", "/nix", "/sys", "/proc", "/dev", "/bin", "/sbin", "/lib", "/lib64" }

    local eff_cwd = utils.normalize_path(target_dir or (os.getenv("PWD") or home))
    for _, sdir in ipairs(sys_dirs) do
        if eff_cwd == "/" or eff_cwd == sdir or eff_cwd:sub(1, #sdir + 1) == (sdir .. "/") then
            return false, "[Grime Security] Команда отклонена: попытка модификации системных файлов за пределами домашней директории."
        end
    end

    for token in cmd_str:gmatch("[^%s|;&()]+") do
        local clean = token:gsub("^['\"]+", ""):gsub("['\"]+$", ""):gsub("^>+", "")
        if clean:sub(1, 2) == "~/" then
            clean = home .. clean:sub(2)
        end
        local resolved_path = nil
        if clean:sub(1, 1) == "/" then
            resolved_path = utils.normalize_path(clean)
        elseif clean:find("%.%.") then
            resolved_path = utils.normalize_path(eff_cwd .. "/" .. clean)
        end

        if resolved_path then
            local in_home = (resolved_path == home) or (resolved_path:sub(1, #home + 1) == (home .. "/"))
            local in_tmp = (resolved_path == "/tmp") or (resolved_path:sub(1, 5) == "/tmp/")
            if not in_home and not in_tmp then
                if resolved_path == "/" then
                    return false, "[Grime Security] Команда отклонена: попытка доступа к корневой директории."
                end
                for _, sdir in ipairs(sys_dirs) do
                    if resolved_path == sdir or resolved_path:sub(1, #sdir + 1) == (sdir .. "/") then
                        return false, "[Grime Security] Команда отклонена: попытка модификации системных файлов за пределами домашней директории."
                    end
                end
            end
        end
    end

    return true, nil
end

--- Выполнение системного действия с информированием и валидацией безопасности
local function execute_ai_action(cmd_str, target_dir, _source_tag)
    cmd_str = cmd_str:match("^%s*(.-)%s*$")
    if not cmd_str or cmd_str == "" then
        return false
    end

    -- Нормализация soft-wrap консольного вывода: склеиваем строки, разорванные форматированием
    local clean_lines = {}
    for line in cmd_str:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(clean_lines, trimmed)
        end
    end

    local normalized_cmd = ""
    for i, line in ipairs(clean_lines) do
        if i == 1 then
            normalized_cmd = line
        else
            local prev_ends_with_op = normalized_cmd:match("[;&|]$") or normalized_cmd:match("&&$") or normalized_cmd:match("\\$")
            local is_continuation = line:match("^[%-~/%.]") or (not prev_ends_with_op and not line:match("^[%a_][%w_]*%s"))
            if is_continuation and not prev_ends_with_op then
                normalized_cmd = normalized_cmd .. " " .. line
            else
                normalized_cmd = normalized_cmd .. "\n" .. line
            end
        end
    end
    cmd_str = normalized_cmd

    local ok, err_msg = validate_command_security(cmd_str, target_dir)
    if not ok then
        ctx.warn(err_msg)
        return false, err_msg
    end

    io.stdout:write(string.format("\27[1;32m[Grime AI Execution] Выполняю действие: %s\27[0m\n", cmd_str))
    ctx.log(string.format("[Grime AI Execution] Выполняю действие: %s (cwd=%s)", cmd_str, target_dir or "."))

    local home = os.getenv("HOME") or "/home/danny"
    local shell_cmd = cmd_str:gsub("~/", home .. "/")

    if target_dir then
        local folder_name = target_dir:match("([^/]+)$")
        if folder_name and folder_name ~= "" then
            local prefix_pattern = "%f[%w]" .. folder_name .. "/"
            if shell_cmd:find(prefix_pattern) then
                shell_cmd = shell_cmd:gsub(prefix_pattern, "")
            end
        end
    end

    local res = ctx.capture({ "sh", "-c", shell_cmd }, target_dir)
    if res.stdout and res.stdout ~= "" then
        io.stdout:write(res.stdout)
        if not res.stdout:match("\n$") then
            io.stdout:write("\n")
        end
    end
    if res.stderr and res.stderr ~= "" then
        io.stderr:write(res.stderr)
        if not res.stderr:match("\n$") then
            io.stderr:write("\n")
        end
    end

    if res.code == 0 then
        ctx.log(string.format("✓ Действие успешно выполнено: %s", cmd_str))
        return true, nil
    else
        local fail_msg = string.format("Действие завершилось с кодом %d: %s", res.code, res.stderr or "")
        ctx.warn(fail_msg)
        return false, fail_msg
    end
end

--- Парсинг вывода ИИ-агента с поддержкой тегов <grime_bus>, <grime_spawn>, <grime_exec>/<grime_action> и <next_agent_prompt>
local function parse_ai_tags(output, working_dir, _user_prompt)
    if not output or output == "" then
        return nil
    end

    -- 1. Обработка тегов <grime_bus key="..." [type="json"]>...</grime_bus>
    for open_tag, content in output:gmatch("<grime_bus(.-)>(.-)</grime_bus>") do
        local key = open_tag:match('key%s*=%s*"([^"]+)"') or open_tag:match("key%s*=%s*'([^']+)'")
        local b_type = open_tag:match('type%s*=%s*"([^"]+)"') or open_tag:match("type%s*=%s*'([^']+)'")
        if key and key ~= "" then
            if not key:find("%.") then
                key = "user." .. key
            end
            local raw_val = content:match("^%s*(.-)%s*$")
            local val = raw_val
            if b_type == "json" or raw_val:match("^[%[{]") then
                local decoded = grime.json.decode(raw_val)
                if decoded ~= nil then
                    val = decoded
                end
            end
            if grime and grime.bus and grime.bus.set then
                local ok, err = pcall(function() grime.bus.set(key, val) end)
                if ok then
                    ctx.log(string.format("Шина grime.bus: сохранено значение по ключу '%s'", key))
                else
                    ctx.warn(string.format("Ошибка сохранения в grime.bus по ключу '%s': %s", key, tostring(err)))
                end
            end
        end
    end

    -- 2. Обработка тегов <grime_exec [cwd="..."]>...</grime_exec> и <grime_action [cwd="..."]>...</grime_action>
    for _, tag_name in ipairs({ "grime_exec", "grime_action" }) do
        local pattern = "<" .. tag_name .. "(.-)>(.-)</" .. tag_name .. ">"
        for open_tag, exec_content in output:gmatch(pattern) do
            local target_cwd = open_tag:match('cwd%s*=%s*"([^"]+)"') or open_tag:match("cwd%s*=%s*'([^']+)'") or working_dir
            target_cwd = ctx.normalize_path(target_cwd)
            local cmd_str = exec_content:match("^%s*(.-)%s*$")
            if cmd_str and cmd_str ~= "" then
                execute_ai_action(cmd_str, target_cwd, tag_name)
            end
        end
    end

    -- 3. Обработка тегов <grime_spawn module="..." [cwd="..."]>...</grime_spawn>
    local grime_bin = resolve_grime_bin()

    for open_tag, spawn_content in output:gmatch("<grime_spawn(.-)>(.-)</grime_spawn>") do
        local target_mod = open_tag:match('module%s*=%s*"([^"]+)"') or open_tag:match("module%s*=%s*'([^']+)'")
        local target_cwd = open_tag:match('cwd%s*=%s*"([^"]+)"') or open_tag:match("cwd%s*=%s*'([^']+)'")
        target_cwd = target_cwd or working_dir

        local prompt = spawn_content:match("^%s*(.-)%s*$")
        if target_mod and target_mod ~= "" then
            target_cwd = ctx.normalize_path(target_cwd)

            if target_mod == "cmd" then
                execute_ai_action(prompt, target_cwd, "grime_spawn")
            else
                ctx.log(string.format("Порождение субагента Grime: модуль '%s', cwd='%s'...", target_mod, target_cwd))

                local spawn_cmd = { grime_bin, target_mod }
                if prompt ~= "" then
                    if target_mod == "ai" then
                        table.insert(spawn_cmd, "-m")
                        table.insert(spawn_cmd, prompt)
                    else
                        for tok in prompt:gmatch("%S+") do
                            table.insert(spawn_cmd, tok)
                        end
                    end
                end

                local sres = ctx.capture(spawn_cmd, target_cwd)
                if sres.code == 0 then
                    ctx.log(string.format("✓ Субагент '%s' успешно завершил работу.", target_mod))
                    if sres.stdout and sres.stdout ~= "" then
                        parse_ai_tags(sres.stdout, target_cwd, prompt)
                    end
                else
                    ctx.warn(string.format("Субагент '%s' завершился с кодом %d: %s", target_mod, sres.code, sres.stderr))
                end
            end
        end
    end

    -- 4. Извлечение мастер-промпта следующего шага
    local next_prompt = output:match("<next_agent_prompt>(.-)</next_agent_prompt>")
    if next_prompt then
        local extracted = next_prompt:match("^%s*(.-)%s*$")
        ctx.log("Извлечен мастер-промпт для следующего шага конвейера (<next_agent_prompt>).")
        return extracted
    end

    return nil
end

--- Компактный микро-рендерер Markdown для стилизации вывода ИИ-агента в терминале
local function render_terminal_markdown(text)
    if not text or text == "" then return text end
    local lines, in_code = {}, false

    local function inline_fmt(s)
        s = s:gsub("`([^`]+)`", "\27[38;5;222m%1\27[0m")
        s = s:gsub("%*%*([^*]+)%*%*", "\27[1m%1\27[22m")
        s = s:gsub("%*([^*]+)%*", "\27[3m%1\27[23m")
        s = s:gsub("(%s)_([^_]+)_(%p?)", "%1\27[3m%2\27[23m%3")
        return s
    end

    for line in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if in_code then
            if line:match("^%s*```") then
                in_code = false
                table.insert(lines, "\27[90m└────────────────────────────────────────\27[0m")
            else
                table.insert(lines, line == "" and "\27[90m│\27[0m" or ("\27[90m│\27[0m \27[38;5;223m" .. line .. "\27[0m"))
            end
        else
            local lang = line:match("^%s*```([%w_%-+#]*)")
            if lang ~= nil then
                in_code = true
                table.insert(lines, string.format("\27[90m┌── [ \27[1;36m%s\27[0;90m ] ──────────────────────\27[0m", lang ~= "" and lang or "code"))
            elseif line:match("^%s*%-%-%-%s*$") then
                table.insert(lines, "\27[90m────────────────────────────────────────\27[0m")
            elseif line:match("^%s*###%s+") then
                table.insert(lines, "\27[1;32m### " .. inline_fmt(line:gsub("^%s*###%s+", "")) .. "\27[0m")
            elseif line:match("^%s*##%s+") then
                table.insert(lines, "\27[1;34m## " .. inline_fmt(line:gsub("^%s*##%s+", "")) .. "\27[0m")
            elseif line:match("^%s*#%s+") then
                table.insert(lines, "\27[1;36m# " .. inline_fmt(line:gsub("^%s*#%s+", "")) .. "\27[0m")
            elseif line:match("^%s*>%s?") then
                table.insert(lines, "  \27[90m│\27[0m \27[3m" .. inline_fmt(line:gsub("^%s*>%s?", "")) .. "\27[0m")
            elseif line:match("^%s*[%-%*]%s+") then
                local indent, content = line:match("^(%s*)[%-%*]%s+(.*)")
                table.insert(lines, string.format("%s  \27[36m•\27[0m %s", indent or "", inline_fmt(content or "")))
            elseif line:match("^%s*%d+%.%s+") then
                local indent, num, content = line:match("^(%s*)(%d+)%.%s+(.*)")
                table.insert(lines, string.format("%s  \27[33m%s.\27[0m %s", indent or "", num or "1", inline_fmt(content or "")))
            else
                table.insert(lines, inline_fmt(line))
            end
        end
    end
    if in_code then table.insert(lines, "\27[90m└────────────────────────────────────────\27[0m") end
    return table.concat(lines, "\n")
end

local function print_help()
    local available = agents.list_available(ctx)
    local avail_names = {}
    for _, ag in ipairs(available) do
        table.insert(avail_names, ag.name)
    end
    local avail_str = (#avail_names > 0) and table.concat(avail_names, ", ") or "не найдены в $PATH"

    print(string.format([[
%s%sGrime AI%s — Универсальный ИИ-оркестратор агентов (Claude Code, Aider)

%sИСПОЛЬЗОВАНИЕ:%s
    grime ai [-claude|-aider|-agent <имя>] [путь_или_проект] [файлы...] [промпт...]
    grime ai [опции] -m "сообщение"
    grime ai -app <имя> [-lang <язык>] [промпт...]
    grime ai -module <имя_модуля> [промпт...]
    grime <модуль_с_контекстом> : ai [опции] [файлы...] [промпт...]

%sРЕЖИМЫ РАБОТЫ:%s
    %sИнтерактивный%s         grime ai [-claude|-aider] [проект] [файлы...]
    %sHeadless (-m)%s         grime ai -claude -m "Добавь тесты для функции парсинга"
    %sСоздание приложения%s   grime ai -app MyTool -lang python "CLI утилита"
    %sРазработка модуля%s     grime ai -mod mymod "Модуль мониторинга"
    %sКонвейерный%s           grime project -path MyProj : ai -aider "Рефакторинг CMake"

%sВЫБОР АГЕНТА И ПРАВ (стандарт со знаком минус):%s
    %s-claude, --claude%s              Использовать адаптер Claude Code
    %s-aider, --aider%s                Использовать адаптер Aider
    %s-agent, --agent <имя>%s          Явно указать агента (claude, aider)
    %s-perm, --permission-mode <m>%s   Режим разрешений Claude (acceptEdits, bypassPermissions, plan...)
    %s-y, --yes%s                      Автоподтверждение действий (--yes-always / bypassPermissions)

%sОСНОВНЫЕ ФЛАГИ:%s
    %s-a, -app, --app <name>%s         Создание и скаффолдинг приложения Grime App
    %s-mod, -module, --module <m>%s    Создание или доработка модуля Grime по стандарту
    %s-l, -lang, --lang <lang>%s       Явный выбор языка (python, java, rust, cpp, lua, bash, fish)
    %s-m, -message, --message <msg>%s  Сообщение / промпт для неинтерактивного (headless) режима
    %s-model, --model <model>%s        Модель LLM (например, sonnet, opus, gpt-4o)
    %s--read <file>%s                  Подключить read-only файл контекста
    %s--add-dir <dir>%s                Предоставить агенту доступ к дополнительной директории
    %s-h, -help, --help%s              Показать эту справку

%sДОСТУПНЫЕ АГЕНТЫ В СИСТЕМЕ:%s %s
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m", avail_str
    ))
end

local LANG_ALIASES = utils.LANG_ALIASES or {
    cpp = "cpp", ["c++"] = "cpp", cxx = "cpp", c = "cpp",
    python = "python", py = "python", python3 = "python",
    rust = "rust", rs = "rust",
    java = "java", jav = "java",
    lua = "lua", luajit = "lua",
    bash = "bash", sh = "bash", shell = "bash",
    fish = "fish",
}

local function append_unique(list, seen, val)
    if type(val) == "string" and val ~= "" and not seen[val] then
        seen[val] = true
        table.insert(list, val)
    end
end

function main()
    local raw_cli_args = {}
    for _, a in ipairs(ctx.args or {}) do
        table.insert(raw_cli_args, a)
    end

    local first_arg = raw_cli_args[1]
    if (#raw_cli_args == 0 and not ctx.pipeline_input and not ctx.input)
        or first_arg == "-h" or first_arg == "--help" or first_arg == "-help"
    then
        print_help()
        return
    end
    for _, a in ipairs(raw_cli_args) do
        if a == "--" or a == "//" then
            break
        end
        if a == "-h" or a == "--help" or a == "-help" then
            print_help()
            return
        end
    end

    local before_sep, after_sep, has_sep = grime.args.split_passthrough(raw_cli_args)

    local target_dir = nil
    local incoming_pipeline_text = nil

    -- Режимы и опции модуля ai
    local is_app_mode = false
    local app_name = nil
    local app_lang = nil
    local app_dir = nil

    local is_module_mode = false
    local module_name = nil
    local target_module_file = nil

    local preferred_agent = nil
    local permission_mode = nil
    local yes_flag = false
    local model = nil
    local explicit_git = nil
    local allowed_tools = nil

    local read_files = {}
    local read_files_seen = {}
    local read_dirs = {}
    local read_dirs_seen = {}
    local passthrough_args = {}

    local remaining_args = {}

    local passthrough_value_flags = {
        ["--openai-api-key"] = true,
        ["--anthropic-api-key"] = true,
        ["--editor"] = true,
        ["--encoding"] = true,
        ["--chat-history-file"] = true,
        ["--restore-chat-history-file"] = true,
        ["--input-history-file"] = true,
        ["--voice-input-device"] = true,
        ["--message-file"] = true,
        ["--load"] = true,
        ["--commit-prompt"] = true,
        ["-c"] = true,
        ["--effort"] = true,
        ["--fallback-model"] = true,
        ["--max-budget-usd"] = true,
        ["--mcp-config"] = true,
        ["--settings"] = true,
        ["--system-prompt"] = true,
        ["--tools"] = true,
    }

    -- 1. Разбор флагов до разделителя -- / // (строгий дефисный стандарт)
    local idx = 1
    while idx <= #before_sep do
        local a = before_sep[idx]
        local eq_flag, eq_val = a:match("^(%-[%w_%-]+)=(.+)$")
        if eq_flag then
            if eq_flag == "-l" or eq_flag == "-lang" or eq_flag == "--lang" then
                app_lang = LANG_ALIASES[eq_val:lower()] or eq_val:lower()
            elseif eq_flag == "-app" or eq_flag == "--app" or eq_flag == "-a" then
                is_app_mode = true
                app_name = eq_val
            elseif eq_flag == "-mod" or eq_flag == "--mod" or eq_flag == "-module" or eq_flag == "--module" then
                is_module_mode = true
                module_name = eq_val:gsub("%.lua$", "")
            elseif eq_flag == "-agent" or eq_flag == "--agent" then
                preferred_agent = eq_val
            elseif eq_flag == "-perm" or eq_flag == "--perm" or eq_flag == "-permission-mode" or eq_flag == "--permission-mode" then
                permission_mode = eq_val
            elseif eq_flag == "-model" or eq_flag == "--model" then
                model = eq_val
            elseif eq_flag == "-m" or eq_flag == "-message" or eq_flag == "--message" then
                table.insert(remaining_args, "-m")
                table.insert(remaining_args, eq_val)
            elseif eq_flag == "-read" or eq_flag == "--read" then
                append_unique(read_files, read_files_seen, eq_val)
            elseif eq_flag == "-add-dir" or eq_flag == "--add-dir" then
                append_unique(read_dirs, read_dirs_seen, eq_val)
            elseif eq_flag == "--allowedTools" or eq_flag == "--allowed-tools" or eq_flag == "-allowedTools" then
                allowed_tools = eq_val
            else
                table.insert(passthrough_args, a)
            end
        elseif a == "-claude" or a == "--claude" or a == "-claude-code" or a == "--claude-code" or a == "-cc" or a == "--cc" then
            preferred_agent = "claude"
        elseif a == "-aider" or a == "--aider" then
            preferred_agent = "aider"
        elseif a == "-agent" or a == "--agent" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                preferred_agent = before_sep[idx]
            else
                ctx.fail("Флаг " .. a .. " требует имя агента (claude или aider)")
                return
            end
        elseif a == "-perm" or a == "--perm" or a == "-permission-mode" or a == "--permission-mode" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                permission_mode = before_sep[idx]
            else
                ctx.fail("Флаг " .. a .. " требует значение режима разрешений")
                return
            end
        elseif a == "-y" or a == "--yes" or a == "--yes-always" then
            yes_flag = true
        elseif a == "--app" or a == "-app" or a == "-a" then
            is_app_mode = true
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                app_name = before_sep[idx]
            end
        elseif a == "--module" or a == "-module" or a == "--mod" or a == "-mod" then
            is_module_mode = true
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                module_name = before_sep[idx]:gsub("%.lua$", "")
            end
        elseif a == "--lang" or a == "-lang" or a == "-l" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                local raw_l = before_sep[idx]:lower()
                app_lang = LANG_ALIASES[raw_l] or raw_l
            end
        elseif a == "-model" or a == "--model" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                model = before_sep[idx]
            end
        elseif a == "-read" or a == "--read" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                append_unique(read_files, read_files_seen, before_sep[idx])
            end
        elseif a == "-add-dir" or a == "--add-dir" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                append_unique(read_dirs, read_dirs_seen, before_sep[idx])
            end
        elseif a == "--allowedTools" or a == "--allowed-tools" or a == "-allowedTools" then
            if idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                allowed_tools = before_sep[idx]
            end
        elseif a == "--git" then
            explicit_git = true
        elseif a == "--no-git" then
            explicit_git = false
        elseif a == "-m" or a == "--message" or a == "-message" then
            table.insert(remaining_args, "-m")
        elseif a:match("^%-") then
            table.insert(passthrough_args, a)
            if passthrough_value_flags[a] and idx + 1 <= #before_sep and not before_sep[idx + 1]:match("^%-") then
                idx = idx + 1
                table.insert(passthrough_args, before_sep[idx])
            end
        else
            table.insert(remaining_args, a)
        end
        idx = idx + 1
    end

    if has_sep and type(after_sep) == "table" then
        for _, tok in ipairs(after_sep) do
            table.insert(passthrough_args, tok)
        end
    end

    -- 2. Режим создания приложения (-app)
    local user_message = ""
    local files = {}
    local files_seen = {}

    if is_app_mode then
        if not app_name or app_name == "" then
            ctx.fail("Укажите имя приложения: grime ai -app <app_name> [-lang <lang>] [prompt]")
            return
        end

        local apps_root = get_apps_root()
        app_dir = apps_root .. "/" .. app_name
        target_dir = app_dir

        local collected_prompt = {}
        for _, arg in ipairs(remaining_args) do
            if arg ~= "-m" then
                table.insert(collected_prompt, arg)
            end
        end
        local user_prompt = table.concat(collected_prompt, " ")

        local prompt_lang = extract_lang_from_prompt(user_prompt) or extract_lang_from_prompt(app_name)
        local explicit = prompt_lang or app_lang
        local stack_plan = plan_app_stack(user_prompt, explicit, app_name, preferred_agent)
        local final_lang = stack_plan.lang or explicit or "python"

        ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, final_lang))
        if #stack_plan.special_dependencies > 0 then
            ctx.log(string.format("Архитектор подключил зависимости Nix: %s", table.concat(stack_plan.special_dependencies, ", ")))
        end

        scaffold_app(app_dir, app_name, final_lang, user_prompt, stack_plan)
        local entry_file = get_entry_file_for_lang(final_lang, app_dir)

        if user_prompt ~= "" then
            local special_deps = stack_plan.special_dependencies or {}
            local deps_desc = (#special_deps > 0)
                and ("Подключенные Nix-пакеты (Nixpkgs): " .. table.concat(special_deps, ", "))
                or "Сторонние Nix-пакеты: не требуются (базовый тулчейн)."

            local has_manifest = ctx.exists(app_dir .. "/app.lua")
            user_message = build_app_dev_prompt(
                user_prompt, final_lang, deps_desc, stack_plan.summary or "", entry_file, app_dir, has_manifest
            )
        end
    end

    -- 3. Входные данные из конвейера
    local pipe_in = ctx.input or ctx.pipeline_input
    if pipe_in then
        local raw = pipe_in:match("^%s*(.-)%s*$")
        if ctx.is_dir(raw) then
            target_dir = raw
        elseif ctx.exists(raw) then
            target_dir = ctx.target_dir
        else
            incoming_pipeline_text = raw
        end
    end

    -- 4. Разрешение пути или имени проекта из первого позиционного аргумента (вне режимов -app / -module)
    if not is_app_mode and not is_module_mode and #remaining_args > 0 and not target_dir then
        local first_rem = remaining_args[1]
        if first_rem ~= "-m" then
            local resolved = resolve_dir_or_project(first_rem)
            if resolved then
                target_dir = resolved
                table.remove(remaining_args, 1)
            end
        end
    end

    local working_dir = ctx.normalize_path(target_dir or ctx.target_dir)

    -- 5. Разбор файлов и промпта из remaining_args (если не в режиме -app)
    if not is_app_mode then
        local msg_flag_idx = nil
        for i, arg in ipairs(remaining_args) do
            if arg == "-m" then
                msg_flag_idx = i
                break
            end
        end

        if msg_flag_idx then
            local collected = {}
            for i = msg_flag_idx + 1, #remaining_args do
                if remaining_args[i] ~= "-m" then
                    table.insert(collected, remaining_args[i])
                end
            end
            user_message = table.concat(collected, " ")

            -- Файлы, переданные позиционно до -m
            for i = 1, msg_flag_idx - 1 do
                local tok = remaining_args[i]
                if ctx.is_file(tok) or ctx.is_file(working_dir .. "/" .. tok) then
                    append_unique(files, files_seen, tok)
                end
            end
        elseif #remaining_args > 0 then
            local prompt_tokens = {}
            local found_prompt = false
            for _, tok in ipairs(remaining_args) do
                if found_prompt then
                    table.insert(prompt_tokens, tok)
                else
                    local is_file = ctx.is_file(tok) or ctx.is_file(working_dir .. "/" .. tok)
                    if is_file then
                        append_unique(files, files_seen, tok)
                    else
                        found_prompt = true
                        table.insert(prompt_tokens, tok)
                    end
                end
            end
            if #prompt_tokens > 0 then
                user_message = table.concat(prompt_tokens, " ")
            end
        end
    end

    -- 6. Режим создания/доработки модуля GRIME (-module или автодетект по тексту промпта)
    if not is_app_mode then
        local auto_mod, detected_mod_name = detect_module_request(user_message, working_dir)
        if auto_mod then
            is_module_mode = true
            if not module_name and detected_mod_name then
                module_name = detected_mod_name
            end
        end
    end

    local primary_mods_dir = get_grime_modules_dirs()
    if is_module_mode then
        if not target_dir then
            working_dir = primary_mods_dir
            target_dir = primary_mods_dir
        end
        if module_name and module_name ~= "" then
            target_module_file = primary_mods_dir .. "/" .. module_name .. ".lua"
            scaffold_grime_module(target_module_file, module_name, user_message)
            append_unique(files, files_seen, target_module_file)
        end

        -- Подключаем общие библиотеки и директории адаптеров для переиспользования
        local shared_read_files = {
            primary_mods_dir .. "/languages/utils.lua",
            primary_mods_dir .. "/languages/base.lua",
        }
        for _, rf in ipairs(shared_read_files) do
            if ctx.is_file(rf) then
                append_unique(read_files, read_files_seen, rf)
            end
        end

        for _, sub in ipairs({ "languages", "agents" }) do
            local sub_path = primary_mods_dir .. "/" .. sub
            if ctx.is_dir(sub_path) then
                append_unique(read_dirs, read_dirs_seen, sub_path)
            end
        end
    elseif #files == 0 and ((target_dir and ctx.exists(target_dir)) or (working_dir and (
        ctx.is_file(working_dir .. "/app.lua")
        or ctx.is_file(working_dir .. "/flake.nix")
        or ctx.is_file(working_dir .. "/main.py")
        or ctx.is_file(working_dir .. "/main.lua")
        or ctx.is_file(working_dir .. "/main.sh")
        or ctx.is_file(working_dir .. "/main.fish")
    ))) then
        -- Автоподключение файлов проекта/приложения по умолчанию
        local entry_candidates = {
            "main.py", "main.lua", "main.sh", "main.fish",
            "src/main.py", "src/Main.java", "src/main.rs", "src/main.lua", "src/main.cpp",
            "src/main.sh", "src/main.fish", "main.rs", "main.cpp", "Main.java",
        }
        for _, c in ipairs(entry_candidates) do
            if ctx.exists(working_dir .. "/" .. c) then
                append_unique(files, files_seen, c)
                break
            end
        end
        if ctx.is_file(working_dir .. "/app.lua") then
            append_unique(files, files_seen, "app.lua")
        end
        local build_candidates = { "flake.nix", "Cargo.toml", "CMakeLists.txt", "pom.xml", "pyproject.toml" }
        for _, bc in ipairs(build_candidates) do
            if ctx.exists(working_dir .. "/" .. bc) then
                append_unique(files, files_seen, bc)
            end
        end
    end

    -- 7. Формирование итогового промпта с учетом входа конвейера
    local final_msg = nil
    if incoming_pipeline_text and incoming_pipeline_text ~= "" then
        if user_message and user_message ~= "" then
            final_msg = string.format("Контекст от предыдущего шага:\n```\n%s\n```\n\nТекущая задача:\n%s", incoming_pipeline_text, user_message)
        else
            final_msg = incoming_pipeline_text
        end
    elseif user_message and user_message ~= "" then
        final_msg = user_message
    end

    local is_headless = (final_msg ~= nil)

    -- 8. Контекст активного терминала
    local is_direct_interactive_call = (not ctx.pipeline_input) and (not ctx.has_next_step) and (os.getenv("GRIME_SUBAGENT") ~= "1")
    local terminal_context_block = nil
    local active_term_dump = nil
    if is_direct_interactive_call then
        active_term_dump = get_terminal_dump()
        if active_term_dump and is_term_data_fresh(active_term_dump, 300) then
            terminal_context_block = format_terminal_context(active_term_dump)
        end
    end

    -- 9. Системные инструкции (system_prompt)
    local sys_parts = { GRIME_CONVENTIONS }
    if is_module_mode then
        table.insert(sys_parts, GRIME_MODULE_STANDARD)
    end
    if is_headless and terminal_context_block then
        table.insert(sys_parts, terminal_context_block)
    end
    if is_headless and ctx.has_next_step then
        table.insert(sys_parts, "\n[СИСТЕМНОЕ ТРЕБОВАНИЕ GRIME]: Сформируйте мастер-промпт для следующего шага и ОБЯЗАТЕЛЬНО оберните его в тег:\n<next_agent_prompt>\nинструкция\n</next_agent_prompt>")
    end
    local system_prompt = table.concat(sys_parts, "\n")

    -- 10. Определение Git-статуса рабочей директории
    local is_git
    if explicit_git ~= nil then
        is_git = explicit_git
    else
        is_git = is_git_repo(working_dir)
        if is_git then
            ctx.log("Обнаружен Git-репозиторий в " .. working_dir .. " -> стандартный контроль версий Git")
        else
            ctx.log("Git-репозиторий отсутствует в " .. working_dir .. " -> режим без Git")
        end
    end

    -- 11. Выбор и проверка ИИ-агента через реестр
    local agent, resolve_err = agents.resolve(preferred_agent, ctx)
    if not agent then
        ctx.fail(resolve_err or "Не найден ни один доступный ИИ-агент (установите claude или aider)")
        return
    end
    if not agent:is_available(ctx) then
        ctx.fail(string.format("ИИ-агент '%s' (бинарник '%s') не найден в $PATH", agent.name, agent:resolve_binary(ctx)))
        return
    end

    -- Адаптация флага -y / --yes под выбранного агента
    if yes_flag then
        if agent.name == "claude" then
            if not permission_mode or permission_mode == "" then
                permission_mode = "bypassPermissions"
            end
        elseif agent.name == "aider" then
            local has_yes = false
            for _, p in ipairs(passthrough_args) do
                if p == "--yes-always" or p == "--yes" then
                    has_yes = true
                    break
                end
            end
            if not has_yes then
                table.insert(passthrough_args, "--yes-always")
            end
        end
    end

    ctx.log(string.format("ИИ-агент: %s (%s)", agent.name, agent:resolve_binary(ctx)))

    local opts = {
        working_dir = working_dir,
        prompt = final_msg,
        system_prompt = system_prompt,
        files = files,
        read_files = read_files,
        read_dirs = read_dirs,
        model = model,
        permission_mode = permission_mode,
        allowed_tools = allowed_tools,
        is_git = is_git,
        passthrough_args = passthrough_args,
    }

    -- 12. Выполнение: headless или интерактивный режим
    if is_headless then
        ctx.log(string.format("Вызов %s (headless)...", agent.name))
        local res = agent:run_headless(opts, ctx)

        local disp_out = (res.text and res.text ~= "") and res.text or res.stdout
        if disp_out and disp_out ~= "" then
            io.stdout:write(render_terminal_markdown(disp_out))
            if not disp_out:match("\n$") then
                io.stdout:write("\n")
            end
        end
        if res.stderr and res.stderr ~= "" then
            io.stderr:write(res.stderr)
            if not res.stderr:match("\n$") then
                io.stderr:write("\n")
            end
        end

        if res.ok then
            local extracted = parse_ai_tags(res.stdout, working_dir, user_message)
            if not extracted or extracted == "" then
                extracted = (disp_out or ""):match("^%s*(.-)%s*$")
            end

            if is_module_mode and target_module_file then
                validate_and_sync_module(target_module_file)
            end

            if is_app_mode then
                ctx.log(string.format("✓ Приложение '%s' создано в %s", app_name, app_dir))
                ctx.log(string.format("Для запуска выполните: grime app -run %s", app_name))
            end

            if ctx.has_next_step and extracted and extracted ~= "" then
                ctx.module_return(extracted)
            elseif ctx.has_next_step and target_dir then
                ctx.module_return(target_dir)
            else
                ctx.module_return(nil)
            end
        else
            ctx.fail(string.format("ИИ-агент '%s' завершился с кодом %s", agent.name, tostring(res.code)))
        end
    else
        local tmp_term_file = nil
        if terminal_context_block and active_term_dump then
            tmp_term_file = string.format("/tmp/grime_term_context_%d_%d.md", os.time(), math.random(1000, 9999))
            local f = io.open(tmp_term_file, "w")
            if f then
                f:write(terminal_context_block)
                f:close()
                opts.tmp_term_file = tmp_term_file
                if agent.name == "claude" then
                    opts.system_prompt = opts.system_prompt .. "\n" .. terminal_context_block
                end
                grime.ui.info(string.format("Подключен контекст терминала: '%s' (код %s)", active_term_dump.cmd or "", tostring(active_term_dump.status or 0)))
            end
        end

        _G.cleanup = function()
            if tmp_term_file and ctx.exists(tmp_term_file) then
                pcall(ctx.delete, tmp_term_file, true)
            end
        end

        local ret = agent:run_interactive(opts, ctx)

        if tmp_term_file and ctx.exists(tmp_term_file) then
            pcall(ctx.delete, tmp_term_file, true)
        end

        if ret == 0 then
            if is_module_mode and target_module_file then
                validate_and_sync_module(target_module_file)
            end
            if is_app_mode then
                ctx.log(string.format("✓ Приложение '%s' настроено в %s", app_name, app_dir))
                ctx.log(string.format("Для запуска выполните: grime app -run %s", app_name))
            end
            if ctx.has_next_step and target_dir then
                ctx.module_return(target_dir)
            else
                ctx.module_return(nil)
            end
        else
            ctx.fail(string.format("ИИ-агент '%s' завершился с кодом %s", agent.name, tostring(ret)))
        end
    end
end

local M = {
    description = description,
    main = main,
    extract_lang_from_prompt = extract_lang_from_prompt,
    classify_stack = classify_stack,
    plan_app_stack = plan_app_stack,
    heuristic_nix_packages = heuristic_nix_packages,
    scaffold_app = scaffold_app,
    scaffold_grime_module = scaffold_grime_module,
    run_dev = run_dev,
    validate_command_security = validate_command_security,
    execute_ai_action = execute_ai_action,
    parse_ai_tags = parse_ai_tags,
    render_terminal_markdown = render_terminal_markdown,
}
return M
