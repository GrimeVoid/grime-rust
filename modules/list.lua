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

local MODULE_DESCRIPTIONS = {
    aider   = "AI-ассистент парного программирования, генерации кода и скаффолдинга",
    app     = "Управление жизненным циклом локальных микроприложений (Grime Apps)",
    box     = "Оркестрация контейнеров Distrobox / Podman и экспорт бинарников",
    bus     = "Управление шиной состояния (StateBus) и событиями (EventBus)",
    cmd     = "Выполнение внешних команд в контексте целевой директории конвейера",
    daemon  = "Управление фоновым сервисом-демоном GRIME и терминальным контекстом",
    doctor  = "Комплексная диагностика системного окружения, путей и журнала сбоев",
    git     = "Декларативные операции Git (status, commit, log, diff, snapshot)",
    host    = "Информация о хост-системе и переключение в домашнюю директорию",
    list    = "Единый реестр модулей GRIME, приложений и проектов разработки",
    log     = "Централизованный сбор, хранение и фильтрация логов системы",
    nix     = "Оркестратор изолированных сред Nix Flakes, сборок и профилей",
    pkg     = "Унифицированный менеджер пакетов хоста, Nix, Flatpak, Cargo и Distrobox",
    project = "Полиглот-оркестратор проектов (C++, Rust, Python, Java, Lua)",
}

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
            local desc = MODULE_DESCRIPTIONS[name] or "Декларативный модуль GRIME"
            if not filter or name:lower():find(filter, 1, true) or desc:lower():find(filter, 1, true) then
                table.insert(list, {
                    name = name,
                    desc = desc,
                    path = mod_dir .. "/" .. item,
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
            local lang = "unknown"
            local desc = ""
            local app_file = app_dir .. "/app.lua"
            if ctx.exists(app_file) then
                local chunk = loadfile(app_file, "t", {})
                if chunk then
                    local ok_m, m = pcall(chunk)
                    if ok_m and type(m) == "table" then
                        lang = tostring(m.type or m.lang or "custom")
                        desc = tostring(m.description or "")
                    end
                end
            end
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
                                if not filter or sub:lower():find(filter, 1, true) or norm_lang:lower():find(filter, 1, true) then
                                    table.insert(list, { name = sub, lang = norm_lang, path = pdir })
                                end
                            end
                        end
                    end
                else
                    if not filter or item:lower():find(filter, 1, true) then
                        table.insert(list, { name = item, lang = "mixed", path = full })
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
            table.insert(rows, { a.name, a.lang, a.desc ~= "" and a.desc or a.path })
            if section == "apps" then table.insert(out_names, a.name) end
        end
        if #rows > 0 then
            ui.print_table(rows, { "Приложение", "Стек", "Описание / Путь" })
        else
            print("  " .. ANSI.GRAY .. "(приложения не найдены)" .. ANSI.RESET)
        end
    end

    if section == "all" or section == "projects" then
        local projs = collect_projects(filter)
        print(string.format("\n%s📂 Проекты разработки (%d):%s", ANSI.BOLD, #projs, ANSI.RESET))
        local rows = {}
        for _, p in ipairs(projs) do
            table.insert(rows, { p.name, p.lang, p.path })
            if section == "projects" then table.insert(out_names, p.path) end
        end
        if #rows > 0 then
            ui.print_table(rows, { "Проект", "Язык", "Директория" })
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
