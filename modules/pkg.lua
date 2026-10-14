local helper = require("helper")
local classifier = require("classifier")
local ctx = helper.ctx

local ACTIONS = {
    list = "list", ls = "list", l = "list", show = "list",
    install = "install", i = "install", ["in"] = "install", add = "install", get = "install",
    run = "run", r = "run", ["try"] = "run",
    init = "init", shell = "init", sh = "init", new = "init",
    help = "help",
}

local MANAGERS = {
    pacman = "pacman", dnf = "dnf", apt = "apt", flatpak = "flatpak",
    nix = "nix", distrobox = "distrobox", dbox = "distrobox", box = "distrobox",
    cargo = "cargo", pipx = "pipx",
    app = "apps", apps = "apps",
}

local MANAGER_BINARIES = {
    pacman = "pacman",
    flatpak = "flatpak",
    nix = "nix",
    distrobox = "distrobox",
    cargo = "cargo",
    pipx = "pipx",
    dnf = "dnf",
    apt = "apt",
}

local binary_cache = {}
local function has_binary(bin)
    if not bin or bin == "" then return false end
    if binary_cache[bin] ~= nil then
        return binary_cache[bin]
    end
    local res = ctx.capture({ "which", bin })
    local exists = (res.code == 0 and res.stdout and res.stdout:match("%S") ~= nil) or false
    binary_cache[bin] = exists
    return exists
end

local function get_apps_root()
    local root = (ctx.paths and ctx.paths.apps)
        or (ctx.get_path and ctx.get_path("apps"))
        or (ctx.apps_root and ctx.apps_root())
        or ((os.getenv("HOME") or "") .. "/.config/grime/apps")
    return ctx.normalize_path(root)
end

local function handle_list(selected_managers, show_all)
    io.stdout:write("\n📦 Обзор установленных пакетов и менеджеров ПО:\n")
    io.stdout:write(string.rep("─", 75) .. "\n")

    local is_explicit = (#selected_managers > 0)
    local managers = is_explicit and selected_managers or { "pacman", "flatpak", "nix", "distrobox", "cargo", "pipx", "apps" }

    local printed = 0
    for _, mgr in ipairs(managers) do
        local bin = MANAGER_BINARIES[mgr]
        local bin_available = true
        if bin then
            bin_available = has_binary(bin)
        end

        local count = 0
        local preview = {}
        local display_label = mgr

        if bin_available then
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
                local target_box = nil
                local res = ctx.capture({ "distrobox", "list", "--no-color" })
                if res.code == 0 and res.stdout then
                    local lines = {}
                    for line in res.stdout:gmatch("[^\r\n]+") do table.insert(lines, line) end
                    for i = 2, #lines do
                        local line = lines[i]:match("^%s*(.-)%s*$")
                        if line ~= "" then
                            local parts = {}
                            for part in line:gmatch("[^|]+") do
                                table.insert(parts, part:match("^%s*(.-)%s*$"))
                            end
                            if #parts >= 3 and parts[1] ~= "ID" then
                                local bname = parts[2]
                                local bstatus = parts[3]
                                if not target_box then
                                    target_box = bname
                                end
                                if bstatus:match("Up") or bname == "fedora-box" then
                                    target_box = bname
                                    break
                                end
                            end
                        end
                    end
                end

                if target_box then
                    display_label = string.format("distrobox (%s)", target_box)
                    local qcmd = 'rpm -qa --qf "%{NAME}\\n" 2>/dev/null || pacman -Qq 2>/dev/null || dpkg-query -f "${Package}\\n" -W 2>/dev/null'
                    local dres = ctx.capture({ "distrobox", "enter", target_box, "--", "sh", "-c", qcmd })
                    if dres.code == 0 and dres.stdout and dres.stdout ~= "" then
                        for line in dres.stdout:gmatch("[^\r\n]+") do
                            local pkg = line:match("^%s*(.-)%s*$")
                            if pkg ~= "" then
                                count = count + 1
                                if count <= 5 then table.insert(preview, pkg) end
                            end
                        end
                    end
                else
                    display_label = "distrobox"
                end
            elseif mgr == "apps" or mgr == "app" then
                local apps_root = get_apps_root()
                if ctx.exists(apps_root) then
                    local p = io.popen(string.format("ls -1 %q 2>/dev/null", apps_root))
                    if p then
                        for l in p:lines() do
                            local item = l:match("^%s*(.-)%s*$")
                            if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then
                                count = count + 1
                                if count <= 5 then table.insert(preview, item) end
                            end
                        end
                        p:close()
                    end
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
        end

        if count > 0 or is_explicit or show_all then
            local preview_str = table.concat(preview, ", ")
            if count > 5 then preview_str = preview_str .. "..." end
            io.stdout:write(string.format("%-24s : %5d пакетов [%s]\n", display_label, count, preview_str))
            printed = printed + 1
        end
    end

    if printed == 0 then
        io.stdout:write("  Пакеты не найдены\n")
    end

    io.stdout:write(string.rep("─", 75) .. "\n")
    io.stdout:write("\27[90mДля подробной справки используйте: grime pkg --help\27[0m\n\n")
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

local function handle_run(manager, packages, command_tokens)
    if not packages or #packages == 0 then
        ctx.fail("Укажите имя пакета или приложения для запуска")
        return
    end

    local target_name = packages[1]
    local apps_root = get_apps_root()
    local app_dir = apps_root .. "/" .. target_name
    local is_app = (manager == "apps" or manager == "app") or (ctx.exists(app_dir) and ctx.is_dir(app_dir))

    if is_app then
        if not ctx.exists(app_dir) then
            ctx.fail(string.format("Приложение '%s' не найдено в %s", target_name, apps_root))
            return
        end

        local run_args = {}
        for i = 2, #packages do
            table.insert(run_args, packages[i])
        end
        for _, ct in ipairs(command_tokens or {}) do
            table.insert(run_args, ct)
        end

        -- Запуск приложения через модуль app
        local ok, app_mod = pcall(require, "app")
        if ok and type(app_mod) == "table" and app_mod.run_app and app_mod.load_manifest then
            local m, err = app_mod.load_manifest(app_dir, target_name)
            if not m then
                ctx.fail(err or ("Не удалось загрузить манифест приложения: " .. target_name))
                return
            end
            local ret = app_mod.run_app(target_name, m, app_dir, run_args, false)
            if ret ~= 0 then
                ctx.fail(string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret))
            end
        else
            local proc = { "grime", "app", target_name }
            for _, a in ipairs(run_args) do
                table.insert(proc, a)
            end
            local ret = ctx.run_process(proc)
            if ret ~= 0 then
                ctx.fail(string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret))
            end
        end
        return
    end

    -- Стандартный запуск через Nix для обычных пакетов
    local pkg = target_name
    local cmd = { "nix-shell", "-p", pkg, "--run" }
    local inner_tokens = {}
    for i = 2, #packages do
        table.insert(inner_tokens, packages[i])
    end
    for _, ct in ipairs(command_tokens or {}) do
        table.insert(inner_tokens, ct)
    end
    local inner = (#inner_tokens > 0) and table.concat(inner_tokens, " ") or pkg
    table.insert(cmd, inner)

    ctx.log(string.format("Изолированный запуск [%s]: %s...", pkg, inner))
    local ret = ctx.run_process(cmd)
    if ret ~= 0 then
        ctx.fail("Выполнение завершилось ошибкой")
    end
end

local function print_help()
    print(string.format([[
%s%sGrime Pkg%s — Унифицированное управление пакетами хоста, контейнеров и окружений

%sИСПОЛЬЗОВАНИЕ:%s
    grime pkg [команда] [менеджер] [пакеты...]

%sКОМАНДЫ:%s
    %slist, ls, show%s        Обзор установленных пакетов во всех или выбранных менеджерах (по умолчанию)
                         grime pkg list [pacman|nix|distrobox|flatpak|cargo|pipx|apps...]
    %sinstall, i, add%s       Установка пакетов через выбранный менеджер
                         grime pkg install pacman <пакеты...>
                         grime pkg install nix <пакеты...>
                         grime pkg install distrobox <box> <пакеты...>
    %srun, r%s                Изолированный запуск приложения или пакета
                         grime pkg run <пакет_или_приложение> [аргументы...]
    %shelp, -h, --help%s      Показать эту справку

%sПОДДЕРЖИВАЕМЫЕ МЕНЕДЖЕРЫ:%s
    pacman, nix, distrobox, flatpak, cargo, pipx, apps

%sПРИМЕРЫ:%s
    grime pkg                               # Быстрый обзор всех пакетов системы
    grime pkg list distrobox nix            # Просмотр пакетов в Distrobox и Nix
    grime pkg install cargo ripgrep         # Установка через cargo
    grime pkg run htop                      # Изолированный запуск через nix-shell
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    for _, a in ipairs(ctx.args or {}) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local cls = classifier.new({
        actions = ACTIONS,
        default_action = "list",
        flags = { all = { "-a", "--all", "--deps" } },
    })

    local parsed = cls:parse(ctx.args)
    local action = parsed.action or "list"

    if action == "help" then
        print_help()
        return
    end

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
        if ctx.has_next_step then
            ctx.module_return(ctx.target_dir)
        end
    elseif action == "install" then
        local mgr = managers[1] or "pacman"
        handle_install(mgr, rest_tokens)
    elseif action == "run" then
        local mgr = managers[1]
        handle_run(mgr, rest_tokens, parsed.command_tokens)
    elseif action == "init" then
        require("nix")
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
