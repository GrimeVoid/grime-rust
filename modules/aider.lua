-- Summary: AI-ассистент парного программирования, генерации кода и скаффолдинга
-- Description: AI-ассистент парного программирования, генерации кода и скаффолдинга
description = "AI-ассистент парного программирования, генерации кода и скаффолдинга"

local ctx = grime.ctx
local utils = require("languages.utils")
local scanner = require("languages.scanner")

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

1. ОБЯЗАТЕЛЬНОЕ ПЕРЕИСПОЛЬЗОВАНИЕ СУЩЕСТВУЮЩИХ МОДУЛЕЙ (`modules/languages/*.lua`):
   - Парсинг аргументов и флагов со знаком минус:
     `local argparse = require("languages.argparse")`
     Используй `argparse.new({ actions = ..., flags = ..., categories = ..., detect_dir = ... })` и `cls:parse(ctx.args, ctx.target_dir)`.
   - Общие утилиты, цвета, проверка бинарников и путей:
     `local utils = require("languages.utils")`
     Переиспользуй: `utils.ANSI`, `utils.utf8_len`, `utils.pad_utf8`, `utils.has_binary(bin, ctx)`, `utils.shell_escape(s)`, `utils.normalize_path(p, cwd, ctx)`, `utils.classify_paths(cmd, args, cwd, ctx)`, `utils.get_apps_root(ctx)`, `utils.get_projects_root(ctx)`, `utils.generate_flake_nix(...)`, `utils.generate_app_manifest(...)`.
   - Для языковых адаптеров (`modules/languages/<lang>.lua`):
     Наследуйся от `local BaseAdapter = require("languages.base")` через `setmetatable(BaseAdapter.new({...}), LangAdapter)`.
   - Для логирования и Git при необходимости используй `local log = require("log")` и `local git = require("git")`.

2. НАТИВНОЕ API ЯДРА GRIME-RS (глобальная таблица `grime`):
   - `local ctx = grime.ctx`:
     * `ctx.args` (таблица аргументов шага), `ctx.target_dir` (текущая рабочая папка шага), `ctx.pipeline_input` / `ctx.input` (вход от предыдущего шага конвейера), `ctx.has_next_step` (bool: есть ли следующий шаг в конвейере), `ctx.force` (bool).
     * `ctx.set_target_dir(dir)` — смена рабочей директории для следующих шагов конвейера.
     * `ctx.module_return(val)` / `ctx.success(val)` — возврат результата шага в конвейер.
     * `ctx.fail(msg)` — завершение шага с ошибкой. ВАЖНО: вызывай ТОЛЬКО `ctx.fail(msg)` и `return`! КАТЕГОРИЧЕСКИ ЗАПРЕЩЕНО вызывать `grime.ui.error(msg)` или `io.stderr:write(msg)` с тем же текстом перед `ctx.fail(msg)`, так как ядро Grime само выводит сообщение из `ctx.fail`!
     * `ctx.run_process(argv, cwd, env)` -> код возврата (int); `ctx.capture(argv_or_cmd, cwd, env)` -> `{ code, stdout, stderr }`.
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
   - Все флаги и подкоманды в модуле и в `print_help()` должны поддерживать стандарт со знаком минус (`-list`, `--list`, `-path`, `--path`, `-p`, `-help`, `--help`, `-h`) с сохранением обратной совместимости без минуса.
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
    }

    for _, group in ipairs(explicit_targets) do
        for _, pat in ipairs(group.patterns) do
            if cleaned:find(pat) then
                return group.lang
            end
        end
    end

    -- 2. Проверка по прямому упоминанию языков, компиляторов и ключевых фреймворков
    -- Python (включая частые опечатки pyhon / phyton / piton)
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

    return nil
end

--- Предметная эвристика выбора стека (когда язык не назван в промпте явно)
local function heuristic_stack_from_prompt(user_prompt)
    if type(user_prompt) ~= "string" or user_prompt == "" then
        return "python"
    end
    local low = utf8_lower(user_prompt)

    -- Задачи для Lua (плагины, хуки, модули Grime, конфигураторы)
    local lua_keywords = { "плагин", "plugin", "модуль grime", "grime module", "хук", "hook", "neovim", "nvim" }
    for _, kw in ipairs(lua_keywords) do
        if low:find(kw, 1, true) then return "lua" end
    end

    -- Задачи для C++ (3D, графика, шейдеры, игры, OpenGL/Vulkan, низкоуровневая физика/матрицы)
    local cpp_keywords = { "opengl", "vulkan", "raylib", "sdl", "шейдер", "shader", "3d", "рендер", "render", "движок", "игр", "game", "физик", "симуляц" }
    for _, kw in ipairs(cpp_keywords) do
        if low:find(kw, 1, true) then return "cpp" end
    end

    -- Задачи для Java (корпоративные системы, банкинг, учет, склад, магазин, расписание, ООП-сервисы)
    local java_keywords = { "банк", "бухгалтер", "склад", "инвентар", "магазин", "заказ", "платеж", "предприят", "enterprise", "crm", "erp", "реестр", "библиотек" }
    for _, kw in ipairs(java_keywords) do
        if low:find(kw, 1, true) then return "java" end
    end

    -- Задачи для Rust (системные демоны, сокеты, прокси, сети, шифрование, криптография, мониторы ресурсов)
    local rust_keywords = { "демон", "daemon", "сокет", "socket", "прокси", "proxy", "шифрован", "крипто", "crypto", "бенчмарк", "benchmark", "монитор систем", "сниффер", "многопоточ" }
    for _, kw in ipairs(rust_keywords) do
        if low:find(kw, 1, true) then return "rust" end
    end

    -- Для скриптов, парсеров, работы с текстом/JSON/CSV/API/CLI/аналитикой/автоматизацией и общих задач — Python
    return "python"
end

--- Парсинг ответа LLM при классификации стека
local function parse_llm_stack_response(stdout)
    if type(stdout) ~= "string" or stdout == "" then
        return nil
    end
    local allowed = {
        python = "python", py = "python", python3 = "python",
        java = "java",
        rust = "rust", rs = "rust",
        lua = "lua", luajit = "lua",
        cpp = "cpp", ["c++"] = "cpp", cxx = "cpp",
    }

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

    -- Ищем с конца вывода точное слово-ответ модели
    for i = #lines, 1, -1 do
        local ln = lines[i]:gsub("[`*'\".,!?;:()<>%[%]%{%}]+", " ")
        local first_tok = ln:match("^%s*(%S+)%s*$")
        if first_tok and allowed[first_tok] then
            return allowed[first_tok]
        end
        for tok in ln:gmatch("%S+") do
            if allowed[tok] then
                return allowed[tok]
            end
        end
    end

    return nil
end

--- Определение оптимального стека: сначала 100% приоритет языка из промпта, затем LLM/эвристика
local function classify_stack(user_prompt)
    if not user_prompt or user_prompt == "" then
        return "python"
    end

    -- 1. Безусловный приоритет: если пользователь явно указал язык в промпте — выбираем его!
    local explicit = extract_lang_from_prompt(user_prompt)
    if explicit then
        return explicit
    end

    -- 2. Запрос к Aider-Архитектору (в изолированной директории /tmp без сканирования чужого репозитория)
    local config_aider = ctx.get_config and ctx.get_config("aider", "auto") or "auto"
    local aider_bin = (config_aider ~= "" and config_aider ~= "auto") and config_aider or "aider"
    if utils.has_binary(aider_bin, ctx) then
        local classify_prompt = string.format([[Выбери наиболее подходящий язык программирования для реализации следующей задачи:
"%s"

Доступные стеки:
- python : скрипты, парсеры, обработка текста/JSON/CSV, CLI-утилиты, автоматизация, веб/API, вычисления, быстрые утилиты.
- java   : приложения со структурированной ООП-моделью, бизнес-логика, учетные системы, кроссплатформенные сервисы.
- rust   : системные утилиты, сетевые демоны, высоконагруженные сервисы, работа с бинарными данными и ОС.
- lua    : легкие плагины, конфигурационные скрипты, расширения экосистемы Grime.
- cpp    : 3D-графика, игры, низкоуровневые алгоритмы реального времени, работа с памятью/железом.

Ответь СТРОГО ОДНИМ СЛОВОМ из списка (python, java, rust, lua, cpp) без пояснений и знаков препинания.]], user_prompt)
        ctx.log("Aider-Архитектор определяет оптимальный стек технологий...")
        local cres = ctx.capture({
            "timeout", "15",
            aider_bin,
            "--no-git", "--map-tokens", "0", "--exit", "--yes-always", "--no-fancy-input", "--no-pretty",
            "-m", classify_prompt,
        }, "/tmp")
        if cres and cres.code == 0 and cres.stdout and cres.stdout ~= "" then
            local parsed_lang = parse_llm_stack_response(cres.stdout)
            if parsed_lang then
                return parsed_lang
            end
        end
    end

    -- 3. Предметная эвристика, если LLM не вызвана или не ответила
    return heuristic_stack_from_prompt(user_prompt)
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
    if type(val) == "string" and (val:sub(1,1) == "{" or val:sub(1,1) == "[") then
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

--- Рекурсивная замена плейсхолдеров в директории
local function replace_placeholders_in_dir(dir, replacements)
    local res = ctx.capture({ "find", dir, "-type", "f" })
    if res and res.code == 0 and res.stdout then
        for raw_line in res.stdout:gmatch("[^\r\n]+") do
            local file_path = raw_line:match("^%s*(.-)%s*$")
            if file_path ~= "" and not file_path:find("/%.git/") and ctx.is_file(file_path) then
                local f = io.open(file_path, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local changed = false
                    for placeholder, val in pairs(replacements) do
                        if content:find(placeholder, 1, true) then
                            local safe_val = tostring(val):gsub("%%", "%%%%")
                            content = content:gsub(placeholder, safe_val)
                            changed = true
                        end
                    end
                    if changed then
                        local f_out = io.open(file_path, "w")
                        if f_out then
                            f_out:write(content)
                            f_out:close()
                        end
                    end
                end
            end
        end
    end
end

--- Генерация актуального манифеста app.lua с учётом специфики сборки языков (включая быстрый автономный Java JAR)
local function build_app_manifest_content(app_name, lang, desc)
    lang = (lang or "python"):lower()
    if lang == "java" then
        local clean_desc = (desc and desc ~= "") and desc:gsub("\n", " ") or ("Приложение " .. app_name)
        local lines = {
            "return {",
            string.format("    name = %q,", app_name),
            string.format("    description = %q,", clean_desc),
            '    type = "java",',
            string.format("    artifact = %q,", "build/" .. app_name .. ".jar"),
            string.format(
                "    build = %q,",
                string.format(
                    "mkdir -p build/classes && javac -encoding UTF-8 -d build/classes $(find src -name '*.java') && jar --create --file build/%s.jar --main-class Main -C build/classes .",
                    app_name
                )
            ),
            string.format("    run = %q,", "java -jar build/" .. app_name .. ".jar"),
            "    special_dependencies = {},",
            "    detached = false,",
            "}",
        }
        return table.concat(lines, "\n") .. "\n"
    end
    return utils.generate_app_manifest(app_name, lang, desc)
end

--- Определение основного файла исходного кода по языку
local function get_entry_file_for_lang(lang, app_dir)
    local map = {
        python = "src/main.py",
        java   = "src/Main.java",
        rust   = "src/main.rs",
        lua    = "src/main.lua",
        cpp    = "src/main.cpp",
    }
    local cand = map[(lang or "python"):lower()] or "src/main.py"
    if app_dir and ctx.exists(app_dir .. "/" .. cand) then
        return cand
    end
    local fallbacks = { "src/main.py", "src/Main.java", "src/main.rs", "src/main.lua", "src/main.cpp" }
    for _, f in ipairs(fallbacks) do
        if app_dir and ctx.exists(app_dir .. "/" .. f) then
            return f
        end
    end
    return cand
end

--- Запуск субагента Aider для реализации приложения
local function run_dev(app_dir, prompt, app_name, lang)
    local grime_bin = os.getenv("GRIME_BIN") or "grime"
    local stack_lang = lang or (prompt and extract_lang_from_prompt(prompt)) or (app_name and extract_lang_from_prompt(app_name)) or "python"
    local entry_file = get_entry_file_for_lang(stack_lang, app_dir)
    if prompt and prompt ~= "" then
        local dev_prompt = string.format(
            "%s\n\n[GRIME APP REQUIREMENT]:\n" ..
            "- Целевой язык и стек приложения: %s (СТРОГО используй язык %s!).\n" ..
            "- Редактируй существующий исходный файл `%s` в директории `%s` (НЕ создавай дублирующие файлы в корне проекта мимо `src/`!).\n" ..
            "- Убедись, что код компилируется/выполняется без ошибок, а манифест `app.lua` содержит актуальные поля `type = %q`, `artifact`, `build` и `run`.",
            prompt, stack_lang, stack_lang, entry_file, app_dir, stack_lang
        )
        ctx.log(string.format("Запуск субагента Aider для реализации '%s' (стек: %s, файл: %s)...", app_name or "app", stack_lang, entry_file))
        local cmd = { "timeout", "180", grime_bin, "aider" }
        if ctx.exists(app_dir .. "/" .. entry_file) then
            table.insert(cmd, entry_file)
        end
        if ctx.exists(app_dir .. "/app.lua") then
            table.insert(cmd, "app.lua")
        end
        table.insert(cmd, "-m")
        table.insert(cmd, dev_prompt)
        local code = ctx.run_process(cmd, app_dir)
        if code ~= 0 then
            ctx.warn(string.format("Aider завершился с кодом %d (продолжаем с базовым шаблоном)", code))
        end
        return code
    else
        ctx.log("Запуск интерактивной сессии Aider для проектирования приложения...")
        local cmd = { grime_bin, "aider" }
        if ctx.exists(app_dir .. "/" .. entry_file) then
            table.insert(cmd, entry_file)
        end
        if ctx.exists(app_dir .. "/app.lua") then
            table.insert(cmd, "app.lua")
        end
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

--- Скаффолдинг структуры приложения
local function scaffold_app(app_dir, app_name, lang, prompt)
    lang = (lang or "python"):lower()
    if not ctx.exists(app_dir) then
        ctx.mkdir_p(app_dir)
    end

    local templates_root = (ctx.paths and ctx.paths.templates)
        or (ctx.get_path and ctx.get_path("templates"))
        or (ctx.templates_root and ctx.templates_root())
    if not templates_root or templates_root == "" then
        local home = os.getenv("HOME") or ""
        templates_root = (home ~= "" and (home .. "/.config/grime/templates")) or "./templates"
    end
    templates_root = ctx.normalize_path(templates_root)
    local tpl_dir = templates_root .. "/" .. lang
    if not ctx.exists(tpl_dir) then
        local home = os.getenv("HOME") or ""
        local dotfiles_tpl = home .. "/dotfiles/grime/templates/" .. lang
        if home ~= "" and ctx.exists(dotfiles_tpl) then
            tpl_dir = dotfiles_tpl
        end
    end

    if ctx.exists(tpl_dir) then
        ctx.copy(tpl_dir, app_dir)
        ctx.log(string.format("Каркас приложения скопирован из шаблона '%s'", lang))
    else
        ctx.mkdir_p(app_dir .. "/src")
    end

    -- Для Java: удаляем устаревший шаблонный pom.xml с несуществующим com.example.App,
    -- чтобы сборка шла быстро и надежно через javac + jar
    if lang == "java" and ctx.exists(app_dir .. "/pom.xml") then
        local pf = io.open(app_dir .. "/pom.xml", "r")
        if pf then
            local pcontent = pf:read("*a") or ""
            pf:close()
            if pcontent:find("com%.example%.App") and not ctx.exists(app_dir .. "/src/main/java") then
                ctx.delete(app_dir .. "/pom.xml", true)
            end
        end
    end

    -- Гарантируем наличие базового исходного файла точки входа для каждого языка
    ctx.mkdir_p(app_dir .. "/src")
    local ok_adp, adp = pcall(require, "languages." .. lang)
    if ok_adp and adp and adp.create_default_files then
        adp:create_default_files(app_dir, ctx, prompt)
    end

    local raw_desc = (prompt and prompt ~= "") and prompt or ("Grime application " .. app_name)
    local escaped_desc = raw_desc:gsub("\n", " "):gsub('"', '\\"')

    local snake_name = grime.str.to_snake_case(app_name)
    local kebab_name = app_name:lower():gsub("[%s_]", "-")
    local replacements = {
        ["{{PROJECT_NAME}}"] = app_name,
        ["{{PROJECT_NAME_LOWER}}"] = app_name:lower(),
        ["{{PROJECT_NAME_UPPER}}"] = app_name:upper(),
        ["{{PROJECT_NAME_SNAKE}}"] = snake_name,
        ["{{PROJECT_NAME_KEBAB}}"] = kebab_name,
        ["{{PROJECT_DESCRIPTION}}"] = escaped_desc,
    }
    replace_placeholders_in_dir(app_dir, replacements)

    -- Всегда записываем актуальный манифест app.lua по современному стандарту
    local manifest_path = app_dir .. "/app.lua"
    local m_content = build_app_manifest_content(app_name, lang, raw_desc)
    local f = io.open(manifest_path, "w")
    if f then
        f:write(m_content)
        f:close()
    end

    -- Автогенерация flake.nix
    local flake_path = app_dir .. "/flake.nix"
    if not ctx.is_file(flake_path) then
        local scan = scanner.scan_project(app_dir, ctx)
        local native_pkgs, lib_pkgs = utils.split_packages(scan.toolchain or {}, scanner)
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

--- Определение путей к каталогам модулей GRIME (репозиторий и пользовательский конфиг)
local function get_grime_modules_dirs()
    local home = os.getenv("HOME") or "/home/danny"
    local repo_dir = home .. "/Archive/_Programing_/rust/grime_pj/modules"
    local config_dir = ((ctx.config_dir and ctx.config_dir()) or (home .. "/.config/grime")) .. "/modules"
    local primary = ctx.exists(repo_dir) and repo_dir or config_dir
    return primary, repo_dir, config_dir
end

--- Автораспознавание запроса на создание/доработку модуля GRIME из текста промпта
local function detect_module_request(user_prompt, working_dir)
    local primary_mods, repo_mods, config_mods = get_grime_modules_dirs()
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

--- Генерация стартового каркаса нового модуля GRIME по стандарту (с переиспользованием argparse и utils)
local function scaffold_grime_module(mod_path, mod_name, prompt)
    if ctx.exists(mod_path) then
        return
    end
    local clean_desc = (prompt and prompt ~= "") and prompt:gsub("\n", " "):gsub('"', '\\"') or ("Модуль расширения Grime: " .. mod_name)
    local template = string.format([[-- Summary: %s
-- Description: %s
description = %q

local argparse = require("languages.argparse")
local utils = require("languages.utils")

local ctx = grime.ctx
local ui = grime.ui
local ANSI = utils.ANSI

local ACTION_SYNONYMS = {
    list = "list", ["-list"] = "list", ["--list"] = "list", ls = "list", ["-ls"] = "list",
    run = "run", ["-run"] = "run", ["--run"] = "run", ["-r"] = "run",
    path = "path", ["-path"] = "path", ["--path"] = "path", ["-p"] = "path",
    help = "help", ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
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

    local cls = argparse.new({
        actions = ACTION_SYNONYMS,
        default_action = "run",
        flags = {
            help = { "-h", "--help", "-help", "help" },
            path = { "-p", "-path", "--path", "path" },
            force = { "-f", "-force", "--force" },
        },
    })

    local parsed = cls:parse(raw_args, ctx.target_dir)
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

--- Валидация байткода модуля через luajit -bl и синхронизация между репозиторием и ~/.config/grime/modules
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

    local _, repo_mods, config_mods = get_grime_modules_dirs()
    local fname = mod_path:match("([^/]+%.lua)$")
    if fname then
        local norm_src = utils.normalize_path(mod_path)
        local repo_target = utils.normalize_path(repo_mods .. "/" .. fname)
        local cfg_target = utils.normalize_path(config_mods .. "/" .. fname)
        if norm_src ~= repo_target and ctx.exists(repo_mods) then
            pcall(ctx.copy, norm_src, repo_target)
        end
        if norm_src ~= cfg_target and ctx.exists(config_mods) then
            pcall(ctx.copy, norm_src, cfg_target)
        end
    end
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

    -- Нормализация soft-wrap от rich/aider консоли: склеиваем строки, разорванные форматированием
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
                local cand_cmd = shell_cmd:gsub(prefix_pattern, "")
                shell_cmd = cand_cmd
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

--- Парсинг вывода Aider с поддержкой тегов <grime_bus>, <grime_spawn>, <grime_exec>/<grime_action> и <next_agent_prompt>
local function parse_aider_tags(output, working_dir, _user_prompt)
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
    local grime_bin = os.getenv("GRIME_BIN")
    if not grime_bin or grime_bin == "" then
        local home = os.getenv("HOME") or ""
        local local_bin = home .. "/.local/bin/grime"
        if ctx.exists(local_bin) then
            grime_bin = local_bin
        else
            grime_bin = "grime"
        end
    end

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
                    if target_mod == "aider" then
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
                        parse_aider_tags(sres.stdout, target_cwd, prompt)
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

--- Компактный микро-рендерер Markdown для стилизации вывода Aider в терминале
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
    print(string.format([[
%s%sGrime Aider%s — AI-ассистент парного программирования, генерации приложений и модулей Grime

%sИСПОЛЬЗОВАНИЕ:%s
    grime aider [путь_или_проект] [файлы...] [промпт...]
    grime aider [опции] -m "сообщение"
    grime aider -app <имя> [-lang <язык>] [промпт...]
    grime aider -module <имя_модуля> [промпт...]
    grime <модуль_с_контекстом> : aider [файлы...] [промпт...]

%sРЕЖИМЫ РАБОТЫ:%s
    %sИнтерактивный%s         grime aider [проект] [файлы...]
    %sHeadless (-m)%s         grime aider -m "Добавь тесты для функции парсинга"
    %sСоздание приложения%s   grime aider -app MyTool -lang python "CLI утилита"
    %sРазработка модуля%s     grime aider -module mymod "Модуль мониторинга"
    %sКонвейерный%s           grime project -path MyProj : aider "Рефакторинг CMake"

%sФЛАГИ (стандарт со знаком минус):%s
    %s-a, -app, --app <name>%s        Создание и скаффолдинг приложения Grime App
    %s-mod, -module, --module <m>%s   Создание или доработка модуля Grime по стандарту
    %s-l, -lang, --lang <lang>%s      Язык шаблона (python, java, rust, cpp, lua)
    %s-m, -message, --message <msg>%s Сообщение / промпт для неинтерактивного режима
    %s-model, --model <model>%s       Модель LLM (например, claude-3-5-sonnet, gpt-4o)
    %s-h, -help, --help%s             Показать эту справку

%sИНТЕГРАЦИЯ С ЭКОСИСТЕМОЙ GRIME:%s
    • Автоматическое определение языка из промпта (русский/английский, падежи, фреймворки)
    • Автоматическое подключение общих библиотек (`languages/argparse.lua`, `languages/utils.lua`) при работе с модулями
    • Поддержка тегов <grime_exec>, <grime_bus>, <grime_spawn>, <next_agent_prompt>
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
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local LANG_ALIASES = {
    cpp = "cpp", ["c++"] = "cpp", cxx = "cpp", c = "cpp",
    python = "python", py = "python", python3 = "python",
    rust = "rust", rs = "rust",
    java = "java", jav = "java",
    lua = "lua", luajit = "lua",
}

function main()
    local raw_cli_args = {}
    for _, a in ipairs(ctx.args or {}) do
        table.insert(raw_cli_args, a)
    end

    local first_arg = raw_cli_args[1]
    if (#raw_cli_args == 0 and not ctx.pipeline_input and not ctx.input)
        or first_arg == "-h" or first_arg == "--help" or first_arg == "-help" or first_arg == "help"
    then
        print_help()
        return
    end
    for _, a in ipairs(raw_cli_args) do
        if a == "-h" or a == "--help" or a == "-help" then
            print_help()
            return
        end
    end

    local target_dir = nil
    local incoming_pipeline_text = nil

    -- 0. Проверка режимов (-app / --app и -module / --module / -mod / --mod) и флага -lang / --lang / -l
    local is_app_mode = false
    local app_name = nil
    local app_lang = nil
    local app_dir = nil

    local is_module_mode = false
    local module_name = nil
    local target_module_file = nil

    local filtered_args = {}

    local idx = 1
    while idx <= #raw_cli_args do
        local a = raw_cli_args[idx]
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
            else
                table.insert(filtered_args, a)
            end
        elseif a == "--app" or a == "-app" or a == "-a" then
            is_app_mode = true
            if idx + 1 <= #raw_cli_args and not raw_cli_args[idx + 1]:match("^%-") then
                idx = idx + 1
                app_name = raw_cli_args[idx]
            end
        elseif a == "--module" or a == "-module" or a == "--mod" or a == "-mod" then
            is_module_mode = true
            if idx + 1 <= #raw_cli_args and not raw_cli_args[idx + 1]:match("^%-") then
                idx = idx + 1
                module_name = raw_cli_args[idx]:gsub("%.lua$", "")
            end
        elseif a == "--lang" or a == "-lang" or a == "-l" then
            if idx + 1 <= #raw_cli_args and not raw_cli_args[idx + 1]:match("^%-") then
                idx = idx + 1
                local raw_l = raw_cli_args[idx]:lower()
                app_lang = LANG_ALIASES[raw_l] or raw_l
            end
        elseif a == "-message" then
            table.insert(filtered_args, "-m")
        elseif a == "-model" then
            table.insert(filtered_args, "--model")
        else
            table.insert(filtered_args, a)
        end
        idx = idx + 1
    end

    local remaining_args = filtered_args

    if is_app_mode then
        if not app_name or app_name == "" then
            ctx.fail("Укажите имя приложения: grime aider -app <app_name> [-lang <lang>] [prompt]")
            return
        end

        local apps_root = get_apps_root()
        app_dir = apps_root .. "/" .. app_name
        target_dir = app_dir

        -- Сбор пользовательского промпта
        local collected_prompt = {}
        for _, arg in ipairs(remaining_args) do
            if arg ~= "-m" and arg ~= "--message" and not arg:match("^%-") then
                table.insert(collected_prompt, arg)
            end
        end
        local user_prompt = table.concat(collected_prompt, " ")

        -- Приоритетное извлечение языка из промпта (или имени приложения): если явно назван язык, он перекрывает авто-выбор!
        local prompt_lang = extract_lang_from_prompt(user_prompt) or extract_lang_from_prompt(app_name)
        local final_lang = prompt_lang or app_lang or classify_stack(user_prompt)

        ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, final_lang))
        scaffold_app(app_dir, app_name, final_lang, user_prompt)
        local entry_file = get_entry_file_for_lang(final_lang, app_dir)

        if user_prompt ~= "" then
            local master_prompt = string.format(
                "%s\n\n[GRIME APP REQUIREMENT]:\n" ..
                "- Выбранный стек приложения: %s (СТРОГО реализуй приложение на языке %s!).\n" ..
                "- Редактируй существующий исходный файл `%s` (НЕ создавай дублирующие файлы в корне директории мимо `src/`!).\n" ..
                "- Убедись, что код компилируется/выполняется и манифест `app.lua` содержит верное описание и параметры сборки/запуска.",
                user_prompt, final_lang, final_lang, entry_file
            )
            remaining_args = { "-m", master_prompt }
        else
            remaining_args = {}
        end
    end

    -- 1. Проверяем входные данные из конвейера
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

    -- 2. Проверяем, передан ли путь или имя проекта первым аргументом (если не в режиме -app / -module)
    if not is_app_mode and not is_module_mode and #remaining_args > 0 and not target_dir then
        local first_rem = remaining_args[1]
        local resolved = resolve_dir_or_project(first_rem)
        if resolved then
            target_dir = resolved
            table.remove(remaining_args, 1)
        end
    end

    local working_dir = ctx.normalize_path(target_dir or ctx.target_dir)

    -- 3. Обработка флага -m / --message / -message и сбор свободных слов промпта без кавычек
    local msg_flag_idx = nil
    for i, arg in ipairs(remaining_args) do
        if arg == "-m" or arg == "--message" or arg == "-message" then
            msg_flag_idx = i
            break
        end
    end

    local user_message = ""
    if msg_flag_idx then
        local collected = {}
        local i = msg_flag_idx + 1
        while i <= #remaining_args do
            local tok = remaining_args[i]
            if tok:match("^%-[a-zA-Z]") then
                break
            end
            table.insert(collected, tok)
            i = i + 1
        end
        user_message = table.concat(collected, " ")
        local new_args = {}
        for k = 1, msg_flag_idx - 1 do
            table.insert(new_args, remaining_args[k])
        end
        table.insert(new_args, "-m")
        table.insert(new_args, user_message)
        for k = i, #remaining_args do
            table.insert(new_args, remaining_args[k])
        end
        remaining_args = new_args
    elseif #remaining_args > 0 and not is_app_mode then
        local flags_part = {}
        local positional = {}
        local i = 1
        local flags_with_value = {
            ["--model"] = true,
            ["-model"] = true,
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
            ["--read"] = true,
            ["--commit-prompt"] = true,
            ["-c"] = true,
        }

        while i <= #remaining_args do
            local arg = remaining_args[i]
            if arg:match("^%-") then
                local norm_flag = (arg == "-model") and "--model" or arg
                table.insert(flags_part, norm_flag)
                if flags_with_value[arg] and i + 1 <= #remaining_args and not remaining_args[i + 1]:match("^%-") then
                    i = i + 1
                    table.insert(flags_part, remaining_args[i])
                end
            else
                table.insert(positional, arg)
            end
            i = i + 1
        end

        local files = {}
        local prompt_tokens = {}
        local found_prompt = false

        for _, tok in ipairs(positional) do
            if found_prompt then
                table.insert(prompt_tokens, tok)
            else
                local is_file = ctx.is_file(tok) or ctx.is_file(working_dir .. "/" .. tok)
                if is_file then
                    table.insert(files, tok)
                else
                    found_prompt = true
                    table.insert(prompt_tokens, tok)
                end
            end
        end

        if #prompt_tokens > 0 then
            user_message = table.concat(prompt_tokens, " ")
            local new_args = {}
            for _, f in ipairs(flags_part) do
                table.insert(new_args, f)
            end
            for _, f in ipairs(files) do
                table.insert(new_args, f)
            end
            table.insert(new_args, "-m")
            table.insert(new_args, user_message)
            remaining_args = new_args
        end
    end

    -- 3.1. Проверка режима создания/доработки модуля GRIME (по флагу -module или автоматически по тексту промпта)
    if not is_app_mode then
        local auto_mod, detected_mod_name = detect_module_request(user_message, working_dir)
        if auto_mod then
            is_module_mode = true
            if not module_name and detected_mod_name then
                module_name = detected_mod_name
            end
        end
    end

    local primary_mods_dir, _, _ = get_grime_modules_dirs()
    if is_module_mode then
        if not target_dir then
            working_dir = primary_mods_dir
            target_dir = primary_mods_dir
        end
        if module_name and module_name ~= "" then
            target_module_file = primary_mods_dir .. "/" .. module_name .. ".lua"
            scaffold_grime_module(target_module_file, module_name, user_message)
        end
    end

    -- 4. Объединение с контекстом от предыдущего шага конвейера
    if incoming_pipeline_text then
        local combined_message = ""
        if user_message and user_message ~= "" then
            combined_message = string.format("Контекст от предыдущего шага:\n```\n%s\n```\n\nТекущая задача:\n%s", incoming_pipeline_text, user_message)
        else
            combined_message = incoming_pipeline_text
        end

        local m_found = false
        for i, a in ipairs(remaining_args) do
            if a == "-m" then
                remaining_args[i + 1] = combined_message
                m_found = true
                break
            end
        end
        if not m_found then
            table.insert(remaining_args, "-m")
            table.insert(remaining_args, combined_message)
        end
    end

    local is_headless = false
    for _, a in ipairs(remaining_args) do
        if a == "-m" or a == "--message" then
            is_headless = true
            break
        end
    end

    -- Сбор терминального контекста для прямых интерактивных вызовов
    local is_direct_interactive_call = (not ctx.pipeline_input) and (not ctx.has_next_step) and (os.getenv("GRIME_SUBAGENT") ~= "1")
    local terminal_context_block = nil
    local active_term_dump = nil

    if is_direct_interactive_call then
        active_term_dump = get_terminal_dump()
        if active_term_dump and is_term_data_fresh(active_term_dump, 300) then
            terminal_context_block = format_terminal_context(active_term_dump)
        end
    end

    -- Добавление системных конвенций Grime и стандарта модулей Grime
    if is_headless then
        for i, a in ipairs(remaining_args) do
            if a == "-m" and remaining_args[i + 1] then
                remaining_args[i + 1] = remaining_args[i + 1] .. GRIME_CONVENTIONS
                if is_module_mode then
                    remaining_args[i + 1] = remaining_args[i + 1] .. "\n" .. GRIME_MODULE_STANDARD
                end
                if terminal_context_block then
                    remaining_args[i + 1] = remaining_args[i + 1] .. "\n" .. terminal_context_block
                end
                break
            end
        end
    end

    -- 5. Prompt Chaining: если есть следующий шаг в конвейере Grime
    if is_headless and ctx.has_next_step then
        local chain_instruction = "\n\n[СИСТЕМНОЕ ТРЕБОВАНИЕ GRIME]: Сформируйте мастер-промпт для следующего шага и ОБЯЗАТЕЛЬНО оберните его в тег:\n<next_agent_prompt>\nинструкция\n</next_agent_prompt>"
        for i, a in ipairs(remaining_args) do
            if a == "-m" and remaining_args[i + 1] then
                remaining_args[i + 1] = remaining_args[i + 1] .. chain_instruction
                break
            end
        end
    end

    local config_aider = ctx.get_config("aider", "auto")
    local aider_bin = (config_aider ~= "" and config_aider ~= "auto") and config_aider or "aider"
    local aider_cmd = { aider_bin }

    -- 6. Проверка наличия Git-репозитория в целевой рабочей директории
    local has_explicit_git_flag = false
    for _, a in ipairs(remaining_args) do
        if a == "--no-git" or a == "--git" then
            has_explicit_git_flag = true
            break
        end
    end

    if not has_explicit_git_flag then
        local in_git = is_git_repo(working_dir)
        if in_git then
            ctx.log("Обнаружен Git-репозиторий в " .. working_dir .. " -> запуск со стандартным контролем версий Git")
        else
            table.insert(aider_cmd, "--no-git")
            ctx.log("Git-репозиторий отсутствует в " .. working_dir .. " -> добавлен флаг --no-git")
        end
    end

    if is_headless then
        local has_exit = false
        local has_yes = false
        local has_fancy = false
        local has_pretty = false
        for _, a in ipairs(remaining_args) do
            if a == "--exit" then has_exit = true end
            if a == "--yes-always" or a == "--yes" then has_yes = true end
            if a == "--no-fancy-input" or a == "--fancy-input" then has_fancy = true end
            if a == "--no-pretty" or a == "--pretty" then has_pretty = true end
        end
        if not has_exit then table.insert(aider_cmd, "--exit") end
        if not has_yes then table.insert(aider_cmd, "--yes-always") end
        if not has_fancy then table.insert(aider_cmd, "--no-fancy-input") end
        if not has_pretty then table.insert(aider_cmd, "--no-pretty") end
    end

    -- 7. В режиме разработки модулей GRIME автоматически подключаем общие библиотеки для переиспользования (--read)
    if is_module_mode then
        local shared_read_files = {
            primary_mods_dir .. "/languages/argparse.lua",
            primary_mods_dir .. "/languages/utils.lua",
            primary_mods_dir .. "/languages/base.lua",
        }
        for _, rf in ipairs(shared_read_files) do
            if ctx.is_file(rf) then
                table.insert(aider_cmd, "--read")
                table.insert(aider_cmd, rf)
            end
        end
        if target_module_file and ctx.is_file(target_module_file) then
            table.insert(aider_cmd, target_module_file)
        end
    elseif (target_dir and ctx.exists(target_dir)) or (working_dir and ctx.is_file(working_dir .. "/app.lua")) then
        -- Подключение файлов проекта/аппа по умолчанию (точка входа + сборочный файл + app.lua)
        local has_explicit = false
        for _, a in ipairs(remaining_args) do
            if not a:match("^%-") and ctx.exists(working_dir .. "/" .. a) then
                has_explicit = true
                break
            end
        end
        if not has_explicit then
            local entry_candidates = { "src/main.py", "src/Main.java", "src/main.rs", "src/main.lua", "src/main.cpp", "main.py", "main.lua" }
            for _, c in ipairs(entry_candidates) do
                if ctx.exists(working_dir .. "/" .. c) then
                    table.insert(aider_cmd, c)
                    break
                end
            end
            local build_candidates = { "app.lua", "Cargo.toml", "CMakeLists.txt", "pom.xml", "pyproject.toml" }
            for _, bc in ipairs(build_candidates) do
                if ctx.exists(working_dir .. "/" .. bc) then
                    table.insert(aider_cmd, bc)
                end
            end
        end
    end

    for _, a in ipairs(remaining_args) do
        table.insert(aider_cmd, a)
    end

    if is_headless then
        ctx.log("Вызов Aider...")
        local res = ctx.capture(aider_cmd, working_dir)
        if res.stdout and res.stdout ~= "" then
            io.stdout:write(render_terminal_markdown(res.stdout))
        end
        local cleaned_stderr = (res.stderr or ""):gsub("Warning: Input is not a terminal %(fd=0%)%.\r?\n?", "")
        io.stderr:write(cleaned_stderr)

        if res.code == 0 then
            local extracted = parse_aider_tags(res.stdout, working_dir, user_message)
            if not extracted or extracted == "" then
                extracted = res.stdout:match("^%s*(.-)%s*$")
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
            ctx.fail("Aider завершился с кодом " .. tostring(res.code))
        end
    else
        local tmp_term_file = nil
        if terminal_context_block and active_term_dump then
            tmp_term_file = string.format("/tmp/grime_term_context_%d_%d.md", os.time(), math.random(1000, 9999))
            local f = io.open(tmp_term_file, "w")
            if f then
                f:write(terminal_context_block)
                f:close()
                table.insert(aider_cmd, "--read")
                table.insert(aider_cmd, tmp_term_file)
                grime.ui.info(string.format("Подключен контекст терминала: '%s' (код %s)", active_term_dump.cmd or "", tostring(active_term_dump.status or 0)))
            end
        end

        local ret = ctx.run_process(aider_cmd, working_dir)

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
            ctx.fail("Aider завершился с кодом " .. tostring(ret))
        end
    end
end

local M = {
    description = description,
    main = main,
    extract_lang_from_prompt = extract_lang_from_prompt,
    classify_stack = classify_stack,
    scaffold_app = scaffold_app,
    scaffold_grime_module = scaffold_grime_module,
    run_dev = run_dev,
    validate_command_security = validate_command_security,
    execute_ai_action = execute_ai_action,
    parse_aider_tags = parse_aider_tags,
    render_terminal_markdown = render_terminal_markdown,
}
return M
