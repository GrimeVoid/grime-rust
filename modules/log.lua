--@grime description: Централизованный сбор, хранение и фильтрация логов системы
--@grime requires: module:git

-- Описание: Управление логами (кольцевой буфер StateBus, grime.jsonl, фильтрация ошибок, интеграция с Git)

local ctx = grime.ctx
local git = require("git")

local ANSI = {
    BOLD = "\27[1m",
    RESET = "\27[0m",
    GREEN = "\27[32m",
    YELLOW = "\27[33m",
    RED = "\27[31m",
    CYAN = "\27[36m",
    PURPLE = "\27[35m",
    BLUE = "\27[34m",
    DIM = "\27[90m",
}

local M = {}

local MAX_RING_BUFFER = 100

local function get_log_dir()
    local cfg = (ctx.config_dir and ctx.config_dir()) or ((os.getenv("HOME") or "") .. "/.config/grime")
    local log_dir = cfg .. "/logs"
    if not ctx.exists(log_dir) then
        ctx.mkdir_p(log_dir)
    end
    return log_dir
end

local function get_log_file()
    return get_log_dir() .. "/grime.jsonl"
end

local function print_help()
    print(string.format([[
%s%sGrime Log%s — Централизованный сбор, хранение и фильтрация логов системы

%sИСПОЛЬЗОВАНИЕ:%s
    grime log [команда|-флаг|сообщение] [аргументы...]
    <данные> : grime log [уровень]

%sКОМАНДЫ И ФЛАГИ (поддерживаются с '-' / '--' и без):%s
    %slist, -l, --list [n]%s            Показать последние N записей логов (по умолчанию 20)
    %serrors, -e, --errors [n]%s        Показать только ошибки и предупреждения (по умолчанию 10)
    %sgit, -g, --git [n|каталог]%s      Вывести коммиты Git в журнал системы
    %sclear, -c, --clear%s              Очистить историю логов на диске и в шине состояния
    %sadd, -a, --add <уровень> <msg>%s  Добавить произвольную запись в лог (INFO, WARN, ERROR)
    %s-n, --limit <N>%s                 Лимит выводимых записей
    %shelp, -h, --help%s                Показать эту справку

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime log -errors 5 : ai
    echo "Сборка завершена успешно" : grime log --info
    grime log -git 5
    grime doctor : grime log
]],
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.DIM, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

-- Ротация grime.jsonl: при превышении порога остаются последние строки
local MAX_LOG_BYTES = 1024 * 1024
local KEEP_LOG_LINES = 1000
-- Максимальный объём хвоста файла, читаемый за один раз
local TAIL_BYTES = 256 * 1024

local function is_error_level(entry)
    local lvl = tostring(entry.level or ""):upper()
    return lvl == "ERROR" or lvl == "WARN" or lvl == "FAIL"
end

--- Последние n элементов массива (копия), либо сам массив, если он короче
local function tail_slice(list, n)
    if #list <= n then return list end
    local sliced = {}
    for i = #list - n + 1, #list do
        table.insert(sliced, list[i])
    end
    return sliced
end

--- Чтение хвоста файла (не более max_bytes) и разбор строк JSON Lines
local function read_tail_entries(lfile, max_bytes)
    local f = io.open(lfile, "r")
    if not f then return {} end
    local size = f:seek("end") or 0
    local truncated = size > max_bytes
    if truncated then f:seek("set", size - max_bytes) else f:seek("set", 0) end
    local content = f:read("*a") or ""
    f:close()

    local entries = {}
    local first = true
    for line in content:gmatch("[^\r\n]+") do
        -- первая строка усечённого хвоста может быть оборвана
        if not (first and truncated) then
            local ok, item = pcall(grime.json.decode, line)
            if ok and type(item) == "table" then
                table.insert(entries, item)
            end
        end
        first = false
    end
    return entries
end

--- Загрузка записей из файла на диске (последние N записей)
local function load_disk_entries(limit)
    local lfile = get_log_file()
    if not ctx.exists(lfile) then
        return {}
    end
    return tail_slice(read_tail_entries(lfile, TAIL_BYTES), limit or math.huge)
end

--- Ротация журнала на диске: оставляем последние KEEP_LOG_LINES строк
local function rotate_log_if_needed(lfile)
    local f = io.open(lfile, "r")
    if not f then return end
    local size = f:seek("end") or 0
    f:close()
    if size <= MAX_LOG_BYTES then return end

    local f_in = io.open(lfile, "r")
    if not f_in then return end
    f_in:seek("set", math.max(0, size - TAIL_BYTES))
    local content = f_in:read("*a") or ""
    f_in:close()

    local lines = {}
    for line in content:gmatch("[^\r\n]+") do table.insert(lines, line) end
    -- первая строка могла быть оборвана при смещении чтения
    if size > TAIL_BYTES then table.remove(lines, 1) end
    lines = tail_slice(lines, KEEP_LOG_LINES)

    local f_out = io.open(lfile, "w")
    if f_out then
        f_out:write(table.concat(lines, "\n"), "\n")
        f_out:close()
    end
end

--- Запись полной истории (не более MAX_RING_BUFFER) в StateBus одним вызовом.
--- Ошибки выводятся из истории при чтении (log.errors/log.latest отдельно не пишутся).
local function sync_to_state_bus(entries)
    if not (grime and grime.bus) then return end
    pcall(grime.bus.set, "log.history", tail_slice(entries, MAX_RING_BUFFER))
end

--- Добавление записи в лог (программный API и ядро)
function M.add(level, message, source, details)
    local lvl = (level or "INFO"):upper()
    local msg = grime.str.trim(tostring(message or ""))
    local src = source or "grime"
    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local entry = {
        timestamp = timestamp,
        level = lvl,
        source = src,
        message = msg,
        details = details or {},
    }

    -- 1. Запись на диск в формате JSON Lines (с ротацией)
    local lfile = get_log_file()
    local f = io.open(lfile, "a")
    if f then
        f:write(grime.json.encode(entry) .. "\n")
        f:close()
        rotate_log_if_needed(lfile)
    end

    -- 2. Обновление кольцевого буфера в шине: одна запись истории на событие
    local current_history
    local ok, bus_history = pcall(grime.bus.get, "log.history")
    if ok and type(bus_history) == "table" then
        current_history = bus_history
    else
        current_history = load_disk_entries(MAX_RING_BUFFER)
        -- запись уже на диске: убираем её дубль из загруженного хвоста
        local last = current_history[#current_history]
        if last and last.timestamp == timestamp and last.message == msg and last.source == src then
            current_history[#current_history] = nil
        end
    end

    table.insert(current_history, entry)
    sync_to_state_bus(current_history)
    return entry
end

function M.info(message, source, details)
    return M.add("INFO", message, source, details)
end

function M.warn(message, source, details)
    return M.add("WARN", message, source, details)
end

function M.error(message, source, details)
    return M.add("ERROR", message, source, details)
end

--- Полная история (до MAX_RING_BUFFER записей): из шины, иначе с диска с восстановлением шины
local function load_full_history()
    local ok, bus_history = pcall(grime.bus.get, "log.history")
    if ok and type(bus_history) == "table" and #bus_history > 0 then
        return bus_history
    end
    local disk = load_disk_entries(MAX_RING_BUFFER)
    if #disk > 0 then sync_to_state_bus(disk) end
    return disk
end

--- Получение последних limit записей истории (шина не урезается)
function M.get_history(limit)
    return tail_slice(load_full_history(), limit or 20)
end

--- Получение списка ошибок
function M.get_errors(limit)
    local errors = {}
    for _, e in ipairs(load_full_history()) do
        if is_error_level(e) then table.insert(errors, e) end
    end
    return tail_slice(errors, limit or 10)
end

--- Очистка логов
function M.clear()
    local lfile = get_log_file()
    if ctx.exists(lfile) then
        local f = io.open(lfile, "w")
        if f then f:close() end
    end
    if grime and grime.bus then
        pcall(grime.bus.set, "log.history", {})
        -- устаревшие ключи прежних версий
        if grime.bus.delete then
            pcall(grime.bus.delete, "log.latest")
            pcall(grime.bus.delete, "log.errors")
        end
    end
    return true
end

--- Печать таблицы записей лога
local function print_entries_table(entries, title)
    if not entries or #entries == 0 then
        grime.ui.log(title or "Записи логов отсутствуют.")
        return
    end

    local rows = {}
    for _, e in ipairs(entries) do
        local lvl = e.level or "INFO"
        local lvl_col = lvl == "ERROR" and (ANSI.RED .. lvl .. ANSI.RESET)
            or (lvl == "WARN" and (ANSI.YELLOW .. lvl .. ANSI.RESET)
            or (ANSI.GREEN .. lvl .. ANSI.RESET))

        local ts = e.timestamp or "-"
        if #ts > 19 then ts = ts:sub(1, 19):gsub("T", " ") end

        table.insert(rows, {
            ts,
            lvl_col,
            ANSI.CYAN .. (e.source or "grime") .. ANSI.RESET,
            e.message or ""
        })
    end

    local headers = { "Время", "Уровень", "Источник", "Сообщение" }
    print()
    grime.ui.print_table(rows, headers)
    print()
end

local LOG_COMMANDS = {
    list = "list", l = "list", ls = "list",
    errors = "errors", err = "errors", e = "errors",
    git = "git", g = "git",
    clear = "clear", c = "clear", clean = "clear",
    add = "add", a = "add",
    help = "help", h = "help",
}

local function extract_log_limit(args, start_idx, default_limit)
    for i = start_idx, #args do
        local a = tostring(args[i])
        if (a == "-n" or a == "--limit" or a == "-limit") and tonumber(args[i + 1]) then
            return tonumber(args[i + 1])
        elseif a:match("^%-n(%d+)$") then
            return tonumber(a:match("^%-n(%d+)$"))
        elseif tonumber(a) then
            return tonumber(a)
        end
    end
    return default_limit
end

--- Главный обработчик CLI
function M.main()
    local args = ctx.args or {}
    local input = ctx.input or ctx.pipeline_input
    local raw_subcmd = args[1]

    for _, a in ipairs(args) do
        if a == "--" or a == "//" then break end
        if grime.args.is_flag(a) then
            local clean = grime.args.strip_dashes(a:lower())
            if clean == "help" or clean == "h" then
                print_help()
                return
            end
        end
    end

    local subcmd = nil
    if type(raw_subcmd) == "string" and grime.args.is_flag(raw_subcmd) then
        local clean = grime.args.strip_dashes(raw_subcmd:lower())
        if LOG_COMMANDS[clean] then
            subcmd = LOG_COMMANDS[clean]
        elseif clean == "info" or clean == "warn" or clean == "error" or clean == "debug" then
            subcmd = clean:upper()
        end
    end

    if subcmd == "help" then
        print_help()
        return
    end

    -- Обработка пайплайна: echo "msg" : grime log [-info/-warn/-error]
    if input and #input > 0 and (not subcmd or subcmd == "INFO" or subcmd == "WARN" or subcmd == "ERROR" or subcmd == "DEBUG") then
        local level = subcmd or "INFO"
        local entry = M.add(level, input, "pipeline")
        grime.ui.success(string.format("Запись добавлена в лог [%s]: %s", level, input))
        ctx.success(grime.json.encode(entry))
        return
    end

    if subcmd == "clear" then
        M.clear()
        grime.ui.success("История логов успешно очищена на диске и в шине состояния.")
        ctx.success("cleared")
        return
    end

    if subcmd == "errors" then
        local limit = extract_log_limit(args, 2, 10)
        local errs = M.get_errors(limit)

        print_entries_table(errs, "Недавних ошибок и сбоев не зафиксировано.")

        if ctx.has_next_step then
            local lines = {}
            for _, e in ipairs(errs) do
                table.insert(lines, string.format("[%s] [%s] %s: %s", e.timestamp, e.level, e.source, e.message))
            end
            ctx.success(table.concat(lines, "\n"))
        else
            ctx.success(tostring(#errs))
        end
        return
    end

    if subcmd == "git" then
        local target = ctx.target_dir or "."
        local limit = extract_log_limit(args, 2, 10)
        if args[2] and not tonumber(args[2]) and not tostring(args[2]):match("^%-") then
            target = args[2]
        end

        local commits, err = git.log(target, limit)
        if not commits then
            M.error("Не удалось прочитать Git-журнал: " .. tostring(err), "git")
            ctx.fail(err)
            return
        end

        M.info(string.format("Просмотрен журнал Git (%d коммитов) в %s", #commits, target), "git")

        if #commits == 0 then
            grime.ui.log("Коммиты в Git-репозитории отсутствуют.")
            ctx.success("0 commits")
            return
        end

        local rows = {}
        for _, c in ipairs(commits) do
            table.insert(rows, { c.hash, c.author, c.date, c.message })
        end

        local headers = { "Хеш", "Автор", "Дата", "Сообщение" }
        print()
        grime.ui.print_table(rows, headers)
        print()

        if ctx.has_next_step then
            local lines = {}
            for _, c in ipairs(commits) do
                table.insert(lines, string.format("%s - %s (%s)", c.hash, c.message, c.author))
            end
            ctx.success(table.concat(lines, "\n"))
        else
            ctx.success(tostring(#commits))
        end
        return
    end

    if subcmd == "add" then
        local raw_lvl = tostring(args[2] or "INFO"):gsub("^%-+", "")
        local level = raw_lvl:upper()
        local start_msg = 3
        if level ~= "INFO" and level ~= "WARN" and level ~= "ERROR" and level ~= "DEBUG" then
            level = "INFO"
            start_msg = 2
        end
        local msg_tokens = {}
        for i = start_msg, #args do table.insert(msg_tokens, args[i]) end
        local msg = table.concat(msg_tokens, " ")
        if #msg == 0 then msg = input or "" end

        if #msg == 0 then
            ctx.fail("Укажите текст сообщения: grime log add <INFO|WARN|ERROR> <текст>")
            return
        end

        local entry = M.add(level, msg, "cli")
        grime.ui.success(string.format("Лог добавлен [%s]: %s", level, msg))
        ctx.success(grime.json.encode(entry))
        return
    end

    -- Вывод обычного списка логов (grime log или grime log -list [n])
    local limit = 20
    if subcmd == "list" then
        limit = extract_log_limit(args, 2, 20)
    elseif subcmd == "INFO" or subcmd == "WARN" or subcmd == "ERROR" or subcmd == "DEBUG" then
        local msg_tokens = {}
        for i = 2, #args do table.insert(msg_tokens, args[i]) end
        local msg = table.concat(msg_tokens, " ")
        if #msg == 0 then msg = input or "" end
        if #msg > 0 then
            local entry = M.add(subcmd, msg, "user")
            grime.ui.success(string.format("Запись добавлена в лог [%s]: %s", subcmd, msg))
            ctx.success(grime.json.encode(entry))
            return
        end
    elseif not subcmd and #args > 0 then
        -- Если передан произвольный текст без дефиса (например: grime log c или grime log Hello World)
        local msg = table.concat(args, " ")
        local entry = M.add("INFO", msg, "user")
        grime.ui.success(string.format("Запись добавлена в лог [INFO]: %s", msg))
        ctx.success(grime.json.encode(entry))
        return
    else
        limit = extract_log_limit(args, 1, 20)
    end

    local entries = M.get_history(limit)
    print_entries_table(entries, "Журнал логов пока пуст.")

    if ctx.has_next_step then
        local lines = {}
        for _, e in ipairs(entries) do
            table.insert(lines, string.format("[%s] [%s] %s: %s", e.timestamp, e.level, e.source, e.message))
        end
        ctx.success(table.concat(lines, "\n"))
    else
        ctx.success(tostring(#entries))
    end
end

return M
