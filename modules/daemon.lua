--@grime description: Управление фоновым сервисом-демоном GRIME и терминальным контекстом


local ctx = grime.ctx
local utils = require("languages.utils")

local function print_help()
    print(string.format([[
%s%sGrime Daemon%s — Управление фоновым сервисом-демоном (grime --daemon-server) и контекстом терминала

%sИСПОЛЬЗОВАНИЕ (действия строго со знаком '-' или '--'):%s
    grime daemon [-status|-s|--status]                   Проверить статус демона и сокета
    grime daemon <-ping|-p|--ping>                       Проверить отклик демона
    grime daemon <-start|--start>                        Запустить демон в фоне (grime --daemon-server)
    grime daemon <-stop|--stop|--kill>                   Остановить работающий демон
    grime daemon <-restart|-r|--restart>                 Перезапустить демон
    grime daemon <-feed|--feed> <cmd> [code] [cwd] [out] Записать событие терминала в StateBus
    grime daemon <-dump|-d|--dump>                       Показать сохраненный терминальный контекст
    grime daemon <-clear|-c|--clear>                     Очистить контекст терминала в шине
    grime daemon <-help|-h|--help>                       Показать эту справку

%sОПИСАНИЕ:%s
    Управляет жизненным циклом демона Grime и оперативным контекстом активного терминала,
    передаваемым AI-ассистентам (Aider) для мгновенного анализа ошибок и сборок.
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function get_socket_path()
    return utils.daemon_socket_path(ctx)
end

--- Запись ключа в шину состояния (персистентность и flock обеспечивает ядро)
local function save_bus_key(key, val)
    if grime and grime.bus and grime.bus.set then
        pcall(grime.bus.set, key, val)
    end
end

local DAEMON_ARG = "--daemon-server"
local STOP_TIMEOUT_SEC = 3

--- Поиск PID демона по точному совпадению /proc/<pid>/cmdline: `<...>/grime --daemon-server`.
--- Родительский sh, pgrep и прочие процессы с подстрокой в командной строке не совпадают.
local function find_daemon_pids()
    local pids = {}
    local ok, entries = pcall(grime.fs.list, "/proc")
    if not ok or type(entries) ~= "table" then return pids end
    for _, name in ipairs(entries) do
        if name:match("^%d+$") then
            local f = io.open("/proc/" .. name .. "/cmdline", "rb")
            if f then
                local raw = f:read("*a") or ""
                f:close()
                local parts = {}
                for part in raw:gmatch("([^%z]+)") do table.insert(parts, part) end
                if #parts == 2 and parts[2] == DAEMON_ARG
                    and (parts[1]:match("([^/]+)$") == "grime"
                        or parts[1] == utils.self_exe())
                    and utils.is_pid_alive(name) then
                    table.insert(pids, name)
                end
            end
        end
    end
    table.sort(pids, function(x, y) return tonumber(x) < tonumber(y) end)
    return pids
end

--- Ожидание условия с опросом (до timeout секунд)
local function wait_until(cond, timeout)
    local deadline = os.time() + timeout
    repeat
        if cond() then return true end
        os.execute("sleep 0.1")
    until os.time() > deadline
    return cond()
end

local function all_dead(pids)
    for _, pid in ipairs(pids) do
        if utils.is_pid_alive(pid) then return false end
    end
    return true
end

--- Остановка процессов демона: SIGTERM, ожидание, при необходимости SIGKILL; сокет удаляется после завершения.
--- Возвращает true, если все процессы завершены.
local function stop_daemon(sock)
    local pids = find_daemon_pids()
    if #pids == 0 then return true end
    for _, pid in ipairs(pids) do ctx.capture({ "kill", "-TERM", pid }) end
    if not wait_until(function() return all_dead(pids) end, STOP_TIMEOUT_SEC) then
        for _, pid in ipairs(pids) do
            if utils.is_pid_alive(pid) then ctx.capture({ "kill", "-KILL", pid }) end
        end
        wait_until(function() return all_dead(pids) end, 1)
    end
    if not all_dead(pids) then return false end
    if ctx.exists(sock) then ctx.delete(sock, true) end
    return true
end

--- Запуск демона в фоне; возвращает PID или nil
local function start_daemon()
    utils.spawn_background({ utils.self_exe(), DAEMON_ARG }, ".", nil, nil, ctx)
    local pids = {}
    wait_until(function()
        pids = find_daemon_pids()
        return #pids > 0
    end, 2)
    return pids[1]
end

local function get_terminal_dump_data()
    local val = nil
    if grime and grime.bus and grime.bus.get then
        local ok, res = pcall(grime.bus.get, "daemon.terminal_dump")
        if ok and res ~= nil then
            val = res
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

local function analyze_terminal_history(history)
    if not history or #history == 0 then
        return nil
    end

    local last = history[#history]
    local is_resolved = false
    local resolved_target = nil

    if last.status == 0 then
        local last_base_cmd = last.cmd:match("^%s*(%S+)") or ""
        for i = #history - 1, 1, -1 do
            local prev = history[i]
            local prev_base_cmd = prev.cmd:match("^%s*(%S+)") or ""
            if prev.status ~= 0 and (prev.cmd == last.cmd or (last_base_cmd ~= "" and last_base_cmd == prev_base_cmd)) then
                is_resolved = true
                resolved_target = prev.cmd
                break
            end
        end
    end

    return {
        is_resolved = is_resolved,
        resolved_target = resolved_target,
    }
end

local DAEMON_ACTIONS = {
    ["-status"] = "status", ["--status"] = "status", ["-s"] = "status", ["-st"] = "status",
    ["-ping"] = "ping", ["--ping"] = "ping", ["-p"] = "ping",
    ["-start"] = "start", ["--start"] = "start", ["-run"] = "start", ["--run"] = "start",
    ["-stop"] = "stop", ["--stop"] = "stop", ["-kill"] = "stop", ["--kill"] = "stop",
    ["-restart"] = "restart", ["--restart"] = "restart", ["-r"] = "restart", ["-reload"] = "restart", ["--reload"] = "restart",
    ["-feed"] = "feed", ["--feed"] = "feed", ["-record"] = "feed", ["--record"] = "feed",
    ["-dump"] = "dump", ["--dump"] = "dump", ["-d"] = "dump",
    ["-clear"] = "clear", ["--clear"] = "clear", ["-c"] = "clear", ["-reset"] = "clear", ["--reset"] = "clear",
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
}

local function main()
    local args = ctx.args or {}
    for _, a in ipairs(args) do
        if type(a) == "string" and a:match("^%-") then
            local matched = grime.fuzzy and grime.fuzzy.match_flag(a, { "--help", "-h", "-help" }, 0.75) or a
            if matched == "--help" or matched == "-h" or matched == "-help" then
                print_help()
                return
            end
        end
    end

    local action = nil
    local action_idx = nil
    for i, a in ipairs(args) do
        if type(a) == "string" and a:match("^%-") then
            local clean = a:lower()
            if DAEMON_ACTIONS[clean] then
                action = DAEMON_ACTIONS[clean]
                action_idx = i
                break
            end
        end
    end

    if #args == 0 then
        action = "status"
    elseif not action then
        ctx.fail("Неизвестная команда daemon: '" .. tostring(args[1]) .. "'. Действия должны начинаться с дефиса ('-status', '-ping', '-start', '-stop', '-dump', '-feed' и др.). Используйте 'grime daemon --help'.")
        return
    end

    if action == "help" then
        print_help()
        return
    end

    local sock = get_socket_path()

    if action == "status" then
        local pids = find_daemon_pids()
        if #pids > 0 then
            local pid = table.concat(pids, ",")
            grime.ui.success(string.format("Демон grime активен (PID: %s, сокет: %s)", pid, sock))
            ctx.success(pid)
        else
            grime.ui.warn("Демон grime не запущен (сокет: " .. sock .. ")")
            ctx.success("stopped")
        end
    elseif action == "ping" then
        local alive = false
        if grime and type(grime.daemon_ping) == "function" then
            local ok, res = pcall(grime.daemon_ping)
            if ok and res then alive = true end
        end
        if not alive then
            alive = #find_daemon_pids() > 0
        end
        if alive then
            grime.ui.success("PONG: демон grime активен")
            ctx.success("PONG")
        else
            ctx.fail("Демон grime недоступен")
        end
    elseif action == "start" then
        local pids = find_daemon_pids()
        if #pids > 0 then
            grime.ui.warn("Демон grime уже запущен (PID: " .. table.concat(pids, ",") .. ")")
            ctx.success("already_running")
            return
        end
        ctx.log("Запуск демона grime в фоне...")
        local pid = start_daemon()
        if pid then
            grime.ui.success(string.format("Демон grime успешно запущен (PID: %s)", pid))
            ctx.success("started")
        else
            ctx.fail("Не удалось запустить демон grime")
        end
    elseif action == "stop" then
        if #find_daemon_pids() == 0 then
            grime.ui.warn("Демон grime не был запущен")
            ctx.success("not_running")
            return
        end
        ctx.log("Остановка демона grime...")
        if stop_daemon(sock) then
            grime.ui.success("Демон grime остановлен")
            ctx.success("stopped")
        else
            ctx.fail("Не удалось остановить процесс grime --daemon-server")
        end
    elseif action == "restart" then
        -- Старый процесс должен завершиться до запуска нового
        if not stop_daemon(sock) then
            ctx.fail("Старый процесс демона не завершился за отведённое время")
            return
        end
        local pid = start_daemon()
        if pid then
            grime.ui.success(string.format("Демон grime успешно перезапущен (PID: %s)", pid))
            ctx.success("restarted")
        else
            ctx.fail("Ошибка перезапуска демона grime")
        end
    elseif action == "feed" or action == "record" then
        local pos_args = {}
        for i, a in ipairs(args) do
            if i ~= action_idx and not (type(a) == "string" and a:match("^%-")) then
                table.insert(pos_args, a)
            end
        end
        local cmd = pos_args[1] or args[2]
        local status = tonumber(pos_args[2] or args[3]) or 0
        local cwd = pos_args[3] or args[4] or os.getenv("PWD") or "."
        local output = pos_args[4] or args[5] or ""

        if not cmd or #cmd == 0 then
            local pipe_in = ctx.input or ctx.pipeline_input
            if pipe_in and #pipe_in > 0 then
                local ok, parsed = pcall(grime.json.decode, pipe_in)
                if ok and type(parsed) == "table" then
                    cmd = parsed.cmd or parsed.command or ""
                    status = tonumber(parsed.status or parsed.code) or 0
                    cwd = parsed.cwd or cwd
                    output = parsed.output or parsed.error or ""
                else
                    cmd = pipe_in
                end
            end
        end

        if not cmd or #cmd == 0 then
            ctx.fail("Укажите команду: grime daemon -feed <cmd> [status_code] [cwd] [output]")
            return
        end

        local current = get_terminal_dump_data() or {}
        local history = current.history or {}
        if type(history) ~= "table" then history = {} end

        local event = {
            timestamp = os.time(),
            time_str = os.date("%Y-%m-%d %H:%M:%S"),
            cmd = cmd,
            status = status,
            cwd = cwd,
            output = output,
        }
        table.insert(history, event)
        while #history > 10 do
            table.remove(history, 1)
        end

        local analysis = analyze_terminal_history(history)
        local dump_data = {
            timestamp = event.timestamp,
            time_str = event.time_str,
            cmd = event.cmd,
            status = event.status,
            cwd = event.cwd,
            output = event.output,
            resolved = analysis and analysis.is_resolved or false,
            resolved_target = analysis and analysis.resolved_target or nil,
            history = history,
        }

        save_bus_key("daemon.terminal_dump", dump_data)

        if status == 0 then
            grime.ui.success(string.format("Терминальное событие записано: '%s' (код 0)", cmd))
        else
            grime.ui.warn(string.format("Терминальное событие с ошибкой записано: '%s' (код %d)", cmd, status))
        end
        ctx.success(grime.json.encode(dump_data))
    elseif action == "dump" then
        local dump_data = get_terminal_dump_data()
        if not dump_data or type(dump_data) ~= "table" or not dump_data.cmd then
            grime.ui.warn("Терминальный контекст пуст (события еще не поступали)")
            ctx.success(nil)
            return
        end

        local lines = {}
        table.insert(lines, string.format("%s%s[Контекст активного терминала]%s", "\27[1m", "\27[36m", "\27[0m"))
        table.insert(lines, string.format("  • Время: %s", dump_data.time_str or os.date("%Y-%m-%d %H:%M:%S", dump_data.timestamp or os.time())))
        table.insert(lines, string.format("  • Команда: %s%s%s", "\27[1m", dump_data.cmd or "(не указана)", "\27[0m"))
        local st_color = (dump_data.status == 0) and "\27[32m" or "\27[31m"
        local st_label = (dump_data.status == 0) and "0 (УСПЕШНО)" or string.format("%d (ОШИБКА)", dump_data.status or 0)
        table.insert(lines, string.format("  • Код возврата: %s%s%s", st_color, st_label, "\27[0m"))
        table.insert(lines, string.format("  • Рабочая директория: %s", dump_data.cwd or "."))

        if dump_data.resolved and dump_data.resolved_target then
            table.insert(lines, string.format("  • %sСтатус проблемы:%s Предыдущая ошибка '%s' УСТРАНЕНА последующим вызовом", "\27[32m\27[1m", "\27[0m", dump_data.resolved_target))
        end

        if dump_data.output and #dump_data.output > 0 then
            table.insert(lines, "  • Вывод / Трейс:")
            for out_line in dump_data.output:gmatch("[^\r\n]+") do
                table.insert(lines, "      " .. out_line)
            end
        end

        if dump_data.history and #dump_data.history > 1 then
            table.insert(lines, string.format("\n  %sИстория недавних команд (%d):%s", "\27[90m", #dump_data.history, "\27[0m"))
            for idx, h in ipairs(dump_data.history) do
                local h_st = (h.status == 0) and "\27[32m✓\27[0m" or string.format("\27[31m✗ (%d)\27[0m", h.status)
                table.insert(lines, string.format("    %d. [%s] %s %s", idx, h.time_str or "", h_st, h.cmd or ""))
            end
        end

        local text_out = table.concat(lines, "\n")
        print(text_out)
        ctx.success(grime.json.encode(dump_data))
    elseif action == "clear" then
        if grime and grime.bus and grime.bus.delete then
            pcall(grime.bus.delete, "daemon.terminal_dump")
        elseif grime and grime.bus and grime.bus.set then
            pcall(grime.bus.set, "daemon.terminal_dump", nil)
        end
        grime.ui.success("Терминальный контекст успешно очищен")
        ctx.success("cleared")
    else
        ctx.fail("Неизвестная команда daemon: " .. action)
    end
end

return {
    main = main,
}
