local ctx = grime.ctx
local BaseAdapter = require("languages.base")
local aider = require("aider")
local box = require("box")
local git = require("git")
local log = require("log")

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

local function generate_flake_nix(app_name, pkgs)
    local pkg_lines = {}
    for _, p in ipairs(pkgs) do
        table.insert(pkg_lines, "              " .. p)
    end
    return string.format([[{
  description = "Dev environment for %s";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
%s
            ];
          };
        });
    };
}
]], app_name, table.concat(pkg_lines, "\n"))
end

local function exec_cmd(m, cmd, dir, env)
    local app_dir = dir or (ctx.paths and ctx.paths.apps)
    local has_flake = app_dir and (ctx.is_file(app_dir .. "/flake.nix") or ctx.exists(app_dir .. "/flake.nix"))
    local has_shell_nix = app_dir and (ctx.is_file(app_dir .. "/shell.nix") or ctx.exists(app_dir .. "/shell.nix"))

    if has_flake then
        local cmd_str = to_cmd_str(cmd)
        local proc = { "nix", "develop", "--command", "sh", "-c", cmd_str }
        return ctx.run_process(proc, dir, env)
    elseif has_shell_nix then
        local cmd_str = to_cmd_str(cmd)
        local proc = { "nix-shell", "shell.nix", "--run", cmd_str }
        return ctx.run_process(proc, dir, env)
    elseif m.nix then
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
        if ctx.is_file(app_dir .. "/flake.nix") or ctx.exists(app_dir .. "/flake.nix") then
            cmd_str = string.format("nix develop --command sh -c %q", cmd_str)
        elseif ctx.is_file(app_dir .. "/shell.nix") or ctx.exists(app_dir .. "/shell.nix") then
            cmd_str = string.format("nix-shell shell.nix --run %q", cmd_str)
        elseif m.nix then
            local pkgs = type(m.nix) == "table" and table.concat(m.nix, " ") or tostring(m.nix)
            cmd_str = string.format("nix-shell -p %s --run %q", pkgs, cmd_str)
        elseif m.box and m.box ~= "" then
            cmd_str = string.format("distrobox enter %s -- sh -c %q", m.box, cmd_str)
        end
        local res = ctx.capture(string.format("nohup %s > %q 2>&1 & echo $!", cmd_str, log), app_dir, env)
        ctx.log(string.format("✓ Приложение запущено в фоне (PID: %s). Лог: %s", res.stdout:match("%d+") or "?", log))
        return 0
    end

    if ctx.has_next_step and not is_detach and not m.detached then
        local cmd_str = to_cmd_str(cmd_tokens)
        if ctx.is_file(app_dir .. "/flake.nix") or ctx.exists(app_dir .. "/flake.nix") then
            cmd_str = string.format("nix develop --command sh -c %q", cmd_str)
        elseif ctx.is_file(app_dir .. "/shell.nix") or ctx.exists(app_dir .. "/shell.nix") then
            cmd_str = string.format("nix-shell shell.nix --run %q", cmd_str)
        elseif m.nix then
            local pkgs = type(m.nix) == "table" and table.concat(m.nix, " ") or tostring(m.nix)
            cmd_str = string.format("nix-shell -p %s --run %q", pkgs, cmd_str)
        elseif m.box and m.box ~= "" then
            cmd_str = string.format("distrobox enter %s -- sh -c %q", m.box, cmd_str)
        end

        local run_cmd = cmd_str
        local tmp_file = nil
        local cur_payload = ctx.input or ctx.pipeline_input
        if cur_payload and cur_payload ~= "" then
            tmp_file = string.format("/tmp/.grime_chain_in_%d_%d.tmp", os.time(), math.random(10000, 99999))
            local f = io.open(tmp_file, "w")
            if f then f:write(cur_payload); f:close() end
            run_cmd = string.format("%s < %q", cmd_str, tmp_file)
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
    local p = io.popen(string.format("ls -1 %q 2>/dev/null", apps_root))
    if p then
        for item in p:lines() do
            if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then
                table.insert(installed, item)
            end
        end
        p:close()
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
        if ctx.is_file(dir .. "/flake.nix") or ctx.exists(dir .. "/flake.nix") then
            cmd_str = string.format("nix develop --command sh -c %q", cmd_str)
        elseif ctx.is_file(dir .. "/shell.nix") or ctx.exists(dir .. "/shell.nix") then
            cmd_str = string.format("nix-shell shell.nix --run %q", cmd_str)
        elseif m.nix then
            local pkgs = type(m.nix) == "table" and table.concat(m.nix, " ") or tostring(m.nix)
            cmd_str = string.format("nix-shell -p %s --run %q", pkgs, cmd_str)
        elseif m.box and m.box ~= "" then
            cmd_str = string.format("distrobox enter %s -- sh -c %q", m.box, cmd_str)
        end

        local env = { GRIME_APP_NAME = name }
        local run_cmd = cmd_str
        local tmp_file = nil
        if cur_payload and cur_payload ~= "" then
            tmp_file = string.format("/tmp/.grime_chain_in_%d_%d.tmp", os.time(), math.random(10000, 99999))
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
            if ctx.exists(app_dir .. "/flake.nix") then
                env_label = ANSI.PURPLE .. "nix:flake" .. ANSI.RESET
            elseif ctx.exists(app_dir .. "/shell.nix") then
                env_label = ANSI.PURPLE .. "nix:shell.nix" .. ANSI.RESET
            elseif m.nix then
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

    local flake_path = app_dir .. "/flake.nix"
    if not ctx.is_file(flake_path) then
        local m = load_manifest(app_dir, app_name)
        local pkgs = (m and m.nix and (type(m.nix) == "table" and m.nix or { m.nix })) or DEFAULT_NIX[lang] or { lang }
        local f = io.open(flake_path, "w")
        if f then
            f:write(generate_flake_nix(app_name, pkgs))
            f:close()
        end
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

    local out, err = git.diff(app_dir, file_param)
    if not out then
        ctx.fail(err or "Не удалось получить diff")
        return
    end

    if #grime.str.trim(out) == 0 then
        grime.ui.log(string.format("В приложении '%s' нет незафиксированных изменений.", app_name))
        ctx.success("")
    else
        print(string.format("\n%sИзменения в приложении %s%s%s:%s\n", ANSI.BOLD, ANSI.YELLOW, app_name, ANSI.BOLD, ANSI.RESET))
        print(out)
        ctx.success(out)
    end
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

local function print_help()
    print(string.format([[
%s%sGrime App%s — Управление и запуск приложений и изолированных инструментов

%sИСПОЛЬЗОВАНИЕ:%s
    grime app [команда] [аргументы...]
    grime app <имя_приложения> [аргументы...]

%sКОМАНДЫ:%s
    %slist, ls%s              Показать список установленных приложений (по умолчанию)
    %snew, create, init%s     Создать новое приложение
                         grime app new <имя> [--lang <язык>] [описание...]
    %srun, start, exec%s      Запустить приложение (с автосборкой)
                         grime app run <имя> [аргументы...]
                         grime app <имя> [аргументы...]
    %sbuild%s                 Собрать приложение
                         grime app build <имя>
    %scommit%s                Зафиксировать изменения приложения в Git
                         grime app commit <имя> [сообщение]
    %slog%s                   История изменений приложения
                         grime app log <имя> [n]
    %sdiff%s                  Незафиксированные изменения приложения
                         grime app diff <имя> [файл]
    %sstatus%s                Статус репозитория приложения
                         grime app status <имя>
    %srm, remove, delete%s    Удалить приложение
                         grime app rm <имя>
    %shelp, -h, --help%s      Показать эту справку

%sФЛАГИ:%s
    %s-d, --detach%s          Запуск приложения в фоновом режиме (демонизация, лог в app.log)
    %s-l, --lang%s            Язык/стек проекта при создании (cpp, rust, python, java, lua)

%sЦЕПОЧКИ ПРИЛОЖЕНИЙ (App Chaining):%s
    grime app App1 -> App2 -> App3
    grime app run Producer -> Consumer

%sПРИМЕРЫ:%s
    grime app new MyTool --lang rust "CLI утилита для обработки JSON"
    grime app run MyTool input.json
    grime app commit MyTool "fix: исправление парсера"
    grime app log MyTool 5
    grime app status MyTool
    grime app run MyServer --detach
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
    ANSI.BOLD, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.YELLOW, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

function main()
    local apps_root = get_apps_root()
    local is_detach, filtered = false, {}
    local wants_help = false
    for _, a in ipairs(ctx.args or {}) do
        local matched = (type(a) == "string" and a:match("^%-")) and grime.fuzzy.match_flag(a, { "--detach", "-d", "--help", "-h" }, 0.75) or a
        if matched == "--detach" or matched == "-d" then
            is_detach = true
        elseif matched == "--help" or matched == "-h" or a == "help" then
            wants_help = true
        else
            table.insert(filtered, a)
        end
    end

    if wants_help then
        print_help()
        return
    end

    local subcmd = filtered[1]
    if not subcmd or subcmd == "list" or subcmd == "ls" then
        list_apps(apps_root)
        print("\27[90mДля подробной справки используйте: grime app --help\27[0m\n")
        return
    elseif subcmd == "new" or subcmd == "create" or subcmd == "init" then
        new_app(apps_root, filtered)
        return
    elseif subcmd == "build" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app build <app_name>"); return end
        local app_name = resolve_app_name(apps_root, filtered[2])
        local dir = apps_root .. "/" .. app_name
        local m, err = load_manifest(dir, app_name)
        if not m then ctx.fail(err or "Манифест не найден"); return end
        build_app(app_name, m, dir)
        return
    elseif subcmd == "commit" then
        if not filtered[2] then ctx.fail("Укажите имя приложения: grime app commit <app_name> [сообщение]"); return end
        local msg_tokens = {}
        for i = 3, #filtered do table.insert(msg_tokens, filtered[i]) end
        commit_app(apps_root, filtered[2], #msg_tokens > 0 and table.concat(msg_tokens, " ") or nil)
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
        status_app(apps_root, filtered[2])
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
        local code = run_app(name, m, dir, rargs, is_detach)
        if code ~= 0 then
            ctx.fail(string.format("Приложение '%s' завершилось с кодом %d", name, code))
        else
            if not ctx.has_next_step then
                ctx.success(dir)
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
    rm_app = rm_app,
    new_app = new_app,
    commit_app = commit_app,
    log_app = log_app,
    diff_app = diff_app,
    status_app = status_app,
}
