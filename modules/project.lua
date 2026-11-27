--@grime description: Полиглот-оркестратор проектов (C++, Rust, Python, Java, Lua, Bash, Fish)
--@grime alias: proj
--@grime requires: module:nix
--@grime default: true
--@grime path.projects: ~/Projects
--@grime path.templates: ~/.config/grime/templates


local ctx = grime.ctx
local utils = require("languages.utils")

local ACTION_SYNONYMS = {
    ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["--ls"] = "list", ["-l"] = "list",
    ["-delete"] = "delete", ["--delete"] = "delete", ["-del"] = "delete", ["-remove"] = "delete", ["--remove"] = "delete", ["-rm"] = "delete", ["--rm"] = "delete", ["-d"] = "delete",
    ["-init"] = "init", ["--init"] = "init", ["-new"] = "init", ["--new"] = "init", ["-create"] = "init", ["--create"] = "init", ["-i"] = "init",
    ["-build"] = "build", ["--build"] = "build", ["-b"] = "build", ["-compile"] = "build", ["--compile"] = "build", ["-make"] = "build",
    ["-run"] = "run", ["--run"] = "run", ["-r"] = "run", ["-start"] = "run", ["--start"] = "run", ["-exec"] = "run", ["--exec"] = "run",
    ["-clear"] = "clear", ["--clear"] = "clear", ["-clean"] = "clear", ["--clean"] = "clear", ["-reset"] = "clear", ["-cls"] = "clear",
    ["-rename"] = "rename", ["--rename"] = "rename", ["-ren"] = "rename", ["-mv"] = "rename", ["--mv"] = "rename", ["-move"] = "rename",
    ["-path"] = "path", ["--path"] = "path", ["-p"] = "path",
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
}

local LANGUAGE_ADAPTERS = {
    cpp = require("languages.cpp"),
    rust = require("languages.rust"),
    python = require("languages.python"),
    java = require("languages.java"),
    lua = require("languages.lua"),
    bash = require("languages.bash"),
    fish = require("languages.fish"),
}

--- Поддерживаемые языки в каноническом порядке (utils.LANG_ORDER)
local function get_supported_languages()
    return utils.LANG_ORDER
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

--- Корень проектов с выводом ошибки при отсутствии настройки
local function get_projects_root()
    local root, err = utils.get_projects_root(ctx)
    if not root then
        ctx.fail(err)
        return nil
    end
    return root
end

--- Каталог-«корзина» языка: существующий вариант регистра либо предпочтительное имя для создания
local function get_language_dir(projects_root, lang)
    projects_root = ctx.normalize_path(projects_root or get_projects_root())
    local names = utils.lang_dir_names(lang)
    if #names == 0 then names = { lang } end
    for _, n in ipairs(names) do
        local cand = projects_root .. "/" .. n
        if ctx.exists(cand) then
            return cand
        end
    end
    return projects_root .. "/" .. names[1]
end

--- Краткое описание проекта (grime.json, Cargo.toml, первая строка README) либо ""
local function project_description(pdir)
    local function read(path)
        if not ctx.exists(path) then return nil end
        local ok, content = pcall(grime.fs.read, path)
        return ok and type(content) == "string" and content or nil
    end
    local function cut(s)
        s = s:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if #s > 70 then s = s:sub(1, 70):gsub("[\128-\191]*$", ""):gsub("[\192-\255]$", "") .. "…" end
        return s
    end
    local j = read(pdir .. "/grime.json")
    local d = j and j:match('"description"%s*:%s*"([^"]*)"')
    if d and d ~= "" then return cut(d) end
    local c = read(pdir .. "/Cargo.toml")
    d = c and c:match('description%s*=%s*"([^"]+)"')
    if d and d ~= "" then return cut(d) end
    for _, rn in ipairs({ "README.md", "readme.md", "README" }) do
        local r = read(pdir .. "/" .. rn)
        if r then
            for line in r:gmatch("[^\r\n]+") do
                local t = line:match("^%s*(.-)%s*$")
                if #t >= 5 and not t:match("^[#%[<|>%-=]") then return cut(t) end
            end
        end
    end
    return ""
end

--- Сбор проектов из корня проектов и extra_roots.
--- opts = { lang = <язык>|nil, extra_roots = {пути}|nil, no_desc = bool }.
--- Возвращает массив { name, lang, path, bucket, description }; плоские проекты (без бакета) имеют lang="mixed".
local function collect_projects(opts)
    opts = opts or {}
    local want = opts.lang and (utils.LANG_ALIASES[tostring(opts.lang):lower()] or tostring(opts.lang):lower()) or nil
    local roots = {}
    local pr = utils.get_projects_root(ctx)
    if pr then roots[#roots + 1] = pr end
    for _, r in ipairs(opts.extra_roots or {}) do
        if type(r) == "string" and r ~= "" then roots[#roots + 1] = ctx.normalize_path(r) end
    end

    local list, seen = {}, {}
    local function add(name, lang, path, bucket)
        if seen[path] then return end
        seen[path] = true
        list[#list + 1] = {
            name = name, lang = lang, path = path, bucket = bucket,
            description = opts.no_desc and "" or project_description(path),
        }
    end
    local function entries(dir)
        local ok, items = pcall(grime.fs.list, dir)
        return (ok and type(items) == "table") and items or {}
    end

    for _, root in ipairs(roots) do
        if ctx.exists(root) and ctx.is_dir(root) then
            for _, item in ipairs(entries(root)) do
                local full = root .. "/" .. item
                if item ~= "" and not item:match("^%.") and ctx.is_dir(full) then
                    local bucket_lang = utils.LANG_ALIASES[item:lower()]
                    if bucket_lang then
                        if not want or want == bucket_lang then
                            for _, sub in ipairs(entries(full)) do
                                local pdir = full .. "/" .. sub
                                if sub ~= "" and not sub:match("^%.") and ctx.is_dir(pdir) then
                                    add(sub, bucket_lang, ctx.normalize_path(pdir), item)
                                end
                            end
                        end
                    elseif not want then
                        add(item, "mixed", ctx.normalize_path(full), nil)
                    end
                end
            end
        end
    end

    local order = {}
    for i, l in ipairs(utils.LANG_ORDER) do order[l] = i end
    table.sort(list, function(a, b)
        if a.lang ~= b.lang then
            local oa, ob = order[a.lang] or 99, order[b.lang] or 99
            if oa ~= ob then return oa < ob end
            return a.lang < b.lang
        end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

--- Поиск проекта по запросу. opts = { lang, exact, extra_roots }.
--- Порядок: точное имя, регистронезависимое, префикс, подстрока, fuzzy (0.75).
--- Возвращает path, lang, name либо nil.
local function find_project(query, opts)
    opts = opts or {}
    if type(query) ~= "string" or not utils.valid_name(query) then
        return nil
    end
    local cands = collect_projects({ lang = opts.lang, extra_roots = opts.extra_roots, no_desc = true })
    if #cands == 0 then return nil end

    local function result(p)
        return p.path, (p.lang ~= "mixed" and p.lang) or detect_language(p.path) or "mixed", p.name
    end

    local q = query:lower()
    for _, p in ipairs(cands) do
        if p.name == query then return result(p) end
    end
    for _, p in ipairs(cands) do
        if p.name:lower() == q then return result(p) end
    end
    if opts.exact then return nil end

    for _, p in ipairs(cands) do
        if p.name:lower():sub(1, #q) == q then return result(p) end
    end
    for _, p in ipairs(cands) do
        if p.name:lower():find(q, 1, true) then return result(p) end
    end

    local names = {}
    for _, p in ipairs(cands) do names[#names + 1] = p.name end
    local best = grime.fuzzy.find_best_match(query, names, 0.75)
    if best then
        for _, p in ipairs(cands) do
            if p.name == best then
                ctx.log(string.format("Проект '%s' не найден, выбран похожий: '%s'", query, best))
                return result(p)
            end
        end
    end
    return nil
end

--- Точный поиск проекта строго по имени внутри projects_root: <язык-каталог>/<имя>.
--- Возвращает список { lang, path }. Без префиксов, подстрок, fuzzy и путей от CWD.
local function find_exact_projects(projects_root, name, lang_filter)
    local found, seen = {}, {}
    local langs = lang_filter and { lang_filter } or get_supported_languages()
    for _, lang in ipairs(langs) do
        local lang_dir = get_language_dir(projects_root, lang)
        local pdir = lang_dir .. "/" .. name
        if ctx.exists(lang_dir) and ctx.is_dir(pdir) and not seen[pdir] then
            seen[pdir] = true
            table.insert(found, { lang = lang, path = ctx.normalize_path(pdir) })
        end
    end
    return found
end

local function handle_rename(projects_root, args, lang_filter)
    projects_root = ctx.normalize_path(projects_root)
    if not args or #args < 2 then
        ctx.fail("Использование: project -rename <СтароеИмя> <НовоеИмя>")
        return nil
    end

    local old_name, new_name = args[1], args[2]
    for _, n in ipairs({ old_name, new_name }) do
        local ok, err = utils.valid_name(n)
        if not ok then
            ctx.fail(string.format("Недопустимое имя проекта '%s': %s", tostring(n), err))
            return nil
        end
    end
    local renamed_path = nil

    for _, found in ipairs(find_exact_projects(projects_root, old_name, lang_filter)) do
        local new_dir = ctx.normalize_path(get_language_dir(projects_root, found.lang) .. "/" .. new_name)
        if ctx.exists(new_dir) then
            ctx.fail(string.format("Проект '%s' (%s) уже существует, переименование отменено", new_name, found.lang))
            return nil
        end
        ctx.move(found.path, new_dir)
        ctx.log(string.format("Проект %s/%s переименован в %s", found.lang, old_name, new_name))
        renamed_path = new_dir
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

            local name_ok, name_err = utils.valid_name(project_name)
            if not name_ok then
                ctx.fail(string.format("Недопустимое имя проекта '%s': %s", project_name, name_err))
                return nil, nil, nil, nil
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
            local matched = find_project(project_name, { lang = lang })
            if matched then
                return action, matched, lang, extra_args
            end
            return action, get_language_dir(projects_root, lang) .. "/" .. project_name, lang, extra_args
        end

        -- Ищем по всем поддерживаемым языкам
        local matched, matched_lang = find_project(project_name)
        if matched then
            return action, matched, matched_lang, extra_args
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
        if action == "path" then
            local target_lang_dir = get_language_dir(projects_root, lang)
            return action, target_lang_dir, lang, extra_args
        end
        -- Предохранитель: запрещено трогать корень языка для разрушительных или сборочных действий
        ctx.fail(string.format("Укажите имя проекта: grime project -%s <имя_проекта>", action))
        return nil, nil, nil, nil
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

--- Удаление/сброс проекта: только по точному имени внутри projects_root и с подтверждением
local function handle_destructive(projects_root, parsed, return_path_requested)
    projects_root = ctx.normalize_path(projects_root)
    local act_name = (parsed.action == "delete") and "-rm" or "--clear"
    local name = parsed.args[1]
    if not name then
        ctx.fail(string.format("Укажите имя проекта: grime project %s <имя_проекта>", act_name))
        return
    end
    local ok, err = utils.valid_name(name)
    if not ok then
        ctx.fail(string.format("Недопустимое имя проекта '%s': %s", name, err))
        return
    end

    local found = find_exact_projects(projects_root, name, parsed.categories.language)
    -- Защита: путь строго <root>/<lang-bucket>/<name> (ровно два уровня) и внутри projects_root
    do
        local safe = {}
        for _, f in ipairs(found) do
            local rel = f.path:sub(1, #projects_root + 1) == (projects_root .. "/") and f.path:sub(#projects_root + 2) or nil
            local bucket, leaf = nil, nil
            if rel then bucket, leaf = rel:match("^([^/]+)/([^/]+)$") end
            if bucket and leaf == name and not rel:find("..", 1, true) then
                table.insert(safe, f)
            else
                ctx.log(string.format("Отказ: путь '%s' не является проектом <корень>/<язык>/<имя> в %s", f.path, projects_root))
            end
        end
        found = safe
    end
    if #found == 0 then
        ctx.fail(string.format("Проект '%s' не найден точно по имени в %s", name, projects_root))
        return
    end
    if #found > 1 then
        local langs = {}
        for _, f in ipairs(found) do table.insert(langs, f.lang) end
        ctx.fail(string.format("Имя '%s' неоднозначно (языки: %s). Укажите язык: grime project %s -<язык> %s",
            name, table.concat(langs, ", "), act_name, name))
        return
    end

    local target = found[1]
    local verb = (parsed.action == "delete") and "Удалить" or "Сбросить к чистому шаблону"
    if not utils.confirm_destructive(string.format("%s проект '%s' (%s)?", verb, name, target.path), parsed.flags.yes, ctx) then
        return
    end

    if parsed.action == "delete" then
        ctx.delete(target.path)
        ctx.log(string.format("Проект (%s) успешно удален: %s", target.lang, target.path))
        if ctx.has_next_step or return_path_requested then
            ctx.module_return(target.path)
        end
        return
    end

    local adapter = LANGUAGE_ADAPTERS[target.lang]
    ctx.delete(target.path)
    ctx.mkdir_p(target.path)
    adapter:init_project(target.path, ctx)
    ctx.log(string.format("Проект (%s) сброшен к заводским настройкам: %s", target.lang, target.path))
    if ctx.has_next_step or return_path_requested then
        if ctx.set_target_dir then ctx.set_target_dir(target.path) end
        ctx.module_return(target.path)
    end
end

--- Есть ли у цели запуска исполняемый артефакт. Для компилируемых языков исходник
--- (например, src/main.cpp из entry_files базового адаптера) бинарником не считается.
local COMPILED_SRC_EXT = { cpp = true, cc = true, cxx = true, c = true, h = true, hpp = true, rs = true, java = true }
local function has_binary(lang, target)
    if not target or not ctx.exists(target) then return false end
    if lang == "cpp" or lang == "rust" or lang == "java" then
        local ext = target:match("%.([%w]+)$")
        if ext and COMPILED_SRC_EXT[ext:lower()] then return false end
    end
    return true
end

--- Сборка проекта: на хосте либо в изолированном Nix (флаг --nix или нехватка утилит).
--- Возвращает ok, via_nix
local function build_project(adapter, project_dir, parsed)
    local use_nix = (parsed.flags and parsed.flags.nix) or false
    local missing_tools = {}
    local in_nix_shell = os.getenv("IN_NIX_SHELL")

    if not use_nix and not in_nix_shell and adapter.check_dependencies then
        local ok, missing = adapter:check_dependencies(ctx, project_dir)
        if not ok then
            use_nix = true
            missing_tools = missing
        end
    end

    if use_nix and not in_nix_shell then
        if #missing_tools > 0 then
            ctx.log(string.format("⚡ [Grime Smart Fallback] На хосте отсутствуют утилиты: %s. Автопереключение сборки в изолированный Nix...", table.concat(missing_tools, ", ")))
        else
            ctx.log("⚡ [Grime Nix] Сборка перенаправлена в изолированное Nix-окружение (--nix)...")
        end
        return ctx.run_process({ utils.self_exe(), "nix", "build", project_dir }) == 0, true
    end

    return adapter:build(project_dir, ctx) and true or false, false
end

--- Нужно ли запускать проект через nix develop: сборка шла через nix, задан --nix, либо на хосте нет
--- нужного рантайма/компилятора, а nix доступен. Внутри nix-оболочки запуск идёт как обычно.
local function should_run_via_nix(adapter, project_dir, parsed, built_via_nix)
    if os.getenv("IN_NIX_SHELL") then return false end
    if not utils.has_binary("nix", ctx) then return false end
    if built_via_nix or (parsed.flags and parsed.flags.nix) then return true end
    if adapter.check_dependencies then
        local ok = adapter:check_dependencies(ctx, project_dir)
        return not ok
    end
    return false
end

--- Токены запуска проекта в nix develop (чистая функция): nil, ошибка — если команды запуска нет.
local function nix_run_tokens(adapter, project_dir, extra_args)
    local run_cmd = adapter:get_run_command(project_dir, extra_args)
    if not run_cmd then
        return nil, "точка входа для запуска не найдена в " .. project_dir
    end
    local esc = {}
    for _, t in ipairs(run_cmd) do esc[#esc + 1] = utils.shell_escape(t) end
    local inner = "cd " .. utils.shell_escape(project_dir) .. " && exec " .. table.concat(esc, " ")
    return require("nix").develop_command(project_dir, { "bash", "-c", inner })
end

local function handle_list(projects_root, parsed, return_path_requested)
    local target_lang = parsed.categories and parsed.categories.language or nil
    local filter = (parsed.args and #parsed.args > 0) and parsed.args[1]:lower() or nil

    local list = {}
    for _, p in ipairs(collect_projects({ lang = target_lang, no_desc = true })) do
        if not filter or p.name:lower():find(filter, 1, true) or p.lang:lower():find(filter, 1, true) then
            table.insert(list, p)
        end
    end

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
    grime project <команда|-флаг> [язык] [имя_проекта] [аргументы...]
    grime project [язык] [имя_проекта] <команда|-флаг>

%sКОМАНДЫ И ФЛАГИ ДЕЙСТВИЙ (с '-' / '--' или без):%s
    %s-l, --list, list, ls%s       Показать список проектов разработки
                              grime project -list [язык] [фильтр]
    %s-i, --init, init, new%s      Создать новый проект по шаблону
                              grime project -init cpp MyGame
                              grime project init rust Tool
    %s-b, --build, build%s         Сборка проекта
                              grime project -build MyGame
    %s-r, --run, run, start%s      Запуск проекта (с автосборкой при изменениях)
                              grime project -run MyGame [-- аргументы...]
    %s-rm, --delete, delete, rm%s  Удалить проект
                              grime project -rm MyGame
    %s--clear, clear, clean%s      Сбросить проект к чистому шаблону
                              grime project --clear MyGame
    %s--rename, rename, mv%s       Переименовать проект
                              grime project --rename OldName NewName
    %s-p, --path, path%s           Получить путь к директории проекта (для конвейеров)
                              grime project -path MyGame
    %s--nix, -nix%s                Принудительная сборка/запуск в изолированном Nix Flake
    %s--force, -f%s                Перезаписать непустую директорию при инициализации
    %s--yes, -y%s                  Подтвердить удаление/сброс без вопроса (-rm, --clear)
    %s-h, --help, help%s           Показать эту справку

%sПОДДЕРЖИВАЕМЫЕ ЯЗЫКИ:%s
    cpp (-cpp, C++), rust (-rust, -rs), python (-python, -py), java (-java), lua (-lua),
    bash (-bash, -sh), fish (-fish)

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime project MyGame -path : cmd nvim CMakeLists.txt
    grime project MyTool -path : ai "Добавь тесты для парсера"
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
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function main()
    local raw_args = ctx.args or {}
    if #raw_args == 0 and not ctx.pipeline_input and not ctx.input then
        print_help()
        return
    end

    for _, a in ipairs(raw_args) do
        if a == "--" or a == "//" then break end
        local matched = (type(a) == "string" and a:match("^%-")) and grime.fuzzy.match_flag(a, { "--help", "-h", "-help" }, 0.75) or a
        if matched == "--help" or matched == "-h" or matched == "-help" then
            print_help()
            return
        end
    end

    local projects_root = get_projects_root()
    if not projects_root then return end

    local parsed = ctx.parse_args({
        actions = ACTION_SYNONYMS,
        default_action = nil,
        flags = {
            path = { "-p", "--path", "-path" },
            path_requested = { "-p", "--path", "-path" },
            help = { "-h", "--help", "-help" },
            force = { "-f", "--force", "-force" },
            yes = { "-y", "--yes", "-yes" },
            nix = { "--nix", "-nix" },
        },
        value_flags = {
            lang = { "--lang", "-lang" },
        },
        categories = { language = utils.LANG_ALIASES },
        detect_dir = false,
    })

    -- Действие без дефиса в первой позиции (project init rust Tool, project list): только если дефисного действия нет
    if not parsed.action and parsed.args and #parsed.args > 0 then
        local bare = ACTION_SYNONYMS["-" .. tostring(parsed.args[1]):lower()]
        if bare and bare ~= "help" then
            parsed.action = bare
            table.remove(parsed.args, 1)
        end
    end

    -- Язык без дефиса в первой позиции (project -init rust Tool, project rust Tool -init):
    -- считаем языком, если за ним есть имя проекта либо действие init/path (одиночное слово в build/run — имя проекта)
    if not parsed.categories.language and parsed.args and #parsed.args > 0 then
        local first = tostring(parsed.args[1]):lower()
        local canon = utils.LANG_ALIASES[first]
        if canon and (#parsed.args >= 2 or parsed.action == "init" or parsed.action == "path") then
            parsed.categories.language = canon
            table.remove(parsed.args, 1)
        end
    end

    if parsed.flags.lang and type(parsed.flags.lang) == "string" then
        local l_low = parsed.flags.lang:lower():gsub("^%-+", "")
        parsed.categories.language = utils.LANG_ALIASES[l_low] or l_low
    end

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
        local renamed = handle_rename(projects_root, parsed.args, parsed.categories.language)
        if return_path_requested and renamed then
            if ctx.set_target_dir then ctx.set_target_dir(renamed) end
            ctx.module_return(renamed)
        end
        return
    end

    if parsed.action == "delete" or parsed.action == "clear" then
        handle_destructive(projects_root, parsed, return_path_requested)
        return
    end

    local action, project_dir, lang, extra_args = resolve_project_context(parsed)
    if not action or not project_dir then
        return
    end
    project_dir = ctx.normalize_path(project_dir)

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

    local canonical_lang = utils.LANG_ALIASES[lang:lower()] or lang
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
        local init_desc = (#extra_args > 0) and table.concat(extra_args, " ") or nil
        adapter:init_project(project_dir, ctx, init_desc)
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

        local ok, via_nix = build_project(adapter, project_dir, parsed)
        if not ok then
            ctx.fail(via_nix and "Сборка в изолированном Nix окружении завершилась с ошибкой."
                or "Сборка проекта завершилась ошибкой.")
            return
        end
        ctx.log(via_nix and "Сборка успешно завершена через Nix!" or "Сборка успешно завершена!")
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
        local via_nix = false
        if not has_binary(canonical_lang, target) or ctx.needs_rebuild(src_dir, target) then
            ctx.log("Обнаружены изменения в исходниках. Запуск сборки...")
            local ok
            ok, via_nix = build_project(adapter, project_dir, parsed)
            if not ok then
                ctx.fail(via_nix and "Сборка упала в Nix, запуск отменен." or "Сборка упала, запуск отменен.")
                return
            end
            target = adapter:get_target(project_dir)
        end

        if not has_binary(canonical_lang, target) then
            ctx.fail(string.format("Исполняемый файл проекта не найден в %s (путь запуска: %s). Сборка не создала бинарник в каталоге проекта%s.",
                project_dir, tostring(target), via_nix and " (сборка через Nix кладёт результат вне проекта)" or ""))
            return
        end
        local ret
        if should_run_via_nix(adapter, project_dir, parsed, via_nix) then
            local tokens, nerr = nix_run_tokens(adapter, project_dir, extra_args)
            if not tokens then
                ctx.fail("Не удалось подготовить запуск через Nix: " .. tostring(nerr))
                return
            end
            ctx.log("⚡ [Grime Nix] На хосте нет нужного рантайма/флаг --nix: запуск в изолированном Nix-окружении...")
            ret = ctx.run_process(tokens, project_dir)
        else
            ret = adapter:run(project_dir, extra_args, ctx)
        end
        if ret and ret ~= 0 then
            ctx.fail(string.format("Выполнение проекта завершилось с ошибкой (код %d).", ret))
            return
        end
        if ctx.has_next_step or return_path_requested then
            if ctx.set_target_dir then ctx.set_target_dir(project_dir) end
            ctx.module_return(project_dir)
        end
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end

return {
    main = main,
    find_project = find_project,
    collect_projects = collect_projects,
    build_project = build_project,
    nix_run_tokens = nix_run_tokens,
    should_run_via_nix = should_run_via_nix,
}
