local argparse = require("languages.argparse")
local ctx = grime.ctx

local ACTION_SYNONYMS = {
    list = "list", ls = "list", l = "list", show = "list",
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
    lua = require("languages.lua"),
}

local LANGUAGE_ALIASES = {
    cpp = "cpp", ["c++"] = "cpp", c = "cpp",
    python = "python", py = "python",
    rust = "rust", rs = "rust",
    java = "java", jav = "java",
    lua = "lua", luajit = "lua",
}

local function get_supported_languages()
    return { "cpp", "python", "rust", "java", "lua" }
end

local function detect_language(dir)
    for _, lang in ipairs(get_supported_languages()) do
        local adp = LANGUAGE_ADAPTERS[lang]
        if adp and adp:detect(dir) then
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

    -- Перечисление директорий без вызова шелла
    local subdirs = {}
    local entries = (grime and grime.fs and grime.fs.list and grime.fs.list(lang_dir)) or {}
    for _, line in ipairs(entries) do
        if line ~= "" and not line:match("^%.") and ctx.exists(lang_dir .. "/" .. line) then
            table.insert(subdirs, line)
        end
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
    local best, _ = grime.fuzzy.find_best_match(query, subdirs, 0.75)
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
        local lang_dir = get_language_dir(projects_root, lang)
        local old_dir = lang_dir .. "/" .. old_name
        local new_dir = lang_dir .. "/" .. new_name
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

local function resolve_abs_path(p)
    local cur_pwd = os.getenv("PWD") or "."
    if not p or p == "" or p == "." then
        local t = ctx.target_dir
        if t and #t > 0 and t ~= "." then return t end
        return cur_pwd
    end
    if p:find("^~") then
        p = (os.getenv("HOME") or "") .. p:sub(2)
    end
    if not p:find("^/") then
        local base = (ctx.target_dir and #ctx.target_dir > 0 and ctx.target_dir ~= ".") and ctx.target_dir or cur_pwd
        p = base .. "/" .. p
    end
    local norm = ctx.normalize_path(p)
    if not norm or norm == "" then
        return cur_pwd
    end
    return norm
end

local function resolve_project_context(parsed)
    local projects_root = get_projects_root()
    local supported_langs = get_supported_languages()

    local action = parsed.action or "path"
    local lang = parsed.categories.language
    local extra_args = {}

    -- 1. Если классификатор явно определил существующую директорию в аргументах
    if parsed.target_dir and ctx.exists(parsed.target_dir) then
        for _, a in ipairs(parsed.args) do table.insert(extra_args, a) end
        for _, a in ipairs(parsed.command_tokens) do table.insert(extra_args, a) end
        local abs_dir = resolve_abs_path(parsed.target_dir)
        local detected_lang = lang or detect_language(abs_dir) or "cpp"
        return action, abs_dir, detected_lang, extra_args
    end

    -- 2. Если явно передано позиционное имя проекта или путь в аргументах (приоритет над pipeline_input)
    if #parsed.args > 0 then
        local project_name = parsed.args[1]
        for i = 2, #parsed.args do table.insert(extra_args, parsed.args[i]) end
        for _, a in ipairs(parsed.command_tokens) do table.insert(extra_args, a) end

        if action == "init" then
            if project_name == "." or project_name:find("^%./") or project_name:find("^/") or project_name:find("^~") then
                return action, resolve_abs_path(project_name), lang or "cpp", extra_args
            end

            local target_lang_dir = get_language_dir(projects_root, lang or "cpp")
            local target_dir = target_lang_dir .. "/" .. project_name
            return action, target_dir, lang or "cpp", extra_args
        end

        if ctx.exists(project_name) and ctx.is_dir(project_name) then
            local abs_dir = resolve_abs_path(project_name)
            local detected_lang = lang or detect_language(abs_dir) or "cpp"
            return action, abs_dir, detected_lang, extra_args
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

    for _, a in ipairs(parsed.command_tokens) do table.insert(extra_args, a) end

    -- 3. Если имя не передано, проверяем вход из конвейера (ctx.pipeline_input / ctx.input)
    local pipe_in = ctx.pipeline_input or ctx.input
    if pipe_in then
        local trimmed_in = grime.str.trim(tostring(pipe_in))
        local target_dir = nil
        if #trimmed_in > 0 and ctx.exists(trimmed_in) and ctx.is_dir(trimmed_in) then
            target_dir = resolve_abs_path(trimmed_in)
        elseif ctx.target_dir and ctx.exists(ctx.target_dir) and ctx.is_dir(ctx.target_dir) then
            target_dir = resolve_abs_path(ctx.target_dir)
        end
        if target_dir then
            local detected_lang = lang or detect_language(target_dir) or "cpp"
            return action, target_dir, detected_lang, extra_args
        end
    end

    -- 4. Язык без имени проекта
    if lang then
        if action == "init" then
            return action, resolve_abs_path("."), lang, extra_args
        end
        local target_lang_dir = get_language_dir(projects_root, lang)
        return action, target_lang_dir, lang, extra_args
    end

    -- 5. Запрос пути без указания проекта -> возвращаем корень проектов
    if action == "path" then
        return action, projects_root, "cpp", extra_args
    end

    -- 6. Текущая папка вызова
    local cur_abs = resolve_abs_path(".")
    local detected_lang = detect_language(cur_abs)
    if detected_lang then
        return action, cur_abs, detected_lang, extra_args
    end

    -- 7. Дефолтный проект
    local default_lang = lang or "cpp"
    local default_dir = get_language_dir(projects_root, default_lang) .. "/default_project"
    return action, default_dir, default_lang, extra_args
end

local function handle_list(projects_root, parsed, return_path_requested)
    projects_root = ctx.normalize_path(projects_root)
    local target_lang = parsed.categories and parsed.categories.language or nil
    local filter = (parsed.args and #parsed.args > 0) and parsed.args[1]:lower() or nil

    local list = {}
    local seen_paths = {}

    local langs_to_scan = target_lang and { target_lang } or get_supported_languages()
    for _, lang in ipairs(langs_to_scan) do
        local lang_dir = get_language_dir(projects_root, lang)
        if ctx.exists(lang_dir) and ctx.is_dir(lang_dir) then
            local entries = (grime and grime.fs and grime.fs.list and grime.fs.list(lang_dir)) or {}
            for _, item in ipairs(entries) do
                if item ~= "" and not item:match("^%.") then
                    local pdir = ctx.normalize_path(lang_dir .. "/" .. item)
                    if ctx.is_dir(pdir) and not seen_paths[pdir] then
                        if not filter or item:lower():find(filter, 1, true) or lang:lower():find(filter, 1, true) then
                            seen_paths[pdir] = true
                            table.insert(list, { name = item, lang = lang, path = pdir })
                        end
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b)
        if a.lang ~= b.lang then return a.lang < b.lang end
        return a.name:lower() < b.name:lower()
    end)

    print(string.format("\n\27[1m📂 Проекты разработки (%d):\27[0m", #list))
    if #list > 0 then
        local rows = {}
        for _, p in ipairs(list) do
            table.insert(rows, { p.name, p.lang, p.path })
        end
        if grime and grime.ui and grime.ui.print_table then
            grime.ui.print_table(rows, { "Проект", "Язык", "Директория" })
        else
            for _, p in ipairs(list) do
                print(string.format("  %-22s %-10s %s", p.name, p.lang, p.path))
            end
        end
    else
        print("  \27[90m(проекты не найдены)\27[0m")
    end
    print()

    if ctx.has_next_step or return_path_requested then
        local out_paths = {}
        for _, p in ipairs(list) do
            table.insert(out_paths, p.path)
        end
        ctx.module_return(table.concat(out_paths, "\n"))
    end
end

local function print_help()
    print(string.format([[
%s%sGrime Project%s — Управление проектами по языкам разработки

%sИСПОЛЬЗОВАНИЕ:%s
    grime project <команда> [язык] [имя_проекта] [аргументы...]
    grime project [язык] [имя_проекта] <команда>

%sКОМАНДЫ:%s
    %slist, ls%s               Показать список проектов разработки
                          grime project list [язык] [фильтр]
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
    cpp (C++), rust (Rust), python (Python), java (Java), lua (Lua/LuaJIT)

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
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    local raw_args = ctx.args or {}
    if #raw_args == 0 and not ctx.pipeline_input and not ctx.input then
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

    local cls = argparse.new({
        actions = ACTION_SYNONYMS,
        default_action = nil,
        flags = {
            path_requested = { "path", "-p", "--path", "-path" },
            help = { "help", "-h", "--help" },
            force = { "-f", "--force", "-force" },
            nix = { "--nix" },
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

    if parsed.action == "list" then
        handle_list(projects_root, parsed, return_path_requested)
        return
    end

    if parsed.action == "rename" then
        local renamed = handle_rename(projects_root, parsed.args)
        if return_path_requested and renamed then
            if ctx.set_target_dir then ctx.set_target_dir(renamed) end
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
            if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
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
        local is_forced = (ctx.force == true)
            or (ctx.flags and ctx.flags.force == true)
            or (parsed.flags and parsed.flags.force == true)

        if ctx.exists(project_dir) then
            local is_empty = true
            local files = (grime and grime.fs and grime.fs.list) and grime.fs.list(project_dir) or {}
            for _, f in ipairs(files) do
                if f ~= "." and f ~= ".." then
                    is_empty = false
                    break
                end
            end
            if not is_empty and not is_forced then
                ctx.fail(string.format("Директория '%s' уже существует и не пуста! Используйте --force для перезаписи.", project_dir))
                return
            end
        end

        ctx.mkdir_p(project_dir)
        adapter:init_project(project_dir, ctx)
        ctx.log(string.format("Проект под %s инициализирован: %s", lang, project_dir))
        if ctx.has_next_step or return_path_requested then
            if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
            ctx.module_return(project_dir)
        end
    elseif action == "build" then
        if not ctx.exists(project_dir) then
            ctx.fail("директория проекта " .. project_dir .. " не найдена!")
            return
        end

        local use_nix = (parsed.flags and parsed.flags.nix) or false
        local missing_tools = {}

        if not use_nix and not os.getenv("IN_NIX_SHELL") and adapter.check_dependencies then
            local ok, missing = adapter:check_dependencies(ctx, project_dir)
            if not ok then
                use_nix = true
                missing_tools = missing
            end
        end

        if use_nix and not os.getenv("IN_NIX_SHELL") then
            if #missing_tools > 0 then
                ctx.log(string.format("⚡ [Grime Smart Fallback] На хосте отсутствуют утилиты: %s. Автопереключение сборки в изолированный Nix...", table.concat(missing_tools, ", ")))
            else
                ctx.log("⚡ [Grime Nix] Сборка перенаправлена в изолированное Nix-окружение (--nix)...")
            end
            local code = ctx.run_process({ "grime", "nix", "build", project_dir })
            if code ~= 0 then
                ctx.fail("Сборка в изолированном Nix окружении завершилась с ошибкой.")
                return
            end
            ctx.log("Сборка успешно завершена через Nix!")
            if ctx.has_next_step or return_path_requested then
                if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
                local target = adapter:get_target(project_dir)
                ctx.module_return(return_path_requested and project_dir or (target or project_dir))
            end
            return
        end

        local ok = adapter:build(project_dir, ctx)
        if not ok then
            ctx.fail("Сборка проекта завершилась ошибкой.")
            return
        end
        ctx.log("Сборка успешно завершена!")
        if ctx.has_next_step or return_path_requested then
            if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
            local target = adapter:get_target(project_dir)
            ctx.module_return(return_path_requested and project_dir or (target or project_dir))
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
            local use_nix = (parsed.flags and parsed.flags.nix) or false
            local missing_tools = {}
            if not use_nix and not os.getenv("IN_NIX_SHELL") and adapter.check_dependencies then
                local ok, missing = adapter:check_dependencies(ctx, project_dir)
                if not ok then
                    use_nix = true
                    missing_tools = missing
                end
            end
            if use_nix and not os.getenv("IN_NIX_SHELL") then
                if #missing_tools > 0 then
                    ctx.log(string.format("⚡ [Grime Smart Fallback] На хосте отсутствуют утилиты: %s. Автопереключение сборки в изолированный Nix...", table.concat(missing_tools, ", ")))
                end
                local code = ctx.run_process({ "grime", "nix", "build", project_dir })
                if code ~= 0 then
                    ctx.fail("Сборка упала в Nix, запуск отменен.")
                    return
                end
            else
                if not adapter:build(project_dir, ctx) then
                    ctx.fail("Сборка упала, запуск отменен.")
                    return
                end
            end
        end

        local ret = adapter:run(project_dir, extra_args, ctx)
        if ret and ret ~= 0 then
            ctx.fail(string.format("Выполнение проекта завершилось с ошибкой (код %d).", ret))
            return
        end
        if ctx.has_next_step or return_path_requested then
            if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
            ctx.module_return(project_dir)
        end
    elseif action == "delete" then
        if not ctx.exists(project_dir) then
            ctx.fail("проект не найден: " .. project_dir)
            return
        end
        ctx.delete(project_dir)
        ctx.log(string.format("Проект (%s) успешно удален: %s", lang, project_dir))
        if ctx.has_next_step or return_path_requested then
            ctx.module_return(project_dir)
        end
    elseif action == "clear" then
        if ctx.exists(project_dir) then
            ctx.delete(project_dir)
        end
        ctx.mkdir_p(project_dir)
        adapter:init_project(project_dir, ctx)
        ctx.log(string.format("Проект (%s) сброшен к заводским настройкам: %s", lang, project_dir))
        if ctx.has_next_step or return_path_requested then
            if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
            ctx.module_return(project_dir)
        end
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
