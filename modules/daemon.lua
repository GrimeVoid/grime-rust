-- Summary: Управление фоновым сервисом-демоном GRIME и терминальным контекстом
-- Description: Управление фоновым сервисом-демоном GRIME и терминальным контекстом
description = "Управление фоновым сервисом-демоном GRIME и терминальным контекстом"

local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Daemon%s — Управление фоновым сервисом-демоном (grime --daemon-server) и контекстом терминала

%sИСПОЛЬЗОВАНИЕ:%s
    grime daemon status                                 Проверить статус демона и сокета
    grime daemon ping                                   Проверить отклик демона
    grime daemon start                                  Запустить демон в фоне (grime --daemon-server)
    grime daemon stop                                   Остановить работающий демон
    grime daemon restart                                Перезапустить демон
    grime daemon feed <cmd> [code] [cwd] [output]       Записать событие терминала в StateBus
    grime daemon dump                                   Показать сохраненный терминальный контекст
    grime daemon clear                                  Очистить контекст терминала в шине

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
    local xdg = os.getenv("XDG_RUNTIME_DIR")
    if xdg and #xdg > 0 then
        return xdg .. "/grime.sock"
    end
    local uid = "default"
    local res = ctx.capture({ "id", "-u" })
    if res and res.code == 0 and res.stdout then
        local u = res.stdout:match("%d+")
        if u and #u > 0 then uid = u end
    end
    if ctx.exists("/run/user/" .. uid) then
        return "/run/user/" .. uid .. "/grime.sock"
    end
    return "/tmp/grime-" .. uid .. ".sock"
end

local function get_state_file()
    local dir = (ctx.config_dir and ctx.config_dir()) or ((os.getenv("HOME") or "") .. "/.config/grime")
    if not ctx.exists(dir) then ctx.mkdir_p(dir) end
    return dir .. "/state.json"
end

local function load_persisted_state()
    local sfile = get_state_file()
    if ctx.exists(sfile) then
        local content = grime.fs.read(sfile)
        if content and #content > 0 then
            local ok, data = pcall(grime.json.decode, content)
            if ok and type(data) == "table" then return data end
        end
    end
    return {}
end

local function write_state_atomic(data)
    local sfile = get_state_file()
    local tmp = sfile .. ".tmp." .. tostring(os.time())
    local f = io.open(tmp, "w")
    if f then
        f:write(grime.json.encode(data))
        f:close()
        os.rename(tmp, sfile)
    end
end

local function save_persisted_key(key, val)
    local data = load_persisted_state()
    data[key] = val
    write_state_atomic(data)
end

local function remove_persisted_key(key)
    local data = load_persisted_state()
    data[key] = nil
    write_state_atomic(data)
end

local function save_bus_key(key, val)
    if grime and grime.bus and grime.bus.set then
        pcall(grime.bus.set, key, val)
    end
    save_persisted_key(key, val)
end

local function get_terminal_dump_data()
    local val = nil
    if grime and grime.bus and grime.bus.get then
        local ok, res = pcall(grime.bus.get, "daemon.terminal_dump")
        if ok and res ~= nil then
            val = res
        end
    end
    if val == nil then
        local persisted = load_persisted_state()
        val = persisted["daemon.terminal_dump"]
        if val ~= nil and grime and grime.bus and grime.bus.set then
            pcall(grime.bus.set, "daemon.terminal_dump", val)
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

function main()
    local args = ctx.args or {}
    local action = args[1] or "status"

    if action == "help" or action == "-h" or action == "--help" then
        print_help()
        return
    end

    local sock = get_socket_path()

    if action == "status" then
        local pgrep = ctx.capture({ "pgrep", "-f", "grime --daemon-server" })
        local is_running = pgrep.code == 0

        if is_running then
            local pid = grime.str.trim(pgrep.stdout)
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
            local pgrep = ctx.capture({ "pgrep", "-f", "grime --daemon-server" })
            alive = (pgrep.code == 0)
        end
        if alive then
            grime.ui.success("PONG: демон grime активен")
            ctx.success("PONG")
        else
            ctx.fail("Демон grime недоступен")
        end
    elseif action == "start" then
        local pgrep = ctx.capture("pgrep -f 'grime --daemon-server'")
        if pgrep.code == 0 then
            local pid = grime.str.trim(pgrep.stdout)
            grime.ui.warn("Демон grime уже запущен (PID: " .. pid .. ")")
            ctx.success("already_running")
            return
        end
        ctx.log("Запуск демона grime в фоне...")
        local res = ctx.run_shell("nohup setsid grime --daemon-server >/dev/null 2>&1 &", ".")
        os.execute("sleep 0.1")
        local check = ctx.capture("pgrep -f 'grime --daemon-server'")
        if check.code == 0 then
            local pid = grime.str.trim(check.stdout)
            grime.ui.success(string.format("Демон grime успешно запущен (PID: %s)", pid))
            ctx.success("started")
        else
            ctx.fail("Не удалось запустить демон grime")
        end
    elseif action == "stop" or action == "kill" then
        local pgrep = ctx.capture("pgrep -f 'grime --daemon-server'")
        if pgrep.code ~= 0 then
            grime.ui.warn("Демон grime не был запущен")
            ctx.success("not_running")
            return
        end
        ctx.log("Остановка демона grime...")
        local res = ctx.run_shell("pkill -f 'grime --daemon-server'", ".")
        if res == 0 then
            if ctx.exists(sock) then
                ctx.delete(sock, true)
            end
            grime.ui.success("Демон grime остановлен")
            ctx.success("stopped")
        else
            ctx.fail("Не удалось остановить процесс grime --daemon-server")
        end
    elseif action == "restart" then
        ctx.run_shell("pkill -f 'grime --daemon-server'", ".")
        if ctx.exists(sock) then
            ctx.delete(sock, true)
        end
        os.execute("sleep 0.1")
        ctx.run_shell("nohup setsid grime --daemon-server >/dev/null 2>&1 &", ".")
        os.execute("sleep 0.1")
        local check = ctx.capture("pgrep -f 'grime --daemon-server'")
        if check.code == 0 then
            local pid = grime.str.trim(check.stdout)
            grime.ui.success(string.format("Демон grime успешно перезапущен (PID: %s)", pid))
            ctx.success("restarted")
        else
            ctx.fail("Ошибка перезапуска демона grime")
        end
    elseif action == "feed" or action == "record" then
        local cmd = args[2]
        local status = tonumber(args[3]) or 0
        local cwd = args[4] or os.getenv("PWD") or "."
        local output = args[5] or ""

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
            ctx.fail("Укажите команду: grime daemon feed <cmd> [status_code] [cwd] [output]")
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
    elseif action == "clear" or action == "reset" then
        if grime and grime.bus and grime.bus.delete then
            pcall(grime.bus.delete, "daemon.terminal_dump")
        elseif grime and grime.bus and grime.bus.set then
            pcall(grime.bus.set, "daemon.terminal_dump", nil)
        end
        remove_persisted_key("daemon.terminal_dump")
        grime.ui.success("Терминальный контекст успешно очищен")
        ctx.success("cleared")
    else
        ctx.fail("Неизвестная команда daemon: " .. action)
    end
end

return {
    main = main,
    description = description,
}
