--[[
    Grime List Module (Unified Inventory: Modules, Apps & Projects)
    Единый каталог установленных декларативных модулей GRIME,
    локальных микроприложений (Grime Apps) и проектов пользователя.
]]

-- Summary: Единый реестр модулей GRIME, приложений и проектов разработки
-- Description: Единый реестр модулей GRIME, приложений и проектов разработки
description = "Единый реестр модулей GRIME, приложений и проектов разработки"

local utils = require("languages.utils")

local ctx = grime.ctx
local fs = grime.fs
local str = grime.str
local ui = grime.ui
local ANSI = utils.ANSI
local HOME = os.getenv("HOME") or ""

local function print_help()
    print(string.format([[
%s%sGrime List%s — Единый обзор модулей, приложений и проектов GRIME

%sИСПОЛЬЗОВАНИЕ:%s
    grime list [секция] [фильтр]

%sСЕКЦИИ:%s
    %sall%s                   Показать сводку всех модулей, приложений и проектов (по умолчанию)
    %smodules, mod, m%s       Показать установленные декларативные модули GRIME
    %sapps, app, a%s          Показать локальные микроприложения Grime Apps
    %sprojects, proj, p%s     Показать проекты разработки по языкам
    %shelp, -h, --help%s      Показать эту справку

%sПРИМЕРЫ:%s
    grime list                    # Полный обзор экосистемы GRIME
    grime list modules            # Список всех модулей оркестратора
    grime list apps               # Список приложений Grime Apps
    grime list projects           # Список проектов пользователя
]],
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

local function get_file_content(filepath)
    local f = io.open(filepath, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

--- Безопасное усечение строки без разрыва многобайтовых символов UTF-8
local function truncate_utf8(s, max_chars)
    if not s or s == "" then return "" end
    s = s:gsub("[\r\n]+", " ")
    local count = 0
    local chars = {}
    for c in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > max_chars then
            return table.concat(chars) .. "..."
        end
        table.insert(chars, c)
    end
    return s
end

local function parse_json_description(content)
    if not content or content == "" then return nil end
    if grime and grime.json and grime.json.decode then
        local ok, data = pcall(grime.json.decode, content)
        if ok and type(data) == "table" and type(data.description) == "string" and data.description ~= "" then
            return data.description
        end
    end
    local desc = content:match('"description"%s*:%s*"([^"]+)"')
    if desc and desc ~= "" then return desc end
    return nil
end

--- Динамическое извлечение описания модуля GRIME
local function get_module_description(mod_path)
    -- 1. Быстрый поиск регулярными выражениями без загрузки файла в Lua
    local content = get_file_content(mod_path)
    if content then
        local d = content:match('M%.description%s*=%s*["\'](.-)["\']')
            or content:match('description%s*=%s*["\'](.-)["\']')
            or content:match('%-%-%s*[Dd]escription:%s*([^\r\n]+)')
            or content:match('%-%-%s*[Ss]ummary:%s*([^\r\n]+)')
            or content:match('%-%-%s*Описание:%s*([^\r\n]+)')
        if d and d ~= "" then
            return (str and str.trim and str.trim(d)) or d:match("^%s*(.-)%s*$")
        end
    end

    -- 2. Если по regex не нашли, безопасный запуск в изолированном окружении
    local env = {
        grime = { ctx = {}, fs = {}, ui = {}, str = {}, bus = {}, events = {}, process = {} },
        require = function() return {} end,
        string = string,
        table = table,
        math = math,
        os = { getenv = os.getenv },
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        pcall = pcall,
        xpcall = xpcall,
        setmetatable = setmetatable,
        getmetatable = getmetatable,
        pairs = pairs,
        ipairs = ipairs,
        next = next,
        select = select,
        rawget = rawget,
        rawset = rawset,
        error = function() end,
        print = function() end,
    }
    env._G = env

    local chunk = loadfile(mod_path, "t", env)
    if chunk then
        local ok, ret = pcall(chunk)
        if ok then
            if type(ret) == "table" and type(ret.description) == "string" and ret.description ~= "" then
                return ret.description
            elseif type(env.description) == "string" and env.description ~= "" then
                return env.description
            end
        end
    end

    return "Декларативный модуль GRIME"
end

--- Извлечение описания приложения Grime App
local function get_app_info(app_dir)
    local lang = "custom"
    local desc = ""
    local app_file = app_dir .. "/app.lua"

    local app_content = get_file_content(app_file)
    if app_content then
        desc = app_content:match('description%s*=%s*["\'](.-)["\']') or ""
        lang = app_content:match('type%s*=%s*["\'](.-)["\']')
            or app_content:match('lang%s*=%s*["\'](.-)["\']')
            or "custom"

        if desc == "" then
            local chunk = loadfile(app_file, "t", {
                os = { getenv = os.getenv },
                string = string,
                table = table,
                type = type,
                tostring = tostring,
                tonumber = tonumber,
            })
            if chunk then
                local ok, m = pcall(chunk)
                if ok and type(m) == "table" then
                    lang = tostring(m.type or m.lang or lang or "custom")
                    desc = tostring(m.description or desc or "")
                end
            end
        end
    end

    -- Проверка grime.json / meta.json
    if desc == "" then
        for _, mf in ipairs({ "grime.json", "meta.json" }) do
            local mp = app_dir .. "/" .. mf
            local content = get_file_content(mp)
            if content then
                local d = parse_json_description(content)
                if d and d ~= "" then
                    desc = d
                    break
                end
            end
        end
    end

    -- Проверка README.md
    if desc == "" then
        for _, rname in ipairs({ "README.md", "readme.md" }) do
            local rcontent = get_file_content(app_dir .. "/" .. rname)
            if rcontent then
                for line in rcontent:gmatch("[^\r\n]+") do
                    local trimmed = (str and str.trim and str.trim(line)) or line:match("^%s*(.-)%s*$")
                    if trimmed ~= "" and not trimmed:match("^#") and not trimmed:match("^%[") and not trimmed:match("^<") and not trimmed:match("^|") and not trimmed:match("^<!%-%-") then
                        local clean = trimmed:gsub("^>%s*", ""):gsub("%*%*", ""):gsub("`", "")
                        if clean ~= "" and #clean >= 5 then
                            desc = truncate_utf8(clean, 70)
                            break
                        end
                    end
                end
                if desc ~= "" then break end
            end
        end
    end

    if desc == "" then
        desc = "Микроприложение GRIME"
    end

    return lang, desc
end

--- Динамическое извлечение описания проекта пользователя
local function get_project_description(pdir)
    -- 1. grime.json или .grime
    for _, fname in ipairs({ "grime.json", ".grime" }) do
        local content = get_file_content(pdir .. "/" .. fname)
        if content then
            local desc = parse_json_description(content)
            if desc and desc ~= "" then return truncate_utf8(desc, 70) end
        end
    end

    -- 2. Cargo.toml (Rust)
    local cargo_content = get_file_content(pdir .. "/Cargo.toml")
    if cargo_content then
        local in_pkg = false
        for line in cargo_content:gmatch("[^\r\n]+") do
            local header = line:match("^%s*%[([^%]]+)%]")
            if header then
                in_pkg = (header == "package")
            elseif in_pkg then
                local desc = line:match('^%s*description%s*=%s*"([^"]+)"')
                    or line:match("^%s*description%s*=%s*'([^']+)'")
                if desc and desc ~= "" then
                    return truncate_utf8(desc, 70)
                end
            end
        end
    end

    -- 3. pyproject.toml / setup.cfg (Python)
    local pyproject = get_file_content(pdir .. "/pyproject.toml")
    if pyproject then
        local desc = pyproject:match('description%s*=%s*"([^"]+)"')
            or pyproject:match("description%s*=%s*'([^']+)'")
        if desc and desc ~= "" then
            return truncate_utf8(desc, 70)
        end
    end
    local setup_cfg = get_file_content(pdir .. "/setup.cfg")
    if setup_cfg then
        local in_meta = false
        for line in setup_cfg:gmatch("[^\r\n]+") do
            local header = line:match("^%s*%[([^%]]+)%]")
            if header then
                in_meta = (header == "metadata")
            elseif in_meta then
                local desc = line:match("^%s*description%s*=%s*([^\r\n]+)")
                if desc and desc ~= "" then
                    desc = (str and str.trim and str.trim(desc)) or desc:match("^%s*(.-)%s*$")
                    return truncate_utf8(desc, 70)
                end
            end
        end
    end

    -- 4. package.json (Node/TS)
    local pkg_json = get_file_content(pdir .. "/package.json")
    if pkg_json then
        local desc = parse_json_description(pkg_json)
        if desc and desc ~= "" then return truncate_utf8(desc, 70) end
    end

    -- 5. CMakeLists.txt (C/C++)
    local cmake = get_file_content(pdir .. "/CMakeLists.txt")
    if cmake then
        local desc = cmake:match('project%s*%b()[^\r\n]*DESCRIPTION%s*"([^"]+)"')
            or cmake:match('DESCRIPTION%s*"([^"]+)"')
        if desc and desc ~= "" then
            return truncate_utf8(desc, 70)
        end
    end

    -- 6. Fallback на README.md
    for _, rname in ipairs({ "README.md", "readme.md", "README", "readme" }) do
        local rcontent = get_file_content(pdir .. "/" .. rname)
        if rcontent then
            for line in rcontent:gmatch("[^\r\n]+") do
                local trimmed = (str and str.trim and str.trim(line)) or line:match("^%s*(.-)%s*$")
                if trimmed ~= ""
                    and not trimmed:match("^#")
                    and not trimmed:match("^%[")
                    and not trimmed:match("^<")
                    and not trimmed:match("^|")
                    and not trimmed:match("^<!%-%-")
                    and not trimmed:match("^===")
                    and not trimmed:match("^%-%-%-")
                    and not trimmed:match("^%*%s*%[")
                    and not trimmed:match("^%*%*%[")
                then
                    local clean = trimmed:gsub("^>%s*", ""):gsub("%*%*", ""):gsub("`", "")
                    clean = (str and str.trim and str.trim(clean)) or clean:match("^%s*(.-)%s*$")
                    if clean ~= "" and #clean >= 5 then
                        return truncate_utf8(clean, 70)
                    end
                end
            end
        end
    end

    return "(нет описания)"
end

local function get_modules_dir()
    local cfg = (ctx.config_dir and ctx.config_dir()) or (HOME .. "/.config/grime")
    return cfg .. "/modules"
end

local function collect_modules(filter)
    local mod_dir = get_modules_dir()
    if not ctx.exists(mod_dir) then return {} end
    local ok, items = pcall(fs.list, mod_dir)
    if not ok or type(items) ~= "table" then return {} end

    local list = {}
    for _, item in ipairs(items) do
        local name = item:match("^([%w_%-]+)%.lua$")
        if name then
            local mod_path = mod_dir .. "/" .. item
            local desc = get_module_description(mod_path)
            if not filter or name:lower():find(filter, 1, true) or desc:lower():find(filter, 1, true) then
                table.insert(list, {
                    name = name,
                    desc = desc,
                    path = mod_path,
                })
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function collect_apps(filter)
    local apps_root = utils.get_apps_root(ctx)
    if not ctx.exists(apps_root) then return {} end
    local ok, items = pcall(fs.list, apps_root)
    if not ok or type(items) ~= "table" then return {} end

    local list = {}
    for _, item in ipairs(items) do
        local app_dir = apps_root .. "/" .. item
        if not item:match("^%.") and ctx.is_dir(app_dir) then
            local lang, desc = get_app_info(app_dir)
            if not filter or item:lower():find(filter, 1, true) or lang:lower():find(filter, 1, true) or desc:lower():find(filter, 1, true) then
                table.insert(list, {
                    name = item,
                    lang = lang,
                    desc = desc,
                    path = app_dir,
                })
            end
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function collect_projects(filter)
    local projects_root = (ctx.paths and ctx.paths.projects)
        or (ctx.get_path and ctx.get_path("projects"))
        or (ctx.projects_root and ctx.projects_root())
    if not projects_root or projects_root == "" then
        projects_root = HOME .. "/Projects"
    end
    projects_root = ctx.normalize_path(projects_root)
    if not ctx.exists(projects_root) then return {} end

    local ok, items = pcall(fs.list, projects_root)
    if not ok or type(items) ~= "table" then return {} end

    local lang_buckets = { cpp = true, ["C++"] = true, rust = true, python = true, java = true, lua = true }
    local list = {}

    for _, item in ipairs(items) do
        if not item:match("^%.") then
            local full = projects_root .. "/" .. item
            if ctx.is_dir(full) then
                if lang_buckets[item] then
                    local ok_sub, subs = pcall(fs.list, full)
                    if ok_sub and type(subs) == "table" then
                        for _, sub in ipairs(subs) do
                            local pdir = full .. "/" .. sub
                            if not sub:match("^%.") and ctx.is_dir(pdir) then
                                local norm_lang = (item == "C++") and "cpp" or item
                                local desc = get_project_description(pdir)
                                if not filter
                                    or sub:lower():find(filter, 1, true)
                                    or norm_lang:lower():find(filter, 1, true)
                                    or desc:lower():find(filter, 1, true)
                                then
                                    table.insert(list, {
                                        name = sub,
                                        lang = norm_lang,
                                        desc = desc,
                                        path = pdir,
                                    })
                                end
                            end
                        end
                    end
                else
                    local desc = get_project_description(full)
                    if not filter
                        or item:lower():find(filter, 1, true)
                        or desc:lower():find(filter, 1, true)
                    then
                        table.insert(list, {
                            name = item,
                            lang = "mixed",
                            desc = desc,
                            path = full,
                        })
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.lang ~= b.lang then return a.lang < b.lang end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

function main()
    local args = ctx.args or {}
    local section = "all"
    local filter = nil

    for _, a in ipairs(args) do
        if a == "help" or a == "-h" or a == "--help" then
            print_help()
            return
        elseif a == "modules" or a == "mod" or a == "m" then
            section = "modules"
        elseif a == "apps" or a == "app" or a == "a" then
            section = "apps"
        elseif a == "projects" or a == "proj" or a == "p" then
            section = "projects"
        elseif a == "all" then
            section = "all"
        elseif not a:match("^%-") then
            filter = a:lower()
        end
    end

    local out_names = {}
    local mods_count = 0

    if section == "all" or section == "modules" then
        local mods = collect_modules(filter)
        mods_count = #mods
        print(string.format("\n%s🧩 Модули GRIME (%d):%s", ANSI.BOLD, #mods, ANSI.RESET))
        local rows = {}
        for _, m in ipairs(mods) do
            table.insert(rows, { m.name, m.desc })
            if section == "modules" then table.insert(out_names, m.name) end
        end
        if #rows > 0 then
            ui.print_table(rows, { "Модуль", "Описание" })
        else
            print("  " .. ANSI.GRAY .. "(модули не найдены)" .. ANSI.RESET)
        end
    end

    if section == "all" or section == "apps" then
        local apps = collect_apps(filter)
        print(string.format("\n%s🚀 Микроприложения Grime Apps (%d):%s", ANSI.BOLD, #apps, ANSI.RESET))
        local rows = {}
        for _, a in ipairs(apps) do
            table.insert(rows, { a.name, a.lang, a.desc, a.path })
            if section == "apps" then table.insert(out_names, a.name) end
        end
        if #rows > 0 then
            ui.print_table(rows, { "Приложение", "Стек", "Описание", "Директория" })
        else
            print("  " .. ANSI.GRAY .. "(приложения не найдены)" .. ANSI.RESET)
        end
    end

    if section == "all" or section == "projects" then
        local projs = collect_projects(filter)
        print(string.format("\n%s📂 Проекты разработки (%d):%s", ANSI.BOLD, #projs, ANSI.RESET))
        local rows = {}
        for _, p in ipairs(projs) do
            table.insert(rows, { p.name, p.lang, p.desc, p.path })
            if section == "projects" then table.insert(out_names, p.path) end
        end
        if #rows > 0 then
            ui.print_table(rows, { "Проект", "Язык", "Описание", "Директория" })
        else
            print("  " .. ANSI.GRAY .. "(проекты не найдены)" .. ANSI.RESET)
        end
    end

    print()
    if ctx.has_next_step then
        ctx.module_return(table.concat(out_names, "\n"))
    else
        ctx.success(tostring(mods_count))
    end
end

return {
    main = main,
    description = description,
    get_module_description = get_module_description,
    get_app_info = get_app_info,
    get_project_description = get_project_description,
}
