local utils = require("languages.utils")
local BaseAdapter = require("languages.base")
local scanner = require("languages.scanner")
local aider = require("aider")
local box = require("box")
local git = require("git")
local log = require("log")

-- Модульные переменные file-scope
local ctx = grime.ctx
local ui = grime.ui
local str = grime.str
local fs = grime.fs
local HOME = os.getenv("HOME") or ""
local ANSI = utils.ANSI
local utf8_len = utils.utf8_len
local pad_utf8 = utils.pad_utf8

local function get_apps_root()
    return utils.get_apps_root(ctx)
end

if grime and not grime.call then
    grime.call = function(...)
        local args = { ... }
        local cmd = { "grime" }
        for _, a in ipairs(args) do
            if type(a) == "table" then
                for _, sub in ipairs(a) do table.insert(cmd, tostring(sub)) end
            else
                table.insert(cmd, tostring(a))
            end
        end
        return ctx.run_process(cmd)
    end
end

if grime and not grime.capture then
    grime.capture = function(...)
        local args = { ... }
        local cmd = { "grime" }
        for _, a in ipairs(args) do
            if type(a) == "table" then
                for _, sub in ipairs(a) do table.insert(cmd, tostring(sub)) end
            else
                table.insert(cmd, tostring(a))
            end
        end
        return ctx.capture(cmd)
    end
end

local DEFAULT_NIX = {
    cpp = { "cmake", "ninja", "gcc" },
    rust = { "cargo", "rustc" },
    python = { "python3" },
    java = { "jdk17", "maven" },
    lua = { "lua5_4" },
    generic = { "gcc", "bashInteractive", "coreutils" },
}

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

local function bus_set(key, val)
    if grime and grime.bus and grime.bus.set then
        pcall(grime.bus.set, key, val)
    end
    local data = load_persisted_state()
    data[key] = val
    local sfile = get_state_file()
    local f = io.open(sfile, "w")
    if f then
        f:write(grime.json.encode(data))
        f:close()
    end
end

local function bus_get(key)
    if grime and grime.bus and grime.bus.get then
        local ok, val = pcall(grime.bus.get, key)
        if ok and val ~= nil then return val end
    end
    local data = load_persisted_state()
    return data[key]
end


local function load_manifest(app_dir, app_name)
    local mpath = app_dir .. "/app.lua"
    if not ctx.is_file(mpath) then return nil, "Манифест app.lua не найден: " .. mpath end
    local chunk, err = loadfile(mpath, "t")
    if not chunk then return nil, "Ошибка синтаксиса манифеста: " .. tostring(err) end
    local ok, res = pcall(chunk)
    if not ok then return nil, "Ошибка выполнения манифеста: " .. tostring(res) end
    local m = type(res) == "table" and res or {}
    m.name = m.name or app_name
    m.description = m.description or ""
    m.type = m.type or m.lang or "generic"
    if not m.artifact and type(m.run) == "string" and not m.run:find(" ") then
        m.artifact = m.run:gsub("^%./", "")
    end
    m.run = m.run or m.artifact
    return m
end

local function check_artifact_status(app_dir, m)
    if not m.build and not m.artifact then return "ready", "Готово (скрипт)" end
    if not m.artifact or m.artifact == "" then return "no_artifact", "Артефакт не указан" end
    local apath = app_dir .. "/" .. m.artifact
    if not ctx.exists(apath) then return "not_built", "Не собран" end
    if m.sources and type(m.sources) == "table" then
        for _, s in ipairs(m.sources) do
            local spath = app_dir .. "/" .. s
            if ctx.exists(spath) and ctx.is_newer(spath, apath) then
                return "needs_rebuild", "Требует пересборки"
            end
        end
        return "built", "Собран"
    end
    local chk = ctx.exists(app_dir .. "/src") and (app_dir .. "/src") or nil
    if chk and ctx.is_newer(chk, apath) then return "needs_rebuild", "Требует пересборки" end
    return "built", "Собран"
end

local function to_cmd_str(cmd)
    if type(cmd) ~= "table" then return cmd end
    local q = {}
    for _, t in ipairs(cmd) do table.insert(q, utils.shell_escape(t)) end
    return table.concat(q, " ")
end

local function extract_nix_packages(app_dir, m)
    local scan = scanner.scan_project(app_dir, ctx)
    local all_pkgs = {}
    local seen = {}

    local function add(p)
        if type(p) == "string" and #p > 0 and not seen[p] then
            seen[p] = true
            table.insert(all_pkgs, p)
        end
    end

    -- 1. Базовый авто-тулчейн от сканера
    for _, p in ipairs(scan.toolchain or {}) do
        add(p)
    end

    -- 2. Пользовательские специальные экстра-зависимости (библиотеки)
    if m then
        local function add_list(list)
            if type(list) == "table" then
                for _, v in ipairs(list) do
                    if type(v) == "string" and #v > 0 then add(v) end
                end
            elseif type(list) == "string" then
                for s in list:gmatch("%S+") do add(s) end
            end
        end

        add_list(m.special_dependencies)
        add_list(m.dependencies)
        add_list(m.extra_packages)
        if type(m.nix) == "table" then
            add_list(m.nix.special_dependencies)
            add_list(m.nix.dependencies)
            add_list(m.nix.packages)
        elseif type(m.nix) == "string" then
            add_list(m.nix)
        end
    end

    return utils.split_packages(all_pkgs, scanner)
end


local function ensure_flake(app_dir, m, app_name)
    if not app_dir or not ctx.exists(app_dir) then return false end
    local flake_path = app_dir .. "/flake.nix"
    if ctx.is_file(flake_path) or ctx.exists(flake_path) then
        return true
    end

    local name = app_name or (m and m.name) or app_dir:match("([^/]+)$") or "app"
    local native_pkgs, lib_pkgs = extract_nix_packages(app_dir, m)
    local content = utils.generate_flake_nix(name, native_pkgs, lib_pkgs)

    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
        pcall(function()
            ctx.run_process({ "git", "add", "-N", flake_path }, app_dir)
        end)
        ctx.log(string.format("⚡ [Grime Flake] Автоматически сгенерирован flake.nix для '%s' (native: %s%s)",
            name,
            table.concat(native_pkgs, ", "),
            #lib_pkgs > 0 and (", libs: " .. table.concat(lib_pkgs, ", ")) or ""
        ))
        return true
    end
    return false
end

local function get_nix_env(app_name, app_dir, extra_env)
    local xdg = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
    local socket_path = os.getenv("GRIME_SOCKET")
    if not socket_path or #socket_path == 0 then
        if ctx.exists(xdg .. "/grime.sock") then
            socket_path = xdg .. "/grime.sock"
        else
            local uid_res = ctx.capture and ctx.capture("id -u")
            local uid = uid_res and uid_res.stdout and uid_res.stdout:match("%d+") or "1000"
            if ctx.exists("/run/user/" .. uid .. "/grime.sock") then
                socket_path = "/run/user/" .. uid .. "/grime.sock"
            elseif ctx.exists("/tmp/grime-" .. uid .. ".sock") then
                socket_path = "/tmp/grime-" .. uid .. ".sock"
            else
                socket_path = xdg .. "/grime.sock"
            end
        end
    end

    local env = {
        GRIME_SOCKET = socket_path,
        GRIME_APP_NAME = app_name,
        GRIME_APP_DIR = app_dir,
        GRIME_STATE_BUS = ((os.getenv("HOME") or "") .. "/.config/grime/state.json"),
        XDG_RUNTIME_DIR = xdg,
        HOME = os.getenv("HOME") or "",
        USER = os.getenv("USER") or "user",
        TERM = os.getenv("TERM") or "xterm-256color",
    }
    if extra_env and type(extra_env) == "table" then
        for k, v in pairs(extra_env) do
            env[k] = tostring(v)
        end
    end
    return env
end

local function exec_cmd(m, cmd, dir, env)
    local app_dir = dir or (ctx.paths and ctx.paths.apps)
    local app_name = (m and m.name) or (app_dir and app_dir:match("([^/]+)$")) or "app"
    ensure_flake(app_dir, m, app_name)

    local nix_env = get_nix_env(app_name, app_dir, env)
    local cmd_str = to_cmd_str(cmd)
    local proc = { "nix", "develop", "--command", "sh", "-c", cmd_str }
    return ctx.run_process(proc, dir, nix_env)
end

local function build_app(app_name, m, app_dir)
    ensure_flake(app_dir, m, app_name)
    if not m.build or m.build == "" then return true end
    ctx.log(string.format("==> Сборка приложения '%s' в изолированном Nix Flake окружении...", app_name))
    local code = 0
    local env = get_nix_env(app_name, app_dir, { GRIME_APP_NAME = app_name })
    if type(m.build) == "function" then
        local ok, res = pcall(m.build, app_dir, m)
        if not ok then
            ctx.fail(string.format("Ошибка сборки приложения '%s': %s", app_name, tostring(res)))
            return false
        end
        code = (type(res) == "number") and res or (res == false and 1 or 0)
    else
        code = exec_cmd(m, m.build, app_dir, env)
    end
    if code ~= 0 then
        ctx.fail(string.format("Ошибка сборки приложения '%s' (код %d)", app_name, code))
        return false
    end
    if m.artifact and m.artifact ~= "" and not ctx.exists(app_dir .. "/" .. m.artifact) then
        ctx.fail(string.format("Сборка завершилась, но артефакт '%s' не найден!", m.artifact))
        return false
    end
    bus_set("app." .. app_name .. ".build_status", "ready")
    if m.artifact and m.artifact ~= "" then
        bus_set("app." .. app_name .. ".artifact", m.artifact)
        local apath = app_dir .. "/" .. m.artifact
        if ctx.exists(apath) then
            local stat_res = ctx.capture({ "stat", "-c", "%s", apath })
            if stat_res.code == 0 then
                local size = tonumber(grime.str.trim(stat_res.stdout))
                bus_set("app." .. app_name .. ".artifact_size", size)
            end
        end
    end
    bus_set("app." .. app_name .. ".last_built_time", os.date("%Y-%m-%d %H:%M:%S"))
    ctx.log(string.format("✓ Приложение '%s' успешно собрано.", app_name))
    return true
end

local function resolve_cmd_tokens(m, run_args)
    local target = m.run or m.artifact
    local tokens = {}
    if type(target) == "table" then
        for _, c in ipairs(target) do table.insert(tokens, c) end
    else
        if not target:find(" ") and not target:find("^/") and not target:find("^%.") then
            table.insert(tokens, "./" .. target)
        else
            for w in target:gmatch("%S+") do table.insert(tokens, w) end
        end
    end
    for _, a in ipairs(run_args) do table.insert(tokens, a) end
    return tokens
end

local function run_app(app_name, m, app_dir, run_args, is_detach)
    ensure_flake(app_dir, m, app_name)
    if m.build and m.build ~= "" then
        local st = check_artifact_status(app_dir, m)
        if st == "not_built" or st == "needs_rebuild" then
            ctx.log("Артефакт приложения отсутствует или устарел. Запуск автоматической сборки в Nix Flake...")
            if not build_app(app_name, m, app_dir) then return 1 end
        end
    end

    if type(m.run) == "function" then
        local ok, res = pcall(m.run, app_dir, run_args, is_detach, m)
        if not ok then
            ctx.fail(string.format("Ошибка выполнения приложения '%s': %s", app_name, tostring(res)))
            return 1
        end
        return (type(res) == "number") and res or (res == false and 1 or 0)
    end

    local env = get_nix_env(app_name, app_dir)
    local cmd_tokens = resolve_cmd_tokens(m, run_args)
    local raw_cmd_str = to_cmd_str(cmd_tokens)
    local nix_cmd_str = string.format("nix develop --command sh -c %s", utils.shell_escape(raw_cmd_str))

    if is_detach or m.detached then
        local log_file = app_dir .. "/app.log"
        ctx.log(string.format("Запуск '%s' в изолированном Nix Flake (фоновый режим)...", app_name))
        local res = ctx.capture(string.format("nohup setsid %s > %s 2>&1 < /dev/null & echo $!", nix_cmd_str, utils.shell_escape(log_file)), app_dir, env)
        local pid = res.stdout and res.stdout:match("%d+") or nil
        if pid then
            local pf = io.open(app_dir .. "/app.pid", "w")
            if pf then
                pf:write(pid .. "\n")
                pf:close()
            end
        end
        if grime and grime.bus and grime.bus.set then
            pcall(grime.bus.set, "app." .. app_name .. ".status", "running")
            pcall(grime.bus.set, "app." .. app_name .. ".pid", pid or "?")
        end
        ctx.log(string.format("✓ Приложение запущено в фоне (PID: %s). Лог: %s", pid or "?", log_file))
        return 0
    end

    if ctx.has_next_step and not is_detach and not m.detached then
        local run_cmd = nix_cmd_str
        local tmp_file = nil
        local cur_payload = ctx.input or ctx.pipeline_input
        if cur_payload and cur_payload ~= "" then
            tmp_file = string.format("/tmp/.grime_chain_in_%d_%d.tmp", os.time(), math.random(10000, 99999))
            local f = io.open(tmp_file, "w")
            if f then f:write(cur_payload); f:close() end
            run_cmd = string.format("%s < %s", nix_cmd_str, utils.shell_escape(tmp_file))
        end

        local res = ctx.capture(run_cmd, app_dir, env)
        if tmp_file then ctx.delete(tmp_file, true) end

        if res.code ~= 0 then
            return res.code
        end

        local out = res.stdout or ""
        ctx.success(out)
        return 0
    end

    return exec_cmd(m, cmd_tokens, app_dir, env)
end

local function resolve_app_name(apps_root, raw_name)
    if not raw_name or raw_name == "" then return raw_name end
    local exact_dir = apps_root .. "/" .. raw_name
    if ctx.exists(exact_dir) then
        return raw_name
    end

    local installed = {}
    local entries = (grime.fs and grime.fs.list and grime.fs.list(apps_root)) or {}
    for _, item in ipairs(entries) do
        if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then
            table.insert(installed, item)
        end
    end

    local best = grime.fuzzy.find_best_match(raw_name, installed, 0.75)
    if best then
        ctx.log(string.format("Приложение '%s' не найдено, выбрано похожее: '%s'", raw_name, best))
        return best
    end

    return raw_name
end

--- Выполнение цепочки приложений через разделитель '->' (App Chaining)
local function run_chain(apps_root, segments)
    local cur_payload = ctx.input or ctx.pipeline_input or ""
    local last_output = cur_payload

    for idx, seg in ipairs(segments) do
        local name = resolve_app_name(apps_root, seg[1])
        local dir = apps_root .. "/" .. name
        if not ctx.exists(dir) then
            ctx.fail(string.format("Приложение '%s' в цепочке не найдено в %s", name, apps_root))
            return 1
        end
        local m, err = load_manifest(dir, name)
        if not m then ctx.fail(err); return 1 end

        ensure_flake(dir, m, name)

        if m.build and m.build ~= "" then
            local st = check_artifact_status(dir, m)
            if st == "not_built" or st == "needs_rebuild" then
                if not build_app(name, m, dir) then return 1 end
            end
        end

        local rargs = {}
        for i = 2, #seg do table.insert(rargs, seg[i]) end
        local cmd_tokens = resolve_cmd_tokens(m, rargs)
        local raw_cmd_str = to_cmd_str(cmd_tokens)
        local nix_cmd_str = string.format("nix develop --command sh -c %s", utils.shell_escape(raw_cmd_str))

        local env = get_nix_env(name, dir)
        local run_cmd = nix_cmd_str
        local tmp_file = nil
        if cur_payload and cur_payload ~= "" then
            tmp_file = string.format("/tmp/.grime_chain_in_%d_%d.tmp", os.time(), math.random(10000, 99999))
            local f = io.open(tmp_file, "w")
            if f then f:write(cur_payload); f:close() end
            run_cmd = string.format("%s < %s", nix_cmd_str, utils.shell_escape(tmp_file))
        end

        local res = ctx.capture(run_cmd, dir, env)
        if tmp_file then ctx.delete(tmp_file, true) end

        if res.code ~= 0 then
            ctx.fail(string.format("Приложение '%s' в цепочке завершилось с кодом %d: %s", name, res.code, res.stderr or ""))
            return res.code
        end

        last_output = res.stdout or ""
        cur_payload = last_output

        if grime and grime.bus then
            grime.bus.set("app.last_output", last_output)
            grime.bus.set("app." .. name .. ".output", last_output)
        end
    end

    ctx.module_return(last_output)
    return 0
end

local function list_apps(apps_root)
    local dirs = {}
    local entries = (grime.fs and grime.fs.list and grime.fs.list(apps_root)) or {}
    for _, item in ipairs(entries) do
        if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then
            table.insert(dirs, item)
        end
    end
    table.sort(dirs)
    if #dirs == 0 then
        print(string.format("В каталоге %s нет установленных приложений.\nИспользуйте 'grime app new <имя>' для создания.", apps_root))
        return
    end

    if ctx.has_next_step then
        ctx.success(table.concat(dirs, "\n"))
        return
    end

    print(string.format("\n%sУстановленные приложения Grime (%s):%s\n", ANSI.BOLD, apps_root, ANSI.RESET))
    local fmt = "%-18s %-10s %-24s %-24s %s"
    print(string.format(ANSI.BOLD .. fmt .. ANSI.RESET, "Имя", "Тип", "Окружение", "Статус", "Описание"))
    print(string.rep("─", 90))

    for _, name in ipairs(dirs) do
        local app_dir = apps_root .. "/" .. name
        local m, err = load_manifest(app_dir, name)
        if not m then
            print(string.format(fmt, name, "unknown", ANSI.PURPLE .. "nix:flake" .. ANSI.RESET, ANSI.RED .. "Поврежден манифест" .. ANSI.RESET, err or ""))
        else
            ensure_flake(app_dir, m, name)
            local sc, slabel = check_artifact_status(app_dir, m)
            local st_col = (sc == "built" or sc == "ready") and (ANSI.GREEN .. slabel .. ANSI.RESET)
                or (sc == "needs_rebuild" and (ANSI.YELLOW .. slabel .. ANSI.RESET) or (ANSI.RED .. slabel .. ANSI.RESET))
            local env_label = ANSI.PURPLE .. "nix:flake" .. ANSI.RESET
            local desc = (m.description or ""):gsub("\n", " ")
            local len = 0
            local cut_idx = nil
            pcall(function()
                for p, _ in utf8.codes(desc) do
                    len = len + 1
                    if len > 32 then cut_idx = p - 1; break end
                end
            end)
            if cut_idx then desc = desc:sub(1, cut_idx) .. "..." end
            print(string.format("%-18s %-19s %-33s %-33s %s", name, ANSI.BLUE .. (m.type or "generic") .. ANSI.RESET, env_label, st_col, desc))
        end
    end
    print()
end

local function rm_app(apps_root, app_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root)); return end
    if ctx.delete(app_dir, true) then ctx.log(string.format("✓ Приложение '%s' успешно удалено.", app_name))
    else ctx.fail(string.format("Не удалось удалить директорию: %s", app_dir)) end
end

local function new_app(apps_root, args)
    local explicit_lang, app_name, prompt_tokens, i = nil, nil, {}, 2
    while i <= #args do
        local a = args[i]
        if (a == "--lang" or a == "-l") and i + 1 <= #args and not args[i + 1]:match("^%-") then
            i = i + 1; explicit_lang = args[i]:lower()
        elseif not a:match("^%-") then
            if not app_name then app_name = a else table.insert(prompt_tokens, a) end
        end
        i = i + 1
    end
    if not app_name or app_name == "" then ctx.fail("Использование: grime app new <app_name> [--lang <lang>] [описание...]"); return end

    local user_prompt = table.concat(prompt_tokens, " ")
    local app_dir = apps_root .. "/" .. app_name
    local lang = explicit_lang or (user_prompt ~= "" and aider.classify_stack(user_prompt)) or "cpp"
    ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, lang))

    ctx.mkdir_p(app_dir)
    BaseAdapter.new({ name = lang }):apply_template(app_dir, ctx, user_prompt ~= "" and user_prompt or ("Grime application " .. app_name))

    local mpath = app_dir .. "/app.lua"
    if not ctx.is_file(mpath) then
        local f = io.open(mpath, "w")
        if f then
            f:write(utils.generate_app_manifest(app_name, lang, user_prompt))
            f:close()
        end
    end

    local flake_path = app_dir .. "/flake.nix"
    if not ctx.is_file(flake_path) then
        local m = load_manifest(app_dir, app_name)
        ensure_flake(app_dir, m, app_name)
    end

    if not ctx.exists(app_dir .. "/.git") then
        git.init(app_dir)
    end
    git.commit(app_dir, "init: flake scaffold", true)
    log.info(string.format("Создано приложение '%s' с инициализацией Git и flake scaffold", app_name), "app")

    aider.run_dev(app_dir, user_prompt, app_name)
    ctx.log(string.format("✓ Приложение '%s' создано в %s\nДля запуска выполните: grime app %s", app_name, app_dir, app_name))
end

local function commit_app(apps_root, raw_name, msg_param)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app commit <app_name> [сообщение]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local msg = msg_param
    if not msg or #msg == 0 then
        msg = ctx.input or ctx.pipeline_input
    end
    if not msg or #msg == 0 then
        msg = "update: " .. app_name .. " source and configuration"
    end

    local res, err = git.commit(app_dir, msg, true)
    if not res then
        log.error(string.format("Ошибка коммита для приложения '%s': %s", app_name, tostring(err)), "app")
        ctx.fail(err or "Не удалось закоммитить изменения")
        return
    end

    if res.no_changes then
        grime.ui.warn(string.format("В приложении '%s' нет изменений для фиксации.", app_name))
        ctx.success(res.message)
    else
        log.info(string.format("Зафиксирован коммит [%s] для приложения '%s': %s", res.hash, app_name, msg), "app")
        grime.ui.success(string.format("Изменения приложения '%s' успешно зафиксированы [%s]: %s", app_name, res.hash, msg))
        ctx.success(res.hash)
    end
end

local function log_app(apps_root, raw_name, limit_param)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app log <app_name> [n]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local limit = tonumber(limit_param) or 10
    local commits, err = git.log(app_dir, limit)
    if not commits then
        ctx.fail(err or "Не удалось получить историю коммитов")
        return
    end

    if #commits == 0 then
        grime.ui.log(string.format("История коммитов приложения '%s' пуста.", app_name))
        ctx.success("0 commits")
        return
    end

    local rows = {}
    for _, c in ipairs(commits) do
        table.insert(rows, { c.hash, c.author, c.date, c.message })
    end

    print(string.format("\n%sИстория изменений приложения %s%s%s:%s", ANSI.BOLD, ANSI.GREEN, app_name, ANSI.BOLD, ANSI.RESET))
    grime.ui.print_table(rows, { "Хеш", "Автор", "Дата", "Сообщение" })
    print()

    if ctx.has_next_step then
        local lines = {}
        for _, c in ipairs(commits) do
            table.insert(lines, string.format("%s %s", c.hash, c.message))
        end
        ctx.success(table.concat(lines, "\n"))
    else
        ctx.success(tostring(#commits))
    end
end

local function snapshot_app(apps_root, raw_name, msg_suffix)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app snapshot <app_name> [сообщение]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    if not git.is_git_repo(app_dir) then
        git.init(app_dir)
    end

    local suffix = msg_suffix
    if not suffix or #suffix == 0 then
        suffix = ctx.input or ctx.pipeline_input
    end

    local res, err = git.snapshot(app_dir, suffix)
    if not res then
        log.error(string.format("Ошибка создания снимка для приложения '%s': %s", app_name, tostring(err)), "app")
        ctx.fail(err or "Не удалось создать снимок приложения")
        return
    end

    local ts = os.date("%Y-%m-%d %H:%M:%S")
    bus_set("app." .. app_name .. ".snapshot_time", ts)
    bus_set("app." .. app_name .. ".last_snapshot", res.hash or "HEAD")
    bus_set("app.last_snapshot_app", app_name)

    if res.no_changes then
        grime.ui.log(string.format("Приложение '%s': рабочее дерево чисто, снимок не потребовал новых коммитов (зафиксирован в StateBus: %s).", app_name, ts))
        ctx.success(res.message)
    else
        log.info(string.format("Создан Git-снимок [%s] для приложения '%s': %s", res.hash, app_name, res.message or ""), "app")
        grime.ui.success(string.format("✓ Git-снимок состояния приложения '%s' успешно создан [%s]: %s (время: %s)", app_name, res.hash, res.message or "", ts))
        ctx.success(res.hash)
    end
end

local function diff_app(apps_root, raw_name, file_param)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app diff <app_name> [файл]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    print(string.format("\n%s══════════════════════════════════════════════════════════════════════%s", ANSI.BOLD, ANSI.RESET))
    print(string.format("%s⚡ [Grime Dual Audit] Двойной аудит приложения '%s'%s", ANSI.BOLD, app_name, ANSI.RESET))
    print(string.format("%s══════════════════════════════════════════════════════════════════════%s\n", ANSI.BOLD, ANSI.RESET))

    -- 1. Аудит исходного кода (Git Diff)
    print(string.format("%s[1/2] 📝 Аудит исходного кода (Git Diff):%s", ANSI.CYAN, ANSI.RESET))
    local out, err = git.diff(app_dir, file_param or ".")
    if not out then
        print(string.format("  %s%s%s", ANSI.YELLOW, err or "Не удалось получить diff репозитория", ANSI.RESET))
    elseif #grime.str.trim(out) == 0 then
        print(string.format("  %s✓ Рабочее дерево исходного кода чисто (нет незафиксированных изменений)%s", ANSI.GREEN, ANSI.RESET))
    else
        print(string.format("\n%s%s%s", ANSI.YELLOW, out, ANSI.RESET))
    end
    print()

    -- 2. Аудит бинарного артефакта и замыканий Nix
    print(string.format("%s[2/2] 📦 Аудит артефакта и замыканий (Artifact & Nix Closures):%s", ANSI.CYAN, ANSI.RESET))
    local m, _ = load_manifest(app_dir, app_name)
    m = m or {}

    local art_path = nil
    if m.artifact and ctx.exists(app_dir .. "/" .. m.artifact) then
        art_path = app_dir .. "/" .. m.artifact
    elseif ctx.exists(app_dir .. "/dist/" .. app_name) then
        art_path = app_dir .. "/dist/" .. app_name
    elseif ctx.exists(app_dir .. "/result") then
        art_path = app_dir .. "/result"
    end

    if not art_path or not ctx.exists(art_path) then
        print(string.format("  %sПриложение '%s' ещё не собрано (артефакт отсутствует)%s", ANSI.YELLOW, app_name, ANSI.RESET))
    else
        local stat_res = ctx.capture({ "stat", "-c", "%s", art_path })
        local cur_size = stat_res.code == 0 and tonumber(grime.str.trim(stat_res.stdout)) or nil
        local prev_size = tonumber(bus_get("app." .. app_name .. ".artifact_size"))
        local size_str = cur_size and string.format("%.2f KB (%d байт)", cur_size / 1024, cur_size) or "неизвестно"

        if cur_size then
            if prev_size and prev_size > 0 then
                local delta = cur_size - prev_size
                local sign = delta > 0 and "+" or ""
                local delta_str = string.format("%s%d байт", sign, delta)
                local col = delta > 0 and ANSI.YELLOW or (delta < 0 and ANSI.GREEN or ANSI.RESET)
                print(string.format("  • Артефакт: %s", art_path))
                print(string.format("  • Текущий размер: %s", size_str))
                print(string.format("  • Предыдущий замер: %d байт (дельта: %s%s%s)", prev_size, col, delta_str, ANSI.RESET))
            else
                print(string.format("  • Артефакт: %s (%s) [базовый размер сохранён в StateBus]", art_path, size_str))
            end
            bus_set("app." .. app_name .. ".artifact_size", cur_size)
        end

        -- Анализ замыканий Nix (diff-closures)
        local has_nix = (ctx.capture({ "which", "nix" }).code == 0)
        if has_nix then
            local current_store_path = nil
            if ctx.exists(app_dir .. "/result") then
                local res_link = ctx.capture({ "readlink", "-f", app_dir .. "/result" })
                if res_link.code == 0 and #res_link.stdout > 0 then
                    current_store_path = grime.str.trim(res_link.stdout)
                end
            end

            if not current_store_path and ctx.exists(app_dir .. "/dist/" .. app_name) then
                local pi = ctx.capture({ "nix", "path-info", "-r", app_dir .. "/dist/" .. app_name })
                if pi.code == 0 and #grime.str.trim(pi.stdout) > 0 then
                    local lines = grime.str.split(grime.str.trim(pi.stdout), "\n")
                    current_store_path = lines[#lines]
                end
            end

            if not current_store_path and ctx.exists(app_dir .. "/flake.nix") then
                local eval_res = ctx.capture({ "nix", "eval", "--raw", ".#packages.x86_64-linux.default.outPath" }, app_dir)
                if eval_res.code == 0 and #eval_res.stdout > 0 then
                    current_store_path = grime.str.trim(eval_res.stdout)
                end
            end

            local prev_store_path = bus_get("app." .. app_name .. ".store_path")

            if current_store_path and #current_store_path > 0 then
                bus_set("app." .. app_name .. ".store_path", current_store_path)
            end

            if prev_store_path and current_store_path and prev_store_path ~= current_store_path then
                print(string.format("\n  %s• Анализ изменений замыканий Nix (diff-closures):%s", ANSI.BOLD, ANSI.RESET))
                print(string.format("    Было:  %s", prev_store_path))
                print(string.format("    Стало: %s", current_store_path))
                local diff_res = ctx.capture({ "nix", "store", "diff-closures", prev_store_path, current_store_path })
                if diff_res.code == 0 then
                    local dc_out = grime.str.trim(diff_res.stdout or "")
                    if #dc_out > 0 then
                        print(dc_out)
                    else
                        print(string.format("    %s✓ Замыкания Nix идентичны%s", ANSI.GREEN, ANSI.RESET))
                    end
                else
                    print(string.format("    %sОшибка запуска diff-closures: %s%s", ANSI.YELLOW, diff_res.stderr or "", ANSI.RESET))
                end
            elseif current_store_path then
                print(string.format("  • Nix Store Path: %s", current_store_path))
                print(string.format("  %s✓ Замыкания Nix стабильны (предыдущий путь совпадает с текущим)%s", ANSI.GREEN, ANSI.RESET))
            else
                local prof_diff = ctx.capture({ "nix", "profile", "diff-closures" })
                if prof_diff.code == 0 and #grime.str.trim(prof_diff.stdout or "") > 0 then
                    print(string.format("\n  %s• Разница замыканий профиля Nix:%s", ANSI.BOLD, ANSI.RESET))
                    print(prof_diff.stdout)
                else
                    print(string.format("  %s✓ В зависимостях Nix изменений не обнаружено%s", ANSI.GREEN, ANSI.RESET))
                end
            end
        else
            print(string.format("  %s(Nix недоступен в системе, проверка замыканий пропущена)%s", ANSI.YELLOW, ANSI.RESET))
        end
    end

    print()
    ctx.success(out or "")
end

local function status_app(apps_root, raw_name)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app status <app_name>")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local st, err = git.status(app_dir)
    if not st then
        ctx.fail(err or "Не удалось получить статус репозитория")
        return
    end

    print(string.format("\n%sПриложение:%s %s%s%s", ANSI.BOLD, ANSI.RESET, ANSI.GREEN, app_name, ANSI.RESET))
    print(string.format("%sПуть:%s %s", ANSI.BOLD, ANSI.RESET, app_dir))
    print(string.format("%sВетка:%s %s", ANSI.BOLD, ANSI.RESET, st.branch))

    if st.is_clean then
        grime.ui.success("Рабочее дерево приложения чисто (нет изменений)")
    else
        if #st.staged > 0 then
            print(string.format("\n%sИндексированные изменения (%d):%s", ANSI.GREEN, #st.staged, ANSI.RESET))
            for _, f in ipairs(st.staged) do print(string.format("  [%s] %s", f.flag, f.file)) end
        end
        if #st.modified > 0 then
            print(string.format("\n%sИзмененные файлы (%d):%s", ANSI.YELLOW, #st.modified, ANSI.RESET))
            for _, f in ipairs(st.modified) do print(string.format("  [%s] %s", f.flag, f.file)) end
        end
        if #st.untracked > 0 then
            print(string.format("\n%sНеотслеживаемые файлы (%d):%s", ANSI.RED, #st.untracked, ANSI.RESET))
            for _, f in ipairs(st.untracked) do print(string.format("  [?] %s", f)) end
        end
        print()
    end

    if ctx.has_next_step then
        ctx.success(string.format("%s: staged=%d, modified=%d, untracked=%d", app_name, #st.staged, #st.modified, #st.untracked))
    else
        ctx.success(st.branch)
    end
end

local function bundle_app(apps_root, raw_name)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app bundle <app_name>")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local m, err = load_manifest(app_dir, app_name)
    if not m then
        ctx.fail(err or "Манифест app.lua не найден")
        return
    end

    -- 1. Сборка артефакта, если необходимо
    if m.build and m.build ~= "" then
        local st = check_artifact_status(app_dir, m)
        if st == "not_built" or st == "needs_rebuild" then
            ctx.log(string.format("Сборка приложения '%s' перед созданием бандла...", app_name))
            if not build_app(app_name, m, app_dir) then
                return
            end
        end
    end

    local art = m.artifact or m.run
    local art_file = nil
    if art and type(art) == "string" then
        local candidate = app_dir .. "/" .. art
        if ctx.exists(candidate) then
            art_file = candidate
        elseif ctx.exists(art) then
            art_file = art
        end
    end

    local dist_dir = app_dir .. "/dist"
    ctx.mkdir_p(dist_dir)
    local out_link = dist_dir .. "/" .. app_name

    -- Безопасно удаляем существующий файл/симлинк перед созданием бандла, чтобы nix bundle не падал с ошибкой
    if ctx.exists(out_link) or ctx.is_file(out_link) then
        ctx.delete(out_link, true)
    end
    pcall(os.remove, out_link)
    pcall(os.remove, out_link .. ".standalone")

    ctx.log(string.format("⚡ [Grime App Bundle] Упаковка приложения '%s' через Nix Bundle в %s...", app_name, dist_dir))

    ensure_flake(app_dir, m, app_name)
    local app_dir_abs = ctx.normalize_path(app_dir)

    local is_polyglot = (m.type == "polyglot")
    if not is_polyglot and type(m.languages) == "table" and #m.languages > 1 then
        is_polyglot = true
    end

    local pkgs_prelude = string.format(
        'let flake = builtins.getFlake ("path:" + %q); nixpkgs = flake.inputs.nixpkgs or (builtins.getFlake "nixpkgs"); pkgs = nixpkgs.legacyPackages.${builtins.currentSystem};',
        app_dir_abs
    )

    local bundle_cmd = nil
    if is_polyglot and art_file and ctx.is_file(art_file) then
        local art_abs = ctx.normalize_path(art_file)
        local art_name = art_file:match("([^/]+)$") or "engine"

        local let_bindings = {
            pkgs_prelude,
            string.format("art = /. + %q;", art_abs),
        }
        local copy_commands = {}
        local entry_script = nil

        local scripts = {}
        if type(m.sources) == "table" then
            for _, s in ipairs(m.sources) do
                local spath = app_dir .. "/" .. s
                if ctx.exists(spath) and ctx.is_file(spath) and ctx.normalize_path(spath) ~= art_abs then
                    local sname = s:match("([^/]+)$") or s
                    table.insert(scripts, { name = sname, path = ctx.normalize_path(spath) })
                    if (sname:match("%.py$") or sname:match("%.lua$") or sname:match("%.sh$")) and not entry_script then
                        entry_script = sname
                    end
                end
            end
        end

        if #scripts == 0 then
            local entries = (grime.fs and grime.fs.list and grime.fs.list(app_dir)) or {}
            for _, fname in ipairs(entries) do
                if fname:match("%.py$") or fname:match("%.sh$") then
                    local fpath = ctx.normalize_path(app_dir .. "/" .. fname)
                    if ctx.is_file(fpath) and fpath ~= art_abs then
                        table.insert(scripts, { name = fname, path = fpath })
                        if not entry_script then
                            entry_script = fname
                        end
                    end
                end
            end
        end

        for idx, sc in ipairs(scripts) do
            local var_name = "src_" .. tostring(idx)
            table.insert(let_bindings, string.format("%s = /. + %q;", var_name, sc.path))
            table.insert(copy_commands, string.format("cp -p ${%s} $out/libexec/%s\n    chmod +x $out/libexec/%s", var_name, sc.name, sc.name))
        end

        local run_cmd_line
        if type(m.run) == "string" and m.run ~= "" and m.run ~= m.artifact then
            run_cmd_line = string.format('cd "$LIBEXEC_DIR" && %s "$@"', m.run)
        elseif entry_script then
            local runner = entry_script:match("%.py$") and "python3" or (entry_script:match("%.lua$") and "luajit" or "sh")
            run_cmd_line = string.format('if [ -f "$LIBEXEC_DIR/%s" ]; then %s "$LIBEXEC_DIR/%s" "$@"; fi', entry_script, runner, entry_script)
        else
            run_cmd_line = string.format('"$LIBEXEC_DIR/%s" "$@"', art_name)
        end

        local nix_expr = string.format([[
%s
in pkgs.stdenv.mkDerivation {
  pname = %q;
  version = "1.0.0";
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.makeWrapper ];
  buildInputs = [ pkgs.python3 pkgs.makeWrapper ];
  installPhase = ''
    mkdir -p $out/bin $out/libexec
    cp -p ${art} $out/libexec/%s
    chmod +x $out/libexec/%s
    %s

    cat << 'EOF' > $out/bin/%s
#!/usr/bin/env bash
trap 'kill 0' EXIT

LIBEXEC_DIR="$(cd "$(dirname "$0")/../libexec" 2>/dev/null && pwd)"
if [ ! -d "$LIBEXEC_DIR" ]; then
    LIBEXEC_DIR="@out@/libexec"
fi

if [ -x "$LIBEXEC_DIR/%s" ]; then
    "$LIBEXEC_DIR/%s" --server &
    sleep 0.1 2>/dev/null || true
fi

%s
EXIT_CODE=$?
exit $EXIT_CODE
EOF
    sed -i "s|@out@|$out|g" $out/bin/%s
    chmod +x $out/bin/%s
    wrapProgram $out/bin/%s --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.python3 pkgs.coreutils pkgs.bash ]}
  '';
  meta.mainProgram = %q;
}
]],
            table.concat(let_bindings, "\n  "),
            app_name,
            art_name, art_name,
            table.concat(copy_commands, "\n    "),
            app_name,
            art_name, art_name,
            run_cmd_line,
            app_name, app_name, app_name,
            app_name
        )
        bundle_cmd = { "nix", "bundle", "--expr", nix_expr, "-o", out_link, "--impure" }
    elseif art_file and ctx.is_file(art_file) then
        local art_abs = ctx.normalize_path(art_file)
        local nix_expr = string.format([[%s art = /. + %q; in pkgs.stdenv.mkDerivation { pname = %q; version = "1.0.0"; dontUnpack = true; installPhase = ''mkdir -p $out/bin; cp -p ${art} $out/bin/%s; chmod +x $out/bin/%s''; meta.mainProgram = %q; }]],
            pkgs_prelude, art_abs, app_name, app_name, app_name, app_name)
        bundle_cmd = { "nix", "bundle", "--expr", nix_expr, "-o", out_link, "--impure" }
    else
        bundle_cmd = { "nix", "bundle", ".", "-o", out_link }
    end

    local res = ctx.run_process(bundle_cmd, app_dir)
    if res ~= 0 then
        ctx.fail(string.format("Ошибка создания бандла приложения '%s' (код %d)", app_name, res))
        return
    end

    -- Разыменовываем симлинк, чтобы бинарник в dist/ стал полностью автономным файлом без зависимости от симлинка
    if ctx.exists(out_link) then
        ctx.run_process({ "cp", "-L", out_link, out_link .. ".standalone" })
        if ctx.exists(out_link .. ".standalone") then
            ctx.run_process({ "mv", "-f", out_link .. ".standalone", out_link })
            ctx.run_process({ "chmod", "+x", out_link })
        end
    end

    if ctx.exists(out_link) then
        local stat_res = ctx.capture({ "stat", "-c", "%s", out_link })
        if stat_res.code == 0 then
            local size = tonumber(grime.str.trim(stat_res.stdout))
            bus_set("app." .. app_name .. ".artifact_size", size)
            bus_set("app." .. app_name .. ".bundle_size", size)
        end
        bus_set("app." .. app_name .. ".last_bundled_time", os.date("%Y-%m-%d %H:%M:%S"))
    end

    grime.ui.success(string.format("✓ Приложение '%s' успешно упаковано в автономный бинарник: %s", app_name, out_link))
    log.info(string.format("Приложение '%s' упаковано в автономный бандл: %s", app_name, out_link), "app")
    if ctx.has_next_step then
        ctx.module_return(out_link)
    end
end

local function rollback_app(apps_root, raw_name, target_commit)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app rollback <app_name> [commit]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    if not git.is_git_repo(app_dir) then
        ctx.fail(string.format("Директория приложения '%s' не является Git-репозиторием", app_name))
        return
    end

    local target = target_commit or "HEAD~1"
    ctx.log(string.format("Откат приложения '%s' на ревизию %s...", app_name, target))
    local res = ctx.capture({ "git", "reset", "--hard", target }, app_dir)
    if res.code ~= 0 then
        ctx.fail(string.format("Ошибка отката приложения '%s': %s", app_name, res.stderr or res.stdout or ""))
        return
    end

    local cur_log = git.log(app_dir, 1)
    local log_msg = (#cur_log > 0) and string.format("[%s] %s", cur_log[1].hash, cur_log[1].message) or target
    log.info(string.format("Откат приложения '%s' на %s", app_name, log_msg), "app")
    grime.ui.success(string.format("✓ Репозиторий приложения '%s' успешно откатан на %s", app_name, log_msg))
    ctx.success(log_msg)
end

local function is_pid_alive(pid)
    if not pid or not tostring(pid):match("^%d+$") then return false end
    local res = ctx.capture(string.format("kill -0 %s 2>/dev/null && echo alive", pid))
    return (res.stdout and res.stdout:match("alive") ~= nil) or ctx.exists("/proc/" .. pid)
end

local function get_process_info(pid)
    local res = ctx.capture(string.format("ps -p %s -o etime=,rss=,comm= 2>/dev/null", pid))
    if res.code == 0 and res.stdout then
        local etime, rss, comm = res.stdout:match("^%s*(%S+)%s+(%S+)%s+(.*)$")
        if etime and rss then
            local rss_kb = tonumber(rss) or 0
            local mem_str = (rss_kb >= 1024) and string.format("%.1f MB", rss_kb / 1024) or string.format("%d KB", rss_kb)
            return {
                etime = etime,
                memory = mem_str,
                comm = comm or "",
            }
        end
    end
    return { etime = "-", memory = "-", comm = "" }
end

local function ps_apps(apps_root)
    local dirs = {}
    local entries = (grime.fs and grime.fs.list and grime.fs.list(apps_root)) or {}
    for _, item in ipairs(entries) do
        if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then
            table.insert(dirs, item)
        end
    end
    table.sort(dirs)

    local running = {}

    for _, name in ipairs(dirs) do
        local app_dir = apps_root .. "/" .. name
        local pid_file = app_dir .. "/app.pid"
        if not ctx.exists(pid_file) then
            pid_file = app_dir .. "/.app.pid"
        end
        local pid = nil
        if ctx.exists(pid_file) then
            local f = io.open(pid_file, "r")
            if f then
                pid = f:read("*l")
                f:close()
                if pid then pid = pid:match("^%s*(%d+)%s*$") end
            end
        end

        local alive = false
        if pid then
            alive = is_pid_alive(pid)
            if not alive then
                ctx.delete(pid_file, true)
                pid = nil
            end
        end

        if alive and pid then
            local pinfo = get_process_info(pid)
            local sock_file = app_dir .. "/app.sock"
            local has_sock = ctx.exists(sock_file)
            local sock_status = has_sock and "сокет активен" or "фоновый процесс"
            local bus_status = (grime and grime.bus and grime.bus.get) and grime.bus.get("app." .. name .. ".status") or nil
            table.insert(running, {
                name = name,
                pid = pid,
                etime = pinfo.etime,
                memory = pinfo.memory,
                comm = pinfo.comm,
                details = bus_status or sock_status,
                dir = app_dir,
            })
        end
    end

    if ctx.has_next_step then
        local names = {}
        for _, r in ipairs(running) do table.insert(names, r.name) end
        ctx.success(table.concat(names, "\n"))
        return
    end

    if #running == 0 then
        io.stdout:write(string.format("\n%sАктивные запущенные приложения Grime:%s\n", ANSI.BOLD, ANSI.RESET))
        io.stdout:write(string.rep("─", 80) .. "\n")
        io.stdout:write("  \27[90m(нет активных запущенных фоновых приложений)\27[0m\n")
        io.stdout:write(string.rep("─", 80) .. "\n")
        io.stdout:write(string.format("\27[90mЗапустить приложение в фоне: \27[36mgrime app run <имя> --detach\27[0m\n\n"))
        return
    end

    io.stdout:write(string.format("\n%sАктивные запущенные приложения Grime (%d):%s\n", ANSI.BOLD, #running, ANSI.RESET))
    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write(string.format("  %s%s %s %s %s %s%s\n",
        ANSI.BOLD,
        pad_utf8("ПРИЛОЖЕНИЕ", 18),
        pad_utf8("PID", 10),
        pad_utf8("ПАМЯТЬ (RSS)", 14),
        pad_utf8("ВРЕМЯ", 12),
        "СТАТУС / ИНФО",
        ANSI.RESET))
    io.stdout:write(string.rep("─", 80) .. "\n")

    for _, r in ipairs(running) do
        io.stdout:write(string.format("  \27[1;36m%s\27[0m \27[32m%s\27[0m \27[33m%s\27[0m \27[90m%s\27[0m %s\n",
            pad_utf8(r.name, 18),
            pad_utf8(r.pid, 10),
            pad_utf8(r.memory, 14),
            pad_utf8(r.etime, 12),
            r.details))
    end

    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write(string.format("\27[90mДля остановки: \27[36mgrime app stop <имя>\27[0m (или \27[36mgrime app kill <имя> -9\27[0m)\n\n"))
end

local function stop_app(apps_root, raw_name, force)
    if not raw_name or raw_name == "" then
        ctx.fail("Укажите имя приложения: grime app stop <app_name> [-9/--force]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local dir = apps_root .. "/" .. app_name
    if not ctx.exists(dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", raw_name, apps_root))
        return
    end

    local m, _ = load_manifest(dir, app_name)
    if m and type(m.stop) == "function" then
        local ok, err = pcall(m.stop, dir, m, force)
        if not ok then ctx.log("Предупреждение при выполнении m.stop: " .. tostring(err)) end
    end

    local pid_file = dir .. "/app.pid"
    if not ctx.exists(pid_file) then
        pid_file = dir .. "/.app.pid"
    end
    local pid = nil
    if ctx.exists(pid_file) then
        local f = io.open(pid_file, "r")
        if f then
            pid = f:read("*l")
            f:close()
            if pid then pid = pid:match("^%s*(%d+)%s*$") end
        end
    end

    local sig = force and "-KILL" or "-TERM"
    local stopped = false

    if pid and is_pid_alive(pid) then
        ctx.capture(string.format("pkill %s -P %s 2>/dev/null; kill %s -- -%s 2>/dev/null; kill %s %s 2>/dev/null", sig, pid, sig, pid, sig, pid))
        for _ = 1, 5 do
            if not is_pid_alive(pid) then
                stopped = true
                break
            end
            if ctx.sleep then ctx.sleep(50) else os.execute("sleep 0.05") end
        end
        if not stopped then
            ctx.capture(string.format("pkill -KILL -P %s 2>/dev/null; kill -9 -- -%s 2>/dev/null; kill -9 %s 2>/dev/null", pid, pid, pid))
            stopped = not is_pid_alive(pid)
        end
        if stopped or not is_pid_alive(pid) then
            ctx.log(string.format("✓ Фоновое приложение '%s' (PID: %s) успешно остановлено.", app_name, pid))
        else
            ctx.fail(string.format("Не удалось остановить процесс %s для '%s'. Попробуйте с флагом --force / -9.", pid, app_name))
        end
    else
        ctx.log(string.format("Приложение '%s' не было запущено.", app_name))
    end

    if ctx.exists(pid_file) then ctx.delete(pid_file, true) end
    local sock_file = dir .. "/app.sock"
    if ctx.exists(sock_file) then ctx.delete(sock_file, true) end

    if grime and grime.bus and grime.bus.set then
        grime.bus.set("app." .. app_name .. ".status", "stopped")
    end

    if ctx.has_next_step then
        ctx.success(dir)
    end
end

local function print_help()
    print(string.format([[
%s%sGrime App%s — Управление и запуск приложений и изолированных инструментов

%sИСПОЛЬЗОВАНИЕ:%s
    grime app [команда] [аргументы...]
    grime app <имя_приложения> [аргументы...]

%sКОМАНДЫ:%s
    %slist, ls%s              Показать список установленных приложений (по умолчанию)
    %sps, running%s           Показать запущенные в фоне приложения (PID, память, uptime)
                         grime app ps
    %snew, create, init%s     Создать новое приложение
                         grime app new <имя> [--lang <язык>] [описание...]
    %srun, start, exec%s      Запустить приложение (с автосборкой)
                         grime app run <имя> [аргументы...]
                         grime app <имя> [аргументы...]
    %sbuild%s                 Собрать приложение
                         grime app build <имя>
    %sstop, kill%s            Остановить запущенное приложение
                         grime app stop <имя> [-9, --force]
                         grime app kill <имя>
    %spath, -p%s              Получить абсолютный путь к приложению или корню приложений
                         grime app path
                         grime app path <имя>
                         grime app <имя> path
    %scommit%s                Зафиксировать изменения приложения в Git
                         grime app commit <имя> [сообщение]
    %slog%s                   История изменений приложения
                         grime app log <имя> [n]
    %sdiff%s                  Двойной аудит: Git-дифф исходников + аудит артефакта и замыканий Nix
                         grime app diff <имя> [файл]
    %ssnapshot%s              Создать мгновенный Git-снимок приложения с отметкой в StateBus
                         grime app snapshot <имя> [сообщение]
    %sstatus%s                Статус репозитория приложения
                         grime app status <имя>
    %sbundle%s                 Упаковать приложение в автономный переносимый бинарник в dist/
                         grime app bundle <имя>
    %srollback%s               Откатить репозиторий приложения на предыдущий коммит/снапшот
                         grime app rollback <имя> [commit]
    %srm, remove, delete%s    Удалить приложение
                         grime app rm <имя>
    %shelp, -h, --help%s      Показать эту справку

%sФЛАГИ:%s
    %s-d, --detach%s          Запуск приложения в фоновом режиме (демонизация, лог в app.log)
    %s-f, --force, -9%s       Принудительная остановка процесса (SIGKILL)
    %s-p, --path%s            Запрос чистого пути (для подстановки в cd)
    %s-l, --lang%s            Язык/стек проекта при создании (cpp, rust, python, java, lua)

%sЦЕПОЧКИ ПРИЛОЖЕНИЙ (App Chaining):%s
    grime app App1 : App2 : App3
    grime app run Producer : Consumer

%sПРИМЕРЫ НАВИГАЦИИ В FISH:%s
    cd (grime app path)                # Переход в корневой каталог приложений
    cd (grime app path polyapp)        # Переход в директорию конкретного апа
    cd (grime app polyapp path)        # Альтернативный синтаксис
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
    ANSI.CYAN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

function main()
    local apps_root = get_apps_root()
    local is_detach, force = false, false
    local wants_help = false
    local path_requested = false
    local filtered = {}
    local extra_args = {}
    local after_sep = false

    local raw_args = ctx.args or {}
    for _, a in ipairs(raw_args) do
        if not after_sep and (a == "--" or a == "//") then
            after_sep = true
        elseif after_sep then
            table.insert(extra_args, a)
        else
            local matched = (type(a) == "string" and a:match("^%-")) and grime.fuzzy.match_flag(a, { "--detach", "-d", "--help", "-h", "--path", "-p", "--force", "-f", "-9" }, 0.75) or a
            if matched == "--detach" or matched == "-d" then
                is_detach = true
            elseif matched == "--help" or matched == "-h" or a == "help" then
                wants_help = true
            elseif matched == "--path" or matched == "-p" or a == "path" then
                path_requested = true
            elseif matched == "--force" or matched == "-f" or a == "-9" then
                force = true
            else
                table.insert(filtered, a)
            end
        end
    end

    if wants_help then
        print_help()
        return
    end

    -- Обработка запроса пути:
    -- 1) grime app path -> apps_root
    -- 2) grime app path <app> -> apps_root/<app>
    -- 3) grime app <app> path -> apps_root/<app>
    -- 4) grime app -p [app] -> apps_root или apps_root/<app>
    if path_requested then
        local known_actions = {
            run = true, start = true, exec = true,
            build = true, new = true, create = true, init = true,
            commit = true, log = true, diff = true, status = true,
            snapshot = true,
            bundle = true, rollback = true, revert = true,
            test = true, rm = true, remove = true, delete = true,
            stop = true, kill = true, ps = true, running = true,
            list = true, ls = true,
        }
        local is_subcmd_action = (#filtered > 0 and known_actions[filtered[1]])
        if not is_subcmd_action then
            if #filtered == 0 then
                if ctx.set_target_dir then ctx.set_target_dir(apps_root) end
                ctx.module_return(apps_root)
                return
            else
                local app_name = resolve_app_name(apps_root, filtered[1])
                local dir = apps_root .. "/" .. app_name
                if not ctx.exists(dir) then
                    ctx.fail(string.format("Приложение '%s' не найдено в %s", filtered[1], apps_root))
                    return
                end
                if ctx.set_target_dir then ctx.set_target_dir(dir) end
                ctx.module_return(dir)
                return
            end
        end
    end

    local subcmd = filtered[1]
    if not subcmd or subcmd == "list" or subcmd == "ls" then
        list_apps(apps_root)
        print("\27[90mДля подробной справки используйте: grime app --help\27[0m\n")
        return
    elseif subcmd == "ps" or subcmd == "running" then
        ps_apps(apps_root)
        return
    elseif subcmd == "stop" or subcmd == "kill" then
        if not filtered[2] then
            ctx.fail(string.format("Укажите имя приложения: grime app %s <app_name> [-9/--force]", subcmd))
            return
        end
        stop_app(apps_root, filtered[2], force)
        return
    elseif subcmd == "new" or subcmd == "create" or subcmd == "init" then
        for _, ea in ipairs(extra_args) do table.insert(filtered, ea) end
        new_app(apps_root, filtered)
        return
    elseif subcmd == "build" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app build <app_name>"); return end
        local app_name = resolve_app_name(apps_root, filtered[2])
        local dir = apps_root .. "/" .. app_name
        local m, err = load_manifest(dir, app_name)
        if not m then ctx.fail(err or "Манифест не найден"); return end
        local ok = build_app(app_name, m, dir)
        if ok and (ctx.has_next_step or path_requested) then
            if ctx.set_target_dir then ctx.set_target_dir(dir) end
            ctx.module_return(dir)
        end
        return
    elseif subcmd == "commit" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app commit <app_name> [сообщение]"); return end
        local msg_tokens = {}
        for i = 3, #filtered do table.insert(msg_tokens, filtered[i]) end
        for _, ea in ipairs(extra_args) do table.insert(msg_tokens, ea) end
        commit_app(apps_root, filtered[2], #msg_tokens > 0 and table.concat(msg_tokens, " ") or nil)
        return
    elseif subcmd == "snapshot" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app snapshot <app_name> [сообщение]"); return end
        local msg_tokens = {}
        for i = 3, #filtered do table.insert(msg_tokens, filtered[i]) end
        for _, ea in ipairs(extra_args) do table.insert(msg_tokens, ea) end
        snapshot_app(apps_root, filtered[2], #msg_tokens > 0 and table.concat(msg_tokens, " ") or nil)
        return
    elseif subcmd == "log" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app log <app_name> [n]"); return end
        log_app(apps_root, filtered[2], filtered[3])
        return
    elseif subcmd == "diff" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app diff <app_name> [файл]"); return end
        diff_app(apps_root, filtered[2], filtered[3])
        return
    elseif subcmd == "status" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app status <app_name>"); return end
        local app_name = resolve_app_name(apps_root, filtered[2])
        local dir = apps_root .. "/" .. app_name
        local m, _ = load_manifest(dir, app_name)
        if m and type(m.status) == "function" then
            m.status(dir, m)
            return
        end
        status_app(apps_root, filtered[2])
        return
    elseif subcmd == "test" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app test <app_name>"); return end
        local app_name = resolve_app_name(apps_root, filtered[2])
        local dir = apps_root .. "/" .. app_name
        local m, err = load_manifest(dir, app_name)
        if not m then ctx.fail(err or "Манифест не найден"); return end
        if type(m.test) == "function" then
            local ok, res = pcall(m.test, dir, m)
            if not ok or res == false or (type(res) == "number" and res ~= 0) then
                ctx.fail(string.format("Тесты приложения '%s' завершились с ошибкой: %s", app_name, tostring(res)))
                return
            end
            ctx.log(string.format("✓ Все тесты приложения '%s' успешно пройдены.", app_name))
        elseif type(m.test) == "string" and m.test ~= "" then
            local code = exec_cmd(m, m.test, dir)
            if code ~= 0 then ctx.fail(string.format("Тесты завершились с кодом %d", code)); return end
            ctx.log(string.format("✓ Все тесты приложения '%s' успешно пройдены.", app_name))
        else
            ctx.log(string.format("Тесты для приложения '%s' не определены в app.lua.", app_name))
        end
        return
    elseif subcmd == "bundle" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app bundle <app_name>"); return end
        bundle_app(apps_root, filtered[2])
        return
    elseif subcmd == "rollback" or subcmd == "revert" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app rollback <app_name> [commit]"); return end
        rollback_app(apps_root, filtered[2], filtered[3])
        return
    elseif subcmd == "rm" or subcmd == "remove" or subcmd == "delete" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app rm <app_name>"); return end
        local app_name = resolve_app_name(apps_root, filtered[2])
        rm_app(apps_root, app_name)
        return
    end

    -- Обработка подкоманд запуска (run, start, exec)
    if subcmd == "run" or subcmd == "start" or subcmd == "exec" then
        table.remove(filtered, 1)
        if #filtered == 0 then
            ctx.fail(string.format("Укажите имя приложения: grime app %s <app_name> [аргументы...]", subcmd))
            return
        end
    end

    -- Проверка на цепочку приложений (App Chaining через '->')
    local segments = {}
    local cur_seg = {}
    for _, tok in ipairs(filtered) do
        if tok == "->" or tok == ":" or tok == "to" or tok == "::" then
            if #cur_seg > 0 then table.insert(segments, cur_seg); cur_seg = {} end
        else
            table.insert(cur_seg, tok)
        end
    end
    if #cur_seg > 0 then table.insert(segments, cur_seg) end
    if #segments > 0 and #extra_args > 0 then
        for _, ea in ipairs(extra_args) do
            table.insert(segments[#segments], ea)
        end
    end

    if #segments > 1 then
        local code = run_chain(apps_root, segments)
        if code ~= 0 then ctx.fail(string.format("Цепочка приложений завершилась с ошибкой (код %d)", code)) end
    else
        local name = resolve_app_name(apps_root, filtered[1])
        local dir = apps_root .. "/" .. name
        if not ctx.exists(dir) then
            ctx.fail(string.format("Приложение '%s' не найдено в %s.\nИспользуйте 'grime app new %s' для создания.", name, apps_root, name))
            return
        end
        local m, err = load_manifest(dir, name)
        if not m then ctx.fail(err); return end
        local rargs = {}
        for i = 2, #filtered do table.insert(rargs, filtered[i]) end
        for _, ea in ipairs(extra_args) do table.insert(rargs, ea) end
        local code = run_app(name, m, dir, rargs, is_detach)
        if code ~= 0 then
            ctx.fail(string.format("Приложение '%s' завершилось с кодом %d", name, code))
        else
            if ctx.has_next_step or path_requested then
                if ctx.set_target_dir then ctx.set_target_dir(dir) end
                ctx.module_return(dir)
            end
        end
    end
end

return {
    main = main,
    get_apps_root = get_apps_root,
    load_manifest = load_manifest,
    check_artifact_status = check_artifact_status,
    build_app = build_app,
    run_app = run_app,
    list_apps = list_apps,
    ps_apps = ps_apps,
    stop_app = stop_app,
    rm_app = rm_app,
    new_app = new_app,
    commit_app = commit_app,
    log_app = log_app,
    diff_app = diff_app,
    status_app = status_app,
    snapshot_app = snapshot_app,
    bundle_app = bundle_app,
    rollback_app = rollback_app,
}
