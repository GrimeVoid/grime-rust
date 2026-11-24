-- Summary: Управление жизненным циклом локальных микроприложений (Grime Apps)
-- Description: Управление жизненным циклом локальных микроприложений (Grime Apps)
description = "Управление жизненным циклом локальных микроприложений (Grime Apps)"

local utils = require("languages.utils")
local BaseAdapter = require("languages.base")
local scanner = require("languages.scanner")
local aider = require("aider")
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

-- Защита от дублирования вызова ctx.fail в рамках одного запуска шага
local has_failed = false
local function fail_once(msg)
    if not has_failed then
        has_failed = true
        ctx.fail(msg)
    end
end

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

local LANG_ALIASES = utils.LANG_ALIASES or {
    cpp = "cpp", ["c++"] = "cpp", cxx = "cpp", c = "cpp",
    python = "python", py = "python", python3 = "python",
    rust = "rust", rs = "rust",
    java = "java", jav = "java",
    lua = "lua", luajit = "lua",
    bash = "bash", sh = "bash", shell = "bash",
    fish = "fish",
}

local ACTION_MAP = {
    -- list
    ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["--ls"] = "list",
    -- ps
    ["-ps"] = "ps", ["--ps"] = "ps", ["-running"] = "ps", ["--running"] = "ps",
    -- new
    ["-new"] = "new", ["--new"] = "new", ["-n"] = "new",
    ["-create"] = "new", ["--create"] = "new", ["-init"] = "new", ["--init"] = "new",
    -- run
    ["-run"] = "run", ["--run"] = "run", ["-r"] = "run",
    ["-start"] = "run", ["--start"] = "run", ["-exec"] = "run", ["--exec"] = "run",
    -- build
    ["-build"] = "build", ["--build"] = "build", ["-b"] = "build",
    -- compile / install
    ["-compile"] = "compile", ["--compile"] = "compile", ["-c"] = "compile",
    ["-install"] = "install", ["--install"] = "install", ["-i"] = "install",
    -- stop
    ["-stop"] = "stop", ["--stop"] = "stop", ["-kill"] = "stop", ["--kill"] = "stop",
    -- path
    ["-path"] = "path", ["--path"] = "path", ["-p"] = "path",
    -- commit
    ["-commit"] = "commit", ["--commit"] = "commit",
    -- log
    ["-log"] = "log", ["--log"] = "log",
    -- diff
    ["-diff"] = "diff", ["--diff"] = "diff",
    -- snapshot
    ["-snapshot"] = "snapshot", ["--snapshot"] = "snapshot",
    -- status
    ["-status"] = "status", ["--status"] = "status",
    -- bundle
    ["-bundle"] = "bundle", ["--bundle"] = "bundle",
    -- rollback
    ["-rollback"] = "rollback", ["--rollback"] = "rollback",
    ["-revert"] = "rollback", ["--revert"] = "rollback",
    -- test
    ["-test"] = "test", ["--test"] = "test", ["-t"] = "test",
    -- rm
    ["-rm"] = "rm", ["--rm"] = "rm", ["-remove"] = "rm", ["--remove"] = "rm",
    ["-delete"] = "rm", ["--delete"] = "rm", ["-del"] = "rm", ["--del"] = "rm",
    -- help
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
}

local SUBCMD_WORDS = {
    ["new"] = "new", ["create"] = "new", ["init"] = "new",
    ["build"] = "build",
    ["compile"] = "compile", ["install"] = "install",
    ["run"] = "run", ["start"] = "run", ["exec"] = "run",
    ["stop"] = "stop", ["kill"] = "stop",
    ["rm"] = "rm", ["remove"] = "rm", ["delete"] = "rm", ["del"] = "rm",
    ["list"] = "list", ["ls"] = "list",
    ["ps"] = "ps", ["running"] = "ps",
    ["status"] = "status",
    ["path"] = "path",
    ["diff"] = "diff",
    ["commit"] = "commit",
    ["log"] = "log",
    ["snapshot"] = "snapshot",
    ["bundle"] = "bundle",
    ["rollback"] = "rollback", ["revert"] = "rollback",
    ["help"] = "help",
    ["test"] = "test",
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

local function to_cmd_str(cmd)
    if type(cmd) ~= "table" then return cmd end
    local q = {}
    for _, t in ipairs(cmd) do table.insert(q, utils.shell_escape(t)) end
    return table.concat(q, " ")
end

local function to_rel_path(base_dir, full_path)
    if not base_dir or not full_path then return full_path end
    local norm_base = ctx.normalize_path(base_dir):gsub("/+$", "") .. "/"
    local norm_full = ctx.normalize_path(full_path)
    if norm_full:sub(1, #norm_base) == norm_base then
        return norm_full:sub(#norm_base + 1)
    end
    return full_path
end

local EXT_TO_LANG = {
    [".py"] = "python",
    [".lua"] = "lua",
    [".sh"] = "bash", [".bash"] = "bash",
    [".fish"] = "fish",
    [".rs"] = "rust",
    [".cpp"] = "cpp", [".cc"] = "cpp", [".cxx"] = "cpp", [".c"] = "cpp",
    [".java"] = "java",
    [".go"] = "go",
    [".js"] = "nodejs", [".ts"] = "nodejs",
}

local BUILD_MANIFEST_LANG = {
    ["Cargo.toml"] = "rust",
    ["CMakeLists.txt"] = "cpp",
    ["Makefile"] = "cpp",
    ["meson.build"] = "cpp",
    ["pom.xml"] = "java",
    ["build.gradle"] = "java",
    ["build.gradle.kts"] = "java",
    ["pyproject.toml"] = "python",
    ["go.mod"] = "go",
    ["build.zig"] = "zig",
}

local IGNORED_ENTRY_FILES = {
    ["app.lua"] = true,
    ["flake.nix"] = true,
    ["flake.lock"] = true,
    ["app.log"] = true,
    ["app.pid"] = true,
    ["app.sock"] = true,
    ["README.md"] = true,
    ["readme.md"] = true,
    ["grime.json"] = true,
    ["meta.json"] = true,
    ["Cargo.lock"] = true,
    [".gitignore"] = true,
    [".grime_app.json"] = true,
    [".grime_link.json"] = true,
}

--- Поиск главного файла скрипта/исходника/бинарника в директории приложения
local function find_main_entry(work_dir, app_name, explicit_entry)
    if not work_dir or not ctx.exists(work_dir) then return nil, false, nil end

    if explicit_entry and explicit_entry ~= "" then
        local rel = to_rel_path(work_dir, explicit_entry)
        if ctx.is_file(work_dir .. "/" .. rel) then
            local _, is_bin = utils.parse_script_header(work_dir .. "/" .. rel)
            return rel, is_bin, nil
        end
    end

    local priority_files = {
        "main.py", "main.lua", "main.fish", "main.sh", "main.bash",
        "main.rs", "main.cpp", "main.c", "Main.java", "main.go",
        "src/main.py", "src/main.lua", "src/main.fish", "src/main.sh", "src/main.bash",
        "src/main.rs", "src/main.cpp", "src/main.c", "src/Main.java",
    }
    if app_name and app_name ~= "" then
        for _, ext in ipairs({ ".py", ".lua", ".fish", ".sh", ".bash", ".rs", ".cpp", ".c", ".go", "" }) do
            table.insert(priority_files, app_name .. ext)
            table.insert(priority_files, "src/" .. app_name .. ext)
        end
    end

    for _, rel in ipairs(priority_files) do
        local full = work_dir .. "/" .. rel
        if ctx.is_file(full) then
            local _, is_bin = utils.parse_script_header(full)
            return rel, is_bin, nil
        end
    end

    -- Проверяем сборочные манифесты
    local found_build = nil
    for _, bname in ipairs({ "Cargo.toml", "CMakeLists.txt", "meson.build", "Makefile", "build.zig", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts", "pyproject.toml" }) do
        if ctx.is_file(work_dir .. "/" .. bname) then
            found_build = bname
            break
        end
    end

    -- Ищем исходник, скрипт или исполняемый файл в корне или src/
    local scan_dirs = { { dir = work_dir, prefix = "" } }
    if ctx.is_dir(work_dir .. "/src") then
        table.insert(scan_dirs, { dir = work_dir .. "/src", prefix = "src/" })
    end

    for _, sd in ipairs(scan_dirs) do
        local items = (grime.fs and grime.fs.list and grime.fs.list(sd.dir)) or {}
        table.sort(items)
        for _, item in ipairs(items) do
            if not item:match("^%.") and not IGNORED_ENTRY_FILES[item] and not BUILD_MANIFEST_LANG[item] then
                local full = sd.dir .. "/" .. item
                if ctx.is_file(full) then
                    local ext = item:match("(%.[%a%d_]+)$")
                    if ext and EXT_TO_LANG[ext:lower()] then
                        return sd.prefix .. item, false, found_build
                    end
                    local hdr, is_bin = utils.parse_script_header(full)
                    if is_bin or (hdr and hdr.shebang) then
                        return sd.prefix .. item, is_bin, found_build
                    end
                end
            end
        end
    end

    if found_build then
        return nil, false, found_build
    end
    return nil, false, nil
end

--- Определение, является ли директория валидным приложением GRIME (с app.lua или Zero-Manifest)
local function is_valid_app_dir(app_dir)
    if not app_dir or not ctx.is_dir(app_dir) then return false end
    if ctx.is_file(app_dir .. "/app.lua") or ctx.is_file(app_dir .. "/flake.nix") then
        return true
    end
    if utils.read_app_link_meta(app_dir) then
        return true
    end
    local entry_rel, _, found_build = find_main_entry(app_dir, app_dir:match("([^/]+)$"))
    return (entry_rel ~= nil or found_build ~= nil)
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

    -- 1. Базовый авто-тулчейн и # nix: зависимости от сканера
    for _, p in ipairs(scan.toolchain or {}) do
        add(p)
    end
    for _, p in ipairs(scan.special_dependencies or {}) do
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
    if not ctx.exists(app_dir .. "/.git") then
        pcall(function() ctx.capture({ "git", "init" }, app_dir) end)
    end
    local flake_path = app_dir .. "/flake.nix"
    if ctx.is_file(flake_path) or ctx.exists(flake_path) then
        local current_flake = nil
        local f = io.open(flake_path, "r")
        if f then
            current_flake = f:read("*a")
            f:close()
        end
        local missing_in_flake = false
        if current_flake and m and m.special_dependencies then
            local deps = type(m.special_dependencies) == "table" and m.special_dependencies or {}
            for _, d in ipairs(deps) do
                local clean = d:gsub("^pkgs%.", "")
                if clean ~= "" and not current_flake:find(clean, 1, true) then
                    missing_in_flake = true
                    break
                end
            end
        end
        if not missing_in_flake then
            pcall(function() ctx.capture({ "git", "add", "-N", "flake.nix" }, app_dir) end)
            return true
        end
        ctx.log(string.format("⚡ [Grime Flake] Обнаружены новые зависимости '%s', синхронизация flake.nix...", app_name or (m and m.name) or "app"))
    end

    local name = app_name or (m and m.name) or app_dir:match("([^/]+)$") or "app"
    local native_pkgs, lib_pkgs = extract_nix_packages(app_dir, m)
    local content = utils.generate_flake_nix(name, native_pkgs, lib_pkgs)

    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
        pcall(function()
            ctx.capture({ "git", "add", "-N", "flake.nix" }, app_dir)
        end)
        ctx.log(string.format("⚡ [Grime Flake] Синхронизирован flake.nix для '%s' (native: %s%s)",
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

--- Получение эфемерного Flake для сборки внешних проектов без засорения их репозитория
local function get_ephemeral_compile_flake(work_dir, m)
    local native_pkgs, lib_pkgs = extract_nix_packages(work_dir, m)
    local sig = work_dir .. "|" .. table.concat(native_pkgs, ",") .. "|" .. table.concat(lib_pkgs, ",")
    local h = 5381
    for i = 1, #sig do
        h = ((h * 33) + sig:byte(i)) % 4294967296
    end
    local cache_dir = HOME .. "/.cache/grime/compile_flakes/" .. string.format("%08x", h)
    ctx.mkdir_p(cache_dir)
    local flake_path = cache_dir .. "/flake.nix"
    local name = (m and m.name) or work_dir:match("([^/]+)$") or "app"
    local content = utils.generate_flake_nix(name, native_pkgs, lib_pkgs)
    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
    end
    return cache_dir
end

local function exec_cmd(m, cmd, dir, env, flake_dir_override)
    local app_dir = dir or (ctx.paths and ctx.paths.apps)
    local app_name = (m and m.name) or (app_dir and app_dir:match("([^/]+)$")) or "app"
    local flake_ref = flake_dir_override
    if not flake_ref then
        ensure_flake(app_dir, m, app_name)
    end

    local nix_env = get_nix_env(app_name, app_dir, env)
    local cmd_str = to_cmd_str(cmd)
    local proc = flake_ref
        and { "nix", "develop", flake_ref, "--command", "sh", "-c", cmd_str }
        or { "nix", "develop", "--command", "sh", "-c", cmd_str }
    return ctx.run_process(proc, dir, nix_env)
end

--- Выполнение сборки через языковой адаптер с автоматическим переключением в Nix Flake при нехватке тулчейна
local function run_adapter_build(adapter, build_dir, manifest, allow_host_fast)
    local has_local_flake = ctx.is_file(build_dir .. "/flake.nix")
    local deps_ok = true
    if adapter.check_dependencies then
        deps_ok = adapter:check_dependencies(ctx, build_dir)
    end
    local has_spec_deps = manifest and manifest.special_dependencies and #manifest.special_dependencies > 0

    if deps_ok and not has_spec_deps and (allow_host_fast or not has_local_flake) then
        local ok = adapter:build(build_dir, ctx)
        return ok and 0 or 1
    end

    local flake_ref = nil
    if not has_local_flake then
        local apps_root = get_apps_root()
        local norm_apps = ctx.normalize_path(apps_root) .. "/"
        local norm_dir = ctx.normalize_path(build_dir)
        if norm_dir:sub(1, #norm_apps) == norm_apps then
            ensure_flake(build_dir, manifest, manifest and manifest.name)
        else
            flake_ref = get_ephemeral_compile_flake(build_dir, manifest)
        end
    end

    local nix_ctx = setmetatable({
        run_shell = function(cmd_str, cwd)
            return exec_cmd(manifest, cmd_str, cwd or build_dir, nil, flake_ref)
        end,
        run_process = function(argv, cwd, env)
            return exec_cmd(manifest, argv, cwd or build_dir, env, flake_ref)
        end,
    }, { __index = ctx })

    local ok = adapter:build(build_dir, nix_ctx)
    return ok and 0 or 1
end

--- Поиск собранного исполняемого артефакта в проекте (включая CMake/Cargo/Meson/Zig)
local function find_compiled_binary(work_dir, app_name, m)
    if m and m._adapter and m._adapter.get_target then
        local t = m._adapter:get_target(work_dir)
        if t and ctx.is_file(t) then
            local _, is_bin = utils.parse_script_header(t)
            if is_bin or t:match("%.jar$") or t:match("%.class$") or m._is_script then
                return to_rel_path(work_dir, t)
            end
        end
    end

    if m and m.artifact and m.artifact ~= "" and ctx.is_file(work_dir .. "/" .. m.artifact) then
        return m.artifact
    end

    local search_dirs = { "target/release", "target/debug", "build", "zig-out/bin", "" }
    local preferred = {}
    if app_name and app_name ~= "" then
        preferred[app_name] = true
        preferred[app_name:lower():gsub("[%s%-]", "_")] = true
    end
    local dir_name = work_dir:match("([^/]+)$")
    if dir_name then
        preferred[dir_name] = true
        preferred[dir_name:lower():gsub("[%s%-]", "_")] = true
    end

    local fallback_bin = nil
    for _, sub in ipairs(search_dirs) do
        local sdir = (sub == "") and work_dir or (work_dir .. "/" .. sub)
        if ctx.is_dir(sdir) then
            local items = (grime.fs and grime.fs.list and grime.fs.list(sdir)) or {}
            table.sort(items)
            for _, item in ipairs(items) do
                if not item:match("^%.") and not item:match("%.o$") and not item:match("%.a$")
                    and not item:match("%.so") and not item:match("%.cmake$") and not item:match("%.txt$")
                    and not item:match("%.ninja") and not item:match("%.lock$") and not item:match("%.d$")
                then
                    local full = sdir .. "/" .. item
                    if ctx.is_file(full) then
                        local _, is_bin = utils.parse_script_header(full)
                        if is_bin or item:match("%.jar$") then
                            local rel = (sub == "") and item or (sub .. "/" .. item)
                            if preferred[item] or item:match("%.jar$") then
                                return rel
                            end
                            if not fallback_bin then
                                fallback_bin = rel
                            end
                        end
                    end
                end
            end
        end
    end

    return fallback_bin
end

local function load_manifest(app_dir, app_name, opts)
    opts = opts or {}
    local mpath = app_dir .. "/app.lua"
    if ctx.is_file(mpath) then
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

    -- Zero-Manifest режим: синтезируем манифест из мета-файла, shebang (#!) и языковых адаптеров
    local link_meta = utils.read_app_link_meta(app_dir)
    local source_dir = (link_meta and link_meta.source_dir and ctx.is_dir(link_meta.source_dir))
        and ctx.normalize_path(link_meta.source_dir) or nil
    local work_dir = source_dir or app_dir

    local entry_rel, entry_is_bin, found_build = find_main_entry(work_dir, app_name, opts.entry_file)
    local local_art_exists = link_meta and link_meta.artifact and ctx.is_file(app_dir .. "/" .. link_meta.artifact)

    if not link_meta and not entry_rel and not found_build and not ctx.is_file(app_dir .. "/flake.nix") and not local_art_exists then
        return nil, "В директории приложения отсутствуют исходники или манифест: " .. app_dir
    end

    local hdr, hdr_is_bin = nil, false
    if entry_rel and ctx.is_file(work_dir .. "/" .. entry_rel) then
        hdr, hdr_is_bin = utils.parse_script_header(work_dir .. "/" .. entry_rel)
    end

    local lang = opts.lang
        or (hdr and hdr.lang)
        or (found_build and BUILD_MANIFEST_LANG[found_build])
        or nil

    if not lang and entry_rel then
        local ext = entry_rel:match("(%.[%a%d_]+)$")
        if ext then lang = EXT_TO_LANG[ext:lower()] end
    end
    if not lang and link_meta and link_meta.lang then
        lang = link_meta.lang
    end
    if not lang then
        lang = (entry_is_bin or hdr_is_bin) and "binary" or "generic"
    end
    lang = LANG_ALIASES[lang:lower()] or lang:lower()

    local m = {
        name = app_name,
        description = "",
        type = lang,
        special_dependencies = {},
        detached = false,
        _zero_manifest = true,
        _work_dir = work_dir,
        _source_dir = source_dir,
        _link_meta = link_meta,
    }

    if hdr and hdr.shebang and entry_rel then
        -- 1. Скрипт с Shebang (#!)
        local interp = hdr.interp or ({ python = "python3", lua = "luajit", bash = "bash", fish = "fish" })[lang] or lang
        m.artifact = entry_rel
        m._is_script = true
        m.run = entry_rel:find("%s") and { interp, entry_rel } or (interp .. " " .. entry_rel)
        m.build = utils.build_syntax_check_cmd(lang, interp, entry_rel)
    elseif entry_is_bin or hdr_is_bin then
        -- 2. Готовый нативный бинарник
        m.artifact = entry_rel
        m.run = "./" .. entry_rel
        m.build = nil
    elseif lang == "python" or lang == "lua" or lang == "bash" or lang == "fish" then
        -- 3a. Скрипт без явного shebang
        local ok_adp, adapter = pcall(require, "languages." .. lang)
        if ok_adp and adapter then m._adapter = adapter end
        local default_interp = ({ python = "python3", lua = "luajit", bash = "bash", fish = "fish" })[lang] or lang
        if not entry_rel and ok_adp and adapter and adapter.get_target then
            local t = adapter:get_target(work_dir)
            if t then entry_rel = to_rel_path(work_dir, t) end
        end
        if entry_rel then
            m.artifact = entry_rel
            m._is_script = true
            m.run = entry_rel:find("%s") and { default_interp, entry_rel } or (default_interp .. " " .. entry_rel)
            m.build = utils.build_syntax_check_cmd(lang, default_interp, entry_rel)
        end
    elseif lang == "cpp" or lang == "rust" or lang == "java" then
        -- 3b. Компилируемый язык через адаптер modules/languages/<lang>.lua
        local ok_adp, adapter = pcall(require, "languages." .. lang)
        if ok_adp and adapter then
            m._adapter = adapter
            local target = adapter:get_target(work_dir)
            local rel_target = target and to_rel_path(work_dir, target) or nil

            if found_build == "meson.build" then
                m.build = "meson setup build 2>/dev/null || true; ninja -C build"
                local bin = find_compiled_binary(work_dir, app_name, m)
                m.artifact = bin
                m.run = bin and ("./" .. bin) or nil
            elseif lang == "cpp" and not ctx.exists(work_dir .. "/CMakeLists.txt") and not ctx.exists(work_dir .. "/Makefile") then
                local dir_bin = work_dir:match("([^/]+)$") or app_name or "main"
                m.artifact = (rel_target and not rel_target:match("%.c[px]*$")) and rel_target or dir_bin
                m.run = "./" .. m.artifact
            elseif lang == "rust" and not ctx.exists(work_dir .. "/Cargo.toml") then
                m.artifact = (rel_target and not rel_target:match("%.rs$")) and rel_target or "main"
                m.run = "./" .. m.artifact
            elseif lang == "rust" then
                m.artifact = (rel_target and not rel_target:match("%.rs$")) and rel_target or nil
                if m.artifact and ctx.exists(work_dir .. "/" .. m.artifact) then
                    m.run = "./" .. m.artifact
                elseif adapter.get_run_command then
                    m.run = adapter:get_run_command(work_dir)
                end
            elseif lang == "java" then
                if rel_target and rel_target:match("%.jar$") then
                    m.artifact = rel_target
                    m.run = "java -jar " .. utils.shell_escape(rel_target)
                else
                    m.artifact = rel_target
                    local rcmd = adapter.get_run_command and adapter:get_run_command(work_dir)
                    if rcmd then
                        -- Преобразуем абсолютный путь classpath к относительному для корректного запуска в work_dir
                        for idx, tok in ipairs(rcmd) do
                            rcmd[idx] = to_rel_path(work_dir, tok)
                        end
                        m.run = rcmd
                    end
                end
            else
                -- CMake / Makefile C++
                m.artifact = (rel_target and not rel_target:match("%.c[px]*$")) and rel_target or ("build/" .. (work_dir:match("([^/]+)$") or app_name or "main"))
                if not ctx.exists(work_dir .. "/" .. m.artifact) then
                    local bin = find_compiled_binary(work_dir, app_name, m)
                    if bin then m.artifact = bin end
                end
                m.run = m.artifact and ("./" .. m.artifact) or nil
            end

            if not m.build then
                m.build = function(dir, manifest)
                    return run_adapter_build(adapter, dir, manifest)
                end
            end
        end
    elseif lang == "go" then
        local bin = work_dir:match("([^/]+)$") or app_name or "app"
        m.artifact = bin
        m.build = "go build -o " .. utils.shell_escape(bin) .. " ."
        m.run = "./" .. bin
    elseif lang == "zig" then
        m.build = "zig build"
        local bin = find_compiled_binary(work_dir, app_name, m)
        m.artifact = bin
        m.run = bin and ("./" .. bin) or nil
    elseif lang == "nodejs" and entry_rel then
        m.artifact = entry_rel
        m._is_script = true
        m.run = { "node", entry_rel }
    end

    -- Мета-комментарии из заголовка скрипта/исходника
    if hdr and hdr.meta then
        if hdr.meta.description and hdr.meta.description ~= "" then
            m.description = hdr.meta.description
        end
        if hdr.meta.special_dependencies and #hdr.meta.special_dependencies > 0 then
            m.special_dependencies = hdr.meta.special_dependencies
        end
        if hdr.meta.detached ~= nil then
            m.detached = hdr.meta.detached
        end
        if hdr.meta.build then m.build = hdr.meta.build end
        if hdr.meta.run then m.run = hdr.meta.run end
        if hdr.meta.test then m.test = hdr.meta.test end
    end

    -- Метаданные из .grime_app.json / .grime_link.json (привязка от -compile)
    if link_meta then
        if m.description == "" and type(link_meta.description) == "string" then
            m.description = link_meta.description
        end
        if type(link_meta.special_dependencies) == "table" and #m.special_dependencies == 0 then
            m.special_dependencies = link_meta.special_dependencies
        end
        if local_art_exists then
            m._local_artifact = link_meta.artifact
            if not m._is_script or source_dir ~= app_dir then
                m.artifact = link_meta.artifact
                m._local_run = link_meta.run or ("./" .. link_meta.artifact)
                if not source_dir then
                    m.run = m._local_run
                end
            end
        end
        if not m.run and link_meta.run then
            m.run = link_meta.run
        end
    end

    if m.description == "" then
        m.description = string.format("Zero-Manifest приложение (%s)", m.type)
    end

    return m
end

local function check_artifact_status(app_dir, m)
    -- Если есть скомпилированный артефакт, привязанный в app_dir через -compile
    if m._local_artifact and ctx.exists(app_dir .. "/" .. m._local_artifact) then
        local apath = app_dir .. "/" .. m._local_artifact
        if m._source_dir and ctx.exists(m._source_dir) then
            local src_check = ctx.exists(m._source_dir .. "/src") and (m._source_dir .. "/src") or m._source_dir
            if ctx.is_newer(src_check, apath) then
                return "needs_rebuild", "Требует пересборки"
            end
        end
        return "built", "Собран"
    end

    local work_dir = m._work_dir or app_dir
    if not m.build and not m.artifact then return "ready", "Готово (скрипт)" end
    if not m.artifact or m.artifact == "" then return "not_built", "Не собран" end
    local apath = work_dir .. "/" .. m.artifact
    if not ctx.exists(apath) then return "not_built", "Не собран" end

    -- Если артефакт сам является интерпретируемым скриптом, он не устаревает относительно папки src/
    if m._is_script or apath:match("%.py$") or apath:match("%.lua$") or apath:match("%.sh$") or apath:match("%.bash$") or apath:match("%.fish$") then
        return "built", "Собран"
    end

    if m.sources and type(m.sources) == "table" then
        for _, s in ipairs(m.sources) do
            local spath = work_dir .. "/" .. s
            if ctx.exists(spath) and spath ~= apath and ctx.is_newer(spath, apath) then
                return "needs_rebuild", "Требует пересборки"
            end
        end
        return "built", "Собран"
    end
    local chk = ctx.exists(work_dir .. "/src") and (work_dir .. "/src") or nil
    if chk and ctx.is_newer(chk, apath) then return "needs_rebuild", "Требует пересборки" end
    return "built", "Собран"
end

local function build_app(app_name, m, app_dir)
    local build_dir = m._source_dir or app_dir
    if build_dir == app_dir then
        ensure_flake(app_dir, m, app_name)
    end
    if not m.build or m.build == "" then return true end
    ctx.log(string.format("==> Сборка приложения '%s'...", app_name))
    local code = 0
    local env = get_nix_env(app_name, build_dir, { GRIME_APP_NAME = app_name })

    -- Автокоррекция для Java-приложений со старым шаблонным pom.xml (где Main.java лежит в src/Main.java)
    if m.type == "java" and type(m.build) == "string" and m.build:find("mvn") and ctx.exists(build_dir .. "/src/Main.java") and not ctx.exists(build_dir .. "/src/main/java") then
        local out_jar = (m.artifact and m.artifact ~= "") and m.artifact or ("build/" .. app_name .. ".jar")
        local jar_dir = out_jar:match("^(.*)/[^/]+$") or "build"
        local direct_java_build = string.format(
            "mkdir -p build/classes %s && javac -encoding UTF-8 -d build/classes $(find src -name '*.java') && jar --create --file %s --main-class Main -C build/classes .",
            utils.shell_escape(jar_dir),
            utils.shell_escape(out_jar)
        )
        code = exec_cmd(m, direct_java_build, build_dir, env)
    elseif type(m.build) == "function" then
        local ok, res = pcall(m.build, build_dir, m)
        if not ok then
            fail_once(string.format("Ошибка сборки приложения '%s': %s", app_name, tostring(res)))
            return false
        end
        code = (type(res) == "number") and res or (res == false and 1 or 0)
    else
        local flake_override = nil
        if build_dir ~= app_dir and not ctx.is_file(build_dir .. "/flake.nix") then
            flake_override = get_ephemeral_compile_flake(build_dir, m)
        end
        code = exec_cmd(m, m.build, build_dir, env, flake_override)
    end

    if code ~= 0 then
        fail_once(string.format("Ошибка сборки приложения '%s' (код %d)", app_name, code))
        return false
    end

    -- После успешной сборки обновляем артефакт, если он был определен динамически
    if (not m.artifact or m.artifact == "" or not ctx.exists(build_dir .. "/" .. m.artifact)) then
        local found = find_compiled_binary(build_dir, app_name, m)
        if found then
            m.artifact = found
            if not m._is_script and (type(m.run) ~= "string" or m.run == "") then
                m.run = "./" .. found
            end
        elseif m.type == "rust" then
            local snake_cand = "target/release/" .. grime.str.to_snake_case(app_name)
            local lower_cand = "target/release/" .. app_name:lower():gsub("[%s%-]", "_")
            if ctx.exists(build_dir .. "/" .. snake_cand) then
                m.artifact = snake_cand
                if type(m.run) == "string" then m.run = snake_cand end
            elseif ctx.exists(build_dir .. "/" .. lower_cand) then
                m.artifact = lower_cand
                if type(m.run) == "string" then m.run = lower_cand end
            end
        end
    end

    if m.artifact and m.artifact ~= "" and not ctx.exists(build_dir .. "/" .. m.artifact) then
        fail_once(string.format("Сборка завершилась, но артефакт '%s' не найден!", m.artifact))
        return false
    end
    bus_set("app." .. app_name .. ".build_status", "ready")
    if m.artifact and m.artifact ~= "" then
        bus_set("app." .. app_name .. ".artifact", m.artifact)
        local apath = build_dir .. "/" .. m.artifact
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
    local exec_dir = app_dir
    if m._local_artifact and ctx.exists(app_dir .. "/" .. m._local_artifact) and not ctx.is_file(app_dir .. "/flake.nix") then
        -- Привязанный скомпилированный артефакт в apps_root/<name>/<bin> запускается напрямую
        local local_tokens = {}
        local ltarget = m._local_run or ("./" .. m._local_artifact)
        if type(ltarget) == "table" then
            for _, c in ipairs(ltarget) do table.insert(local_tokens, c) end
        else
            for w in ltarget:gmatch("%S+") do table.insert(local_tokens, w) end
        end
        for _, a in ipairs(run_args) do table.insert(local_tokens, a) end

        if is_detach or m.detached then
            local log_file = app_dir .. "/app.log"
            local cmd_str = to_cmd_str(local_tokens)
            ctx.log(string.format("Запуск '%s' в фоновом режиме...", app_name))
            local res = ctx.capture(string.format("nohup setsid %s > %s 2>&1 < /dev/null & echo $!", cmd_str, utils.shell_escape(log_file)), app_dir)
            local pid = res.stdout and res.stdout:match("%d+") or nil
            if pid then
                local pf = io.open(app_dir .. "/app.pid", "w")
                if pf then pf:write(pid .. "\n"); pf:close() end
            end
            bus_set("app." .. app_name .. ".status", "running")
            bus_set("app." .. app_name .. ".pid", pid or "?")
            ctx.log(string.format("✓ Приложение запущено в фоне (PID: %s). Лог: %s", pid or "?", log_file))
            return 0
        elseif ctx.has_next_step then
            local cmd_str = to_cmd_str(local_tokens)
            local res = ctx.capture(cmd_str, app_dir)
            if res.code ~= 0 then return res.code end
            ctx.success(res.stdout or "")
            return 0
        else
            return ctx.run_process(local_tokens, app_dir)
        end
    end

    ensure_flake(exec_dir, m, app_name)
    if m.build and m.build ~= "" then
        local st = check_artifact_status(exec_dir, m)
        if st == "not_built" or st == "needs_rebuild" then
            ctx.log("Артефакт приложения отсутствует или устарел. Запуск автоматической сборки в Nix Flake...")
            if not build_app(app_name, m, exec_dir) then return 1 end
        end
    end

    if type(m.run) == "function" then
        local ok, res = pcall(m.run, exec_dir, run_args, is_detach, m)
        if not ok then
            fail_once(string.format("Ошибка выполнения приложения '%s': %s", app_name, tostring(res)))
            return 1
        end
        return (type(res) == "number") and res or (res == false and 1 or 0)
    end

    local env = get_nix_env(app_name, exec_dir)
    local cmd_tokens = resolve_cmd_tokens(m, run_args)
    local raw_cmd_str = to_cmd_str(cmd_tokens)
    local nix_cmd_str = string.format("nix develop --command sh -c %s", utils.shell_escape(raw_cmd_str))

    if is_detach or m.detached then
        local log_file = app_dir .. "/app.log"
        ctx.log(string.format("Запуск '%s' в изолированном Nix Flake (фоновый режим)...", app_name))
        local res = ctx.capture(string.format("nohup setsid %s > %s 2>&1 < /dev/null & echo $!", nix_cmd_str, utils.shell_escape(log_file)), exec_dir, env)
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

        local res = ctx.capture(run_cmd, exec_dir, env)
        if tmp_file then ctx.delete(tmp_file, true) end

        if res.code ~= 0 then
            return res.code
        end

        local out = res.stdout or ""
        ctx.success(out)
        return 0
    end

    return exec_cmd(m, cmd_tokens, exec_dir, env)
end

--- Нечеткий и префиксный поиск приложения в apps_root по аналогии с project.lua
local function find_app_name(apps_root, raw_name)
    if not raw_name or raw_name == "" then return nil end
    if not ctx.exists(apps_root) then return nil end

    -- 1. Точное совпадение
    local exact_dir = apps_root .. "/" .. raw_name
    if is_valid_app_dir(exact_dir) then
        return raw_name
    end

    local installed = {}
    local entries = (grime.fs and grime.fs.list and grime.fs.list(apps_root)) or {}
    for _, item in ipairs(entries) do
        if item ~= "" and not item:match("^%.") and is_valid_app_dir(apps_root .. "/" .. item) then
            table.insert(installed, item)
        end
    end
    table.sort(installed)

    local q_low = raw_name:lower()

    -- 2. Точное совпадение без учета регистра
    for _, name in ipairs(installed) do
        if name:lower() == q_low then
            return name
        end
    end

    -- 3. Префиксное совпадение
    for _, name in ipairs(installed) do
        if name:lower():sub(1, #q_low) == q_low then
            return name
        end
    end

    -- 4. Подстрочное совпадение
    for _, name in ipairs(installed) do
        if name:lower():find(q_low, 1, true) then
            return name
        end
    end

    -- 5. Нечеткое сопоставление (порог 0.75)
    local best = grime.fuzzy.find_best_match(raw_name, installed, 0.75)
    if best then
        ctx.log(string.format("Приложение '%s' не найдено, выбрано похожее: '%s'", raw_name, best))
        return best
    end

    return nil
end

local function resolve_app_name(apps_root, raw_name)
    if not raw_name or raw_name == "" then return raw_name end
    return find_app_name(apps_root, raw_name) or raw_name
end

--- Выполнение цепочки приложений через разделитель '->' (App Chaining)
local function run_chain(apps_root, segments)
    local cur_payload = ctx.input or ctx.pipeline_input or ""
    local last_output = cur_payload

    for _, seg in ipairs(segments) do
        local name = resolve_app_name(apps_root, seg[1])
        local dir = apps_root .. "/" .. name
        if not ctx.exists(dir) then
            fail_once(string.format("Приложение '%s' в цепочке не найдено в %s", name, apps_root))
            return 1
        end
        local m, err = load_manifest(dir, name)
        if not m then fail_once(err); return 1 end

        if m._local_artifact and ctx.exists(dir .. "/" .. m._local_artifact) and not ctx.is_file(dir .. "/flake.nix") then
            local local_tokens = {}
            local ltarget = m._local_run or ("./" .. m._local_artifact)
            if type(ltarget) == "table" then
                for _, c in ipairs(ltarget) do table.insert(local_tokens, c) end
            else
                for w in ltarget:gmatch("%S+") do table.insert(local_tokens, w) end
            end
            for i = 2, #seg do table.insert(local_tokens, seg[i]) end
            local run_cmd = to_cmd_str(local_tokens)
            local tmp_file = nil
            if cur_payload and cur_payload ~= "" then
                tmp_file = string.format("/tmp/.grime_chain_in_%d_%d.tmp", os.time(), math.random(10000, 99999))
                local f = io.open(tmp_file, "w")
                if f then f:write(cur_payload); f:close() end
                run_cmd = string.format("%s < %s", run_cmd, utils.shell_escape(tmp_file))
            end
            local res = ctx.capture(run_cmd, dir)
            if tmp_file then ctx.delete(tmp_file, true) end
            if res.code ~= 0 then
                fail_once(string.format("Приложение '%s' в цепочке завершилось с кодом %d: %s", name, res.code, res.stderr or ""))
                return res.code
            end
            last_output = res.stdout or ""
            cur_payload = last_output
        else
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
                fail_once(string.format("Приложение '%s' в цепочке завершилось с кодом %d: %s", name, res.code, res.stderr or ""))
                return res.code
            end

            last_output = res.stdout or ""
            cur_payload = last_output
        end

        if grime and grime.bus then
            grime.bus.set("app.last_output", last_output)
            grime.bus.set("app." .. name .. ".output", last_output)
        end
    end

    ctx.module_return(last_output)
    return 0
end

local function list_apps(apps_root, return_path_requested)
    local dirs = {}
    local entries = (grime.fs and grime.fs.list and grime.fs.list(apps_root)) or {}
    for _, item in ipairs(entries) do
        if item ~= "" and not item:match("^%.") and is_valid_app_dir(apps_root .. "/" .. item) then
            table.insert(dirs, item)
        end
    end
    table.sort(dirs)
    if #dirs == 0 then
        print(string.format("В каталоге %s нет установленных приложений.\nИспользуйте 'grime app -new <имя>' для создания.", apps_root))
        return
    end

    if ctx.has_next_step or return_path_requested then
        local out_items = {}
        for _, d in ipairs(dirs) do
            table.insert(out_items, return_path_requested and (apps_root .. "/" .. d) or d)
        end
        ctx.module_return(table.concat(out_items, "\n"))
        if ctx.has_next_step then
            return
        end
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
            if not (m._local_artifact and not ctx.is_file(app_dir .. "/flake.nix")) then
                ensure_flake(app_dir, m, name)
            end
            local sc, slabel = check_artifact_status(app_dir, m)
            local st_col = (sc == "built" or sc == "ready") and (ANSI.GREEN .. slabel .. ANSI.RESET)
                or (sc == "needs_rebuild" and (ANSI.YELLOW .. slabel .. ANSI.RESET) or (ANSI.RED .. slabel .. ANSI.RESET))
            local env_label = ctx.is_file(app_dir .. "/flake.nix")
                and (ANSI.PURPLE .. "nix:flake" .. ANSI.RESET)
                or (ANSI.CYAN .. "bin:local" .. ANSI.RESET)
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
    if not ctx.exists(app_dir) then fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root)); return end

    -- Удаляем симлинк из ~/.local/bin/<app_name>, если он указывает внутрь удаляемого приложения
    local bin_link = HOME .. "/.local/bin/" .. app_name
    local rl = ctx.capture({ "readlink", "-f", bin_link })
    if rl and rl.code == 0 and rl.stdout then
        local target_real = grime.str.trim(rl.stdout)
        local norm_app_dir = ctx.normalize_path(app_dir)
        if target_real:sub(1, #norm_app_dir + 1) == (norm_app_dir .. "/") or target_real == norm_app_dir then
            pcall(os.remove, bin_link)
        end
    end

    if ctx.delete(app_dir, true) then
        local prefix = "app." .. app_name .. "."
        if grime and grime.bus and grime.bus.remove then
            for _, suffix in ipairs({ "artifact", "artifact_size", "build_status", "bundle_size", "last_built_time", "last_bundled_time", "last_snapshot", "snapshot_time", "status", "pid", "output", "source_dir", "bin_path" }) do
                pcall(grime.bus.remove, prefix .. suffix)
            end
        end
        local data = load_persisted_state()
        local changed = false
        for k, _ in pairs(data) do
            if type(k) == "string" and k:sub(1, #prefix) == prefix then
                data[k] = nil
                changed = true
            end
        end
        if changed then
            local sfile = get_state_file()
            local f = io.open(sfile, "w")
            if f then
                f:write(grime.json.encode(data))
                f:close()
            end
        end
        ctx.log(string.format("✓ Приложение '%s' успешно удалено.", app_name))
        if ctx.has_next_step then ctx.module_return(app_dir) end
    else
        fail_once(string.format("Не удалось удалить директорию: %s", app_dir))
    end
end

local function new_app(apps_root, args, explicit_lang_from_main, return_path_requested)
    local explicit_lang = explicit_lang_from_main
    local positional = {}
    local start_i = 1
    if args[1] and (args[1] == "-new" or args[1] == "--new" or args[1] == "new" or args[1] == "-n" or args[1] == "-create" or args[1] == "--create" or args[1] == "-init" or args[1] == "--init") then
        start_i = 2
    end
    local i = start_i
    while i <= #args do
        local a = args[i]
        local eq_flag, eq_val = a:match("^(%-[%w_%-]+)=(.+)$")
        if eq_flag and (eq_flag == "-l" or eq_flag == "-lang" or eq_flag == "--lang") then
            local raw_l = eq_val:lower()
            explicit_lang = LANG_ALIASES[raw_l] or raw_l
        elseif (a == "--lang" or a == "-lang" or a == "-l") and i + 1 <= #args and not args[i + 1]:match("^%-") then
            i = i + 1
            local raw_l = args[i]:lower()
            explicit_lang = LANG_ALIASES[raw_l] or raw_l
        elseif a == "-m" or a == "--message" or a == "-message" then
            -- пропускаем сам флаг -m, следующие слова пойдут в промпт
        elseif a:match("^%-%-?([%w_%-]+)$") then
            local clean_cat = a:match("^%-%-?([%w_%-]+)$"):lower()
            if LANG_ALIASES[clean_cat] then
                explicit_lang = LANG_ALIASES[clean_cat]
            end
        elseif not a:match("^%-") then
            table.insert(positional, a)
        end
        i = i + 1
    end

    -- Первый позиционный токен — ВСЕГДА имя приложения! Бездефисный перехват языка запрещен.
    local app_name = nil
    local prompt_tokens = {}
    if #positional >= 1 then
        app_name = positional[1]
        for k = 2, #positional do
            table.insert(prompt_tokens, positional[k])
        end
    end

    if not app_name or app_name == "" then
        fail_once("Использование: grime app -new <app_name> [-lang <lang>] [описание...]")
        return
    end

    local user_prompt = table.concat(prompt_tokens, " ")
    if user_prompt == "" then
        local pipe_in = ctx.pipeline_input or ctx.input
        if pipe_in and type(pipe_in) == "string" and #grime.str.trim(pipe_in) > 0 then
            user_prompt = grime.str.trim(pipe_in)
        end
    end

    -- Комплексное архитектурное проектирование стека и библиотек Nixpkgs:
    -- Язык из промпта или флага -lang имеет приоритет, но Архитектор ОБЯЗАН определить
    -- библиотеки Nixpkgs (special_dependencies) и параметры сборки/запуска
    local prompt_lang = (user_prompt ~= "" and aider.extract_lang_from_prompt) and aider.extract_lang_from_prompt(user_prompt) or nil
    local name_lang = (aider.extract_lang_from_prompt and app_name) and aider.extract_lang_from_prompt(app_name) or nil
    local explicit = prompt_lang or explicit_lang or name_lang

    local stack_plan = nil
    if aider.plan_app_stack and user_prompt ~= "" then
        stack_plan = aider.plan_app_stack(user_prompt, explicit, app_name)
    elseif aider.classify_stack and user_prompt ~= "" then
        local l, sp = aider.classify_stack(user_prompt, explicit)
        stack_plan = sp or { lang = l, special_dependencies = {} }
    else
        stack_plan = { lang = explicit or "python", special_dependencies = {} }
    end

    local lang = stack_plan.lang or explicit or "python"
    lang = LANG_ALIASES[lang:lower()] or lang:lower()
    stack_plan.lang = lang

    local app_dir = apps_root .. "/" .. app_name
    ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, lang))
    if stack_plan.special_dependencies and #stack_plan.special_dependencies > 0 then
        ctx.log(string.format("Архитектор подключил зависимости Nix: %s", table.concat(stack_plan.special_dependencies, ", ")))
    end

    if aider.scaffold_app then
        aider.scaffold_app(app_dir, app_name, lang, user_prompt, stack_plan)
    else
        -- Минималистичный fallback скаффолдинга без app.lua
        ctx.mkdir_p(app_dir)
        local ok_adp, adp = pcall(require, "languages." .. lang)
        if ok_adp and adp and adp.create_default_files then
            if lang == "rust" or lang == "cpp" or lang == "java" then
                ctx.mkdir_p(app_dir .. "/src")
            end
            adp:create_default_files(app_dir, ctx, user_prompt)
        end
    end

    local m = load_manifest(app_dir, app_name, { lang = lang })
    if m and stack_plan.special_dependencies and #stack_plan.special_dependencies > 0 then
        m.special_dependencies = stack_plan.special_dependencies
    end
    ensure_flake(app_dir, m, app_name)

    if not ctx.exists(app_dir .. "/.git") then
        git.init(app_dir)
    end
    git.commit(app_dir, "init: zero-manifest flake scaffold", true)
    log.info(string.format("Создано приложение '%s' (стек: %s) с инициализацией Git и flake scaffold", app_name, lang), "app")

    if user_prompt and user_prompt:match("%S") then
        aider.run_dev(app_dir, user_prompt, app_name, lang, stack_plan)
        -- Синхронизация метаданных и flake.nix после возможного добавления библиотек субагентом
        local updated_m = load_manifest(app_dir, app_name, { lang = lang })
        if updated_m then
            ensure_flake(app_dir, updated_m, app_name)
        end
    end
    ctx.log(string.format("✓ Приложение '%s' (%s) создано в %s\nДля запуска выполните: grime app -run %s", app_name, lang, app_dir, app_name))

    if ctx.has_next_step or return_path_requested then
        if ctx.set_target_dir then ctx.set_target_dir(app_dir) end
        ctx.module_return(app_dir)
    end
end

local function commit_app(apps_root, raw_name, msg_param)
    if not raw_name or raw_name == "" then
        fail_once("Укажите имя приложения: grime app -commit <app_name> [сообщение]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
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
        fail_once(err or "Не удалось закоммитить изменения")
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
        fail_once("Укажите имя приложения: grime app -log <app_name> [n]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local limit = tonumber(limit_param) or 10
    local commits, err = git.log(app_dir, limit)
    if not commits then
        fail_once(err or "Не удалось получить историю коммитов")
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
        fail_once("Укажите имя приложения: grime app -snapshot <app_name> [сообщение]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
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
        fail_once(err or "Не удалось создать снимок приложения")
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
        fail_once("Укажите имя приложения: grime app -diff <app_name> [файл]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
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
        fail_once("Укажите имя приложения: grime app -status <app_name>")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local st, err = git.status(app_dir)
    if not st then
        fail_once(err or "Не удалось получить статус репозитория")
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
        fail_once("Укажите имя приложения: grime app -bundle <app_name>")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local m, err = load_manifest(app_dir, app_name)
    if not m then
        fail_once(err or "Манифест app.lua не найден")
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
        fail_once(string.format("Ошибка создания бандла приложения '%s' (код %d)", app_name, res))
        return
    end

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
        fail_once("Укажите имя приложения: grime app -rollback <app_name> [commit]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    if not git.is_git_repo(app_dir) then
        fail_once(string.format("Директория приложения '%s' не является Git-репозиторием", app_name))
        return
    end

    local target = target_commit or "HEAD~1"
    ctx.log(string.format("Откат приложения '%s' на ревизию %s...", app_name, target))
    local res = ctx.capture({ "git", "reset", "--hard", target }, app_dir)
    if res.code ~= 0 then
        fail_once(string.format("Ошибка отката приложения '%s': %s", app_name, res.stderr or res.stdout or ""))
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
        io.stdout:write(string.format("\27[90mЗапустить приложение в фоне: \27[36mgrime app -run <имя> -detach\27[0m\n\n"))
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
    io.stdout:write(string.format("\27[90mДля остановки: \27[36mgrime app -stop <имя>\27[0m (или \27[36mgrime app -stop <имя> -9\27[0m)\n\n"))
end

local function stop_app(apps_root, raw_name, force)
    if not raw_name or raw_name == "" then
        fail_once("Укажите имя приложения: grime app -stop <app_name> [-9/-force]")
        return
    end
    local app_name = resolve_app_name(apps_root, raw_name)
    local dir = apps_root .. "/" .. app_name
    if not ctx.exists(dir) then
        fail_once(string.format("Приложение '%s' не найдено в %s", raw_name, apps_root))
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
            fail_once(string.format("Не удалось остановить процесс %s для '%s'. Попробуйте с флагом -force / -9.", pid, app_name))
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
%s%sGrime App%s — Управление и запуск локальных микроприложений в изоляции Nix Flake

%sИСПОЛЬЗОВАНИЕ:%s
    grime app [-команда] [аргументы...]
    grime app <имя_приложения> [-команда] [аргументы...]

%sКОМАНДЫ И ФЛАГИ ДЕЙСТВИЙ (стандарт со знаком минус):%s
    %s-list, --list, -ls%s        Показать список установленных приложений (по умолчанию)
    %s-ps, --ps, -running%s       Показать запущенные в фоне приложения (PID, память, uptime)
                              grime app -ps
    %s-new, --new, -n%s           Создать новое приложение (с автовыбором стека из промпта)
                              grime app -new <имя> [-lang <язык>] [описание...]
    %s-run, --run, -r%s           Запустить приложение (с автосборкой при необходимости)
                              grime app -run <имя> [аргументы...]
                              grime app <имя> [аргументы...]
    %s-build, --build, -b%s       Собрать приложение в изолированном Nix Flake окружении
                              grime app -build <имя>
    %s-compile, --compile, -c%s   Скомпилировать апп/папку/проект, поместить в apps и создать симлинк в ~/.local/bin
    %s-install, --install, -i%s   grime app -compile <цель|путь|проект> [имя_команды]
    %s-stop, --stop, -kill%s      Остановить запущенное фоновое приложение
                              grime app -stop <имя> [-9, -force]
    %s-path, --path, -p%s         Получить абсолютный путь к приложению или корню приложений
                              grime app -path [имя]
                              grime app <имя> -path
    %s-commit, --commit%s         Зафиксировать изменения приложения в Git
                              grime app -commit <имя> [сообщение]
    %s-log, --log%s               История коммитов приложения
                              grime app -log <имя> [n]
    %s-diff, --diff%s             Двойной аудит: Git-дифф исходников + аудит артефакта и замыканий Nix
                              grime app -diff <имя> [файл]
    %s-snapshot, --snapshot%s     Создать мгновенный Git-снимок приложения с отметкой в StateBus
                              grime app -snapshot <имя> [сообщение]
    %s-status, --status%s         Статус репозитория приложения
                              grime app -status <имя>
    %s-bundle, --bundle%s         Упаковать приложение в автономный переносимый бинарник в dist/
                              grime app -bundle <имя>
    %s-rollback, --rollback%s     Откатить репозиторий приложения на предыдущий коммит/снапшот
                              grime app -rollback <имя> [commit]
    %s-rm, --rm, -remove%s        Удалить приложение
                              grime app -rm <имя>
    %s-help, --help, -h%s         Показать эту справку

%sОПЦИОНАЛЬНЫЕ ФЛАГИ:%s
    %s-d, -detach, --detach%s     Запуск приложения в фоновом режиме (демонизация, лог в app.log)
    %s-f, -force, --force, -9%s   Принудительная остановка процесса (SIGKILL)
    %s-p, -path, --path%s         Возврат пути приложения в конвейер или для подстановки в cd
    %s-l, -lang, --lang <lang>%s  Явный выбор стека (python, java, rust, cpp, lua, bash, fish)

%sЦЕПОЧКИ ПРИЛОЖЕНИЙ (App Chaining):%s
    grime app App1 : App2 : App3
    grime app -run Producer : Consumer

%sПРИМЕРЫ НАВИГАЦИИ И КОНВЕЙЕРОВ В FISH:%s
    cd (grime app -path)               # Переход в корневой каталог приложений
    cd (grime app -path polyapp)       # Переход в директорию конкретного аппа (с fuzzy-поиском)
    grime app -path MyApp : aider -m "Оптимизируй код"
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

local SHEBANG_BY_LANG = {
    python = "#!/usr/bin/env python3",
    lua    = "#!/usr/bin/env luajit",
    bash   = "#!/usr/bin/env bash",
    fish   = "#!/usr/bin/env fish",
    nodejs = "#!/usr/bin/env node",
}

--- Гарантирует наличие shebang (#!) в первой строке скрипта
local function ensure_script_shebang(filepath, lang)
    local f = io.open(filepath, "rb")
    if not f then return false end
    local content = f:read("*a") or ""
    f:close()

    -- Пропускаем бинарные файлы
    if content:sub(1, 4) == "\127ELF" or content:sub(1, 512):find("\0", 1, true) then
        return false
    end

    -- Убираем UTF-8 BOM, если присутствует
    local bom_stripped = false
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
        bom_stripped = true
    end

    if content:sub(1, 2) == "#!" then
        if bom_stripped then
            local wf = io.open(filepath, "wb")
            if wf then wf:write(content); wf:close() end
        end
        return true
    end

    local ext = filepath:match("(%.[%a%d_]+)$")
    local inferred = (ext and EXT_TO_LANG[ext:lower()]) or lang
    local sb = SHEBANG_BY_LANG[(inferred or ""):lower()]
    if not sb then
        return false
    end

    local wf = io.open(filepath, "wb")
    if wf then
        wf:write(sb .. "\n" .. content)
        wf:close()
        ctx.log(string.format("Добавлен shebang '%s' в %s", sb, filepath))
        return true
    end
    return false
end

--- Поиск директории проекта в проектных каталогах GRIME
local function find_project_by_name(query)
    if not query or query == "" then return nil end
    local roots = {}
    local seen_r = {}
    local function add_root(r)
        if r and r ~= "" then
            local nr = ctx.normalize_path(r)
            if ctx.is_dir(nr) and not seen_r[nr] then
                seen_r[nr] = true
                table.insert(roots, nr)
            end
        end
    end
    add_root(utils.get_projects_root(ctx))
    if HOME ~= "" then
        add_root(HOME .. "/Archive/_Programing_")
        add_root(HOME .. "/Projects")
    end

    local buckets = { "cpp", "C++", "rust", "python", "java", "lua", "bash", "fish" }
    local candidates = {}
    for _, root in ipairs(roots) do
        -- 1. Точное совпадение в корне и бакетах
        if ctx.is_dir(root .. "/" .. query) then
            return ctx.normalize_path(root .. "/" .. query)
        end
        for _, b in ipairs(buckets) do
            local p = root .. "/" .. b .. "/" .. query
            if ctx.is_dir(p) then
                return ctx.normalize_path(p)
            end
        end
        -- Собираем список подпроектов для нечёткого поиска
        local items = (grime.fs and grime.fs.list and grime.fs.list(root)) or {}
        for _, item in ipairs(items) do
            if not item:match("^%.") and ctx.is_dir(root .. "/" .. item) then
                local full = root .. "/" .. item
                local is_bucket = false
                for _, b in ipairs(buckets) do
                    if item == b then is_bucket = true; break end
                end
                if is_bucket then
                    local subs = (grime.fs and grime.fs.list and grime.fs.list(full)) or {}
                    for _, sub in ipairs(subs) do
                        if not sub:match("^%.") and ctx.is_dir(full .. "/" .. sub) then
                            table.insert(candidates, { name = sub, path = full .. "/" .. sub })
                        end
                    end
                else
                    table.insert(candidates, { name = item, path = full })
                end
            end
        end
    end

    local qlow = query:lower()
    for _, c in ipairs(candidates) do
        if c.name:lower() == qlow then return ctx.normalize_path(c.path) end
    end
    for _, c in ipairs(candidates) do
        if c.name:lower():sub(1, #qlow) == qlow then return ctx.normalize_path(c.path) end
    end
    for _, c in ipairs(candidates) do
        if c.name:lower():find(qlow, 1, true) then return ctx.normalize_path(c.path) end
    end
    local names = {}
    for _, c in ipairs(candidates) do table.insert(names, c.name) end
    local best = grime.fuzzy and grime.fuzzy.find_best_match and grime.fuzzy.find_best_match(query, names, 0.75)
    if best then
        for _, c in ipairs(candidates) do
            if c.name == best then
                ctx.log(string.format("Проект '%s' не найден, выбран похожий: '%s'", query, best))
                return ctx.normalize_path(c.path)
            end
        end
    end
    return nil
end

--- Проверка наличия всех необходимых бинарников команды на хосте
local function has_command_bins_on_host(cmd_str)
    if type(cmd_str) ~= "string" or cmd_str == "" then return false end
    local first = cmd_str:match("^%s*(%S+)")
    if not first or first == "mkdir" or first == "cd" then
        return false
    end
    return utils.has_binary(first, ctx)
end

--- Компиляция (и/или установка в apps + ~/.local/bin) аппа, папки или проекта
local function compile_or_install_app(apps_root, args, _is_install, explicit_lang, path_requested)
    local target_arg = args[1]
    local custom_name = (args[2] and not args[2]:match("^%-")) and args[2] or nil

    if not target_arg or target_arg == "" then
        local pipe_in = ctx.pipeline_input or ctx.input
        if pipe_in and type(pipe_in) == "string" then
            local trimmed = grime.str.trim(pipe_in)
            if #trimmed > 0 and not trimmed:find("\n") then
                target_arg = trimmed
            end
        end
    end

    if not target_arg or target_arg == "" then
        fail_once("Использование: grime app -compile <имя_аппа | путь | имя_проекта> [имя_команды]")
        return 1
    end

    local target_dir = nil
    local resolved_app_name = nil
    local entry_override = nil

    local looks_like_path = target_arg:find("/") ~= nil or target_arg:sub(1, 1) == "~" or target_arg:sub(1, 1) == "."
    local norm_arg_path = utils.normalize_path(target_arg, nil, ctx)

    -- 1. Проверяем существующий Grime App (если аргумент не явный путь)
    if not looks_like_path and not ctx.is_file(norm_arg_path) then
        local matched = find_app_name(apps_root, target_arg)
        if matched then
            local app_dir = apps_root .. "/" .. matched
            local link_meta = utils.read_app_link_meta(app_dir)
            if link_meta and link_meta.source_dir and ctx.is_dir(link_meta.source_dir) then
                target_dir = ctx.normalize_path(link_meta.source_dir)
            else
                target_dir = ctx.normalize_path(app_dir)
            end
            resolved_app_name = matched
        end
    end

    -- 2. Проверяем как путь к файлу или директории на диске
    if not target_dir then
        if ctx.is_file(norm_arg_path) then
            target_dir = norm_arg_path:match("^(.*)/[^/]+$") or "/"
            entry_override = norm_arg_path:match("([^/]+)$")
        elseif ctx.is_dir(norm_arg_path) then
            target_dir = norm_arg_path
        end
    end

    -- 3. Проверяем среди проектов grime project
    if not target_dir and not looks_like_path then
        target_dir = find_project_by_name(target_arg)
    end

    if not target_dir or not ctx.is_dir(target_dir) then
        fail_once(string.format("Цель для компиляции не найдена (приложение, путь или проект): '%s'", target_arg))
        return 1
    end

    local initial_name = custom_name or resolved_app_name or (target_dir:match("([^/]+)$") or "app")
    local m, err = load_manifest(target_dir, initial_name, { entry_file = entry_override, lang = explicit_lang })
    if not m then
        fail_once(err or ("Не удалось определить тип проекта для компиляции в " .. target_dir))
        return 1
    end

    -- Выполняем сборку / синтаксическую проверку в target_dir
    if m.build and m.build ~= "" then
        ctx.log(string.format("==> Компиляция/проверка '%s' в %s...", initial_name, target_dir))
        local code = 0
        if type(m.build) == "function" then
            local ok, res = pcall(m.build, target_dir, m)
            if not ok then
                fail_once(string.format("Ошибка компиляции '%s': %s", initial_name, tostring(res)))
                return 1
            end
            code = (type(res) == "number") and res or (res == false and 1 or 0)
        else
            local has_local_flake = ctx.is_file(target_dir .. "/flake.nix")
            local has_spec_deps = m.special_dependencies and #m.special_dependencies > 0
            local fast_host = (not has_local_flake) and (not has_spec_deps) and has_command_bins_on_host(m.build)
            if fast_host then
                code = ctx.run_process({ "sh", "-c", m.build }, target_dir)
            else
                local flake_override = nil
                local norm_apps = ctx.normalize_path(apps_root) .. "/"
                if not has_local_flake and target_dir:sub(1, #norm_apps) ~= norm_apps then
                    flake_override = get_ephemeral_compile_flake(target_dir, m)
                end
                local env = get_nix_env(initial_name, target_dir, { GRIME_APP_NAME = initial_name })
                code = exec_cmd(m, m.build, target_dir, env, flake_override)
            end
        end

        if code ~= 0 then
            fail_once(string.format("Компиляция '%s' завершилась с ошибкой (код %d)", initial_name, code))
            return 1
        end
    end

    -- Определяем итоговый артефакт в target_dir
    local compiled_rel = nil
    if m._is_script and m.artifact and ctx.is_file(target_dir .. "/" .. m.artifact) then
        compiled_rel = m.artifact
    elseif entry_override and ctx.is_file(target_dir .. "/" .. entry_override) and m._is_script then
        compiled_rel = entry_override
    else
        compiled_rel = find_compiled_binary(target_dir, initial_name, m)
    end

    if not compiled_rel or not ctx.is_file(target_dir .. "/" .. compiled_rel) then
        fail_once(string.format("Сборка завершилась, но исполняемый артефакт не найден в %s", target_dir))
        return 1
    end

    local abs_compiled = ctx.normalize_path(target_dir .. "/" .. compiled_rel)
    local art_base = abs_compiled:match("([^/]+)$") or initial_name

    -- Определяем итоговое имя команды и каталога в apps_root
    local final_name = custom_name
    if not final_name or final_name == "" then
        local stripped = art_base
            :gsub("%.py$", "")
            :gsub("%.lua$", "")
            :gsub("%.sh$", "")
            :gsub("%.bash$", "")
            :gsub("%.fish$", "")
            :gsub("%.jar$", "")
            :gsub("%.class$", "")
        if stripped == "" or ((stripped == "main" or stripped == "Main") and not entry_override) then
            final_name = resolved_app_name or (target_dir:match("([^/]+)$") or "app")
        else
            final_name = stripped
        end
    end

    -- Подготовка скрипта: добавляем shebang при отсутствии и ставим chmod +x
    local is_script = m._is_script
        or abs_compiled:match("%.py$")
        or abs_compiled:match("%.lua$")
        or abs_compiled:match("%.sh$")
        or abs_compiled:match("%.bash$")
        or abs_compiled:match("%.fish$")
    if is_script then
        ensure_script_shebang(abs_compiled, m.type)
    end
    ctx.capture({ "chmod", "+x", abs_compiled })

    -- Размещаем скомпилированное содержимое в <apps_root>/<final_name>/
    local dest_app_dir = ctx.normalize_path(apps_root .. "/" .. final_name)
    ctx.mkdir_p(dest_app_dir)

    local dest_bin_path = nil
    local dest_file_name = nil
    local norm_target = ctx.normalize_path(target_dir)

    if norm_target ~= dest_app_dir then
        if abs_compiled:match("%.jar$") then
            local jar_dst = dest_app_dir .. "/" .. art_base
            ctx.capture({ "cp", "-f", abs_compiled, jar_dst })
            dest_file_name = final_name
            dest_bin_path = dest_app_dir .. "/" .. dest_file_name
            local wf = io.open(dest_bin_path, "w")
            if wf then
                wf:write(string.format("#!/usr/bin/env bash\nexec java -jar \"$(dirname \"$(readlink -f \"$0\")\")/%s\" \"$@\"\n", art_base))
                wf:close()
            end
            ctx.capture({ "chmod", "+x", dest_bin_path })
        elseif abs_compiled:match("%.class$") then
            local bin_sub = dest_app_dir .. "/bin"
            ctx.mkdir_p(bin_sub)
            local class_dir = abs_compiled:match("^(.*)/[^/]+$") or target_dir
            ctx.copy(class_dir, bin_sub)
            dest_file_name = final_name
            dest_bin_path = dest_app_dir .. "/" .. dest_file_name
            local wf = io.open(dest_bin_path, "w")
            if wf then
                wf:write("#!/usr/bin/env bash\nexec java -cp \"$(dirname \"$(readlink -f \"$0\")\")/bin\" Main \"$@\"\n")
                wf:close()
            end
            ctx.capture({ "chmod", "+x", dest_bin_path })
        else
            local ext = abs_compiled:match("(%.[%a%d_]+)$") or ""
            dest_file_name = (is_script and ext ~= "") and (final_name .. ext) or final_name
            dest_bin_path = dest_app_dir .. "/" .. dest_file_name
            ctx.capture({ "cp", "-f", abs_compiled, dest_bin_path })
            ctx.capture({ "chmod", "+x", dest_bin_path })

            -- Копируем сопутствующие .so библиотеки из директории бинарника, если они есть
            local art_dir = abs_compiled:match("^(.*)/[^/]+$")
            if art_dir and ctx.is_dir(art_dir) then
                local sibs = (grime.fs and grime.fs.list and grime.fs.list(art_dir)) or {}
                for _, s in ipairs(sibs) do
                    if s:match("%.so$") or s:match("%.so%.") then
                        ctx.capture({ "cp", "-f", art_dir .. "/" .. s, dest_app_dir .. "/" .. s })
                    end
                end
            end
        end

        -- Сохраняем привязку к исходникам в .grime_app.json (если нет app.lua)
        if not ctx.is_file(dest_app_dir .. "/app.lua") and grime and grime.json and grime.json.encode then
            local meta_tbl = {
                name = final_name,
                source_dir = norm_target,
                artifact = dest_file_name,
                source_artifact = compiled_rel,
                lang = m.type,
                run = "./" .. dest_file_name,
                bin_link = HOME .. "/.local/bin/" .. final_name,
                description = m.description or ("Скомпилированное приложение " .. final_name),
                special_dependencies = m.special_dependencies or {},
            }
            local mf = io.open(dest_app_dir .. "/.grime_app.json", "w")
            if mf then
                mf:write(grime.json.encode(meta_tbl))
                mf:close()
            end
        end
    else
        -- Апп уже находится в dest_app_dir
        if abs_compiled:match("%.jar$") then
            dest_file_name = final_name
            dest_bin_path = dest_app_dir .. "/" .. dest_file_name
            local wf = io.open(dest_bin_path, "w")
            if wf then
                wf:write(string.format("#!/usr/bin/env bash\nexec java -jar \"$(dirname \"$(readlink -f \"$0\")\")/%s\" \"$@\"\n", compiled_rel))
                wf:close()
            end
            ctx.capture({ "chmod", "+x", dest_bin_path })
        elseif abs_compiled:match("%.class$") then
            dest_file_name = final_name
            dest_bin_path = dest_app_dir .. "/" .. dest_file_name
            local wf = io.open(dest_bin_path, "w")
            if wf then
                wf:write("#!/usr/bin/env bash\nexec java -cp \"$(dirname \"$(readlink -f \"$0\")\")/bin\" Main \"$@\"\n")
                wf:close()
            end
            ctx.capture({ "chmod", "+x", dest_bin_path })
        else
            dest_bin_path = abs_compiled
            dest_file_name = compiled_rel
            ctx.capture({ "chmod", "+x", dest_bin_path })
        end
    end

    -- Создаём симлинк в ~/.local/bin/<final_name> -> <apps_root>/<final_name>/<artifact>
    local local_bin_dir = HOME .. "/.local/bin"
    ctx.mkdir_p(local_bin_dir)
    local bin_link = local_bin_dir .. "/" .. final_name
    local ln_res = ctx.capture({ "ln", "-sf", dest_bin_path, bin_link })
    if ln_res.code ~= 0 then
        fail_once(string.format("Не удалось создать симлинк %s -> %s: %s", bin_link, dest_bin_path, ln_res.stderr or ""))
        return 1
    end

    -- Регистрируем состояние в StateBus
    bus_set("app." .. final_name .. ".source_dir", norm_target)
    bus_set("app." .. final_name .. ".artifact", dest_bin_path)
    bus_set("app." .. final_name .. ".bin_path", bin_link)
    bus_set("app." .. final_name .. ".build_status", "ready")
    bus_set("app." .. final_name .. ".last_built_time", os.date("%Y-%m-%d %H:%M:%S"))

    ctx.log(string.format("✓ Артефакт размещён: %s", dest_bin_path))
    ctx.log(string.format("✓ Системная команда зарегистрирована: %s -> %s", bin_link, dest_bin_path))

    local cur_path = os.getenv("PATH") or ""
    if not cur_path:find(local_bin_dir, 1, true) then
        ctx.log(string.format("ℹ Убедитесь, что %s добавлен в ваш $PATH.", local_bin_dir))
    end

    if ctx.has_next_step or path_requested then
        local ret = path_requested and norm_target or bin_link
        if ctx.set_target_dir then ctx.set_target_dir(dest_app_dir) end
        ctx.module_return(ret)
    end
    return 0
end

local function run_existing_app(apps_root, filtered, extra_args, is_detach, explicit_lang, path_requested)
    if not filtered or #filtered == 0 then
        list_apps(apps_root, false)
        return
    end
    local raw_name = filtered[1]
    local matched_name = find_app_name(apps_root, raw_name)
    if matched_name then
        local dir = apps_root .. "/" .. matched_name
        local m, err = load_manifest(dir, matched_name)
        if not m then fail_once(err); return end
        local rargs = {}
        for i = 2, #filtered do table.insert(rargs, filtered[i]) end
        for _, ea in ipairs(extra_args) do table.insert(rargs, ea) end
        local code = run_app(matched_name, m, dir, rargs, is_detach)
        if code ~= 0 then
            fail_once(string.format("Приложение '%s' завершилось с кодом %d", matched_name, code))
        else
            if ctx.has_next_step or path_requested then
                if ctx.set_target_dir then ctx.set_target_dir(dir) end
                ctx.module_return(dir)
            end
        end
    else
        fail_once(string.format("Приложение '%s' не найдено в %s.\nДля создания укажите флаг new: grime app -new %s", raw_name, apps_root, raw_name))
    end
end
local run_or_create = run_existing_app

function main()
    has_failed = false
    local apps_root = get_apps_root()
    local is_detach, force = false, false
    local wants_help = false
    local path_requested = false
    local explicit_lang = nil
    local explicit_subcmd = nil
    local filtered = {}

    local raw_args = ctx.args or {}
    local tokens_before, extra_args, _ = grime.args.split_passthrough(raw_args)
    local idx = 1
    while idx <= #tokens_before do
        local a = tokens_before[idx]
        local alow = type(a) == "string" and a:lower() or ""
        local eq_flag, eq_val = alow:match("^(%-[%w_%-]+)=(.+)$")
        if eq_flag and (eq_flag == "-l" or eq_flag == "-lang" or eq_flag == "--lang") then
            explicit_lang = LANG_ALIASES[eq_val] or eq_val
        elseif (alow == "--lang" or alow == "-lang" or alow == "-l") and idx + 1 <= #tokens_before and not tokens_before[idx + 1]:match("^%-") then
            idx = idx + 1
            local raw_l = tokens_before[idx]:lower()
            explicit_lang = LANG_ALIASES[raw_l] or raw_l
        elseif alow == "--detach" or alow == "-detach" or alow == "-d" then
            is_detach = true
        elseif alow == "--help" or alow == "-help" or alow == "-h" then
            wants_help = true
        elseif alow == "--path" or alow == "-path" or alow == "-p" then
            path_requested = true
        elseif alow == "--force" or alow == "-force" or alow == "-f" or alow == "-9" then
            force = true
        elseif ACTION_MAP[alow] then
            -- Точное совпадение с действием со знаком минус (-new, -build, -compile, -install, -run, -diff, -ps, -rm, -test)
            explicit_subcmd = ACTION_MAP[alow]
        else
            -- Нечеткое сопоставление только если это неизвестный флаг со знаком минус
            local fuzzy_matched = nil
            if type(a) == "string" and a:match("^%-") then
                fuzzy_matched = grime.fuzzy.match_flag(a, {
                    "--detach", "--help", "--path", "--force",
                    "--new", "--build", "--compile", "--install", "--run", "--stop", "--list", "--rm", "--bundle", "--snapshot", "--rollback", "--diff", "--status", "--test",
                }, 0.80)
            end
            if fuzzy_matched == "--detach" then
                is_detach = true
            elseif fuzzy_matched == "--help" then
                wants_help = true
            elseif fuzzy_matched == "--path" then
                path_requested = true
            elseif fuzzy_matched == "--force" then
                force = true
            elseif fuzzy_matched and ACTION_MAP[fuzzy_matched] then
                explicit_subcmd = ACTION_MAP[fuzzy_matched]
            else
                table.insert(filtered, a)
            end
        end
        idx = idx + 1
    end

    local subcmd = explicit_subcmd
    if not subcmd and #filtered > 0 then
        local first_tok = type(filtered[1]) == "string" and filtered[1]:lower() or ""
        if SUBCMD_WORDS[first_tok] then
            if first_tok == "test" and #filtered == 1 and find_app_name(apps_root, filtered[1]) then
                -- Одиночный аргумент 'test' при наличии приложения с таким именем запускает само приложение
            else
                subcmd = SUBCMD_WORDS[first_tok]
                table.remove(filtered, 1)
            end
        end
    end

    if wants_help or subcmd == "help" then
        print_help()
        return 0
    end

    -- Обработка запроса пути (-path / --path / -p / subcmd == "path"):
    -- 1) grime app -path -> apps_root
    -- 2) grime app -path <app> -> source_dir (если внешний проект) или apps_root/<app>
    -- 3) grime app <app> -path -> source_dir или apps_root/<app>
    if path_requested or subcmd == "path" then
        local target_query = filtered[1]
        if not target_query or target_query == "" then
            local pipe_in = ctx.pipeline_input or ctx.input
            if pipe_in and type(pipe_in) == "string" then
                local trimmed = grime.str.trim(pipe_in)
                if #trimmed > 0 and not trimmed:find("\n") and not ctx.is_dir(trimmed) then
                    target_query = trimmed
                end
            end
        end

        local app_dir = apps_root
        if target_query and target_query ~= "" then
            local matched_name = find_app_name(apps_root, target_query)
            local resolved_name = matched_name or target_query
            local cand_dir = ctx.normalize_path(apps_root .. "/" .. resolved_name)
            local link_meta = utils.read_app_link_meta(cand_dir)
            if link_meta and link_meta.source_dir and ctx.is_dir(link_meta.source_dir) then
                app_dir = ctx.normalize_path(link_meta.source_dir)
            else
                local bus_src = bus_get("app." .. resolved_name .. ".source_dir")
                if type(bus_src) == "string" and bus_src ~= "" and ctx.is_dir(bus_src) then
                    app_dir = ctx.normalize_path(bus_src)
                else
                    app_dir = cand_dir
                end
            end
        end

        if ctx.set_target_dir then ctx.set_target_dir(app_dir) end
        ctx.module_return(app_dir)
        return 0
    end

    if not subcmd then
        if #filtered == 0 then
            list_apps(apps_root, false)
            if not ctx.has_next_step then
                print("\27[90mДля подробной справки используйте: grime app -help\27[0m\n")
            end
            return 0
        end
    elseif subcmd == "list" then
        list_apps(apps_root, false)
        return 0
    elseif subcmd == "ps" then
        ps_apps(apps_root)
        return 0
    elseif subcmd == "stop" then
        if not filtered[1] then
            fail_once("Укажите имя приложения: grime app -stop <app_name> [-9/-force]")
            return 1
        end
        stop_app(apps_root, filtered[1], force)
        return 0
    elseif subcmd == "new" then
        for _, ea in ipairs(extra_args) do table.insert(filtered, ea) end
        new_app(apps_root, filtered, explicit_lang, path_requested)
        return 0
    elseif subcmd == "compile" or subcmd == "install" then
        return compile_or_install_app(apps_root, filtered, subcmd == "install", explicit_lang, path_requested)
    elseif subcmd == "build" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -build <app_name>"); return 1 end
        local app_name = resolve_app_name(apps_root, filtered[1])
        local dir = apps_root .. "/" .. app_name
        if not ctx.exists(dir) then
            fail_once(string.format("Приложение '%s' не найдено в %s", filtered[1], apps_root))
            return 1
        end
        local m, err = load_manifest(dir, app_name)
        if not m then fail_once(err or "Конфигурация приложения не найдена"); return 1 end
        local ok = build_app(app_name, m, dir)
        if ok and m._source_dir and m._source_dir ~= ctx.normalize_path(dir) then
            -- Синхронизируем обновлённый артефакт в apps_root/<app_name>/ и ~/.local/bin/<app_name>
            return compile_or_install_app(apps_root, { app_name }, false, explicit_lang, path_requested)
        end
        if ok and (ctx.has_next_step or path_requested) then
            local ret_dir = m._source_dir or dir
            if ctx.set_target_dir then ctx.set_target_dir(ret_dir) end
            ctx.module_return(ret_dir)
        end
        return 0
    elseif subcmd == "commit" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -commit <app_name> [сообщение]"); return 1 end
        local msg_tokens = {}
        for i = 2, #filtered do table.insert(msg_tokens, filtered[i]) end
        for _, ea in ipairs(extra_args) do table.insert(msg_tokens, ea) end
        commit_app(apps_root, filtered[1], #msg_tokens > 0 and table.concat(msg_tokens, " ") or nil)
        return 0
    elseif subcmd == "snapshot" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -snapshot <app_name> [сообщение]"); return 1 end
        local msg_tokens = {}
        for i = 2, #filtered do table.insert(msg_tokens, filtered[i]) end
        for _, ea in ipairs(extra_args) do table.insert(msg_tokens, ea) end
        snapshot_app(apps_root, filtered[1], #msg_tokens > 0 and table.concat(msg_tokens, " ") or nil)
        return 0
    elseif subcmd == "log" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -log <app_name> [n]"); return 1 end
        log_app(apps_root, filtered[1], filtered[2])
        return 0
    elseif subcmd == "diff" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -diff <app_name> [файл]"); return 1 end
        diff_app(apps_root, filtered[1], filtered[2])
        return 0
    elseif subcmd == "status" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -status <app_name>"); return 1 end
        local app_name = resolve_app_name(apps_root, filtered[1])
        local dir = apps_root .. "/" .. app_name
        local m, _ = load_manifest(dir, app_name)
        if m and type(m.status) == "function" then
            m.status(dir, m)
            return 0
        end
        status_app(apps_root, filtered[1])
        return 0
    elseif subcmd == "test" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -test <app_name>"); return 1 end
        local app_name = resolve_app_name(apps_root, filtered[1])
        local dir = apps_root .. "/" .. app_name
        local m, err = load_manifest(dir, app_name)
        if not m then fail_once(err or "Конфигурация приложения не найдена"); return 1 end
        if type(m.test) == "function" then
            local ok, res = pcall(m.test, dir, m)
            if not ok or res == false or (type(res) == "number" and res ~= 0) then
                fail_once(string.format("Тесты приложения '%s' завершились с ошибкой: %s", app_name, tostring(res)))
                return 1
            end
            ctx.log(string.format("✓ Все тесты приложения '%s' успешно пройдены.", app_name))
        elseif type(m.test) == "string" and m.test ~= "" then
            local code = exec_cmd(m, m.test, m._source_dir or dir)
            if code ~= 0 then fail_once(string.format("Тесты завершились с кодом %d", code)); return 1 end
            ctx.log(string.format("✓ Все тесты приложения '%s' успешно пройдены.", app_name))
        else
            ctx.log(string.format("Тесты для приложения '%s' не определены.", app_name))
        end
        return 0
    elseif subcmd == "bundle" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -bundle <app_name>"); return 1 end
        bundle_app(apps_root, filtered[1])
        return 0
    elseif subcmd == "rollback" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -rollback <app_name> [commit]"); return 1 end
        rollback_app(apps_root, filtered[1], filtered[2])
        return 0
    elseif subcmd == "rm" then
        if not filtered[1] then fail_once("Укажите имя приложения: grime app -rm <app_name>"); return 1 end
        local app_name = resolve_app_name(apps_root, filtered[1])
        rm_app(apps_root, app_name)
        return 0
    elseif subcmd == "run" then
        if not filtered[1] then
            fail_once("Укажите имя приложения: grime app -run <app_name> [аргументы...]")
            return 1
        end
    end

    -- Проверка на цепочку приложений (App Chaining)
    local segments = {}
    local cur_seg = {}
    for _, tok in ipairs(filtered) do
        if tok == "->" or tok == ":" or tok == "::" then
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
        if code ~= 0 then fail_once(string.format("Цепочка приложений завершилась с ошибкой (код %d)", code)) end
    else
        -- Запуск существующего или создание нового приложения (gap <app_name>)
        run_or_create(apps_root, filtered, extra_args, is_detach, explicit_lang, path_requested)
    end
end

return {
    description = description,
    main = main,
    get_apps_root = get_apps_root,
    find_app_name = find_app_name,
    resolve_app_name = resolve_app_name,
    load_manifest = load_manifest,
    check_artifact_status = check_artifact_status,
    build_app = build_app,
    compile_or_install_app = compile_or_install_app,
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
    run_or_create = run_or_create,
}
