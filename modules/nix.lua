--@grime description: Оркестратор изолированных сред Nix Flakes, сборок и профилей
--@grime wraps: pipeline

--[[
    Grime Nix Module (Flakes-Only DevShells, Builds & Profile Management)
    Оркестратор изолированных сред Nix Flakes, эфемерных сборок без shell.nix,
    управления профилем пользователя Nix и переносимых бандлов.
]]


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
    ["-init"] = "init", ["--init"] = "init", ["-create"] = "init", ["--create"] = "init", ["-new"] = "init", ["--new"] = "init",
    ["-flake"] = "flake", ["--flake"] = "flake", ["-f"] = "flake",
    ["-build"] = "build", ["--build"] = "build", ["-b"] = "build", ["-compile"] = "build",
    ["-history"] = "history", ["--history"] = "history", ["-hist"] = "history", ["--hist"] = "history", ["-log"] = "history",
    ["-rollback"] = "rollback", ["--rollback"] = "rollback", ["-revert"] = "rollback",
    ["-update"] = "update", ["--update"] = "update", ["-u"] = "update", ["-up"] = "update",
    ["-bundle"] = "bundle", ["--bundle"] = "bundle", ["-pack"] = "bundle",
    ["-diff"] = "diff", ["--diff"] = "diff", ["-d"] = "diff",
    ["-gc"] = "gc", ["--gc"] = "gc", ["-clean"] = "gc", ["--clean"] = "gc",
    ["-optimise"] = "optimise", ["--optimise"] = "optimise", ["-optimize"] = "optimise", ["-opt"] = "optimise",
    ["-add"] = "add", ["--add"] = "add",
    ["-rm"] = "rm", ["--rm"] = "rm", ["-remove"] = "rm", ["--remove"] = "rm", ["-del"] = "rm", ["--del"] = "rm",
    ["-install"] = "install", ["--install"] = "install", ["-i"] = "install",
    ["-uninstall"] = "uninstall", ["--uninstall"] = "uninstall", ["-un"] = "uninstall",
    ["-enter"] = "enter", ["--enter"] = "enter", ["-shell"] = "enter", ["--shell"] = "enter", ["-sh"] = "enter",
    ["-run"] = "run", ["--run"] = "run", ["-exec"] = "run", ["--exec"] = "run", ["-r"] = "run",
    ["-check"] = "check", ["--check"] = "check", ["-test"] = "check", ["--test"] = "check", ["-c"] = "check",
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
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

--- Комплексный сбор всех зависимостей проекта (Auto-Toolchain + Special Dependencies + манифест app.lua + CLI args)
local function resolve_project_dependencies(target_dir, user_packages, scan)
    scan = scan or scanner.scan_project(target_dir, ctx)
    local r = utils.collect_nix_packages(target_dir, nil, scan, user_packages, ctx)
    return r.native, r.libs
end

-- Единый корень кэша эфемерных flake; подкаталоги по kind (env, compile)
local FLAKES_ROOT = HOME .. "/.cache/grime/flakes"
local FLAKES_TTL_DAYS = 30

--- Лёгкий sweep раз в сутки (по маркер-файлу): удаляет каталоги кэша старше FLAKES_TTL_DAYS суток
local function sweep_flakes_cache()
    if HOME == "" or HOME:sub(1, 1) ~= "/" or not ctx.exists(FLAKES_ROOT) then return end
    local marker = FLAKES_ROOT .. "/.sweep"
    local fresh = ctx.capture({ "find", FLAKES_ROOT, "-maxdepth", "1", "-name", ".sweep", "-mtime", "-1", "-print" })
    if fresh and fresh.code == 0 and (fresh.stdout or ""):find("%S") then return end
    local res = ctx.capture({
        "find", FLAKES_ROOT, "-mindepth", "1", "-maxdepth", "2", "-type", "d",
        "-mtime", "+" .. FLAKES_TTL_DAYS, "-print",
    })
    if res and res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\n]+") do
            -- Корни kind-подкаталогов не удаляем; строго внутри кэша grime
            if line:sub(1, #FLAKES_ROOT + 1) == FLAKES_ROOT .. "/" and not line:find("/../", 1, true)
                and line ~= FLAKES_ROOT .. "/env" and line ~= FLAKES_ROOT .. "/compile" then
                ctx.capture({ "rm", "-rf", line })
            end
        end
    end
    local f = io.open(marker, "w")
    if f then f:write(tostring(os.time())); f:close() end
end

--- Эфемерный Flake в кэше ~/.cache/grime/flakes/<kind>/<hash>/ (чистая функция, без ctx.fail).
--- opts: { kind = "env"|"compile" (по умолчанию env), packages = {...}, name = имя devShell }.
--- Возвращает путь к каталогу flake либо nil, сообщение об ошибке.
local function ephemeral_flake_dir(target_dir, opts)
    opts = opts or {}
    local kind = (opts.kind == "compile") and "compile" or "env"
    local user_packages = opts.packages
    sweep_flakes_cache()

    local scan = scanner.scan_project(target_dir, ctx)
    local app_raw = ctx.exists(target_dir .. "/app.lua") and (fs.read(target_dir .. "/app.lua") or "") or ""
    local sorted_user = {}
    for _, p in ipairs(user_packages or {}) do table.insert(sorted_user, tostring(p)) end
    table.sort(sorted_user)
    local sig = kind .. "|" .. target_dir .. "|" .. table.concat(scan.toolchain or {}, ",") .. "|" .. table.concat(scan.special_dependencies or {}, ",")
        .. "|" .. table.concat(sorted_user, ",") .. "|" .. app_raw
    local cache_dir = FLAKES_ROOT .. "/" .. kind .. "/" .. utils.djb2_hex(sig)
    ctx.mkdir_p(cache_dir)

    -- user_packages входят в ключ кэша: при совпадении ключа перезапись не нужна
    local cache_flake_path = cache_dir .. "/flake.nix"
    if ctx.exists(cache_flake_path) then
        ctx.capture({ "touch", cache_dir })  -- продлеваем TTL используемого flake
        return cache_dir
    end
    local native_pkgs, lib_pkgs = resolve_project_dependencies(target_dir, user_packages, scan)
    local proj_name = opts.name or target_dir:match("([^/]+)$") or "ephemeral"
    local ok = utils.write_flake(cache_dir, proj_name, native_pkgs, lib_pkgs,
        { desc = "Ephemeral DevShell for " .. target_dir, ctx = ctx })
    if not ok then
        return nil, "Не удалось создать эфемерный Flake в " .. cache_flake_path
    end
    return cache_dir
end

--- Обёртка с фатальной ошибкой для внутренних handlers
local function get_ephemeral_flake_dir(target_dir, user_packages)
    local dir, err = ephemeral_flake_dir(target_dir, { packages = user_packages })
    if not dir then ctx.fail(err) end
    return dir
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

--- Создан ли flake.nix самим grime (по описанию из utils.generate_flake_nix)
local function is_grime_flake(flake_path)
    local content = fs.read(flake_path)
    return content ~= nil and content:find("Grime Flake DevShell", 1, true) ~= nil
end

--- Применение fn(тело_списка) к первому списку `with pkgs; [ ... ]` в пользовательском flake.nix
--- (приоритет: nativeBuildInputs, packages, buildInputs). Возвращает новый текст либо nil
local function edit_user_pkg_list(content, fn)
    for _, key in ipairs({ "nativeBuildInputs", "packages", "buildInputs" }) do
        local s_start, s_end = content:find(key .. "%s*=%s*with%s+pkgs;%s*%[")
        if s_start then
            local close = content:find("]", s_end + 1, true)
            if close then
                local body = content:sub(s_end + 1, close - 1)
                return content:sub(1, s_end) .. fn(body) .. content:sub(close)
            end
        end
    end
    return nil
end

local function write_text(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function handle_add(target_dir, packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для добавления в окружение проекта: grime nix add <pkg...>")
        return
    end
    local valid_pkgs = {}
    for _, p in ipairs(packages) do
        local clean = tostring(p):gsub("^pkgs%.", "")
        if utils.valid_pkg_name(clean) then
            table.insert(valid_pkgs, clean)
        else
            utils.warn_invalid_pkg(clean)
        end
    end
    if #valid_pkgs == 0 then
        ctx.fail("Нет допустимых имён пакетов для добавления")
        return
    end
    packages = valid_pkgs

    local flake_path = target_dir .. "/flake.nix"
    if ctx.exists(flake_path) and not is_grime_flake(flake_path) then
        -- Пользовательский flake.nix не перезаписываем: правим только список пакетов
        local content = fs.read(flake_path) or ""
        local present = {}
        for _, t in ipairs(parse_existing_flake_packages(flake_path)) do present[t] = true end
        local to_add = {}
        for _, p in ipairs(packages) do
            if not present[p] then table.insert(to_add, p) end
        end
        local updated = edit_user_pkg_list(content, function(body)
            local add = {}
            for _, p in ipairs(to_add) do table.insert(add, "\n            " .. p) end
            return body:gsub("%s*$", "") .. table.concat(add) .. "\n          "
        end)
        if not updated then
            ctx.fail("flake.nix создан не grime и не содержит списка 'with pkgs; [ ... ]' в nativeBuildInputs/packages/buildInputs. Добавьте пакеты вручную: " .. table.concat(packages, ", "))
            return
        end
        if #to_add > 0 and not write_text(flake_path, updated) then
            ctx.fail("Не удалось обновить " .. flake_path)
            return
        end
        ui.success("Пакеты добавлены в пользовательский flake.nix: " .. table.concat(packages, ", "))
        if ctx.has_next_step then ctx.module_return(target_dir) end
        return
    end

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

    if not is_grime_flake(flake_path) then
        -- Пользовательский flake.nix: удаляем только токены внутри списка пакетов
        local content = fs.read(flake_path) or ""
        local updated = edit_user_pkg_list(content, function(body)
            return (body:gsub("[%w_%-%.]+", function(tok)
                if rm_set[tok] then return "" end
            end))
        end)
        if not updated or not write_text(flake_path, updated) then
            ctx.fail("Не удалось аккуратно изменить пользовательский flake.nix; удалите пакеты вручную: " .. table.concat(packages, ", "))
            return
        end
        ui.success("Пакеты удалены из пользовательского flake.nix: " .. table.concat(packages, ", "))
        if ctx.has_next_step then ctx.module_return(target_dir) end
        return
    end

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
    if write_text(flake_path, content) then
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

--- Токены `nix develop [path:<flake>] [--pure] [--impure] --command <cmd...>`.
--- dir_or_flake: каталог проекта (при наличии flake.nix — локальный flake, иначе эфемерный в кэше)
--- либо готовая flake-ссылка (содержит ':' или '#'). opts: { pure, impure, packages, kind, name }.
--- Возвращает токены, cache_dir | nil (для локального flake) либо nil, сообщение об ошибке.
local function develop_command(dir_or_flake, cmd_tokens, opts)
    opts = opts or {}
    local ref, cache_dir = nil, nil
    if dir_or_flake and dir_or_flake ~= "" then
        if dir_or_flake:find("[:#]") then
            ref = dir_or_flake
        elseif not ctx.exists(dir_or_flake .. "/flake.nix") then
            local err
            cache_dir, err = ephemeral_flake_dir(dir_or_flake,
                { kind = opts.kind, packages = opts.packages, name = opts.name })
            if not cache_dir then return nil, err end
            ref = cache_dir
        end
    end
    local t = utils.develop_cmd(ref, cmd_tokens, { impure = opts.impure })
    if opts.pure then
        for i, tok in ipairs(t) do
            if tok == "--command" then table.insert(t, i, "--pure"); break end
        end
    end
    return t, cache_dir
end

--- Разбор токенов сборки: возвращает (пользовательские пакеты, собственная команда сборки | nil)
local function parse_build_tokens(extra_tokens)
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

    return user_packages, custom_build_cmd
end

--- План сборки: { cmd, cwd, mode = "local"|"ephemeral", cache_dir } либо nil, сообщение об ошибке.
--- Внутри nix develop вызывается тот же исполняемый файл grime, что и снаружи (self_exe), с явным каталогом проекта:
--- "grime" из PATH может оказаться другой (устаревшей) версией и не создать артефакт.
local function plan_build(target_dir, extra_tokens)
    target_dir = ctx.normalize_path(target_dir)
    local user_packages, custom_build_cmd = parse_build_tokens(extra_tokens)

    if ctx.exists(target_dir .. "/flake.nix") then
        local cmd_str = custom_build_cmd or (utils.shell_escape(utils.self_exe()) .. " project build " .. utils.shell_escape(target_dir))
        return { cmd = { "nix", "develop", "--command", "bash", "-c", cmd_str }, cwd = target_dir, mode = "local" }
    end

    local cache_dir, err = ephemeral_flake_dir(target_dir, { packages = user_packages })
    if not cache_dir then return nil, err end
    local escaped_dir = utils.shell_escape(target_dir)
    local build_cmd = custom_build_cmd or (utils.shell_escape(utils.self_exe()) .. " project build " .. escaped_dir)
    return {
        cmd = utils.develop_cmd(cache_dir, { "bash", "-c", "cd " .. escaped_dir .. " && " .. build_cmd }),
        cwd = target_dir, mode = "ephemeral", cache_dir = cache_dir,
    }
end

--- Сборка проекта в эфемерном Flake-окружении (без загрязнения рабочего дерева)
local function handle_build(target_dir, extra_tokens)
    target_dir = ctx.normalize_path(target_dir)
    local plan, err = plan_build(target_dir, extra_tokens)
    if not plan then
        ctx.fail(err)
        return
    end
    if plan.mode == "local" then
        ctx.log("⚡ [Grime Nix Build] Сборка через локальный flake.nix в " .. target_dir .. "...")
    else
        ctx.log("⚡ [Grime Ephemeral Flake] Запуск чистой сборки в " .. plan.cache_dir .. "...")
    end
    local ret = ctx.run_process(plan.cmd, plan.cwd)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        if plan.mode == "local" then
            ctx.fail("Сборка внутри Nix завершилась с ошибкой (код " .. tostring(ret) .. ")")
        else
            ctx.fail("Сборка в эфемерном Nix Flake завершилась с ошибкой (код " .. tostring(ret) .. ")")
        end
    elseif plan.mode ~= "local" then
        ctx.log("✓ Сборка в изолированном Nix Flake успешно завершена!")
    end
end

local function handle_gc(assume_yes)
    if HOME == "" or HOME:sub(1, 1) ~= "/" then
        ctx.fail("Отказ: переменная HOME не задана, очистка кэша небезопасна")
        return
    end
    if not utils.confirm_destructive("Выполнить сборку мусора Nix (удалит старые поколения профилей) и очистить кэш flakes GRIME?", assume_yes, ctx) then
        return
    end
    ctx.log("Запуск комплексной очистки хранилища Nix и кэша GRIME (Garbage Collection)...")
    local ret = ctx.run_process({ "nix-collect-garbage", "-d" })
    if ret ~= 0 then
        ret = ctx.run_process({ "nix", "store", "gc" })
    end

    -- Очистка эфемерного кэша Flakes GRIME (только кэш grime, ~/.cache/nix не трогаем):
    -- весь flakes (kind-подкаталоги env/compile) и прежний compile_flakes для миграции
    local legacy_compile = HOME .. "/.cache/grime/compile_flakes"
    for _, dir in ipairs({ FLAKES_ROOT, legacy_compile }) do
        if ctx.exists(dir) then
            ctx.log("Очистка эфемерного кэша Flakes GRIME (" .. dir .. ")...")
            ctx.capture({ "rm", "-rf", dir })
        end
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

--- План запуска команды в devShell: { cmd, cwd, tokens, cmd_target, use_sudo } либо nil, причина отказа
local function plan_run(target_dir, command_tokens, pure)
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
        return nil, string.format("Отказ: %s", reason)
    end

    local shell_cmd = utils.build_nixgl_wrapper(cmd_target, cmd_args, use_sudo)
    local cmd, err = develop_command(target_dir, { "bash", "-c", shell_cmd }, { pure = pure })
    if not cmd then return nil, err end
    return { cmd = cmd, cwd = target_dir, tokens = tokens, cmd_target = cmd_target, use_sudo = use_sudo }
end

local function handle_run(target_dir, command_tokens, pure)
    local plan, err = plan_run(target_dir, command_tokens, pure)
    if not plan then
        ctx.fail(err)
        return
    end
    ctx.log(string.format("Запуск внутри Nix devShell [%s%s]: %s (директория: %s)",
        plan.cmd_target, plan.use_sudo and " (sudo -E)" or "", table.concat(plan.tokens, " "), target_dir))
    local ret = ctx.run_process(plan.cmd, plan.cwd)
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

    -- `nix profile add` (install устарел); unfree: --impure + NIXPKGS_ALLOW_UNFREE
    local cmd, env = utils.nix_profile_add_cmd(packages)

    ctx.log("Установка пакетов в профиль Nix: " .. table.concat(packages, ", ") .. "...")
    local ret = ctx.run_process(cmd, nil, env)
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
    -- Парсер: старый однострочный формат и многострочный формат современного nix:
    --   • Updated input 'nixpkgs':
    --       'github:...' (дата)
    --     → 'github:...' (дата)
    local updated_inputs = {}
    local cur = nil
    for line in out:gmatch("[^\r\n]+") do
        line = line:gsub("\27%[[%d;]*m", "")
        local input, from, to = line:match("Updated input '([^']+)':%s*'([^']+)'%s*%->%s*'([^']+)'")
        if input then
            table.insert(updated_inputs, { input = input, from = from, to = to })
            cur = nil
        else
            local name = line:match("Updated input '([^']+)'")
            if name then
                cur = { input = name }
                table.insert(updated_inputs, cur)
            elseif cur then
                local ref = line:match("'([^']+)'")
                if ref then
                    if line:find("→", 1, true) or line:find("->", 1, true) then
                        cur.to = ref
                    elseif not cur.from then
                        cur.from = ref
                    end
                end
            end
        end
    end
    for _, inp in ipairs(updated_inputs) do
        inp.from = inp.from or "?"
        inp.to = inp.to or "?"
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
    -- Flake-ссылки (nixpkgs#X) считаются в чистом режиме: unfree требует --impure + env
    local env = nil
    if installable:find("#", 1, true) and not installable:find("^[%./]") then
        for _, f in ipairs(utils.nix_unfree_flags()) do table.insert(cmd, f) end
        env = utils.nix_unfree_env()
    end
    if out_link and #out_link > 0 then
        table.insert(cmd, "-o")
        table.insert(cmd, out_link)
    end

    ctx.log(string.format("⚡ [Grime Nix Bundle] Упаковка '%s' в переносимый бинарник...", installable))
    local ret = ctx.run_process(cmd, target_dir, env)
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
    grime nix [команда|-флаг] [аргументы/пакеты...]

%sКОМАНДЫ И ФЛАГИ (поддерживаются с '-' / '--' и без):%s
    %sbuild, -b, --build%s          Сборка проекта в изолированном Nix Flake (без загрязнения репозитория)
                                grime nix --build [проект/путь]
    %sinit, -init, --flake%s        Создать постоянный flake.nix в проекте (авто-тулчейн)
                                grime nix --init [пакеты...] [--force]
    %senter, --enter, --shell%s     Войти в изолированный devShell (nix develop)
                                grime nix --enter [--pure]
    %srun, -r, --run, --exec%s      Выполнить команду в Flake devShell окружении
                                grime nix --run <команда...> [--pure]
    %shistory, --history, --hist%s  История поколений профиля пользователя Nix
                                grime nix --history
    %srollback, --rollback%s        Откатить профиль Nix на предыдущее или указанное поколение
                                grime nix --rollback [--to <N>]
    %supdate, -u, --update%s        Обновить входные зависимостей флейка (nix flake update)
                                grime nix --update [каталог]
    %sbundle, --bundle%s            Упаковать цель в автономный переносимый бинарник (nix bundle)
                                grime nix --bundle [цель] [-o вывод]
    %sdiff, -d, --diff%s            Анализ изменений замыканий профиля (diff-closures)
                                grime nix --diff
    %sinstall, -i, --install%s      Установить пакеты в профиль Nix (nix profile add; unfree разрешены)
                                grime nix --install <пакеты...>
    %suninstall, --uninstall%s      Удалить пакеты из профиля пользователя Nix
                                grime nix --uninstall <пакеты...>
    %sgc, --gc, --clean%s           Очистить неиспользуемые пути в Nix store (garbage collector)
                                grime nix --gc [-y]   (в неинтерактивном режиме обязателен --yes)
    %soptimise, --optimise%s        Дедупликация жестких ссылок в Nix store
                                grime nix --optimise
    %scheck, -c, --check%s          Проверить валидность конфигурации flake.nix
                                grime nix --check
    %shelp, -h, --help%s            Показать эту справку

%sДОПОЛНИТЕЛЬНЫЕ ФЛАГИ:%s
    %s--force, -f%s                 Перезаписать существующий файл flake.nix
    %s--pure, -pure%s               Изолированный запуск без переменных хоста
    %s--to, -to <N>%s               Целевое поколение для отката (rollback)
    %s-o, --out-link <путь>%s       Путь для сохранения бандла (bundle)

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime nix --init : nix --build          # Генерация flake.nix и сборка
    grime nix -run cargo test               # Запуск тестов внутри Flake devShell
    grime nix -history                      # Просмотр истории поколений профиля
    grime nix -rollback --to 3              # Откат профиля на указанную версию
    grime nix -update                       # Обновление зависимостей flake.lock
    grime nix -bundle nixpkgs#hello         # Упаковка в автономный переносимый бинарник
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

local function main()
    local raw_args = ctx.args or {}
    if #raw_args == 0 then
        print_help()
        return
    end

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

    local raw_target = ctx.target_dir
    if not raw_target or #raw_target == 0 or not ctx.is_dir(raw_target) then
        raw_target = "."
    end
    local target_dir = ctx.normalize_path(raw_target)
    local parsed = ctx.parse_args({
        actions = ACTIONS,
        default_action = "init",
        flags = {
            force = { "-f", "--force", "-force" },
            pure = { "--pure", "-pure" },
            flake = { "--flake", "-flake" },
            gpu = { "--gpu", "--gl", "-gpu", "-gl" },
            nv = { "--nv", "--prime", "--nvidia", "-nv", "-prime", "-nvidia" },
            help = { "-h", "--help", "-help" },
            yes = { "-y", "--yes", "-yes" },
        },
        value_flags = {
            to = { "--to", "-to" },
            out_link = { "-o", "--out-link", "-out-link" },
        },
        detect_dir = true,
    })
    local action = parsed.action or "init"
    -- TTL-политика кэша эфемерных flake: лёгкий sweep раз в сутки при любом вызове nix (-gc чистит всё)
    if action ~= "gc" then sweep_flakes_cache() end

    if action == "help" or parsed.flags.help then
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

    -- Голое слово `build` (так вызывает project.build_project: `grime nix build <dir>`)
    -- равнозначно -build; иначе оно попадало в пакеты flake как ложный пакет `build`
    if action == "init" and command_tokens[1] == "build" then
        table.remove(command_tokens, 1)
        action = "build"
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
        handle_gc(parsed.flags.yes)
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
        local to_gen = parsed.flags.to
        if not to_gen then
            for i, a in ipairs(command_tokens) do
                if (a == "--to" or a == "-to") and command_tokens[i + 1] then
                    to_gen = command_tokens[i + 1]
                    break
                elseif tostring(a):match("^%d+$") then
                    to_gen = a
                    break
                end
            end
        end
        handle_rollback(to_gen)
    elseif action == "update" then
        handle_update(target_dir)
    elseif action == "bundle" then
        local out_link = parsed.flags.out_link
        local clean_tokens = {}
        local skip_next = false
        for i, a in ipairs(command_tokens) do
            if skip_next then
                skip_next = false
            elseif (a == "-o" or a == "--out-link" or a == "-out-link") and command_tokens[i + 1] then
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

--- Экранирование аргумента для отображения shell-команды (безопасные символы без кавычек)
local function display_escape(arg)
    arg = tostring(arg)
    if arg ~= "" and not arg:find("[^%w%-_%./=+@]") then
        return arg
    end
    return utils.shell_escape(arg)
end

--- Хук ядра для `wraps: pipeline`: переключение конвейера в Nix DevShell.
--- nil — не переключать; { args = {...} } — аргументы nix для запуска подконвейера в devshell.
--- Переключение происходит только для `nix`, `nix -enter|-shell|-sh` без иных аргументов.
local function wrap_pipeline(args, rest_argv)
    args = args or {}
    if #args > 1 then
        return nil
    end
    if #args == 1 then
        local first = args[1]:lower():gsub("^%-+", "")
        if first ~= "enter" and first ~= "shell" and first ~= "sh" then
            return nil
        end
    end
    if type(rest_argv) ~= "table" or #rest_argv == 0 then
        return nil
    end

    -- Для отображения отбрасываем префикс `grime -p <dir> [-f]`
    local i = 1
    if rest_argv[i] == "grime" then i = i + 1 end
    if rest_argv[i] == "-p" then i = i + 2 end
    if rest_argv[i] == "-f" then i = i + 1 end
    local shown = {}
    for j = i, #rest_argv do
        local t = rest_argv[j]
        shown[#shown + 1] = (t == ":") and ":" or display_escape(t)
    end
    io.stderr:write(string.format("\27[1m\27[36m[Grime Nix]\27[0m Переключение среды в Nix DevShell -> %s\n",
        table.concat(shown, " ")))

    return utils.wrap_pipeline_run(rest_argv)
end

return {
    main = main,
    wrap_pipeline = wrap_pipeline,
    ephemeral_flake_dir = ephemeral_flake_dir,
    develop_command = develop_command,
}
