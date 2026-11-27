--@grime description: Единый реестр модулей GRIME, приложений и проектов разработки
--@grime requires: module:app?, module:project?
--@grime alias: ls, modules

--[[
    Grime List Module (Unified Inventory: Modules, Apps & Projects)
    Единый каталог установленных декларативных модулей GRIME,
    локальных микроприложений (Grime Apps) и проектов пользователя.
]]


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
    grime list [секция|-флаг] [фильтр]

%sСЕКЦИИ И ФЛАГИ (поддерживаются с '-' / '--' и без):%s
    %sall, --all%s                       Показать сводку всех модулей, приложений и проектов (по умолчанию)
    %smodules, mod, -m, --modules%s      Показать установленные декларативные модули GRIME
    %sapps, app, -a, --apps%s            Показать локальные микроприложения Grime Apps
    %sprojects, proj, -p, --projects%s   Показать проекты разработки по языкам
    %shelp, -h, --help%s                 Показать эту справку

%sПРИМЕРЫ:%s
    grime list                    # Полный обзор экосистемы GRIME
    grime list -modules           # Список всех модулей оркестратора
    grime list --apps             # Список приложений Grime Apps
    grime list -p                 # Список проектов пользователя
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

--- Описание модуля GRIME из реестра ядра (аннотация `--@grime description:`)
local function get_module_description(name)
    local meta = grime.modules and grime.modules.get(name)
    if meta and type(meta.description) == "string" and meta.description ~= "" then
        return meta.description
    end
    return "Декларативный модуль GRIME"
end

--- Извлечение описания приложения Grime App
local function get_app_info(app_dir)
    local lang = "custom"
    local desc = ""
    local app_file = app_dir .. "/app.lua"

    -- Манифест читается в песочнице (быстро, без загрузки тяжёлого app.lua)
    local manifest
    if ctx.exists(app_file) then
        manifest = utils.load_manifest_sandboxed(app_file)
    end
    if manifest then
        lang = tostring(manifest.type or manifest.lang or "custom")
        desc = tostring(manifest.description or "")
    else
        -- Zero-Manifest App: проверяем мета-файл привязки или синтезируем через app.load_manifest / scanner
        local link_meta = utils.read_app_link_meta(app_dir)
        if link_meta then
            if type(link_meta.lang) == "string" and link_meta.lang ~= "" then
                lang = link_meta.lang
            end
            if type(link_meta.description) == "string" and link_meta.description ~= "" then
                desc = link_meta.description
            end
        end

        local app_name = app_dir:match("([^/]+)$") or "app"
        local ok_app, app_mod = pcall(require, "app")
        if ok_app and type(app_mod) == "table" and app_mod.load_manifest then
            local m = app_mod.load_manifest(app_dir, app_name)
            if m then
                if lang == "custom" and m.type and m.type ~= "" and m.type ~= "generic" then
                    lang = tostring(m.type)
                end
                if desc == "" and m.description and m.description ~= "" then
                    desc = tostring(m.description)
                end
            end
        end

        -- Определение стека сканером (общие адаптеры языков) только если манифест не помог
        if lang == "custom" then
            local ok_scan, scanner = pcall(require, "languages.scanner")
            if ok_scan and scanner and scanner.scan_project then
                local scan = scanner.scan_project(app_dir, ctx)
                if scan and scan.languages and #scan.languages > 0 then
                    lang = scan.languages[1]
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

local function collect_modules(filter)
    local list = {}
    for _, meta in ipairs((grime.modules and grime.modules.list()) or {}) do
        local desc = get_module_description(meta.name)
        if not filter or meta.name:lower():find(filter, 1, true) or desc:lower():find(filter, 1, true) then
            table.insert(list, {
                name = meta.name,
                desc = desc,
                path = meta.path,
            })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

--- Приложения: перечисление делегировано app.collect_apps (единый источник правды), здесь только фильтр и описание
local function collect_apps(filter)
    local apps_root = utils.get_named_path("apps", HOME .. "/.config/grime/apps", ctx)
    if not ctx.exists(apps_root) then return {} end
    local ok_app, app_mod = pcall(require, "app")
    if not ok_app or type(app_mod) ~= "table" or type(app_mod.collect_apps) ~= "function" then return {} end

    local list = {}
    for _, a in ipairs(app_mod.collect_apps(apps_root)) do
        local lang, desc = get_app_info(a.path)
        if not filter or a.name:lower():find(filter, 1, true) or lang:lower():find(filter, 1, true) or desc:lower():find(filter, 1, true) then
            table.insert(list, { name = a.name, lang = lang, desc = desc, path = a.path })
        end
    end
    table.sort(list, function(x, y) return x.name:lower() < y.name:lower() end)
    return list
end

--- Проекты пользователя: сбор делегирован модулю project (единый источник правды)
local function collect_projects(filter)
    local ok, project = pcall(require, "project")
    if not ok or type(project) ~= "table" or type(project.collect_projects) ~= "function" then
        error("модуль project не экспортирует collect_projects: обновите modules/project.lua", 0)
    end
    local list = {}
    for _, p in ipairs(project.collect_projects({}) or {}) do
        local desc = p.description
        if type(desc) ~= "string" or desc == "" then
            desc = get_project_description(p.path)
        end
        local lang = p.lang or "mixed"
        if not filter
            or p.name:lower():find(filter, 1, true)
            or lang:lower():find(filter, 1, true)
            or desc:lower():find(filter, 1, true)
        then
            table.insert(list, { name = p.name, lang = lang, desc = desc, path = p.path })
        end
    end
    table.sort(list, function(a, b)
        if a.lang ~= b.lang then return a.lang < b.lang end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

local function main()
    local args = ctx.args or {}
    local section = "all"
    local filter = nil

    for _, a in ipairs(args) do
        local raw = tostring(a)
        if grime.args.is_flag(raw) then
            local clean = grime.args.strip_dashes(raw)
            if clean == "help" or clean == "h" then
                print_help()
                return
            elseif clean == "modules" or clean == "module" or clean == "mod" or clean == "m" then
                section = "modules"
            elseif clean == "apps" or clean == "app" or clean == "a" then
                section = "apps"
            elseif clean == "projects" or clean == "project" or clean == "proj" or clean == "p" then
                section = "projects"
            elseif clean == "all" then
                section = "all"
            end
        else
            filter = raw:lower()
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
    get_module_description = get_module_description,
    get_app_info = get_app_info,
    get_project_description = get_project_description,
}
