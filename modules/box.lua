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
}

local function get_containers()
    if grime and grime.distrobox then
        return grime.distrobox.list()
    end
    return {}
end

local function get_default_box(containers)
    if grime and grime.distrobox then
        return grime.distrobox.default_box()
    end
    if containers and #containers > 0 then
        return containers[1].name
    end
    return nil
end

local function handle_list(containers, target_box)
    if not containers or #containers == 0 then
        ctx.log("Контейнеры Distrobox не обнаружены.")
        ctx.log("Создайте новый контейнер: grime box create <имя_контейнера>")
        return
    end

    local def_name = get_default_box(containers)
    io.stderr:write("\n📦 Контейнеры Distrobox:\n")
    io.stderr:write(string.rep("─", 76) .. "\n")
    io.stderr:write(string.format("%-20s %-22s %-25s %s\n", "ИМЯ (NAME)", "СТАТУС (STATUS)", "ОБРАЗ (IMAGE)", "ДЕФОЛТ"))
    io.stderr:write(string.rep("─", 76) .. "\n")

    for _, c in ipairs(containers) do
        local name = c.name or ""
        local status = c.status or ""
        local image = c.image or ""
        local is_def = (name == def_name) and "★ default" or ""

        if #image > 24 then
            image = "..." .. string.sub(image, -21)
        end

        io.stderr:write(string.format("%-20s %-22s %-25s %s\n", name, status, image, is_def))
    end
    io.stderr:write(string.rep("─", 76) .. "\n\n")
end

local function handle_enter(box_name, target_dir)
    ctx.log(string.format("Вход в контейнер '%s' (директория: %s)...", box_name, target_dir))
    local cmd = { "distrobox", "enter", box_name }
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail(string.format("Сессия в '%s' завершилась с кодом %d", box_name, ret))
    end
end

local function handle_run(box_name, target_dir, command_tokens)
    local cmd_str = "grime project run"
    if command_tokens and #command_tokens > 0 then
        cmd_str = table.concat(command_tokens, " ")
    end

    ctx.log(string.format("Запуск в [%s]: %s (директория: %s)", box_name, cmd_str, target_dir))
    local escaped_dir = target_dir:gsub("'", "'\\''")
    local inner = string.format("export PATH=\"$PATH:$HOME/.local/bin\"; cd '%s' && %s", escaped_dir, cmd_str)
    local cmd = { "distrobox", "enter", box_name, "--", "bash", "-c", inner }

    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail(string.format("Команда в контейнере '%s' завершилась с кодом %d", box_name, ret))
    end
end

local function handle_export(box_name, target_dir, tokens)
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
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Остановка завершилась с ошибкой " .. tostring(ret))
    end
end

local function handle_rm(box_name, target_dir)
    ctx.log("Удаление контейнера '" .. box_name .. "'...")
    local cmd = { "distrobox", "rm", box_name, "-f" }
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Удаление завершилось с ошибкой " .. tostring(ret))
    end
end

function main()
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
    local specified_box = parsed.categories.box
    local command_tokens = parsed.args
    for _, tok in ipairs(parsed.command_tokens) do
        table.insert(command_tokens, tok)
    end

    if action == "list" then
        handle_list(containers, specified_box)
        ctx.module_return(target_dir)
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
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
