local helper = require("helper")
local classifier = require("classifier")
local ctx = helper.ctx

local ACTIONS = {
    list = "list", ls = "list", l = "list", show = "list",
    install = "install", i = "install", ["in"] = "install", add = "install", get = "install",
    run = "run", r = "run", ["try"] = "run",
    init = "init", shell = "init", sh = "init", new = "init",
}

local MANAGERS = {
    pacman = "pacman", dnf = "dnf", apt = "apt", flatpak = "flatpak",
    nix = "nix", distrobox = "distrobox", dbox = "distrobox", box = "distrobox",
    cargo = "cargo", pipx = "pipx",
}

local function handle_list(selected_managers, show_all)
    io.stderr:write("\n📦 Обзор установленных пакетов и менеджеров ПО:\n")
    io.stderr:write(string.rep("─", 65) .. "\n")

    local managers = (#selected_managers > 0) and selected_managers or { "pacman", "flatpak", "nix", "distrobox", "cargo", "pipx" }

    for _, mgr in ipairs(managers) do
        local count = 0
        local preview = {}

        if mgr == "pacman" then
            local res = ctx.capture({ "pacman", "-Qe" })
            if res.code == 0 then
                for line in res.stdout:gmatch("[^\r\n]+") do
                    count = count + 1
                    if count <= 5 then table.insert(preview, line:match("^(%S+)")) end
                end
            end
        elseif mgr == "flatpak" then
            local res = ctx.capture({ "flatpak", "list", "--app" })
            if res.code == 0 then
                for line in res.stdout:gmatch("[^\r\n]+") do
                    count = count + 1
                    if count <= 5 then table.insert(preview, line:match("^(%S+)")) end
                end
            end
        elseif mgr == "cargo" then
            local res = ctx.capture({ "cargo", "install", "--list" })
            if res.code == 0 then
                for line in res.stdout:gmatch("[^\r\n]+") do
                    if not line:match("^%s") and line:match(":") then
                        count = count + 1
                        if count <= 5 then table.insert(preview, line:match("^(%S+)")) end
                    end
                end
            end
        elseif mgr == "pipx" then
            local res = ctx.capture({ "pipx", "list", "--short" })
            if res.code == 0 then
                for line in res.stdout:gmatch("[^\r\n]+") do
                    count = count + 1
                    if count <= 5 then table.insert(preview, line:match("^(%S+)")) end
                end
            end
        elseif mgr == "distrobox" then
            local containers = grime.distrobox.list()
            count = #containers
            for i = 1, math.min(count, 5) do
                table.insert(preview, containers[i].name)
            end
        elseif mgr == "nix" then
            local res = ctx.capture({ "nix", "profile", "list" })
            if res.code == 0 then
                for line in res.stdout:gmatch("[^\r\n]+") do
                    if line:find("packages%.") or line:find("legacyPackages%.") then
                        count = count + 1
                        if count <= 5 then
                            local pkg = line:match("packages%S+%.(%S+)") or line:match("legacyPackages%S+%.(%S+)") or line:match("(%S+)$")
                            table.insert(preview, pkg)
                        end
                    end
                end
            end
        end

        local preview_str = table.concat(preview, ", ")
        if count > 5 then preview_str = preview_str .. "..." end
        io.stderr:write(string.format("%-14s : %4d пакетов [%s]\n", mgr, count, preview_str))
    end
    io.stderr:write(string.rep("─", 65) .. "\n\n")
end

local function handle_install(manager, packages)
    if not packages or #packages == 0 then
        ctx.fail("Не указаны пакеты для установки")
        return
    end

    local cmd = {}
    if manager == "pacman" then
        cmd = { "sudo", "pacman", "-S" }
    elseif manager == "dnf" then
        cmd = { "sudo", "dnf", "install", "-y" }
    elseif manager == "apt" then
        cmd = { "sudo", "apt", "install", "-y" }
    elseif manager == "flatpak" then
        cmd = { "flatpak", "install", "-y" }
    elseif manager == "nix" then
        cmd = { "nix", "profile", "install" }
        for i, p in ipairs(packages) do
            if not p:find("[:#/]") then
                packages[i] = "nixpkgs#" .. p
            end
        end
    elseif manager == "cargo" then
        cmd = { "cargo", "install" }
    elseif manager == "pipx" then
        cmd = { "pipx", "install" }
    elseif manager == "distrobox" then
        local target_box = table.remove(packages, 1)
        if not target_box then
            ctx.fail("Укажите имя контейнера Distrobox")
            return
        end
        cmd = { "distrobox", "enter", target_box, "--", "sudo", "dnf", "install", "-y" }
    else
        ctx.fail("Неизвестный пакетный менеджер: " .. tostring(manager))
        return
    end

    for _, p in ipairs(packages) do
        table.insert(cmd, p)
    end

    ctx.log("Установка через " .. manager .. ": " .. table.concat(packages, " ") .. "...")
    local ret = ctx.run_process(cmd)
    if ret == 0 then
        ctx.log("Установка успешно завершена.")
    else
        ctx.fail("Установка завершилась ошибкой (код " .. tostring(ret) .. ")")
    end
end

local function handle_run(packages, command_tokens)
    if not packages or #packages == 0 then
        ctx.fail("Укажите имя пакета для запуска через Nix")
        return
    end

    local pkg = packages[1]
    local cmd = { "nix-shell", "-p", pkg, "--run" }
    local inner = (#command_tokens > 0) and table.concat(command_tokens, " ") or pkg
    table.insert(cmd, inner)

    ctx.log(string.format("Изолированный запуск [%s]: %s...", pkg, inner))
    local ret = ctx.run_process(cmd)
    if ret ~= 0 then
        ctx.fail("Выполнение завершилось ошибкой")
    end
end

function main()
    local cls = classifier.new({
        actions = ACTIONS,
        default_action = "list",
        flags = { all = { "-a", "--all", "--deps" } },
    })

    local parsed = cls:parse(ctx.args)
    local action = parsed.action or "list"

    local managers = {}
    local rest_tokens = {}

    for _, tok in ipairs(parsed.args) do
        local tok_lower = tok:lower()
        if MANAGERS[tok_lower] then
            if action == "list" or #managers == 0 then
                table.insert(managers, MANAGERS[tok_lower])
            else
                table.insert(rest_tokens, tok)
            end
        else
            table.insert(rest_tokens, tok)
        end
    end

    for _, t in ipairs(parsed.command_tokens) do
        table.insert(rest_tokens, t)
    end

    if action == "list" then
        handle_list(managers, parsed.flags.all)
        ctx.module_return(ctx.target_dir)
    elseif action == "install" then
        local mgr = managers[1] or "pacman"
        handle_install(mgr, rest_tokens)
    elseif action == "run" then
        handle_run(rest_tokens, parsed.command_tokens)
    elseif action == "init" then
        require("nix")
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
