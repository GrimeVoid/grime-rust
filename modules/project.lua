local classifier = require("classifier")
local ctx = grime.ctx

local ACTION_SYNONYMS = {
    delete = "delete", del = "delete", remove = "delete", rm = "delete", d = "delete",
    init = "init", new = "init", create = "init", i = "init",
    build = "build", b = "build", compile = "build", make = "build",
    run = "run", r = "run", start = "run", ["exec"] = "run",
    clear = "clear", clean = "clear", reset = "clear", cls = "clear",
    rename = "rename", ren = "rename", mv = "rename", move = "rename",
    path = "path", p = "path",
    help = "help",
}

local LANGUAGE_ADAPTERS = {
    cpp = require("languages.cpp"),
    python = require("languages.python"),
    rust = require("languages.rust"),
    java = require("languages.java"),
}

local LANGUAGE_ALIASES = {
    cpp = "cpp", ["c++"] = "cpp", c = "cpp",
    python = "python", py = "python",
    rust = "rust", rs = "rust",
    java = "java", jav = "java",
}

local function get_supported_languages()
    return { "cpp", "python", "rust", "java" }
end

local function detect_language(dir)
    for lang, adp in pairs(LANGUAGE_ADAPTERS) do
        if adp:detect(dir) then
            return lang
        end
    end
    return nil
end

local function get_projects_root()
    local root = (ctx.paths and ctx.paths.projects)
        or (ctx.get_path and ctx.get_path("projects"))
        or (ctx.projects_root and ctx.projects_root())
    if not root or root == "" then
        local home = os.getenv("HOME") or ""
        root = (home ~= "" and (home .. "/Projects")) or "./projects"
    end
    return ctx.normalize_path(root)
end

local function get_templates_root()
    local root = (ctx.paths and ctx.paths.templates)
        or (ctx.get_path and ctx.get_path("templates"))
        or (ctx.templates_root and ctx.templates_root())
    if not root or root == "" then
        local home = os.getenv("HOME") or ""
        root = (home ~= "" and (home .. "/.config/grime/templates")) or "./templates"
    end
    return ctx.normalize_path(root)
end

local function get_language_dir(projects_root, lang)
    projects_root = ctx.normalize_path(projects_root or get_projects_root())
    local candidates = {
        projects_root .. "/" .. lang,
        projects_root .. "/" .. lang:sub(1,1):upper() .. lang:sub(2),
        projects_root .. "/" .. lang:upper(),
    }
    if lang == "cpp" then
        table.insert(candidates, projects_root .. "/C++")
        table.insert(candidates, projects_root .. "/c++")
    end
    for _, cand in ipairs(candidates) do
        if ctx.exists(cand) then
            return cand
        end
    end
    return candidates[1]
end

local function find_project_dir(lang_dir, query)
    if not ctx.exists(lang_dir) then
        return nil
    end

    -- 1. Точное совпадение
    local exact = lang_dir .. "/" .. query
    if ctx.exists(exact) then
        return exact
    end

    -- Перечисление директорий
    local subdirs = {}
    local p = io.popen("ls -1 \"" .. lang_dir .. "\" 2>/dev/null")
    if p then
        for line in p:lines() do
            if not line:match("^%.") and ctx.exists(lang_dir .. "/" .. line) then
                table.insert(subdirs, line)
            end
        end
        p:close()
    end

    -- 2. Точное совпадение без учета регистра
    for _, name in ipairs(subdirs) do
        if name:lower() == query:lower() then
            return lang_dir .. "/" .. name
        end
    end

    -- 3. Префикс
    for _, name in ipairs(subdirs) do
        if name:lower():find("^" .. query:lower()) then
            return lang_dir .. "/" .. name
        end
    end

    -- 4. Подстрока
    for _, name in ipairs(subdirs) do
        if name:lower():find(query:lower(), 1, true) then
            return lang_dir .. "/" .. name
        end
    end

    -- 5. Нечеткий поиск с высоким порогом (порог 0.75)
    local best, score = grime.fuzzy.find_best_match(query, subdirs, 0.75)
    if best then
        ctx.log(string.format("Проект '%s' не найден, выбран похожий: '%s'", query, best))
        return lang_dir .. "/" .. best
    end

    return nil
end

local function handle_rename(projects_root, args)
    projects_root = ctx.normalize_path(projects_root)
    local clean_args = {}
    for _, a in ipairs(args) do
        if a ~= "rename" and a ~= "mv" and a ~= "path" and a ~= "-p" and a ~= "--path" then
            table.insert(clean_args, a)
        end
    end

    if #clean_args < 2 then
        ctx.fail("Использование: project rename <СтароеИмя> <НовоеИмя> [path]")
        return nil
    end

    local old_name, new_name = clean_args[1], clean_args[2]
    local renamed_path = nil

    for _, lang in ipairs(get_supported_languages()) do
        local old_dir = projects_root .. "/" .. lang .. "/" .. old_name
        local new_dir = projects_root .. "/" .. lang .. "/" .. new_name
        if ctx.exists(old_dir) then
            ctx.move(old_dir, new_dir)
            ctx.log(string.format("Проект %s/%s переименован в %s", lang, old_name, new_name))
            renamed_path = new_dir
        end
    end

    if not renamed_path then
        ctx.fail("Проект '" .. old_name .. "' не найден ни в одном языке для переименования!")
    end
    return renamed_path
end

local function resolve_project_context(parsed)
    local projects_root = get_projects_root()
    local supported_langs = get_supported_languages()

    local action = parsed.action or "path"
    local lang = parsed.categories.language
    local extra_args = parsed.command_tokens

    -- 1. Если пришли по конвейеру
    if ctx.pipeline_input then
        local target_dir = ctx.target_dir
        local detected_lang = lang or detect_language(target_dir) or "cpp"
        return action, target_dir, detected_lang, extra_args
    end

    -- 2. Если классификатор определил существующую директорию
    if parsed.target_dir and ctx.exists(parsed.target_dir) then
        local detected_lang = lang or detect_language(parsed.target_dir) or "cpp"
        return action, parsed.target_dir, detected_lang, extra_args
    end

    -- 3. Если передано позиционное имя проекта
    if #parsed.args > 0 then
        local project_name = parsed.args[1]
        if ctx.exists(project_name) then
            local detected_lang = lang or detect_language(project_name) or "cpp"
            return action, project_name, detected_lang, extra_args
        end

        if action == "init" then
            local target_lang_dir = get_language_dir(projects_root, lang or "cpp")
            local target_dir = target_lang_dir .. "/" .. project_name
            return action, target_dir, lang or "cpp", extra_args
        end

        if lang then
            local target_lang_dir = get_language_dir(projects_root, lang)
            local matched = find_project_dir(target_lang_dir, project_name)
            if matched then
                return action, matched, lang, extra_args
            end
            return action, target_lang_dir .. "/" .. project_name, lang, extra_args
        end

        -- Ищем по всем поддерживаемым языкам
        for _, candidate_lang in ipairs(supported_langs) do
            local candidate_lang_dir = get_language_dir(projects_root, candidate_lang)
            local matched = find_project_dir(candidate_lang_dir, project_name)
            if matched then
                return action, matched, candidate_lang, extra_args
            end
        end

        local default_lang = "cpp"
        local target_lang_dir = get_language_dir(projects_root, default_lang)
        return action, target_lang_dir .. "/" .. project_name, default_lang, extra_args
    end

    -- 4. Язык без имени проекта
    if lang then
        local target_lang_dir = get_language_dir(projects_root, lang)
        return action, target_lang_dir, lang, extra_args
    end

    -- 5. Текущая папка вызова
    local detected_lang = detect_language(ctx.target_dir)
    if detected_lang then
        return action, ctx.target_dir, detected_lang, extra_args
    end

    -- 6. Дефолтный проект
    local default_lang = lang or "cpp"
    local default_dir = get_language_dir(projects_root, default_lang) .. "/default_project"
    return action, default_dir, default_lang, extra_args
end

local function print_help()
    print(string.format([[
%s%sGrime Project%s — Управление проектами по языкам разработки

%sИСПОЛЬЗОВАНИЕ:%s
    grime project <команда> [язык] [имя_проекта] [аргументы...]
    grime project [язык] [имя_проекта] <команда>

%sКОМАНДЫ:%s
    %sinit, new, create%s      Создать новый проект по шаблону
                          grime project init cpp MyGame
                          grime project init rust Tool
    %sbuild, b, compile%s      Сборка проекта
                          grime project build MyGame
    %srun, r, start%s          Запуск проекта (с автосборкой при изменениях)
                          grime project run MyGame [аргументы...]
    %sdelete, rm%s             Удалить проект
                          grime project rm MyGame
    %sclear, clean, reset%s    Сбросить проект к чистому шаблону
                          grime project clear MyGame
    %srename, mv%s             Переименовать проект
                          grime project rename OldName NewName
    %spath, -p%s               Получить путь к директории проекта (для конвейеров)
                          grime project path MyGame
    %shelp, -h, --help%s       Показать эту справку

%sПОДДЕРЖИВАЕМЫЕ ЯЗЫКИ:%s
    cpp (C++), rust (Rust), python (Python), java (Java)

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime project MyGame path : cmd nvim CMakeLists.txt
    grime project MyTool path : aider "Добавь тесты для парсера"
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
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

    local projects_root = get_projects_root()

    local cls = classifier.new({
        actions = ACTION_SYNONYMS,
        default_action = nil,
        flags = {
            path_requested = { "path", "-p", "--path", "-path" },
            help = { "help", "-h", "--help" },
        },
        categories = { language = LANGUAGE_ALIASES },
        detect_dir = true,
    })

    local parsed = cls:parse(ctx.args, ctx.target_dir)

    if parsed.flags.help or parsed.action == "help" then
        print_help()
        return
    end
    local return_path_requested = parsed.flags.path_requested

    if parsed.action == "rename" then
        local renamed = handle_rename(projects_root, parsed.args)
        if return_path_requested and renamed then
            ctx.module_return(renamed)
        end
        return
    end

    local action, project_dir, lang, extra_args = resolve_project_context(parsed)
    if project_dir then
        project_dir = ctx.normalize_path(project_dir)
    end

    if action == "path" then
        if ctx.exists(project_dir) then
            ctx.module_return(project_dir)
            return
        else
            ctx.fail("проект или путь не найден: " .. tostring(project_dir))
            return
        end
    end

    local canonical_lang = LANGUAGE_ALIASES[lang:lower()] or lang
    local adapter = LANGUAGE_ADAPTERS[canonical_lang]
    if not adapter then
        ctx.fail("адаптер для языка '" .. lang .. "' не найден!")
        return
    end

    if action == "init" then
        ctx.mkdir_p(project_dir)
        adapter:init_project(project_dir, ctx)
        ctx.log(string.format("Проект под %s инициализирован: %s", lang, project_dir))
        if return_path_requested then
            ctx.module_return(project_dir)
        end
    elseif action == "build" then
        if not ctx.exists(project_dir) then
            ctx.fail("директория проекта " .. project_dir .. " не найдена!")
            return
        end
        local ok = adapter:build(project_dir, ctx)
        if not ok then
            ctx.fail("Сборка проекта завершилась ошибкой.")
            return
        end
        ctx.log("Сборка успешно завершена!")
        if return_path_requested then
            local target = adapter:get_target(project_dir)
            ctx.module_return(target or project_dir)
        end
    elseif action == "run" then
        if not ctx.exists(project_dir) then
            ctx.fail("директория проекта " .. project_dir .. " не найдена!")
            return
        end

        local target = adapter:get_target(project_dir)
        local src_dir = project_dir .. "/" .. adapter.src_dir
        if not target or ctx.needs_rebuild(src_dir, target) then
            ctx.log("Обнаружены изменения в исходниках. Запуск сборки...")
            if not adapter:build(project_dir, ctx) then
                ctx.fail("Сборка упала, запуск отменен.")
                return
            end
        end

        adapter:run(project_dir, extra_args, ctx)
        if return_path_requested then
            ctx.module_return(project_dir)
        end
    elseif action == "delete" then
        if not ctx.exists(project_dir) then
            ctx.fail("проект не найден: " .. project_dir)
            return
        end
        ctx.delete(project_dir)
        ctx.log(string.format("Проект (%s) успешно удален: %s", lang, project_dir))
        if return_path_requested then
            ctx.module_return(project_dir)
        end
    elseif action == "clear" then
        if ctx.exists(project_dir) then
            ctx.delete(project_dir)
        end
        ctx.mkdir_p(project_dir)
        adapter:init_project(project_dir, ctx)
        ctx.log(string.format("Проект (%s) сброшен к заводским настройкам: %s", lang, project_dir))
        if return_path_requested then
            ctx.module_return(project_dir)
        end
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
