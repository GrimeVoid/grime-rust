local helper = require("helper")
local ctx = helper.ctx
local BaseAdapter = require("languages.base")
local aider = require("aider")
local box = require("box")

local DEFAULT_NIX = {
    cpp = { "cmake", "ninja", "gcc" },
    rust = { "cargo", "rustc" },
    python = { "python3" },
    java = { "jdk17", "maven" },
    lua = { "lua5_4" },
}

local ANSI = {
    BOLD = "\27[1m", RESET = "\27[0m", GREEN = "\27[32m",
    YELLOW = "\27[33m", RED = "\27[31m", CYAN = "\27[36m",
    PURPLE = "\27[35m", BLUE = "\27[34m"
}

local function get_apps_root()
    local root = (ctx.paths and ctx.paths.apps) or (ctx.get_path and ctx.get_path("apps")) or (ctx.apps_root and ctx.apps_root()) or ((os.getenv("HOME") or "") .. "/.config/grime/apps")
    root = ctx.normalize_path(root)
    if not ctx.exists(root) then ctx.mkdir_p(root) end
    return root
end

local function load_manifest(app_dir, app_name)
    local mpath = app_dir .. "/app.lua"
    if not ctx.is_file(mpath) then return nil, "Манифест app.lua не найден: " .. mpath end
    local chunk, err = loadfile(mpath)
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
    local chk = ctx.exists(app_dir .. "/src") and (app_dir .. "/src") or app_dir
    if ctx.is_newer(chk, apath) then return "needs_rebuild", "Требует пересборки" end
    return "built", "Собран"
end

local function to_cmd_str(cmd)
    if type(cmd) ~= "table" then return cmd end
    local q = {}
    for _, t in ipairs(cmd) do table.insert(q, string.format("%q", t)) end
    return table.concat(q, " ")
end

local function exec_cmd(m, cmd, dir, env)
    if m.nix then
        local pkgs = type(m.nix) == "table" and m.nix or {}
        if type(m.nix) == "string" then for p in m.nix:gmatch("%S+") do table.insert(pkgs, p) end end
        local proc = { "nix-shell" }
        for _, p in ipairs(pkgs) do table.insert(proc, "-p"); table.insert(proc, p) end
        table.insert(proc, "--run"); table.insert(proc, to_cmd_str(cmd))
        return ctx.run_process(proc, dir, env)
    elseif m.box and m.box ~= "" then
        return box.exec(m.box, cmd, dir, env)
    else
        return type(cmd) == "table" and ctx.run_process(cmd, dir, env) or ctx.run_shell(cmd, dir, env)
    end
end

local function build_app(app_name, m, app_dir)
    if not m.build or m.build == "" then return true end
    ctx.log(string.format("==> Сборка приложения '%s'...", app_name))
    local code = exec_cmd(m, m.build, app_dir, { GRIME_APP_NAME = app_name })
    if code ~= 0 then
        ctx.fail(string.format("Ошибка сборки приложения '%s' (код %d)", app_name, code))
        return false
    end
    if m.artifact and m.artifact ~= "" and not ctx.exists(app_dir .. "/" .. m.artifact) then
        ctx.fail(string.format("Сборка завершилась, но артефакт '%s' не найден!", m.artifact))
        return false
    end
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
    if m.build and m.build ~= "" then
        local st = check_artifact_status(app_dir, m)
        if st == "not_built" or st == "needs_rebuild" then
            ctx.log("Артефакт приложения отсутствует или устарел. Запуск автоматической сборки...")
            if not build_app(app_name, m, app_dir) then return 1 end
        end
    end

    local socket_path = os.getenv("GRIME_SOCKET") or (os.getenv("XDG_RUNTIME_DIR") and (os.getenv("XDG_RUNTIME_DIR") .. "/grime.sock") or "/tmp/grime.sock")
    local env = { GRIME_SOCKET = socket_path, GRIME_APP_NAME = app_name }
    local cmd_tokens = resolve_cmd_tokens(m, run_args)

    if is_detach or m.detached then
        local log = app_dir .. "/app.log"
        ctx.log(string.format("Запуск '%s' в фоновом режиме...", app_name))
        local cmd_str = to_cmd_str(cmd_tokens)
        if m.nix then
            local pkgs = type(m.nix) == "table" and table.concat(m.nix, " ") or tostring(m.nix)
            cmd_str = string.format("nix-shell -p %s --run %q", pkgs, cmd_str)
        elseif m.box and m.box ~= "" then
            cmd_str = string.format("distrobox enter %s -- sh -c %q", m.box, cmd_str)
        end
        local res = ctx.capture(string.format("nohup %s > %q 2>&1 & echo $!", cmd_str, log), app_dir, env)
        ctx.log(string.format("✓ Приложение запущено в фоне (PID: %s). Лог: %s", res.stdout:match("%d+") or "?", log))
        return 0
    end

    return exec_cmd(m, cmd_tokens, app_dir, env)
end

--- Выполнение цепочки приложений через разделитель '->' (App Chaining)
local function run_chain(apps_root, segments)
    local cur_payload = ctx.pipeline_input or ""
    local last_output = cur_payload

    for idx, seg in ipairs(segments) do
        local name = seg[1]
        local dir = apps_root .. "/" .. name
        if not ctx.exists(dir) then
            ctx.fail(string.format("Приложение '%s' в цепочке не найдено в %s", name, apps_root))
            return 1
        end
        local m, err = load_manifest(dir, name)
        if not m then ctx.fail(err); return 1 end

        if m.build and m.build ~= "" then
            local st = check_artifact_status(dir, m)
            if st == "not_built" or st == "needs_rebuild" then
                if not build_app(name, m, dir) then return 1 end
            end
        end

        local rargs = {}
        for i = 2, #seg do table.insert(rargs, seg[i]) end
        local cmd_tokens = resolve_cmd_tokens(m, rargs)
        local cmd_str = to_cmd_str(cmd_tokens)
        if m.nix then
            local pkgs = type(m.nix) == "table" and table.concat(m.nix, " ") or tostring(m.nix)
            cmd_str = string.format("nix-shell -p %s --run %q", pkgs, cmd_str)
        elseif m.box and m.box ~= "" then
            cmd_str = string.format("distrobox enter %s -- sh -c %q", m.box, cmd_str)
        end

        local env = { GRIME_APP_NAME = name }
        local run_cmd = cmd_str
        local tmp_file = nil
        if cur_payload and cur_payload ~= "" then
            tmp_file = dir .. "/.chain_in_" .. tostring(os.time()) .. ".tmp"
            local f = io.open(tmp_file, "w")
            if f then f:write(cur_payload); f:close() end
            run_cmd = string.format("%s < %q", cmd_str, tmp_file)
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
    local p = io.popen(string.format("ls -1 %q 2>/dev/null", apps_root))
    if p then
        for l in p:lines() do
            local item = l:match("^%s*(.-)%s*$")
            if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then table.insert(dirs, item) end
        end
        p:close()
    end
    table.sort(dirs)
    if #dirs == 0 then
        print(string.format("В каталоге %s нет установленных приложений.\nИспользуйте 'grime app new <имя>' для создания.", apps_root))
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
            print(string.format(fmt, name, "unknown", "host", ANSI.RED .. "Поврежден манифест" .. ANSI.RESET, err or ""))
        else
            local sc, slabel = check_artifact_status(app_dir, m)
            local st_col = (sc == "built" or sc == "ready") and (ANSI.GREEN .. slabel .. ANSI.RESET)
                or (sc == "needs_rebuild" and (ANSI.YELLOW .. slabel .. ANSI.RESET) or (ANSI.RED .. slabel .. ANSI.RESET))
            local env_label = "host"
            if m.nix then
                local pstr = type(m.nix) == "table" and table.concat(m.nix, ", ") or tostring(m.nix)
                env_label = ANSI.PURPLE .. "nix:[" .. pstr .. "]" .. ANSI.RESET
            elseif m.box and m.box ~= "" then
                env_label = ANSI.CYAN .. "box:" .. m.box .. ANSI.RESET
            end
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
        local pkgs = DEFAULT_NIX[lang] or { lang }
        local f = io.open(mpath, "w")
        if f then
            f:write(string.format('return {\n    name = %q,\n    description = %q,\n    type = %q,\n    artifact = "build/%s",\n    build = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",\n    run = "build/%s",\n    nix = { "%s" },\n    box = nil,\n    detached = false,\n}\n',
                app_name, user_prompt, lang, app_name, app_name, table.concat(pkgs, '", "')))
            f:close()
        end
    end
    if not ctx.exists(app_dir .. "/.git") then ctx.capture({ "git", "init" }, app_dir) end

    aider.run_dev(app_dir, user_prompt, app_name)
    ctx.log(string.format("✓ Приложение '%s' создано в %s\nДля запуска выполните: grime app %s", app_name, app_dir, app_name))
end

function main()
    local apps_root = get_apps_root()
    local is_detach, filtered = false, {}
    for _, a in ipairs(ctx.args or {}) do
        if a == "--detach" or a == "-d" then is_detach = true else table.insert(filtered, a) end
    end

    local subcmd = filtered[1]
    if not subcmd or subcmd == "list" or subcmd == "ls" then list_apps(apps_root)
    elseif subcmd == "new" or subcmd == "create" or subcmd == "init" then new_app(apps_root, filtered)
    elseif subcmd == "build" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app build <app_name>"); return end
        local dir = apps_root .. "/" .. filtered[2]
        local m, err = load_manifest(dir, filtered[2])
        if not m then ctx.fail(err or "Манифест не найден"); return end
        build_app(filtered[2], m, dir)
    elseif subcmd == "rm" or subcmd == "remove" or subcmd == "delete" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app rm <app_name>"); return end
        rm_app(apps_root, filtered[2])
    else
        -- Проверка на цепочку приложений (App Chaining через '->')
        local segments = {}
        local cur_seg = {}
        for _, tok in ipairs(filtered) do
            if tok == "->" then
                if #cur_seg > 0 then table.insert(segments, cur_seg); cur_seg = {} end
            else
                table.insert(cur_seg, tok)
            end
        end
        if #cur_seg > 0 then table.insert(segments, cur_seg) end

        if #segments > 1 then
            local code = run_chain(apps_root, segments)
            if code ~= 0 then ctx.fail(string.format("Цепочка приложений завершилась с ошибкой (код %d)", code)) end
        else
            local name, dir = subcmd, apps_root .. "/" .. subcmd
            if not ctx.exists(dir) then ctx.fail(string.format("Приложение '%s' не найдено в %s.\nИспользуйте 'grime app new %s' для создания.", name, apps_root, name)); return end
            local m, err = load_manifest(dir, name)
            if not m then ctx.fail(err); return end
            local rargs = {}
            for i = 2, #filtered do table.insert(rargs, filtered[i]) end
            local code = run_app(name, m, dir, rargs, is_detach)
            if code ~= 0 then ctx.fail(string.format("Приложение '%s' завершилось с кодом %d", name, code)) end
        end
    end
end
