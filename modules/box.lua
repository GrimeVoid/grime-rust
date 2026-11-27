--@grime description: Оркестрация контейнеров Distrobox / Podman и экспорт бинарников
--@grime requires: bin:distrobox?
--@grime wraps: pipeline


local utils = require("languages.utils")
local ctx = grime.ctx

local ACTIONS = {
    ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["--ls"] = "list", ["-l"] = "list", ["-ps"] = "list", ["--ps"] = "list",
    ["-enter"] = "enter", ["--enter"] = "enter", ["-sh"] = "enter", ["--sh"] = "enter", ["-shell"] = "enter", ["--shell"] = "enter", ["-e"] = "enter",
    ["-run"] = "run", ["--run"] = "run", ["-r"] = "run", ["-exec"] = "run", ["--exec"] = "run",
    ["-export"] = "export", ["--export"] = "export", ["-exp"] = "export", ["--exp"] = "export",
    ["-create"] = "create", ["--create"] = "create", ["-new"] = "create", ["--new"] = "create", ["-init"] = "create", ["--init"] = "create", ["-c"] = "create",
    ["-stop"] = "stop", ["--stop"] = "stop", ["-s"] = "stop",
    ["-rm"] = "rm", ["--rm"] = "rm", ["-delete"] = "rm", ["--delete"] = "rm", ["-remove"] = "rm", ["--remove"] = "rm", ["-del"] = "rm", ["-d"] = "rm",
    ["-keepalive"] = "keepalive", ["--keepalive"] = "keepalive",
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
}

--- Определение имени текущего контейнера (если grime запущен внутри Distrobox/Podman)
local current_container_cache = nil -- false = «не в контейнере» (кэш на процесс)

local function get_current_container()
    if current_container_cache ~= nil then
        return current_container_cache or nil
    end
    local name = (function()
    local cid = os.getenv("CONTAINER_ID")
    if cid then
        cid = cid:match("^%s*(.-)%s*$")
        if cid ~= "" then
            return cid
        end
    end
    local f = io.open("/run/.containerenv", "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content then
            for line in content:gmatch("[^\r\n]+") do
                local name = line:match('^%s*name%s*=%s*"([^"]+)"')
                    or line:match("^%s*name%s*=%s*'([^']+)'")
                    or line:match("^%s*name%s*=%s*(%S+)")
                if name and name ~= "" then
                    return name
                end
            end
        end
    end
    return nil
    end)()
    current_container_cache = name or false
    return name
end

--- Формирование команды для хостовых утилит (distrobox/podman) с fallback на distrobox-host-exec
local function host_cmd(tool, args)
    local cmd = {}
    if not utils.has_binary(tool, ctx) and get_current_container() ~= nil and utils.has_binary("distrobox-host-exec", ctx) then
        table.insert(cmd, "distrobox-host-exec")
    end
    table.insert(cmd, tool)
    if args then
        for _, a in ipairs(args) do
            table.insert(cmd, a)
        end
    end
    return cmd
end

--- Получение списка контейнеров Distrobox без захардкоженного ядра Rust
local containers_cache = nil

--- Сброс кэша списка контейнеров (после create/start/stop/rm)
local function invalidate_containers()
    containers_cache = nil
end

local function get_containers()
    if containers_cache then
        return containers_cache
    end
    if not (grime and grime.process) then
        return {}
    end

    local res = grime.process.capture(host_cmd("distrobox", { "list", "--no-color" }))
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
        containers_cache = {}
        return containers_cache
    end

    local containers = {}
    local lines = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    for i = 2, #lines do
        local line = lines[i]:match("^%s*(.-)%s*$")
        if line ~= "" then
            local parts = {}
            for part in line:gmatch("[^|]+") do
                table.insert(parts, part:match("^%s*(.-)%s*$"))
            end
            if #parts >= 3 and parts[1] ~= "ID" then
                table.insert(containers, {
                    id = parts[1],
                    name = parts[2],
                    status = parts[3],
                    image = parts[4] or "",
                })
            end
        end
    end
    containers_cache = containers
    return containers
end

--- Определение дефолтного контейнера
local function get_default_box(containers)
    if not containers or #containers == 0 then
        return nil
    end

    local cfg_def = nil
    if grime and grime.config then
        cfg_def = grime.config.get("distrobox_default")
    end

    if cfg_def and cfg_def ~= "" then
        for _, c in ipairs(containers) do
            if c.name == cfg_def then
                return c.name
            end
        end
    end

    for _, c in ipairs(containers) do
        local st = string.lower(c.status or "")
        if st:find("up") or st:find("running") then
            return c.name
        end
    end

    return containers[1].name
end

--- Управление жизненным циклом: запуск контейнера при необходимости и фиксация активности в bus
local function ensure_box_running(box_name)
    local current_box = get_current_container()
    if current_box ~= box_name then
        local containers = get_containers()
        local is_running = false
        for _, c in ipairs(containers) do
            if c.name == box_name then
                local st = string.lower(c.status or "")
                if st:find("up") or st:find("running") then
                    is_running = true
                    break
                end
            end
        end

        if not is_running then
            ctx.log(string.format("Запуск окружения Distrobox/Podman '%s'...", box_name))
            local res = grime.process.capture(host_cmd("podman", { "start", box_name }))
            if res.code ~= 0 then
                grime.process.run(host_cmd("distrobox", { "enter", box_name, "--", "true" }))
            end
            invalidate_containers()
        end
    end

    -- Фиксация отметки времени последней активности в grime.bus
    if grime and grime.bus then
        local now = os.time()
        grime.bus.set("box." .. box_name .. ".last_active", now)
        grime.bus.set("box." .. box_name .. ".status", "running")
        grime.bus.set("box.last_active", now)
        grime.bus.set("box.current", box_name)
    end
    return true
end

--- Счётчик активных сессий контейнера в bus (enter/run); защищает от гашения при keepalive
local function session_begin(box_name)
    if not (grime and grime.bus) then return end
    local n = tonumber(grime.bus.get("box." .. box_name .. ".sessions")) or 0
    grime.bus.set("box." .. box_name .. ".sessions", n + 1)
    grime.bus.set("box." .. box_name .. ".last_active", os.time())
end

local function session_end(box_name)
    if not (grime and grime.bus) then return end
    local n = tonumber(grime.bus.get("box." .. box_name .. ".sessions")) or 0
    grime.bus.set("box." .. box_name .. ".sessions", n > 1 and (n - 1) or 0)
    grime.bus.set("box." .. box_name .. ".last_active", os.time())
end

--- Выполнение fn внутри учтённой сессии (счётчик снимается даже при ошибке)
local function with_session(box_name, fn)
    session_begin(box_name)
    local ok, res = pcall(fn)
    session_end(box_name)
    if not ok then error(res, 0) end
    return res
end

--- Контроль времени простоя (Idle Keep-Alive) силами модуля
local function check_idle_keepalive(box_name)
    if not (grime and grime.bus) then return end
    if get_current_container() == box_name then return end

    local last_active = tonumber(grime.bus.get("box." .. box_name .. ".last_active"))
    if not last_active or last_active <= 0 then return end

    -- Есть активные сессии: не гасим (счётчик старше суток считаем «протухшим»)
    local sessions = tonumber(grime.bus.get("box." .. box_name .. ".sessions")) or 0
    if sessions > 0 and (os.time() - last_active) < 86400 then return end

    local idle_limit = 300 -- 5 минут по умолчанию
    if grime.config then
        local cfg_limit = tonumber(grime.config.get("box_idle_timeout"))
        if cfg_limit and cfg_limit > 0 then
            idle_limit = cfg_limit
        end
    end

    local now = os.time()
    local elapsed = now - last_active
    if elapsed > idle_limit then
        if grime.bus.get("box." .. box_name .. ".status") == "stopped" then return end
        -- Не гасим уже остановленный контейнер
        local is_running = false
        for _, c in ipairs(get_containers()) do
            if c.name == box_name then
                local st = string.lower(c.status or "")
                is_running = (st:find("up") or st:find("running")) ~= nil
                break
            end
        end
        if not is_running then
            grime.bus.set("box." .. box_name .. ".status", "stopped")
            return
        end
        ctx.log(string.format("Контейнер '%s' простаивает более %d сек (%d сек). Гашение контейнера...", box_name, idle_limit, elapsed))
        grime.process.run(host_cmd("distrobox", { "stop", box_name, "-Y" }))
        invalidate_containers()
        grime.bus.set("box." .. box_name .. ".status", "stopped")
    end
end

local function handle_list(containers, target_box)
    if not containers or #containers == 0 then
        ctx.log("Контейнеры Distrobox не обнаружены.")
        ctx.log("Создайте новый контейнер: grime box create <имя_контейнера>")
        return
    end

    local def_name = get_default_box(containers)
    io.stdout:write("\n📦 Контейнеры Distrobox:\n")
    io.stdout:write(string.rep("─", 76) .. "\n")
    io.stdout:write(string.format("%-20s %-22s %-25s %s\n", "ИМЯ (NAME)", "СТАТУС (STATUS)", "ОБРАЗ (IMAGE)", "ДЕФОЛТ"))
    io.stdout:write(string.rep("─", 76) .. "\n")

    for _, c in ipairs(containers) do
        local name = c.name or ""
        local status = c.status or ""
        local image = c.image or ""
        local is_def = (name == def_name) and "★ default" or ""

        if #image > 24 then
            image = "..." .. string.sub(image, -21)
        end

        io.stdout:write(string.format("%-20s %-22s %-25s %s\n", name, status, image, is_def))
    end
    io.stdout:write(string.rep("─", 76) .. "\n")
    io.stdout:write("\27[90mДля подробной справки используйте: grime box --help\27[0m\n\n")
end

local function handle_enter(box_name, target_dir)
    ensure_box_running(box_name)
    if get_current_container() == box_name then
        ctx.log(string.format("Вы уже находитесь внутри контейнера '%s' (директория: %s).", box_name, target_dir))
        if grime and grime.bus then
            grime.bus.set("box." .. box_name .. ".last_active", os.time())
        end
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
        return
    end

    ctx.log(string.format("Вход в контейнер '%s' (директория: %s)...", box_name, target_dir))
    local cmd = host_cmd("distrobox", { "enter", box_name })
    local ret = with_session(box_name, function() return ctx.run_process(cmd, target_dir) end)
    if ctx.has_next_step then
        ctx.module_return(target_dir)
    end
    if ret ~= 0 then
        ctx.fail(string.format("Сессия в '%s' завершилась с кодом %d", box_name, ret))
    end
end

local function handle_run(box_name, target_dir, command_tokens)
    ensure_box_running(box_name)
    local cmd_str = "grime project run"
    local inp = ctx.input or ctx.pipeline_input
    if inp and type(inp) == "string" and #inp > 0 and grime and grime.fs and grime.fs.is_dir(inp) then
        target_dir = ctx.normalize_path and ctx.normalize_path(inp) or inp
    end

    if command_tokens and #command_tokens > 0 then
        local escaped = {}
        for _, tok in ipairs(command_tokens) do
            table.insert(escaped, utils.shell_escape(tok))
        end
        cmd_str = table.concat(escaped, " ")
    elseif inp and type(inp) == "string" and #inp > 0 and not (grime and grime.fs and grime.fs.is_dir(inp)) then
        cmd_str = inp
    end

    local is_internal_grime = command_tokens and command_tokens[1] and
        (command_tokens[1] == "grime" or command_tokens[1]:match("/grime$") ~= nil)
    if not is_internal_grime then
        ctx.log(string.format("Запуск в [%s]: %s (директория: %s)", box_name, cmd_str, target_dir))
    end
    local escaped_dir = utils.shell_escape(target_dir)
    local cmd
    if get_current_container() == box_name then
        local local_inner = string.format("cd %s && %s", escaped_dir, cmd_str)
        cmd = { "sh", "-c", local_inner }
    else
        local inner = string.format("export PATH=\"$PATH:$HOME/.local/bin\"; cd %s && %s", escaped_dir, cmd_str)
        cmd = host_cmd("distrobox", { "enter", box_name, "--", "bash", "-c", inner })
    end

    local ret = with_session(box_name, function() return ctx.run_process(cmd, target_dir) end)
    if ctx.has_next_step then
        ctx.module_return(target_dir)
    end
    if ret ~= 0 then
        ctx.fail(string.format("Команда в контейнере '%s' завершилась с кодом %d", box_name, ret))
    end
end

local function handle_export(box_name, target_dir, tokens)
    ensure_box_running(box_name)
    if not tokens or #tokens == 0 then
        ctx.log("Использование экспорта из контейнера:")
        ctx.log("  grime box [box_name] export bin <binary_path>  (или --bin <binary_path>)")
        ctx.log("  grime box [box_name] export app <app_name>     (или --app <app_name>)")
        ctx.fail("Не указаны параметры экспорта")
        return
    end

    local exp_type = nil
    local target_item = nil
    local extra_flags = {}

    local i = 1
    while i <= #tokens do
        local t = tokens[i]
        if (t == "app" or t == "--app" or t == "-a") and tokens[i + 1] then
            exp_type = "app"
            target_item = tokens[i + 1]
            i = i + 1
        elseif (t == "bin" or t == "--bin" or t == "-b") and tokens[i + 1] then
            exp_type = "bin"
            target_item = tokens[i + 1]
            i = i + 1
        elseif t:match("^%-%-app=(.+)$") then
            exp_type = "app"
            target_item = t:match("^%-%-app=(.+)$")
        elseif t:match("^%-%-bin=(.+)$") then
            exp_type = "bin"
            target_item = t:match("^%-%-bin=(.+)$")
        elseif not target_item and not t:match("^%-") then
            target_item = t
            exp_type = exp_type or (t:find("/") and "bin" or "app")
        else
            table.insert(extra_flags, t)
        end
        i = i + 1
    end

    if not target_item then
        ctx.fail("Укажите тип (bin/app или --bin/--app) и имя элемента для экспорта")
        return
    end

    local flag = (exp_type == "app") and "--app" or "--bin"
    local cmd
    if get_current_container() == box_name then
        cmd = { "distrobox-export", flag, target_item }
        for _, ef in ipairs(extra_flags) do
            table.insert(cmd, ef)
        end
    else
        local args = { "enter", box_name, "--", "distrobox-export", flag, target_item }
        for _, ef in ipairs(extra_flags) do
            table.insert(args, ef)
        end
        cmd = host_cmd("distrobox", args)
    end
    ctx.log(string.format("Экспорт %s '%s' из [%s]...", exp_type or "bin", target_item, box_name))

    local ret = with_session(box_name, function() return ctx.run_process(cmd, target_dir) end)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Экспорт завершился с кодом " .. tostring(ret))
    end
end

local function handle_create(box_name, target_dir, tokens)
    local args = { "create" }
    local start_idx = 1
    if box_name then
        table.insert(args, "--name")
        table.insert(args, box_name)
        if tokens and tokens[1] == box_name then
            start_idx = 2
        end
    end
    if tokens then
        for i = start_idx, #tokens do
            table.insert(args, tokens[i])
        end
    end

    local cmd = host_cmd("distrobox", args)
    ctx.log("Создание контейнера Distrobox: " .. table.concat(cmd, " ") .. "...")
    local ret = ctx.run_process(cmd, target_dir)
    invalidate_containers()
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Ошибка при создании контейнера (код " .. tostring(ret) .. ")")
    end
end

local function handle_stop(box_name, target_dir)
    -- Уже остановленный контейнер повторно не гасим
    for _, c in ipairs(get_containers()) do
        if c.name == box_name then
            local st = string.lower(c.status or "")
            if not (st:find("up") or st:find("running")) then
                ctx.log("Контейнер '" .. box_name .. "' уже остановлен.")
                if grime and grime.bus then
                    grime.bus.set("box." .. box_name .. ".status", "stopped")
                    grime.bus.set("box." .. box_name .. ".last_active", 0)
                end
                ctx.module_return(target_dir)
                return
            end
            break
        end
    end
    ctx.log("Остановка контейнера '" .. box_name .. "'...")
    local cmd = host_cmd("distrobox", { "stop", box_name, "-Y" })
    local ret = ctx.run_process(cmd, target_dir)
    invalidate_containers()
    if grime and grime.bus then
        grime.bus.set("box." .. box_name .. ".status", "stopped")
        grime.bus.set("box." .. box_name .. ".last_active", 0)
    end
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Остановка завершилась с ошибкой " .. tostring(ret))
    end
end

local function handle_rm(box_name, target_dir)
    ctx.log("Удаление контейнера '" .. box_name .. "'...")
    local cmd = host_cmd("distrobox", { "rm", box_name, "-f" })
    local ret = ctx.run_process(cmd, target_dir)
    invalidate_containers()
    if grime and grime.bus then
        grime.bus.set("box." .. box_name .. ".status", "deleted")
    end
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Удаление завершилось с ошибкой " .. tostring(ret))
    end
end

local function print_help()
    print(string.format([[
%s%sGrime Box%s — Управление контейнерами Distrobox и запуск задач

%sИСПОЛЬЗОВАНИЕ:%s
    grime box [команда|-флаг] [имя_контейнера] [-- аргументы_или_команда...]

%sКОМАНДЫ И ФЛАГИ (поддерживаются с '-' / '--' и без):%s
    %slist, -l, --list%s          Список доступных контейнеров Distrobox (по умолчанию)
                              grime box --list
    %senter, -e, --enter%s        Интерактивный вход в контейнер
                              grime box --enter [контейнер]
    %srun, -r, --run, --exec%s    Выполнение команды внутри контейнера
                              grime box --run <контейнер> -- <команда...>
                              grime box [контейнер] <команда...>
    %screate, -c, --create%s      Создать новый контейнер Distrobox
                              grime box --create <имя> [--image <образ>]
    %sstop, -s, --stop%s          Остановить работающий контейнер
                              grime box --stop <имя>
    %srm, -d, --rm, --delete%s    Удалить контейнер Distrobox
                              grime box --rm <имя>
    %sexport, --export%s          Экспорт бинарника или desktop-файла из контейнера на хост
                              grime box --export [имя] --app <приложение> | --bin <путь>
    %shelp, -h, --help%s          Показать эту справку

%sПРИМЕРЫ:%s
    grime box                               # Обзор статуса всех контейнеров
    grime box -enter fedora-box             # Вход в контейнер
    grime box --run fedora-box gcc --version # Выполнение команды в контейнере
    grime box -create mybox                 # Создание нового контейнера
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function main()
    local raw_args = ctx.args or {}
    for _, a in ipairs(raw_args) do
        if a == "--" or a == "//" then break end
        if grime.args.is_flag(a) then
            local clean = grime.args.strip_dashes(a:lower())
            if clean == "help" or clean == "h" then
                print_help()
                return
            end
        end
    end

    local target_dir = ctx.target_dir
    local containers = get_containers()

    local box_cats = {}
    for _, c in ipairs(containers) do
        box_cats[string.lower(c.name)] = c.name
    end

    local parsed = ctx.parse_args({
        actions = ACTIONS,
        default_action = "list",
        categories = { box = box_cats },
        flags = {
            help = { "-h", "--help", "-help" },
        },
    })
    local action = parsed.action or "list"

    if action == "help" or parsed.flags.help then
        print_help()
        return
    end

    local specified_box = parsed.categories.box
    local command_tokens = parsed.args
    for _, tok in ipairs(parsed.command_tokens) do
        table.insert(command_tokens, tok)
    end

    if action == "list" then
        handle_list(containers, specified_box)
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
        return
    end

    if action == "create" then
        handle_create(specified_box or (command_tokens[1]), target_dir, command_tokens)
        return
    end

    -- Разрешаем имя контейнера
    local box_name = specified_box
    if not box_name then
        if #command_tokens > 0 and not command_tokens[1]:match("^%-") and not (action == "export" and (command_tokens[1] == "app" or command_tokens[1] == "bin")) then
            box_name = table.remove(command_tokens, 1)
        else
            box_name = get_default_box(containers)
        end
    end

    if not box_name then
        ctx.fail("Не удалось определить контейнер Distrobox. Создайте контейнер: grime box create <имя>")
        return
    end

    if action == "enter" then
        handle_enter(box_name, target_dir)
    elseif action == "run" then
        handle_run(box_name, target_dir, command_tokens)
    elseif action == "export" then
        handle_export(box_name, target_dir, command_tokens)
    elseif action == "stop" then
        handle_stop(box_name, target_dir)
    elseif action == "rm" then
        handle_rm(box_name, target_dir)
    elseif action == "keepalive" then
        check_idle_keepalive(box_name)
        ctx.module_return(target_dir)
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end

local function cleanup()
    if grime and grime.bus then
        local cur_box = grime.bus.get("box.current")
        if cur_box then
            check_idle_keepalive(cur_box)
        end
    end
end

local M = {
    main = main,
    cleanup = cleanup,
    ensure_running = ensure_box_running,
    -- Чистые функции без ctx.fail/module_return: используются другими модулями (pkg и др.)
    get_containers = get_containers,
    get_default_box = get_default_box,
    get_current_container = get_current_container,
    exec = function(box_name, cmd, cwd, env)
        ensure_box_running(box_name)
        if get_current_container() == box_name then
            if type(cmd) == "table" then
                return ctx.run_process(cmd, cwd, env)
            else
                return ctx.run_process({ "sh", "-c", cmd }, cwd, env)
            end
        end

        local args = { "enter", box_name, "--" }
        if type(cmd) == "table" then
            for _, c in ipairs(cmd) do table.insert(args, c) end
        else
            table.insert(args, "sh")
            table.insert(args, "-c")
            table.insert(args, cmd)
        end
        local full = host_cmd("distrobox", args)
        return with_session(box_name, function() return ctx.run_process(full, cwd, env) end)
    end,
}
-- Действия box, не требующие переключения среды (разовые операции хоста)
local ONE_SHOT_ACTIONS = {}
for _, a in ipairs({
    "list", "ls", "status", "ps", "stop", "create", "new", "init", "rm", "delete", "remove",
    "del", "export", "exp", "keepalive", "idle", "help", "-h", "--help", "runner", "wrap", "do",
}) do
    ONE_SHOT_ACTIONS[a] = true
end

--- Действие входа в контейнер (enter/shell/sh/e/run/r/exec с любым числом дефисов)
local function is_switch_action(s)
    local clean = tostring(s):lower():gsub("^%-+", "")
    return clean == "enter" or clean == "shell" or clean == "sh" or clean == "e"
        or clean == "run" or clean == "r" or clean == "exec"
end

--- Имя контейнера для переключения среды по аргументам шага (nil — шаг не меняет среду)
local function extract_env_switch(args)
    for _, a in ipairs(args) do
        if a == "--" or a == "//" then
            return nil
        end
    end

    for _, a in ipairs(args) do
        local clean = a:lower():gsub("^%-+", "")
        if not is_switch_action(a) and (a:sub(1, 1) == "-" or ONE_SHOT_ACTIONS[clean]) then
            return nil
        end
    end

    local function default_box()
        local def = grime.config and grime.config.get("distrobox_default")
        if type(def) == "string" and def ~= "" then
            return def
        end
        return "default"
    end

    if #args == 0 then
        return default_box()
    elseif #args == 1 then
        if is_switch_action(args[1]) then
            return default_box()
        end
        return args[1]
    elseif #args == 2 then
        local a0_act, a1_act = is_switch_action(args[1]), is_switch_action(args[2])
        if a0_act and not a1_act and args[2]:sub(1, 1) ~= "-" then
            return args[2]
        elseif a1_act and not a0_act and args[1]:sub(1, 1) ~= "-" then
            return args[1]
        end
    end
    return nil
end

--- Хук ядра для `wraps: pipeline`: переключение конвейера в контейнер.
--- nil — не переключать; { skip = true } — уже в нужном контейнере;
--- { args = {...} } — аргументы box для запуска подконвейера внутри контейнера.
function M.wrap_pipeline(args, rest_argv)
    local box_name = extract_env_switch(args or {})
    if not box_name then
        return nil
    end
    if get_current_container() == box_name then
        return { skip = true }
    end
    if type(rest_argv) ~= "table" or #rest_argv == 0 then
        return nil
    end
    return utils.wrap_pipeline_run(rest_argv, { box_name })
end

return M
