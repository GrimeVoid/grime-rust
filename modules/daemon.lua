local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Daemon%s — Управление фоновым сервисом-демоном (grimed)

%sИСПОЛЬЗОВАНИЕ:%s
    grime daemon status       Проверить статус демона и сокета
    grime daemon ping         Проверить отклик демона
    grime daemon start        Запустить демон grimed в фоне
    grime daemon stop         Остановить работающий демон
    grime daemon restart      Перезапустить демон

%sОПИСАНИЕ:%s
    Управляет жизненным циклом демона Grime, обрабатывающего фоновые задачи,
    IPC-запросы и события конвейера.
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
    local uid_p = io.popen("id -u 2>/dev/null")
    if uid_p then
        local u = uid_p:read("*line")
        uid_p:close()
        if u and #u > 0 then uid = u:match("%d+") or uid end
    end
    if ctx.exists("/run/user/" .. uid) then
        return "/run/user/" .. uid .. "/grime.sock"
    end
    return "/tmp/grime-" .. uid .. ".sock"
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
        local pgrep = ctx.capture("pgrep -x grimed")
        local is_running = pgrep.code == 0
        local sock_exists = ctx.exists(sock)

        if is_running then
            local pid = grime.str.trim(pgrep.stdout)
            grime.ui.success(string.format("Демон grimed активен (PID: %s, сокет: %s)", pid, sock))
            ctx.success(pid)
        else
            grime.ui.warn("Демон grimed не запущен (сокет: " .. sock .. ")")
            ctx.success("stopped")
        end
    elseif action == "ping" then
        local pgrep = ctx.capture("pgrep -x grimed")
        if pgrep.code == 0 then
            grime.ui.success("PONG: демон grimed активен")
            ctx.success("PONG")
        else
            ctx.fail("Демон grimed недоступен")
        end
    elseif action == "start" then
        local pgrep = ctx.capture("pgrep -x grimed")
        if pgrep.code == 0 then
            grime.ui.warn("Демон grimed уже запущен (PID: " .. grime.str.trim(pgrep.stdout) .. ")")
            ctx.success("already_running")
            return
        end
        ctx.log("Запуск демона grimed в фоне...")
        local res = ctx.run_shell("grimed --daemon &", ".")
        if res == 0 then
            grime.ui.success("Демон grimed успешно запущен")
            ctx.success("started")
        else
            ctx.fail("Ошибка запуска grimed")
        end
    elseif action == "stop" or action == "kill" then
        local pgrep = ctx.capture("pgrep -x grimed")
        if pgrep.code ~= 0 then
            grime.ui.warn("Демон grimed не был запущен")
            ctx.success("not_running")
            return
        end
        ctx.log("Остановка демона grimed...")
        local res = ctx.run_shell("pkill -x grimed", ".")
        if res == 0 then
            if ctx.exists(sock) then
                ctx.delete(sock, true)
            end
            grime.ui.success("Демон grimed остановлен")
            ctx.success("stopped")
        else
            ctx.fail("Не удалось остановить процесс grimed")
        end
    elseif action == "restart" then
        ctx.run_shell("pkill -x grimed", ".")
        if ctx.exists(sock) then
            ctx.delete(sock, true)
        end
        ctx.run_shell("grimed --daemon &", ".")
        grime.ui.success("Демон grimed перезапущен")
        ctx.success("restarted")
    else
        ctx.fail("Неизвестная команда daemon: " .. action)
    end
end
