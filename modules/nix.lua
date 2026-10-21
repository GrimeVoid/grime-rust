--[[
    Grime Nix Module (Flakes-Only DevShells, Builds & Profile Management)
    Оркестратор изолированных сред Nix Flakes, эфемерных сборок без shell.nix,
    управления профилем пользователя Nix и переносимых бандлов.
]]

-- Summary: Оркестратор изолированных сред Nix Flakes, сборок и профилей
-- Description: Оркестратор изолированных сред Nix Flakes, сборок и профилей
description = "Оркестратор изолированных сред Nix Flakes, сборок и профилей"

local argparse = require("languages.argparse")
local scanner = require("languages.scanner")
local utils = require("languages.utils")

-- Модульные переменные file-scope
local ctx = grime.ctx
local ui = grime.ui
local str = grime.str
local fs = grime.fs
local HOME = os.getenv("HOME") or ""
local ANSI = utils.ANSI

local ACTIONS = {
    init = "init", create = "init", new = "init", make = "init",
    flake = "flake", f = "flake",
    build = "build", b = "build", compile = "build",
    history = "history", hist = "history", log = "history",
    rollback = "rollback", revert = "rollback",
    update = "update", up = "update",
    bundle = "bundle", pack = "bundle",
    diff = "diff", closures = "diff",
    gc = "gc", clean = "gc", cleanup = "gc", ["garbage-collect"] = "gc",
    optimise = "optimise", optimize = "optimise", opt = "optimise", dedup = "optimise",
    add = "add", append = "add", ["in"] = "add",
    rm = "rm", remove = "rm", del = "rm", delete = "rm",
    install = "install", i = "install", ["profile-install"] = "install", get = "install",
    uninstall = "uninstall", un = "uninstall", ["remove-profile"] = "uninstall", ["rm-profile"] = "uninstall", erase = "uninstall",
    enter = "enter", shell = "enter", sh = "enter",
    run = "run", ["exec"] = "run", ["do"] = "run", ["run-in"] = "run", e = "run",
    check = "check", test = "check", validate = "check",
    help = "help",
}

local ROOT_COMMANDS = {
    ["aircrack-ng"] = true, ["airmon-ng"] = true, ["airodump-ng"] = true, ["aireplay-ng"] = true,
    ["packetforge-ng"] = true, ["airbase-ng"] = true,
    tcpdump = true, wireshark = true, tshark = true,
    nmap = true, netdiscover = true, masscan = true,
    iftop = true, iptraf = true, bmon = true,
    iptables = true, ip6tables = true, nft = true,
    ethtool = true, iw = true, iwconfig = true, iwpriv = true,
    wavemon = true, kismet = true, hping3 = true, arping = true,
    bettercap = true, ettercap = true, dsniff = true,
}

--- Загрузка специальных зависимостей из app.lua (если есть)
local function load_app_special_dependencies(root)
    local app_file = root .. "/app.lua"
    if not ctx.exists(app_file) then return {} end

    local chunk = loadfile(app_file, "t", {})
    if not chunk then return {} end

    local ok, m = pcall(chunk)
    if not ok or type(m) ~= "table" then return {} end

    local deps = {}
    local function add_all(list)
        if type(list) == "table" then
            for _, v in ipairs(list) do
                if type(v) == "string" and #v > 0 then
                    table.insert(deps, v)
                end
            end
        elseif type(list) == "string" then
            for s in list:gmatch("%S+") do
                table.insert(deps, s)
            end
        end
    end

    add_all(m.special_dependencies)
    add_all(m.dependencies)
    add_all(m.extra_packages)
    if type(m.nix) == "table" then
        add_all(m.nix.dependencies)
        add_all(m.nix.packages)
        add_all(m.nix.special_dependencies)
    end

    return deps
end

--- Извлечение существующих пакетов из локального flake.nix (если есть)
local function parse_existing_flake_packages(flake_path)
    if not ctx.exists(flake_path) then return {} end
    local content = fs.read(flake_path)
    if not content then return {} end
    local pkgs = {}
    local seen = {}
    for block in content:gmatch("with%s+pkgs;%s*%[([^%]]*)%]") do
        for token in block:gmatch("[%w_%-%.]+") do
            if not seen[token] then
                seen[token] = true
                table.insert(pkgs, token)
            end
        end
    end
    return pkgs
end

--- Комплексный сбор всех зависимостей проекта (Auto-Toolchain + Special Dependencies + CLI args)
local function resolve_project_dependencies(target_dir, user_packages)
    local scan = scanner.scan_project(target_dir, ctx)
    local all_packages = {}

    for _, p in ipairs(scan.toolchain or {}) do
        table.insert(all_packages, p)
    end
    for _, p in ipairs(load_app_special_dependencies(target_dir)) do
        table.insert(all_packages, p)
    end
    for _, p in ipairs(user_packages or {}) do
        table.insert(all_packages, p)
    end

    return utils.split_packages(all_packages, scanner)
end

--- Получение или синтез эфемерного Flake в каталоге кэша ~/.cache/grime/flakes/<hash>/
local function get_ephemeral_flake_dir(target_dir, user_packages)
    local scan = scanner.scan_project(target_dir, ctx)
    local app_raw = ctx.exists(target_dir .. "/app.lua") and (fs.read(target_dir .. "/app.lua") or "") or ""
    local sig = target_dir .. "|" .. table.concat(scan.toolchain or {}, ",") .. "|" .. app_raw
    local h = 5381
    for i = 1, #sig do
        h = ((h * 33) + sig:byte(i)) % 4294967296
    end
    local hash = string.format("%08x", h)
    local cache_dir = HOME .. "/.cache/grime/flakes/" .. hash
    ctx.mkdir_p(cache_dir)

    local cache_flake_path = cache_dir .. "/flake.nix"
    if not ctx.exists(cache_flake_path) or (user_packages and #user_packages > 0) then
        local native_pkgs, lib_pkgs = resolve_project_dependencies(target_dir, user_packages)
        local proj_name = target_dir:match("([^/]+)$") or "ephemeral"
        local flake_content = utils.generate_flake_nix(proj_name, native_pkgs, lib_pkgs, "Ephemeral DevShell for " .. target_dir)
        local f = io.open(cache_flake_path, "w")
        if f then
            f:write(flake_content)
            f:close()
        else
            ctx.fail("Не удалось создать эфемерный Flake в " .. cache_flake_path)
        end
    end
    return cache_dir
end

local function handle_flake(target_dir, packages, force)
    local flake_path = target_dir .. "/flake.nix"
    if ctx.exists(flake_path) and not force then
        ctx.log("Файл flake.nix уже существует. Используйте -f / --force для перезаписи.")
        return
    end

    local native_pkgs, lib_pkgs = resolve_project_dependencies(target_dir, packages)
    local proj_name = target_dir:match("([^/]+)$") or "project"
    local content = utils.generate_flake_nix(proj_name, native_pkgs, lib_pkgs)
    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
        ctx.log(string.format("Создан flake.nix в %s (native: %s%s)",
            target_dir,
            table.concat(native_pkgs, ", "),
            #lib_pkgs > 0 and (", libs: " .. table.concat(lib_pkgs, ", ")) or ""
        ))
    else
        ctx.fail("Не удалось записать " .. flake_path)
    end
end

local function handle_add(target_dir, packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для добавления в окружение проекта: grime nix add <pkg...>")
        return
    end
    local flake_path = target_dir .. "/flake.nix"
    local existing = parse_existing_flake_packages(flake_path)
    for _, p in ipairs(packages) do
        table.insert(existing, p)
    end
    handle_flake(target_dir, existing, true)
    ui.success("Пакеты добавлены в flake.nix: " .. table.concat(packages, ", "))
    if ctx.has_next_step then ctx.module_return(target_dir) end
end

local function handle_rm(target_dir, packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для удаления из окружения проекта: grime nix rm <pkg...>")
        return
    end
    local flake_path = target_dir .. "/flake.nix"
    if not ctx.exists(flake_path) then
        ctx.fail("Файл flake.nix не найден в " .. target_dir)
        return
    end
    local rm_set = {}
    for _, p in ipairs(packages) do rm_set[p] = true; rm_set["pkgs." .. p] = true end

    local existing = parse_existing_flake_packages(flake_path)
    local filtered = {}
    for _, p in ipairs(existing) do
        if not rm_set[p] then
            table.insert(filtered, p)
        end
    end

    local native_pkgs, lib_pkgs = utils.split_packages(filtered, scanner)
    local proj_name = target_dir:match("([^/]+)$") or "project"
    local content = utils.generate_flake_nix(proj_name, native_pkgs, lib_pkgs)
    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
        ui.success("Пакеты удалены из flake.nix: " .. table.concat(packages, ", "))
        if ctx.has_next_step then ctx.module_return(target_dir) end
    else
        ctx.fail("Не удалось обновить " .. flake_path)
    end
end

-- В стандарте Flakes-Only init создает современный flake.nix
local function handle_init(target_dir, packages, force)
    handle_flake(target_dir, packages, force)
end

--- Сборка проекта в эфемерном Flake-окружении (без загрязнения рабочего дерева)
local function handle_build(target_dir, extra_tokens)
    target_dir = ctx.normalize_path(target_dir)

    local user_packages = {}
    local custom_build_cmd = nil

    if extra_tokens and #extra_tokens > 0 then
        local is_command = false
        for _, t in ipairs(extra_tokens) do
            if type(t) == "string" then
                if t:find("%s") or t:find("^%-") or t:find("&&") or t:find(";") or t:find("|") or t:find(">") or t:find("<") or t:find("^%./") or t:find("^/") then
                    is_command = true
                    break
                end
            end
        end

        if not is_command then
            local first = extra_tokens[1]
            local known_build_cmds = {
                make = true, cmake = true, ninja = true, cargo = true,
                ["g++"] = true, ["clang++"] = true, gcc = true, clang = true,
                bash = true, sh = true, meson = true, gradle = true, mvn = true
            }
            if known_build_cmds[first] and #extra_tokens >= 1 then
                is_command = true
            end
        end

        if is_command then
            if #extra_tokens == 1 then
                custom_build_cmd = extra_tokens[1]
            else
                local escaped = {}
                local shell_ops = { ["&&"] = true, ["||"] = true, [";"] = true, ["|"] = true }
                for _, tok in ipairs(extra_tokens) do
                    if shell_ops[tok] then
                        table.insert(escaped, tok)
                    else
                        table.insert(escaped, utils.shell_escape(tok))
                    end
                end
                custom_build_cmd = table.concat(escaped, " ")
            end
        else
            user_packages = extra_tokens
        end
    end

    if ctx.exists(target_dir .. "/flake.nix") then
        ctx.log("⚡ [Grime Nix Build] Сборка через локальный flake.nix в " .. target_dir .. "...")
        local cmd_str = custom_build_cmd or "grime project build"
        local cmd = { "nix", "develop", "--command", "bash", "-c", cmd_str }
        local ret = ctx.run_process(cmd, target_dir)
        ctx.module_return(target_dir)
        if ret ~= 0 then
            ctx.fail("Сборка внутри Nix завершилась с ошибкой (код " .. tostring(ret) .. ")")
        end
        return
    end

    local cache_dir = get_ephemeral_flake_dir(target_dir, user_packages)
    ctx.log("⚡ [Grime Ephemeral Flake] Запуск чистой сборки в " .. cache_dir .. "...")

    local escaped_dir = utils.shell_escape(target_dir)
    local build_cmd = custom_build_cmd or ("grime project build " .. escaped_dir)
    local cmd = {
        "nix", "develop", "path:" .. cache_dir,
        "--command", "bash", "-c",
        "cd " .. escaped_dir .. " && " .. build_cmd
    }

    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Сборка в эфемерном Nix Flake завершилась с ошибкой (код " .. tostring(ret) .. ")")
    else
        ctx.log("✓ Сборка в изолированном Nix Flake успешно завершена!")
    end
end

local function handle_gc()
    ctx.log("Запуск комплексной очистки хранилища Nix и кэша GRIME (Garbage Collection)...")
    local ret = ctx.run_process({ "nix-collect-garbage", "-d" })
    if ret ~= 0 then
        ret = ctx.run_process({ "nix", "store", "gc" })
    end

    -- Очистка эфемерного кэша Flakes GRIME
    local flakes_cache = HOME .. "/.cache/grime/flakes"
    if ctx.exists(flakes_cache) then
        ctx.log("Очистка эфемерного кэша Flakes GRIME (" .. flakes_cache .. ")...")
        ctx.capture({ "rm", "-rf", flakes_cache })
    end

    -- Очистка локального eval/tarball кэша Nix
    local nix_eval_cache = HOME .. "/.cache/nix"
    if ctx.exists(nix_eval_cache) then
        ctx.log("Очистка локального кэша вычислений Nix (" .. nix_eval_cache .. ")...")
        ctx.capture({ "rm", "-rf", nix_eval_cache })
    end

    if ret == 0 then
        ctx.log("✓ Хранилище Nix и кэш GRIME успешно очищены.")
    else
        ctx.fail("Ошибка при сборке мусора Nix (код " .. tostring(ret) .. ")")
    end
end

local function handle_optimise()
    ctx.log("Оптимизация и дедупликация хранилища Nix...")
    local ret = ctx.run_process({ "nix", "store", "optimise" })
    if ret ~= 0 then
        ret = ctx.run_process({ "nix-store", "--optimise" })
    end
    if ret == 0 then
        ctx.log("Дедупликация жестких ссылок Nix завершена.")
    else
        ctx.fail("Ошибка оптимизации хранилища Nix (код " .. tostring(ret) .. ")")
    end
end

local function handle_enter(target_dir, pure)
    local has_flake = ctx.exists(target_dir .. "/flake.nix")
    local cmd = { "nix", "develop" }
    if not has_flake then
        local cache_dir = get_ephemeral_flake_dir(target_dir)
        cmd = { "nix", "develop", "path:" .. cache_dir }
    end
    if pure then table.insert(cmd, "--pure") end

    ctx.log("Активация Flake devShell в " .. target_dir .. "...")
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Сессия Nix завершилась с кодом " .. tostring(ret))
    end
end

local function handle_run(target_dir, command_tokens, pure)
    local tokens = {}
    for _, t in ipairs(command_tokens or {}) do
        if t ~= "--nv" and t ~= "--prime" and t ~= "--nvidia" and t ~= "--gl" and t ~= "--gpu" and t ~= "--no-gpu" then
            table.insert(tokens, t)
        end
    end

    local use_sudo = false
    if #tokens > 0 and tokens[1] == "sudo" then
        use_sudo = true
        table.remove(tokens, 1)
    end

    local cmd_target = tokens[1]
    local cmd_args = {}
    if not cmd_target or cmd_target == "" then
        cmd_target = "grime"
        cmd_args = { "project", "run" }
    else
        for i = 2, #tokens do
            table.insert(cmd_args, tokens[i])
        end
    end

    if not use_sudo and (ROOT_COMMANDS[cmd_target] or utils.is_root_user(ctx)) then
        use_sudo = true
    end

    -- Аудит безопасности путей (Path Sovereignty)
    local allowed, reason = utils.classify_paths(cmd_target, cmd_args, target_dir, ctx)
    if not allowed then
        ctx.fail(string.format("[Grime Nix] Отказ: %s", reason))
        return
    end

    local shell_cmd = utils.build_nixgl_wrapper(cmd_target, cmd_args, use_sudo)
    local cmd = { "nix", "develop" }
    if not ctx.exists(target_dir .. "/flake.nix") then
        local cache_dir = get_ephemeral_flake_dir(target_dir)
        cmd = { "nix", "develop", "path:" .. cache_dir }
    end
    if pure then table.insert(cmd, "--pure") end
    table.insert(cmd, "--command")
    table.insert(cmd, "bash")
    table.insert(cmd, "-c")
    table.insert(cmd, shell_cmd)

    ctx.log(string.format("Запуск внутри Nix devShell [%s%s]: %s (директория: %s)",
        cmd_target, use_sudo and " (sudo -E)" or "", table.concat(tokens, " "), target_dir))
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Команда внутри Nix завершилась с кодом " .. tostring(ret))
    end
end

local function handle_install(packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для установки в профиль Nix")
        return
    end

    local cmd = { "nix", "profile", "install" }
    for _, p in ipairs(packages) do
        if not p:find("[:#/]") then
            table.insert(cmd, "nixpkgs#" .. p)
        else
            table.insert(cmd, p)
        end
    end

    ctx.log("Установка пакетов в профиль Nix: " .. table.concat(packages, ", ") .. "...")
    local ret = ctx.run_process(cmd)
    if ret == 0 then
        ctx.log("Пакеты успешно установлены в профиль Nix.")
    else
        ctx.fail("Ошибка установки пакетов в профиль Nix")
    end
end

local function handle_uninstall(packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для удаления из профиля Nix")
        return
    end

    local cmd = { "nix", "profile", "remove" }
    for _, p in ipairs(packages) do
        table.insert(cmd, p)
    end

    ctx.log("Удаление пакетов из профиля Nix: " .. table.concat(packages, ", ") .. "...")
    local ret = ctx.run_process(cmd)
    if ret == 0 then
        ctx.log("Пакеты успешно удалены из профиля Nix.")
    else
        ctx.fail("Ошибка удаления пакетов из профиля Nix")
    end
end

local function handle_check(target_dir)
    local has_flake = ctx.exists(target_dir .. "/flake.nix")
    local cmd = { "nix", "flake", "check" }
    if not has_flake then
        local cache_dir = get_ephemeral_flake_dir(target_dir)
        cmd = { "nix", "flake", "check", "path:" .. cache_dir }
    end

    ctx.log("Проверка конфигурации Flake в " .. target_dir .. "...")
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret == 0 then
        ctx.log("Конфигурация Nix Flake валидна.")
    else
        ctx.fail("Ошибка валидации конфигурации Nix Flake")
    end
end

local function handle_history()
    ctx.log("Получение истории поколений профиля Nix...")
    local res = ctx.capture({ "nix", "profile", "history" })
    if res.code ~= 0 then
        ctx.fail("Ошибка получения истории профиля Nix: " .. (res.stderr or ""))
        return
    end

    local stdout = res.stdout or ""
    if #str.trim(stdout) == 0 then
        ui.log("История поколений профиля Nix пуста.")
        ctx.success("0 generations")
        return
    end

    local lines = str.split(stdout, "\n")
    local generations = {}
    local current_gen = nil

    for _, raw_line in ipairs(lines) do
        local line = raw_line:gsub("\27%[[%d;]*m", "")
        local v, date = line:match("Version%s+(%d+)%s*%(([%d%-]+)%)")
        if v then
            current_gen = {
                version = v,
                date = date,
                changes = {},
            }
            table.insert(generations, current_gen)
        elseif current_gen and #str.trim(line) > 0 then
            table.insert(current_gen.changes, str.trim(line))
        end
    end

    if #generations == 0 then
        print(stdout)
        ctx.success(stdout)
        return
    end

    local rows = {}
    for _, g in ipairs(generations) do
        local change_summary = tostring(#g.changes) .. " изм."
        if #g.changes > 0 then
            local first = g.changes[1]
            local pkg = first:match("([^%s:]+):") or first:match("([^%s:]+)$") or first
            pkg = pkg:match("([^%.]+)$") or pkg
            change_summary = string.format("%d изм. (%s%s)", #g.changes, pkg, #g.changes > 1 and "..." or "")
        end
        table.insert(rows, { "v" .. g.version, g.date, change_summary })
    end

    print(string.format("\n\27[1mИстория поколений профиля Nix (%d поколений):\27[0m", #generations))
    ui.print_table(rows, { "Версия", "Дата", "Изменения" })
    print()

    if #generations > 0 then
        local latest = generations[#generations]
        print(string.format("\27[1;36mТекущее поколение v%s (%s):\27[0m", latest.version, latest.date))
        for _, ch in ipairs(latest.changes) do
            print(string.format("  \27[32m•\27[0m %s", ch))
        end
        print()
    end

    if ctx.has_next_step then
        ctx.success(generations[#generations].version)
    else
        ctx.success(tostring(#generations))
    end
end

local function handle_rollback(to_generation)
    local cmd = { "nix", "profile", "rollback" }
    local target_desc = "на предыдущее поколение"
    if to_generation and tostring(to_generation):match("^%d+$") then
        table.insert(cmd, "--to")
        table.insert(cmd, tostring(to_generation))
        target_desc = "на поколение " .. tostring(to_generation)
    end

    ctx.log(string.format("Откат профиля Nix %s...", target_desc))
    local res = ctx.capture(cmd)
    if res.code ~= 0 then
        ctx.fail("Ошибка отката профиля Nix: " .. (res.stderr or res.stdout or ""))
        return
    end

    ui.success(string.format("Профиль Nix успешно откатан %s.", target_desc))
    ctx.success(to_generation or "prev")
end

local function handle_update(target_dir)
    target_dir = ctx.normalize_path(target_dir or ".")
    local flake_path = target_dir .. "/flake.nix"
    if not ctx.exists(flake_path) then
        ctx.fail("Файл flake.nix не найден в " .. target_dir)
        return
    end

    ctx.log(string.format("Обновление входных зависимостей флейка (nix flake update) в %s...", target_dir))
    local res = ctx.capture({ "nix", "flake", "update" }, target_dir)
    if res.code ~= 0 then
        ctx.fail("Ошибка обновления flake: " .. (res.stderr or res.stdout or ""))
        return
    end

    local out = (res.stderr or "") .. "\n" .. (res.stdout or "")
    local updated_inputs = {}
    for line in out:gmatch("[^\r\n]+") do
        local input, from, to = line:match("Updated input '([^']+)':%s*'([^']+)'%s*%->%s*'([^']+)'")
        if input then
            table.insert(updated_inputs, { input = input, from = from, to = to })
        end
    end

    if #updated_inputs > 0 then
        print(string.format("\n\27[1;32m✓ Обновлены зависимости flake.lock (%d шт.):\27[0m", #updated_inputs))
        for _, inp in ipairs(updated_inputs) do
            print(string.format("  \27[1m%s\27[0m: \27[90m%s\27[0m -> \27[36m%s\27[0m", inp.input, inp.from, inp.to))
        end
        print()
    else
        ui.success("Зависимости флейка уже находятся в актуальном состоянии.")
    end

    ctx.module_return(target_dir)
end

local function handle_bundle(target_dir, args, out_link)
    target_dir = ctx.normalize_path(target_dir or ".")
    local cmd = { "nix", "bundle" }

    local installable = nil
    if args and #args > 0 then
        installable = args[1]
    elseif ctx.exists(target_dir .. "/flake.nix") then
        installable = "."
    else
        ctx.fail("Укажите цель для сборки бандла (например, '.' или nixpkgs#hello)")
        return
    end

    table.insert(cmd, installable)
    if out_link and #out_link > 0 then
        table.insert(cmd, "-o")
        table.insert(cmd, out_link)
    end

    ctx.log(string.format("⚡ [Grime Nix Bundle] Упаковка '%s' в переносимый бинарник...", installable))
    local ret = ctx.run_process(cmd, target_dir)
    if ret == 0 then
        local bundle_name = out_link or installable:match("([^#/]+)$") or "bundle"
        ui.success(string.format("Автономный переносимый бандл успешно собран: %s", bundle_name))
        ctx.module_return(out_link or target_dir)
    else
        ctx.fail("Ошибка сборки бандла nix bundle (код " .. tostring(ret) .. ")")
    end
end

local function handle_diff()
    ctx.log("Анализ изменений замыканий профиля Nix (diff-closures)...")
    local res = ctx.capture({ "nix", "profile", "diff-closures" })
    if res.code ~= 0 then
        ctx.fail("Ошибка анализа diff-closures: " .. (res.stderr or ""))
        return
    end

    local out = str.trim(res.stdout or "")
    if #out == 0 then
        ui.log("Изменений между версиями профиля Nix не обнаружено.")
        ctx.success("no_diff")
    else
        print(string.format("\n\27[1mИзменения замыканий профиля Nix:\27[0m\n"))
        print(out)
        print()
        ctx.success(out)
    end
end

local function print_help()
    print(string.format([[
%s%sGrime Nix%s — Управление Flake-окружениями разработки и профилями Nix

%sИСПОЛЬЗОВАНИЕ:%s
    grime nix [команда] [аргументы/пакеты...]

%sКОМАНДЫ:%s
    %sbuild, b%s                Сборка проекта в изолированном Nix Flake (без загрязнения репозитория)
                          grime nix build [проект/путь]
    %sinit, create, new, flake%s Создать постоянный flake.nix в проекте (авто-тулчейн)
                          grime nix init [пакеты...] [--force]
    %senter, shell, sh%s      Войти в изолированный devShell (nix develop)
                          grime nix enter [--pure]
    %srun, exec%s             Выполнить команду в Flake devShell окружении
                          grime nix run <команда...> [--pure]
    %shistory, hist%s          История поколений профиля пользователя Nix
                          grime nix history
    %srollback%s               Откатить профиль Nix на предыдущее или указанное поколение
                          grime nix rollback [--to <N>]
    %supdate, up%s             Обновить входные зависимости флейка (nix flake update)
                          grime nix update [каталог]
    %sbundle%s                 Упаковать цель в автономный переносимый бинарник (nix bundle)
                          grime nix bundle [цель] [-o вывод]
    %sdiff%s                   Анализ изменений замыканий профиля (diff-closures)
                          grime nix diff
    %sinstall, i%s            Установить пакеты в профиль пользователя Nix
                          grime nix install <пакеты...>
    %suninstall%s              Удалить пакеты из профиля пользователя Nix
                          grime nix uninstall <пакеты...>
    %sgc, clean%s              Очистить неиспользуемые пути в Nix store (garbage collector)
                          grime nix gc
    %soptimise, opt%s          Дедупликация жестких ссылок в Nix store
                          grime nix optimise
    %scheck, validate%s        Проверить валидность конфигурации flake.nix
                          grime nix check
    %shelp, -h, --help%s       Показать эту справку

%sФЛАГИ:%s
    %s--force, -f%s           Перезаписать существующий файл flake.nix
    %s--pure%s                Изолированный запуск без переменных хоста
    %s--to <N>%s              Целевое поколение для отката (rollback)
    %s-o, --out-link%s        Путь для сохранения бандла (bundle)

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime nix init : nix build              # Генерация flake.nix и сборка
    grime nix run cargo test                # Запуск тестов внутри Flake devShell
    grime nix history                       # Просмотр истории поколений профиля
    grime nix rollback                      # Откат профиля на предыдущую версию
    grime nix update                        # Обновление зависимостей flake.lock
    grime nix bundle nixpkgs#hello          # Упаковка в автономный переносимый бинарник
]],
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

function main()
    local raw_args = ctx.args or {}
    if #raw_args == 0 then
        print_help()
        return
    end

    for _, a in ipairs(raw_args) do
        local matched = (type(a) == "string" and a:match("^%-")) and grime.fuzzy.match_flag(a, { "--help", "-h" }, 0.75) or a
        if matched == "--help" or matched == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local raw_target = ctx.target_dir
    if not raw_target or #raw_target == 0 or not ctx.is_dir(raw_target) then
        raw_target = "."
    end
    local target_dir = ctx.normalize_path(raw_target)
    local cls = argparse.new({
        actions = ACTIONS,
        default_action = "init",
        flags = {
            force = { "-f", "--force" },
            pure = { "--pure" },
            flake = { "--flake" },
            gpu = { "--gpu", "--gl" },
            nv = { "--nv", "--prime", "--nvidia" },
        },
        detect_dir = true,
    })

    local parsed = cls:parse(ctx.args, target_dir)
    local action = parsed.action or "init"

    if action == "help" then
        print_help()
        return
    end

    if parsed.flags.flake and action == "init" then
        action = "flake"
    end

    local command_tokens = parsed.args
    for _, t in ipairs(parsed.command_tokens) do
        table.insert(command_tokens, t)
    end

    if parsed.target_dir and ctx.is_dir(parsed.target_dir) then
        target_dir = ctx.normalize_path(parsed.target_dir)
    elseif #command_tokens > 0 and ctx.is_dir(command_tokens[1]) then
        target_dir = ctx.normalize_path(table.remove(command_tokens, 1))
    end

    if action == "build" then
        handle_build(target_dir, command_tokens)
    elseif action == "init" or action == "flake" then
        handle_flake(target_dir, command_tokens, parsed.flags.force)
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
    elseif action == "add" then
        handle_add(target_dir, command_tokens)
    elseif action == "rm" then
        handle_rm(target_dir, command_tokens)
    elseif action == "gc" then
        handle_gc()
    elseif action == "optimise" then
        handle_optimise()
    elseif action == "enter" then
        handle_enter(target_dir, parsed.flags.pure)
    elseif action == "run" then
        handle_run(target_dir, command_tokens, parsed.flags.pure)
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
    elseif action == "install" then
        handle_install(command_tokens)
    elseif action == "uninstall" then
        handle_uninstall(command_tokens)
    elseif action == "check" then
        handle_check(target_dir)
    elseif action == "history" then
        handle_history()
    elseif action == "rollback" then
        local to_gen = nil
        for i, a in ipairs(command_tokens) do
            if a == "--to" and command_tokens[i + 1] then
                to_gen = command_tokens[i + 1]
                break
            elseif tostring(a):match("^%d+$") then
                to_gen = a
                break
            end
        end
        handle_rollback(to_gen)
    elseif action == "update" then
        handle_update(target_dir)
    elseif action == "bundle" then
        local out_link = nil
        local clean_tokens = {}
        local skip_next = false
        for i, a in ipairs(command_tokens) do
            if skip_next then
                skip_next = false
            elseif (a == "-o" or a == "--out-link") and command_tokens[i + 1] then
                out_link = command_tokens[i + 1]
                skip_next = true
            else
                table.insert(clean_tokens, a)
            end
        end
        handle_bundle(target_dir, clean_tokens, out_link)
    elseif action == "diff" then
        handle_diff()
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end

return {
    main = main,
    description = description,
}
