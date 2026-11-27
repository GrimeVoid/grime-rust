--@grime description: Комплексная диагностика системного окружения, путей и журнала сбоев
--@grime requires: module:log, module:ai?

-- Описание: Проверка утилит, каталогов конфигурации, состояния логов и недавних ошибок системы

local ctx = grime.ctx
local log = require("log")
local utils = require("languages.utils")

local ANSI = {
    BOLD = "\27[1m",
    RESET = "\27[0m",
    GREEN = "\27[32m",
    YELLOW = "\27[33m",
    RED = "\27[31m",
    CYAN = "\27[36m",
    DIM = "\27[90m",
}

local function print_help()
    print(string.format([[
%s%sGrime Doctor%s — Диагностика системного окружения, путей, зависимостей и журнала сбоев

%sИСПОЛЬЗОВАНИЕ:%s
    grime doctor [help|-h|--help]
    grime doctor -fix [-dry|-n] [-yes|-y] [описание проблемы…]

%sОПИСАНИЕ:%s
    Проверяет доступность ключевых утилит (git, nix, distrobox, cargo, claude, aider),
    корректность путей в реестре конфигурации, статус журнала логов и
    отображает недавние ошибки и сбои из централизованного хранилища StateBus.

%sИИ-РЕМОНТ (-fix):%s
    Собирает контекст (отчёт doctor, ошибки журнала, последняя упавшая команда,
    journalctl, упавшие юниты, состояние pacman), маскирует секреты, показывает сводку
    и после подтверждения отправляет агенту. Агент даёт диагноз и скрипт <grime_fix>.
    Скрипт показывается целиком с SHA-256, списком строк sudo и рисками; запуск —
    только после явного «y» (флаг -yes на запуск НЕ распространяется), в окне терминала,
    где sudo сам запрашивает пароль (grime пароль не видит и не хранит). Скрипт
    эфемерный и удаляется после закрытия окна.
      -fix            включить режим ИИ-ремонта; остальные слова — описание проблемы
      -dry, -n        ничего не отправлять и не запускать: показать только сводку
      -yes, -y        пропустить подтверждение ОТПРАВКИ контекста (не запуска скрипта)
    Настройки: ключ конфига doctor_agent (затем ai_agent, иначе claude);
    терминал берётся из $TERMINAL, по умолчанию ghostty (без дисплея — текущий TTY).
]],
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

--- Поиск исполняемого файла по PATH без запуска внешних процессов
local function find_in_path(name)
    if grime.process and grime.process.which then
        local p = grime.process.which(name)
        if p and #p > 0 then return p end
    end
    for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        local cand = dir .. "/" .. name
        if ctx.exists(cand) and not ctx.is_dir(cand) then return cand end
    end
    return nil
end

-- =====================================================================
-- Режим «ИИ-ремонт»: grime doctor -fix [описание проблемы…]
-- =====================================================================

local FIX_CONTEXT_LIMIT = 24 * 1024    -- общий лимит контекста, отправляемого агенту
local FIX_SECTION_LIMIT = 6 * 1024     -- лимит одного раздела
local FIX_AGENT_TIMEOUT = 300          -- таймаут headless-запроса к агенту, сек
-- Имя каталога внутри эфемерной сессии ядра начинается с этого префикса (за ним идёт счётчик)
local FIX_TMP_PREFIX = "grime-fix."

--- Проверка, что путь — каталог fix-сессии (имя начинается с префикса, без обхода вверх)
local function is_fix_dir(dir)
    local base = tostring(dir):match("([^/]+)$") or ""
    return base:sub(1, #FIX_TMP_PREFIX) == FIX_TMP_PREFIX and not tostring(dir):find("..", 1, true)
end

-- Внедряемые зависимости (подменяются в тестах)
local deps = {}

local function get_ai()
    if deps.ai == nil then
        local ok, mod = pcall(require, "ai")
        deps.ai = ok and mod or false
    end
    return deps.ai or nil
end

local function get_registry()
    if deps.registry == nil then
        deps.registry = require("agents.registry")
    end
    return deps.registry
end

-- Каталоги, созданные в этом запуске: удаляются в cleanup() даже при прерывании
local pending_dirs = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Экранирование строки для одинарных кавычек shell
local function sh_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- ---------------------------------------------------------------------
-- Чистка секретов
-- ---------------------------------------------------------------------

local SENSITIVE_NAMES = { "key", "token", "secret", "passw", "pwd", "credential", "auth" }

local function is_sensitive_name(name)
    local low = name:lower()
    for _, part in ipairs(SENSITIVE_NAMES) do
        if low:find(part, 1, true) then return true end
    end
    return false
end

--- Известные формы токенов (по слову целиком)
local function is_token_shape(w)
    if #w < 20 then return false end
    return w:match("^sk%-[%w_%-]+$") ~= nil
        or w:match("^gh[pousr]_[%w]+$") ~= nil
        or w:match("^github_pat_[%w_]+$") ~= nil
        or w:match("^xox[abprs]%-[%w%-]+$") ~= nil
        or w:match("^AKIA[%u%d]+$") ~= nil
        or w:match("^eyJ[%w_%-]+%.[%w_%-]+%.[%w_%-]+$") ~= nil
end

local function sanitize_line(line)
    -- URL с user:pass@
    line = line:gsub("(%a[%w+.%-]*://[^/%s:@]+):[^/%s@]+@", "%1:***@")
    -- Заголовок Authorization: всё до конца строки
    line = line:gsub("([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]%s*:%s*).*$", "%1***")
    -- ИМЯ=значение / имя: значение для чувствительных имён
    line = line:gsub("([%w_%.%-]+)(%s*[=:]%s*)([\"']?)([^%s\"',;]+)", function(name, sep, q, val)
        if val ~= "***" and is_sensitive_name(name) then
            return name .. sep .. q .. "***"
        end
    end)
    -- Флаги --password foo / --token foo
    line = line:gsub("(%-%-[%w%-]*)(%s+)(%S+)", function(flag, sp, val)
        if is_sensitive_name(flag) and val ~= "***" then
            return flag .. sp .. "***"
        end
    end)
    -- Публичные ключи ssh и токены известных форматов
    line = line:gsub("(ssh%-[%w]+%s+)[%w+/=]+", "%1***")
    line = line:gsub("%S+", function(w)
        if is_token_shape(w) then return "***" end
    end)
    return line
end

--- Маскирование секретов во всём тексте (PEM-блоки, пароли, токены, URL с учётными данными)
local function sanitize_secrets(text)
    if type(text) ~= "string" or text == "" then return text or "" end
    -- Приватные ключи: целые блоки, оборванный блок до конца, оборванный хвост в начале
    text = text:gsub("%-%-%-%-%-BEGIN [%u ]-PRIVATE KEY%-%-%-%-%-.-%-%-%-%-%-END [%u ]-PRIVATE KEY%-%-%-%-%-", "[PEM-КЛЮЧ СКРЫТ]")
    text = text:gsub("%-%-%-%-%-BEGIN [%u ]-PRIVATE KEY%-%-%-%-%-.*$", "[PEM-КЛЮЧ СКРЫТ]")
    text = text:gsub("^.-%-%-%-%-%-END [%u ]-PRIVATE KEY%-%-%-%-%-", "[PEM-КЛЮЧ СКРЫТ]")
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        out[#out + 1] = sanitize_line(line)
    end
    return (table.concat(out, "\n"):gsub("\n$", ""))
end

--- Хвост текста не более n байт по границе строки
local function tail_bytes(text, n)
    text = text or ""
    if #text <= n then return text end
    local cut = text:sub(#text - n + 1)
    local nl = cut:find("\n", 1, true)
    if nl then cut = cut:sub(nl + 1) end
    return "[…обрезано…]\n" .. cut
end

--- Последние n строк текста
local function tail_lines(text, n)
    local lines = {}
    for l in (text or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
    if #lines <= n then return table.concat(lines, "\n") end
    return table.concat(lines, "\n", #lines - n + 1)
end

-- ---------------------------------------------------------------------
-- Сбор контекста
-- ---------------------------------------------------------------------

local function capture_text(cmd, line_limit)
    local ok, res = pcall(ctx.capture, cmd)
    if not ok or type(res) ~= "table" then return nil end
    local out = res.stdout or ""
    if out:match("%S") == nil then return nil end
    return tail_lines(out, line_limit or 60)
end

--- Сбор разделов контекста: список { title, body } (только то, что доступно)
local function collect_context_sections()
    local sections = {}
    local function add(title, body)
        if body and body:match("%S") then
            sections[#sections + 1] = { title = title, body = body }
        end
    end

    -- Отчёт doctor: наличие утилит и ключевых каталогов
    local rep = {}
    for _, name in ipairs({ "git", "nix", "distrobox", "cargo", "claude", "aider", "journalctl", "pacman" }) do
        rep[#rep + 1] = string.format("%s: %s", name, utils.has_binary(name, ctx) and "есть" or "нет")
    end
    pcall(function()
        for _, p in ipairs({ { "config", ctx.config_dir() }, { "projects", ctx.get_path("projects") },
                             { "apps", ctx.get_path("apps") } }) do
            rep[#rep + 1] = string.format("каталог %s: %s", p[1], ctx.exists(p[2]) and "существует" or "отсутствует")
        end
    end)
    add("Отчёт doctor", table.concat(rep, "\n"))

    -- Последние ошибки журнала grime
    pcall(function()
        local lines = {}
        for _, e in ipairs(log.get_errors(10) or {}) do
            lines[#lines + 1] = string.format("[%s] %s: %s", e.level or "ERROR", e.source or "?", e.message or "")
        end
        add("Ошибки журнала grime", table.concat(lines, "\n"))
    end)

    -- Последняя упавшая команда
    pcall(function()
        local val = grime.bus.get("daemon.terminal_dump")
        if type(val) == "string" and val:sub(1, 1) == "{" then
            local ok, parsed = pcall(grime.json.decode, val)
            if ok then val = parsed end
        end
        if type(val) == "table" then
            add("Последняя упавшая команда", string.format("cmd: %s\nстатус: %s\ncwd: %s\nвывод:\n%s",
                tostring(val.cmd), tostring(val.status), tostring(val.cwd),
                tail_bytes(tostring(val.output or ""), 3 * 1024)))
        end
    end)

    if utils.has_binary("journalctl", ctx) then
        add("journalctl --user -p 3 -b (хвост)",
            capture_text({ "journalctl", "--user", "-p", "3", "-b", "--no-pager", "-n", "60" }, 60))
        add("journalctl -p 3 -b (хвост)",
            capture_text({ "journalctl", "-p", "3", "-b", "--no-pager", "-n", "60" }, 60))
    end
    if utils.has_binary("systemctl", ctx) then
        add("Упавшие юниты (только чтение)",
            capture_text({ "systemctl", "--failed", "--no-pager", "--plain" }, 30))
    end
    if utils.has_binary("pacman", ctx) then
        add("pacman: сироты (-Qdtq)", capture_text({ "pacman", "-Qdtq" }, 30))
        add("pacman: обновления по локальной базе (-Qu)", capture_text({ "pacman", "-Qu" }, 40))
    end
    return sections
end

--- Чистка и ограничение размера разделов; возвращает очищенные разделы и общий размер
local function prepare_sections(sections, user_text)
    local prepared, total = {}, 0
    local function push(title, body)
        body = sanitize_secrets(tail_bytes(body, FIX_SECTION_LIMIT))
        if total + #body > FIX_CONTEXT_LIMIT then
            body = tail_bytes(body, math.max(0, FIX_CONTEXT_LIMIT - total))
        end
        if body:match("%S") then
            prepared[#prepared + 1] = { title = title, body = body }
            total = total + #body
        end
    end
    if user_text and user_text ~= "" then push("Описание проблемы от пользователя", user_text) end
    for _, s in ipairs(sections) do push(s.title, s.body) end
    return prepared, total
end

local FIX_SYSTEM_PROMPT = [[
Ты — ассистент по починке Linux-окружения (CachyOS, оболочка Fish, Nix, distrobox).
Ниже собран диагностический контекст; секреты в нём уже замаскированы.
1. Проанализируй данные и дай диагноз обычным текстом на русском: вероятная причина и уверенность (в процентах).
2. Если исправление возможно, выдай bash-скрипт СТРОГО внутри тега <grime_fix>…</grime_fix> (без markdown-ограждений).
Требования к скрипту:
- пронумерованные шаги; перед каждым шагом комментарий «# Шаг N: что делаем и зачем» и строка «# Откат: как отменить шаг»;
- никаких интерактивных вопросов и ожидания ввода;
- sudo только там, где реально нужны права root, и ТОЛЬКО в начале строки (без sudo в конвейерах, подстановках, &&, ||; запись в системные файлы — через `sudo cp`/`sudo install` из временного файла);
- без $(...) и обратных кавычек, без heredoc (<<), без sudo -i/-s/-u/-S, без su/doas/pkexec;
- без systemctl и pacman -S/-R/-U (опиши такие действия в диагнозе, пользователь выполнит сам);
- без rm -rf вне явных конкретных путей (только полные абсолютные пути; никаких /, ~, $HOME, масок и переменных), без curl|sh и wget|sh, без dd/mkfs/fdisk;
- если автоматическое исправление невозможно или рискованно — не выдавай тег, только диагноз.
Ты не должен ничего выполнять сам и менять файлы: только анализ и текст ответа.
]]

local function build_prompt(prepared)
    local parts = { FIX_SYSTEM_PROMPT, "=== ДИАГНОСТИЧЕСКИЙ КОНТЕКСТ ===" }
    for _, s in ipairs(prepared) do
        parts[#parts + 1] = string.format("--- %s ---\n%s", s.title, s.body)
    end
    return table.concat(parts, "\n\n")
end

-- ---------------------------------------------------------------------
-- Разбор ответа и проверка скрипта
-- ---------------------------------------------------------------------

--- Извлечение диагноза и скрипта: возвращает diagnosis, script|nil, err|nil
local function extract_fix(text)
    text = text or ""
    local script = text:match("<grime_fix>(.-)</grime_fix>")
    if not script then
        if text:find("<grime_fix>", 1, true) then
            return trim((text:gsub("<grime_fix>.*$", ""))), nil,
                "тег <grime_fix> не закрыт (ответ обрезан), скрипт отброшен"
        end
        return trim(text), nil, nil
    end
    local diagnosis = trim((text:gsub("<grime_fix>.-</grime_fix>", "", 1)))
    -- снимаем markdown-ограждения на случай, если агент их добавил
    script = script:gsub("^%s*```[%w]*\n", ""):gsub("\n```%s*$", "")
    script = trim(script)
    if script == "" then return diagnosis, nil, nil end
    return diagnosis, script, nil
end

--- Разбиение скрипта на логические строки (склейка \-продолжений); пропуск пустых и комментариев
local function logical_lines(script)
    local result, buf, start_no, n = {}, nil, 0, 0
    local function flush()
        local t = trim(buf)
        if t ~= "" and not t:match("^#") then
            result[#result + 1] = { no = start_no, text = t }
        end
        buf = nil
    end
    for raw in (script .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        local line = raw:gsub("\r$", "")
        if buf then
            buf = buf .. " " .. trim(line)
        else
            buf, start_no = line, n
        end
        if buf:match("\\$") then
            buf = buf:gsub("\\$", "")
        else
            flush()
        end
    end
    if buf then flush() end
    return result
end

-- Опции повышения привилегий, допустимые в скрипте (остальные — обход правил или пароль через stdin)
local SUDO_OK_FLAGS = { ["-E"] = true, ["-H"] = true, ["-k"] = true }

--- Снятие ведущего sudo: возвращает остаток, был_sudo, ошибка
local function strip_sudo(line)
    local rest = line:match("^sudo%s+(.+)$")
    if not rest then
        if line == "sudo" then return nil, true, "sudo без команды" end
        return line, false, nil
    end
    while true do
        local flag, tail = rest:match("^(%-%S*)%s*(.*)$")
        if not flag then break end
        if flag == "--" then
            rest = tail
            break
        end
        if not SUDO_OK_FLAGS[flag] then
            return nil, true, "недопустимая опция sudo " .. flag .. " (разрешены -E, -H, -k)"
        end
        rest = tail
    end
    if rest == "" then return nil, true, "sudo без команды" end
    return rest, true, nil
end

--- Проверка скрипта: { ok, blockers = {{no,text,reason}}, sudo_lines = {{no,text}}, risks = {строки} }
--- Повышение привилегий разрешено только как ведущее слово строки; остаток строки
--- проверяется ai.validate_command_security (она же ловит вторичные sudo/su/doas/pkexec)
local function check_script(script, validate)
    local res = { ok = true, blockers = {}, sudo_lines = {}, risks = {} }
    if not validate then
        local ai = get_ai()
        validate = ai and ai.validate_command_security
    end
    if not validate then
        res.ok = false
        res.blockers[1] = { no = 0, text = "", reason = "модуль ai недоступен: проверка безопасности невозможна" }
        return res
    end
    local home = os.getenv("HOME") or ""
    local function block(l, reason)
        res.ok = false
        res.blockers[#res.blockers + 1] = { no = l.no, text = l.text, reason = reason }
    end

    for _, l in ipairs(logical_lines(script)) do
        local line = l.text
        if line:find("<<", 1, true) then
            block(l, "heredoc и here-string не поддерживаются")
        elseif line:match("|%s*[%w/%.]*sh%f[%W]") or line:match("|%s*[%w/%.]*bash%f[%W]") then
            block(l, "передача данных в оболочку через конвейер (curl|sh) запрещена")
        else
            local rest, had_sudo, err = strip_sudo(line)
            if err then
                block(l, err)
            else
                if had_sudo then res.sudo_lines[#res.sudo_lines + 1] = { no = l.no, text = line } end
                local ok, verr = validate(rest, home)
                if not ok then
                    local reason = tostring(verr or "отклонено проверкой"):gsub("^%[Grime Security%] Команда отклонена: ", "")
                    if had_sudo and reason:find("системных файлов", 1, true) then
                        -- для sudo правка системных путей — ожидаемое действие: только предупреждение
                        res.risks[#res.risks + 1] = string.format("строка %d: затрагивает системные пути (sudo): %s", l.no, line)
                    else
                        block(l, reason)
                    end
                else
                    local head = rest:match("^(%S+)") or ""
                    if had_sudo then
                        res.risks[#res.risks + 1] = string.format("строка %d: выполняется с правами root: %s", l.no, line)
                    elseif head == "rm" or head == "mv" or head == "chmod" or head == "chown" then
                        res.risks[#res.risks + 1] = string.format("строка %d: изменение/удаление файлов: %s", l.no, line)
                    end
                end
            end
        end
    end
    return res
end

-- ---------------------------------------------------------------------
-- Запуск скрипта в окне терминала
-- ---------------------------------------------------------------------

-- Формы запуска программы в окне терминала (argv программы добавляется в конец)
local TERMINAL_FORMS = {
    ghostty = { "--gtk-single-instance=false", "-e" },
    kitty = {},
    foot = {},
    alacritty = { "-e" },
    wezterm = { "start", "--" },
    konsole = { "-e" },
    ["gnome-terminal"] = { "--wait", "--" },
    xterm = { "-e" },
}

--- Выбор терминала: $TERMINAL, иначе ghostty. Возвращает argv-префикс или nil, причина
local function resolve_terminal()
    local has_display = trim(os.getenv("DISPLAY")) ~= "" or trim(os.getenv("WAYLAND_DISPLAY")) ~= ""
    if not has_display then return nil, "нет DISPLAY/WAYLAND_DISPLAY" end
    local term = trim(os.getenv("TERMINAL"))
    if term == "" then term = "ghostty" end
    local words = {}
    for w in term:gmatch("%S+") do words[#words + 1] = w end
    local bin = words[1]
    local base = bin:match("([^/]+)$") or bin
    if not utils.has_binary(bin, ctx) then
        return nil, "терминал '" .. bin .. "' не найден"
    end
    local argv = {}
    for _, w in ipairs(words) do argv[#argv + 1] = w end
    for _, f in ipairs(TERMINAL_FORMS[base] or { "-e" }) do argv[#argv + 1] = f end
    return argv, nil
end

--- Создание приватного каталога (0700): grime.ephemeral.dir, запасной вариант — mktemp -d
local function make_private_dir()
    local dir
    if grime.ephemeral and grime.ephemeral.dir then
        local ok, d = pcall(grime.ephemeral.dir, FIX_TMP_PREFIX)
        dir = ok and d or nil
    else
        local res = ctx.capture({ "mktemp", "-d", "-t", "grime-fix.XXXXXXXX" })
        dir = trim(res and res.stdout)
        if not res or res.code ~= 0 then dir = nil end
        if dir and dir:sub(1, 5) ~= "/tmp/" then dir = nil end
    end
    if not dir or dir == "" or not is_fix_dir(dir) then return nil end
    pending_dirs[#pending_dirs + 1] = dir
    return dir
end

--- Удаление каталога (идемпотентно); true, если каталога больше нет
local function remove_dir(dir)
    if not is_fix_dir(dir) then return false end
    if ctx.exists(dir) then
        pcall(ctx.delete, dir, true)
        if ctx.exists(dir) then
            pcall(ctx.capture, { "rm", "-rf", "--", dir })
        end
    end
    return not ctx.exists(dir)
end

local function cleanup()
    for _, d in ipairs(pending_dirs) do pcall(remove_dir, d) end
    pending_dirs = {}
end

--- Текст запускаемого файла: ловушки очистки, set -euo pipefail, код возврата, пауза
local function build_runner(script, dir, rc_file)
    return table.concat({
        "#!/usr/bin/env bash",
        "# Эфемерный скрипт grime doctor -fix: удаляется при выходе",
        "DIR=" .. sh_quote(dir),
        "RCFILE=" .. sh_quote(rc_file),
        "trap 'rm -rf -- \"$DIR\"' EXIT",
        "trap 'exit 130' INT TERM HUP",
        "set -uo pipefail",
        "echo '=== grime doctor -fix: выполнение скрипта исправления ==='",
        "(",
        "set -euo pipefail",
        script,
        ")",
        "rc=$?",
        "printf '%s\\n' \"$rc\" > \"$RCFILE\"",
        "if [ \"$rc\" -eq 0 ]; then echo '=== Готово: скрипт завершён успешно ==='; else echo \"=== ОШИБКА: скрипт прерван, код $rc ===\"; fi",
        "if [ -z \"${GRIME_FIX_NOPAUSE:-}\" ]; then read -r -p 'Нажмите Enter для закрытия окна' _ || true; fi",
        "exit \"$rc\"",
        "",
    }, "\n")
end

--- Запуск: окно терминала либо текущий TTY. Возвращает код скрипта (или nil), режим, ошибку
local function run_fix_script(script)
    local dir = make_private_dir()
    local rdir = make_private_dir()
    if not dir or not rdir then return nil, "-", "не удалось создать приватный каталог" end
    local rc_file = rdir .. "/rc"
    local path = dir .. "/fix.sh"

    local f = io.open(path, "w")
    if not f then return nil, "-", "не удалось создать файл скрипта" end
    f:write(build_runner(script, dir, rc_file))
    f:close()
    ctx.capture({ "chmod", "700", path })

    local term_argv, why = resolve_terminal()
    local mode, ok, err
    if term_argv then
        mode = "окно " .. term_argv[1]
        local cmd = {}
        for _, a in ipairs(term_argv) do cmd[#cmd + 1] = a end
        cmd[#cmd + 1] = "bash"
        cmd[#cmd + 1] = path
        grime.ui.log("Запускаю скрипт в окне терминала (" .. term_argv[1] .. "); пароль sudo вводится только в нём...")
        ok, err = pcall(ctx.run_interactive, cmd)
    else
        mode = "текущий TTY"
        grime.ui.warn("Окно терминала недоступно (" .. tostring(why) .. "): запуск в текущем TTY.")
        ok, err = pcall(ctx.run_interactive, { "bash", path }, nil, { GRIME_FIX_NOPAUSE = "1" })
    end

    local rc
    local rf = io.open(rc_file, "r")
    if rf then
        rc = tonumber(trim(rf:read("*a")))
        rf:close()
    end

    -- Страховочное удаление в любом случае
    local clean = remove_dir(dir)
    clean = remove_dir(rdir) and clean
    if not clean then
        grime.ui.warn("Не удалось удалить временные каталоги: " .. dir .. " , " .. rdir)
    end
    return rc, mode, (not ok) and tostring(err) or nil
end

-- ---------------------------------------------------------------------
-- Интерактивные подтверждения
-- ---------------------------------------------------------------------

local function has_tty()
    return os.execute("test -t 0") and true or false
end

local function ask_yes(prompt)
    io.stdout:write(prompt .. " [y/N]: ")
    io.stdout:flush()
    local low = trim(io.read()):lower()
    return low == "y" or low == "yes" or low == "д" or low == "да"
end

-- ---------------------------------------------------------------------
-- Основной сценарий -fix
-- ---------------------------------------------------------------------

--- Разбор аргументов режима fix: { fix, dry, yes, text }
local function parse_fix_args(args)
    local o = { fix = false, dry = false, yes = false }
    local words = {}
    for _, a in ipairs(args or {}) do
        if a == "-fix" or a == "--fix" then
            o.fix = true
        elseif a == "-dry" or a == "--dry" or a == "-n" then
            o.dry = true
        elseif a == "-yes" or a == "--yes" or a == "-y" then
            o.yes = true
        else
            words[#words + 1] = a
        end
    end
    o.text = trim(table.concat(words, " "))
    return o
end

--- Выбор агента: doctor_agent -> ai_agent -> claude
local function pick_agent()
    local function cfg(key)
        local v = trim(ctx.get_config(key, "auto")):lower()
        if v ~= "" and v ~= "auto" then return v end
    end
    return get_registry().resolve(cfg("doctor_agent") or cfg("ai_agent") or "claude", ctx)
end

local function one_line(s, n)
    s = trim((tostring(s or ""):gsub("%s+", " ")))
    if #s > n then s = s:sub(1, n - 1) .. "…" end
    return s
end

local function run_fix(opts)
    local prepared, total = prepare_sections(collect_context_sections(), opts.text)
    local prompt = build_prompt(prepared)

    print(string.format("%sСводка: что будет отправлено агенту%s", ANSI.BOLD, ANSI.RESET))
    for _, s in ipairs(prepared) do
        print(string.format("  • %s (%d Б)", s.title, #s.body))
    end
    print(string.format("  Итого контекста: %d Б из %d Б (секреты замаскированы), промпт: %d Б\n", total, FIX_CONTEXT_LIMIT, #prompt))

    if opts.dry then
        print(string.format("%s-dry: ничего не отправляется и не запускается.%s", ANSI.DIM, ANSI.RESET))
        ctx.success("")
        return
    end

    if not opts.yes then
        if not has_tty() then
            ctx.fail("Отправка данных агенту требует подтверждения: в неинтерактивном режиме добавьте -yes (-y)")
            return
        end
        if not ask_yes("Отправить этот контекст ИИ-агенту?") then
            ctx.fail("Отправка отменена пользователем")
            return
        end
    end

    local agent, aerr = pick_agent()
    if not agent then ctx.fail(aerr or "ИИ-агент не найден") return end
    if not agent:is_available(ctx) then
        ctx.fail(string.format("ИИ-агент '%s' не найден в $PATH", agent.name))
        return
    end

    local hopts = { prompt = prompt, working_dir = os.getenv("HOME") }
    if agent.name == "claude" then
        -- только анализ: без инструментов и правок
        hopts.permission_mode = "plan"
        hopts.passthrough_args = { "--tools", "" }
    end
    local cmd = agent:build_headless_cmd(hopts, ctx)
    if not cmd then ctx.fail("Агент не поддерживает headless-запуск") return end
    table.insert(cmd, 1, "timeout")
    table.insert(cmd, 2, tostring(FIX_AGENT_TIMEOUT))
    hopts.cmd = cmd

    grime.ui.log(string.format("Запрос к агенту %s (до %d с)...", agent.name, FIX_AGENT_TIMEOUT))
    local res = agent:run_headless(hopts, ctx)
    if not res.ok then
        ctx.fail(string.format("Агент завершился с кодом %s: %s", tostring(res.code), one_line(res.stderr, 300)))
        return
    end

    local diagnosis, script, xerr = extract_fix(res.text)
    local ai = get_ai()
    print()
    if diagnosis ~= "" then
        print(string.format("%sДиагноз:%s", ANSI.BOLD, ANSI.RESET))
        print((ai and ai.render_terminal_markdown) and ai.render_terminal_markdown(diagnosis) or diagnosis)
    else
        print("Агент не вернул текстового диагноза.")
    end
    local diag_line = one_line(diagnosis, 200)
    if xerr then grime.ui.warn(xerr) end

    if not script then
        log.info(string.format("doctor -fix: только диагноз (агент %s): %s", agent.name, diag_line), "doctor")
        ctx.success("doctor_fix_diagnosis_only")
        return
    end

    local h = ctx.capture({ "sha256sum" }, nil, nil, script)
    local hash = (h and h.stdout or ""):match("^(%x+)") or "n/a"
    print(string.format("\n%sСкрипт исправления (целиком):%s", ANSI.BOLD, ANSI.RESET))
    print(ANSI.DIM .. string.rep("-", 60) .. ANSI.RESET)
    print(script)
    print(ANSI.DIM .. string.rep("-", 60) .. ANSI.RESET)
    print("SHA-256: " .. hash)

    local check = check_script(script)
    if #check.sudo_lines > 0 then
        print(string.format("%sСтроки с sudo (%d):%s", ANSI.YELLOW, #check.sudo_lines, ANSI.RESET))
        for _, s in ipairs(check.sudo_lines) do print(string.format("  %d: %s", s.no, s.text)) end
    else
        print("Строк с sudo нет.")
    end
    if #check.risks > 0 then
        print(string.format("%sОбнаруженные риски:%s", ANSI.YELLOW, ANSI.RESET))
        for _, r in ipairs(check.risks) do print("  • " .. r) end
    end
    if not check.ok then
        print(string.format("%sСкрипт ЗАБЛОКИРОВАН проверкой безопасности и не будет запущен:%s", ANSI.RED, ANSI.RESET))
        for _, b in ipairs(check.blockers) do
            print(string.format("  строка %d: %s — %s", b.no, b.text, b.reason))
        end
        log.warn(string.format("doctor -fix: скрипт заблокирован (sha256=%s, нарушений=%d)", hash, #check.blockers), "doctor")
        ctx.fail("Скрипт исправления заблокирован проверкой безопасности")
        return
    end

    -- --yes на запуск скрипта не распространяется (root-права): всегда интерактивно
    if not has_tty() then
        ctx.fail("Запуск скрипта требует интерактивного подтверждения (TTY недоступен)")
        return
    end
    if not ask_yes("Запустить этот скрипт? Пароль sudo будет запрошен в окне терминала") then
        log.info(string.format("doctor -fix: запуск отклонён пользователем (sha256=%s)", hash), "doctor")
        ctx.fail("Запуск отклонён пользователем")
        return
    end

    local rc, mode, rerr = run_fix_script(script)
    log.info(string.format("doctor -fix: sha256=%s, режим=%s, код=%s, диагноз: %s",
        hash, tostring(mode), tostring(rc), diag_line), "doctor")
    if rerr then grime.ui.warn("Ошибка запуска: " .. rerr) end
    if rc == 0 then
        grime.ui.success("Скрипт исправления выполнен успешно.")
        ctx.success("doctor_fix_ok")
    elseif rc == nil then
        ctx.fail("Код возврата скрипта не получен (окно закрыто до завершения или запуск не удался)")
    else
        ctx.fail("Скрипт исправления завершился с кодом " .. tostring(rc))
    end
end

local function main()
    local fix_opts = parse_fix_args(ctx.args)
    if fix_opts.fix then
        local ok, err = pcall(run_fix, fix_opts)
        cleanup()
        if not ok then ctx.fail("doctor -fix: " .. tostring(err)) end
        return
    end

    for _, a in ipairs(ctx.args or {}) do
        if type(a) == "string" and a:match("^%-") then
            local matched = grime.fuzzy and grime.fuzzy.match_flag(a, { "--help", "-h", "-help" }, 0.75) or a
            if matched == "--help" or matched == "-h" or matched == "-help" then
                print_help()
                return
            end
        end
    end

    grime.ui.log("Запуск комплексной диагностики окружения Grime Doctor...")

    local checks = {
        { name = "git", category = "Инструменты" },
        { name = "nix", category = "Пакеты/Окружение" },
        { name = "distrobox", category = "Контейнеры" },
        { name = "cargo", category = "Сборка" },
        { name = "claude", category = "ИИ/Разработка" },
        { name = "aider", category = "ИИ/Разработка" },
    }

    local rows = {}
    local all_ok = true

    for _, c in ipairs(checks) do
        local found = utils.has_binary(c.name, ctx)
        local path = found and find_in_path(c.name) or "-"
        table.insert(rows, { c.category, c.name, found and "Доступен" or "Не найден", path })
        if not found and c.name == "git" then
            all_ok = false
        end
    end

    -- Проверка путей реестра
    local cfg_dir = ctx.config_dir()
    local log_dir = cfg_dir .. "/logs"
    local log_file = log_dir .. "/grime.jsonl"

    local paths_to_check = {
        { name = "Конфигурация", path = cfg_dir },
        { name = "Проекты", path = ctx.get_path("projects") },
        { name = "Шаблоны", path = ctx.get_path("templates") },
        { name = "Приложения", path = ctx.get_path("apps") },
        { name = "Журнал логов", path = log_dir },
    }

    for _, p in ipairs(paths_to_check) do
        local exists = ctx.exists(p.path)
        local status = exists and "Существует" or "Отсутствует"
        table.insert(rows, { "Каталог", p.name, status, p.path })
    end

    -- Печать отчета компонентов через grime.ui.print_table
    local headers = { "Категория", "Компонент", "Статус", "Путь" }
    print()
    grime.ui.print_table(rows, headers)
    print()

    -- Проверка состояния подсистемы логов и недавних ошибок
    local recent_errors = log.get_errors(5)
    local log_exists = ctx.exists(log_file)
    local history = log.get_history(100)

    print(string.format("%sСостояние подсистемы логирования и здоровья системы:%s", ANSI.BOLD, ANSI.RESET))
    print(string.format("  • Файл логов: %s (%s)", log_file, log_exists and (ANSI.GREEN .. "Активен" .. ANSI.RESET) or (ANSI.YELLOW .. "Не создан" .. ANSI.RESET)))
    print(string.format("  • Записей в истории: %d", #history))
    print(string.format("  • Зафиксировано ошибок/сбоев: %s%d%s", #recent_errors > 0 and ANSI.RED or ANSI.GREEN, #recent_errors, ANSI.RESET))

    if #recent_errors > 0 then
        print(string.format("\n%sПоследние недавние сбои в системе (StateBus):%s", ANSI.RED .. ANSI.BOLD, ANSI.RESET))
        for i, err_item in ipairs(recent_errors) do
            local ts = err_item.timestamp or "-"
            if #ts > 19 then ts = ts:sub(1, 19):gsub("T", " ") end
            print(string.format("  %d. [%s] [%s] %s: %s", i, ts, err_item.level or "ERROR", err_item.source or "unknown", err_item.message or ""))
        end
        print()
    else
        print(string.format("  • Недавние системные сбои: %sотсутствуют (система стабильна)%s\n", ANSI.GREEN, ANSI.RESET))
    end

    if all_ok and #recent_errors == 0 then
        grime.ui.success("Диагностика Grime Doctor завершена: окружение и журнал ошибок в идеальном порядке!")
        log.info("Диагностика Doctor завершена успешно: все компоненты в порядке", "doctor")
        ctx.success("")
    elseif all_ok and #recent_errors > 0 then
        grime.ui.warn(string.format("Диагностика компонентов пройдена, но в журнале зафиксировано %d сбоев.", #recent_errors))
        log.warn(string.format("Диагностика Doctor: обнаружены недавние сбои (%d)", #recent_errors), "doctor")
        ctx.success("doctor_with_errors")
    else
        grime.ui.warn("Обнаружены отсутствующие критические компоненты. Рекомендуется установить недостающие утилиты.")
        log.warn("Диагностика Doctor: отсутствуют критические компоненты", "doctor")
        ctx.success("doctor_warnings")
    end
end

return {
    main = main,
    cleanup = cleanup,
    -- Внутренности для юнит-тестов
    _test = {
        sanitize_secrets = sanitize_secrets,
        extract_fix = extract_fix,
        check_script = check_script,
        build_runner = build_runner,
        parse_fix_args = parse_fix_args,
        tail_bytes = tail_bytes,
        deps = deps,
    },
}
