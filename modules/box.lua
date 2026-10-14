local helper = require("helper")
local classifier = require("classifier")
local ctx = helper.ctx

local ACTIONS = {
    list = "list", ls = "list", status = "list", ps = "list",
    enter = "enter", shell = "enter", sh = "enter",
    run = "run", runner = "run", ["exec"] = "run", wrap = "run", ["do"] = "run",
    export = "export", exp = "export",
    create = "create", new = "create", init = "create",
    stop = "stop",
    rm = "rm", delete = "rm", remove = "rm", del = "rm",
    keepalive = "keepalive", idle = "keepalive",
    help = "help",
}

--- Получение списка контейнеров Distrobox без захардкоженного ядра Rust
local function get_containers()
    if not (grime and grime.process) then
        return {}
    end

    local res = grime.process.capture({ "distrobox", "list", "--no-color" })
    if res.code ~= 0 or not res.stdout or res.stdout == "" then
        return {}
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
        local res = grime.process.capture({ "podman", "start", box_name })
        if res.code ~= 0 then
            grime.process.run({ "distrobox", "enter", box_name, "--", "true" })
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
end

--- Контроль времени простоя (Idle Keep-Alive) силами модуля
local function check_idle_keepalive(box_name)
    if not (grime and grime.bus) then return end

    local last_active = grime.bus.get("box." .. box_name .. ".last_active")
    if not last_active then return end

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
        ctx.log(string.format("Контейнер '%s' простаивает более %d сек (%d сек). Гашение контейнера...", box_name, idle_limit, elapsed))
        grime.process.run({ "distrobox", "stop", box_name, "-Y" })
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
    ctx.log(string.format("Вход в контейнер '%s' (директория: %s)...", box_name, target_dir))
    local cmd = { "distrobox", "enter", box_name }
    local ret = ctx.run_process(cmd, target_dir)
    if grime and grime.bus then
        grime.bus.set("box." .. box_name .. ".last_active", os.time())
    end
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail(string.format("Сессия в '%s' завершилась с кодом %d", box_name, ret))
    end
end

local function handle_run(box_name, target_dir, command_tokens)
    ensure_box_running(box_name)
    local cmd_str = "grime project run"
    if command_tokens and #command_tokens > 0 then
        cmd_str = table.concat(command_tokens, " ")
    end

    ctx.log(string.format("Запуск в [%s]: %s (директория: %s)", box_name, cmd_str, target_dir))
    local escaped_dir = target_dir:gsub("'", "'\\''")
    local inner = string.format("export PATH=\"$PATH:$HOME/.local/bin\"; cd '%s' && %s", escaped_dir, cmd_str)
    local cmd = { "distrobox", "enter", box_name, "--", "bash", "-c", inner }

    local ret = ctx.run_process(cmd, target_dir)
    if grime and grime.bus then
        grime.bus.set("box." .. box_name .. ".last_active", os.time())
    end
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail(string.format("Команда в контейнере '%s' завершилась с кодом %d", box_name, ret))
    end
end

local function handle_export(box_name, target_dir, tokens)
    ensure_box_running(box_name)
    if not tokens or #tokens == 0 then
        ctx.log("Использование экспорта из контейнера:")
        ctx.log("  grime box [box_name] export bin <binary_path>")
        ctx.log("  grime box [box_name] export app <app_name>")
        ctx.fail("Не указаны параметры экспорта")
        return
    end

    local exp_type = tokens[1]
    local target_item = tokens[2]
    if not target_item then
        ctx.fail("Укажите тип (bin/app) и имя элемента для экспорта")
        return
    end

    local flag = (exp_type == "app") and "--app" or "--bin"
    local cmd = { "distrobox", "enter", box_name, "--", "distrobox-export", flag, target_item }
    ctx.log(string.format("Экспорт %s '%s' из [%s]...", exp_type, target_item, box_name))

    local ret = ctx.run_process(cmd, target_dir)
    if grime and grime.bus then
        grime.bus.set("box." .. box_name .. ".last_active", os.time())
    end
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Экспорт завершился с кодом " .. tostring(ret))
    end
end

local function handle_create(box_name, target_dir, tokens)
    local cmd = { "distrobox", "create" }
    if box_name then
        table.insert(cmd, "--name")
        table.insert(cmd, box_name)
    end
    for _, t in ipairs(tokens or {}) do
        table.insert(cmd, t)
    end

    ctx.log("Создание контейнера Distrobox: " .. table.concat(cmd, " ") .. "...")
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Ошибка при создании контейнера (код " .. tostring(ret) .. ")")
    end
end

local function handle_stop(box_name, target_dir)
    ctx.log("Остановка контейнера '" .. box_name .. "'...")
    local cmd = { "distrobox", "stop", box_name, "-Y" }
    local ret = ctx.run_process(cmd, target_dir)
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
    local cmd = { "distrobox", "rm", box_name, "-f" }
    local ret = ctx.run_process(cmd, target_dir)
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
    grime box [команда] [имя_контейнера] [-- аргументы_или_команда...]

%sКОМАНДЫ:%s
    %slist, ls, status%s      Список доступных контейнеров Distrobox (по умолчанию)
                         grime box list
    %senter, shell, sh%s      Интерактивный вход в контейнер
                         grime box enter [контейнер]
    %srun, exec%s             Выполнение команды внутри контейнера
                         grime box run <контейнер> -- <команда...>
                         grime box [контейнер] <команда...>
    %screate, new%s           Создать новый контейнер Distrobox
                         grime box create <имя> [--image <образ>]
    %sstop%s                  Остановить работающий контейнер
                         grime box stop <имя>
    %srm, delete%s            Удалить контейнер Distrobox
                         grime box rm <имя>
    %sexport%s                Экспорт бинарника или desktop-файла из контейнера на хост
                         grime box export <имя> --app <бинарник>
    %shelp, -h, --help%s      Показать эту справку

%sПРИМЕРЫ:%s
    grime box                               # Обзор статуса всех контейнеров
    grime box enter fedora-box              # Вход в контейнер
    grime box run fedora-box gcc --version  # Выполнение команды в контейнере
    grime box create mybox                  # Создание нового контейнера
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

function main()
    for _, a in ipairs(ctx.args or {}) do
        local matched = (type(a) == "string" and a:match("^%-")) and helper.fuzzy_match_flag(a, { "--help", "-h" }, 0.75) or a
        if matched == "--help" or matched == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local target_dir = ctx.target_dir
    local containers = get_containers()

    local box_cats = {}
    for _, c in ipairs(containers) do
        box_cats[string.lower(c.name)] = c.name
    end

    local cls = classifier.new({
        actions = ACTIONS,
        default_action = "list",
        categories = { box = box_cats },
    })

    local parsed = cls:parse(ctx.args, target_dir)
    local action = parsed.action or "list"

    if action == "help" then
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
        if #command_tokens > 0 and not command_tokens[1]:match("^%-") then
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

function cleanup()
    if grime and grime.bus then
        local cur_box = grime.bus.get("box.current")
        if cur_box then
            check_idle_keepalive(cur_box)
        end
    end
end

local M = {
    ensure_running = ensure_box_running,
    exec = function(box_name, cmd, cwd, env)
        ensure_box_running(box_name)
        local cmd_list = { "distrobox", "enter", box_name, "--" }
        if type(cmd) == "table" then
            for _, c in ipairs(cmd) do table.insert(cmd_list, c) end
            return ctx.run_process(cmd_list, cwd, env)
        else
            table.insert(cmd_list, "sh")
            table.insert(cmd_list, "-c")
            table.insert(cmd_list, cmd)
            return ctx.run_process(cmd_list, cwd, env)
        end
    end,
}
return M
