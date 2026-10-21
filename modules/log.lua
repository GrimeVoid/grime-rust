-- Summary: Централизованный сбор, хранение и фильтрация логов системы
-- Description: Централизованный сбор, хранение и фильтрация логов системы
-- Описание: Управление логами (кольцевой буфер StateBus, grime.jsonl, фильтрация ошибок, интеграция с Git)
description = "Централизованный сбор, хранение и фильтрация логов системы"

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
M.description = description

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
    grime log [команда|сообщение] [аргументы...]
    <данные> : grime log [уровень]

%sКОМАНДЫ:%s
    %slist [n]%s                  Показать последние N записей логов (по умолчанию 20)
    %serrors [n]%s                Показать только ошибки и предупреждения (по умолчанию 10)
    %sgit [n|каталог]%s           Вывести коммиты Git в журнал системы
    %sclear%s                     Очистить историю логов на диске и в шине состояния
    %sadd <уровень> <текст>%s     Добавить произвольную запись в лог (INFO, WARN, ERROR)
    %shelp, -h, --help%s          Показать эту справку

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime log errors 5 : aider
    echo "Сборка завершена успешно" : grime log INFO
    grime log git 5
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
    ANSI.DIM, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

--- Загрузка записей из файла на диске (последние N записей)
local function load_disk_entries(limit)
    local lfile = get_log_file()
    if not ctx.exists(lfile) then
        return {}
    end

    local content = grime.fs.read(lfile)
    if not content or #content == 0 then
        return {}
    end

    local raw_lines = grime.str.split(content, "\n")
    local entries = {}
    for _, line in ipairs(raw_lines) do
        local l = grime.str.trim(line)
        if #l > 0 then
            local ok, item = pcall(grime.json.decode, l)
            if ok and type(item) == "table" then
                table.insert(entries, item)
            end
        end
    end

    if limit and #entries > limit then
        local sliced = {}
        for i = #entries - limit + 1, #entries do
            table.insert(sliced, entries[i])
        end
        return sliced
    end

    return entries
end

--- Синхронизация истории в StateBus
local function sync_to_state_bus(entries)
    if not (grime and grime.bus) then return end

    local bus_entries = {}
    local errors = {}
    local max_count = math.min(#entries, MAX_RING_BUFFER)
    local start_idx = #entries - max_count + 1

    for i = start_idx, #entries do
        table.insert(bus_entries, entries[i])
        local lvl = (entries[i].level or ""):upper()
        if lvl == "ERROR" or lvl == "WARN" or lvl == "FAIL" then
            table.insert(errors, entries[i])
        end
    end

    pcall(grime.bus.set, "log.history", bus_entries)
    if #bus_entries > 0 then
        pcall(grime.bus.set, "log.latest", bus_entries[#bus_entries])
    end
    pcall(grime.bus.set, "log.errors", errors)
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

    -- 1. Запись на диск в формате JSON Lines
    local lfile = get_log_file()
    local json_str = grime.json.encode(entry)
    local f = io.open(lfile, "a")
    if f then
        f:write(json_str .. "\n")
        f:close()
    end

    -- 2. Обновление шины состояния
    local current_history = {}
    local ok, bus_history = pcall(grime.bus.get, "log.history")
    if ok and type(bus_history) == "table" then
        current_history = bus_history
    else
        current_history = load_disk_entries(MAX_RING_BUFFER)
    end

    table.insert(current_history, entry)
    while #current_history > MAX_RING_BUFFER do
        table.remove(current_history, 1)
    end

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

--- Получение всей истории логов
function M.get_history(limit)
    local n = limit or 20
    local ok, bus_history = pcall(grime.bus.get, "log.history")
    if ok and type(bus_history) == "table" and #bus_history > 0 then
        if #bus_history <= n then return bus_history end
        local sliced = {}
        for i = #bus_history - n + 1, #bus_history do
            table.insert(sliced, bus_history[i])
        end
        return sliced
    end

    local disk = load_disk_entries(n)
    sync_to_state_bus(disk)
    return disk
end

--- Получение списка ошибок
function M.get_errors(limit)
    local n = limit or 10
    local ok, bus_errs = pcall(grime.bus.get, "log.errors")
    if ok and type(bus_errs) == "table" and #bus_errs > 0 then
        if #bus_errs <= n then return bus_errs end
        local sliced = {}
        for i = #bus_errs - n + 1, #bus_errs do
            table.insert(sliced, bus_errs[i])
        end
        return sliced
    end

    local all = load_disk_entries(MAX_RING_BUFFER)
    local errors = {}
    for _, e in ipairs(all) do
        local lvl = (e.level or ""):upper()
        if lvl == "ERROR" or lvl == "WARN" or lvl == "FAIL" then
            table.insert(errors, e)
        end
    end

    sync_to_state_bus(all)

    if #errors > n then
        local sliced = {}
        for i = #errors - n + 1, #errors do
            table.insert(sliced, errors[i])
        end
        return sliced
    end
    return errors
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
        pcall(grime.bus.set, "log.latest", nil)
        pcall(grime.bus.set, "log.errors", {})
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

--- Главный обработчик CLI
function M.main()
    local args = ctx.args or {}
    local input = ctx.input or ctx.pipeline_input
    local subcmd = args[1]

    if subcmd == "help" or subcmd == "-h" or subcmd == "--help" then
        print_help()
        return
    end

    -- Обработка пайплайна: echo "msg" : grime log [уровень]
    if input and #input > 0 and (not subcmd or subcmd == "INFO" or subcmd == "WARN" or subcmd == "ERROR") then
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
        local limit = tonumber(args[2]) or 10
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
        local target = args[2] or ctx.target_dir or "."
        local limit = tonumber(args[2]) or tonumber(args[3]) or 10
        if tonumber(args[2]) then target = ctx.target_dir or "." end

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
        local level = (args[2] or "INFO"):upper()
        local msg_tokens = {}
        for i = 3, #args do table.insert(msg_tokens, args[i]) end
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

    -- Вывод обычного списка логов (grime log или grime log list [n])
    local limit = 20
    if subcmd == "list" then
        limit = tonumber(args[2]) or 20
    elseif tonumber(subcmd) then
        limit = tonumber(subcmd)
    elseif subcmd and subcmd ~= "" then
        -- Если передан произвольный текст как лог-сообщение
        local msg_tokens = {}
        for i = 1, #args do table.insert(msg_tokens, args[i]) end
        local msg = table.concat(msg_tokens, " ")
        local entry = M.add("INFO", msg, "user")
        grime.ui.success(string.format("Запись добавлена в лог [INFO]: %s", msg))
        ctx.success(grime.json.encode(entry))
        return
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

function main()
    M.main()
end

return M
