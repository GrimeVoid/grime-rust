local helper = require("helper")
local ctx = helper.ctx

--- Получение корневой директории приложений
local function get_apps_root()
    local root = (ctx.paths and ctx.paths.apps)
        or (ctx.get_path and ctx.get_path("apps"))
        or (ctx.apps_root and ctx.apps_root())
    if not root or root == "" then
        local home = os.getenv("HOME") or ""
        root = (home ~= "" and (home .. "/.config/grime/apps")) or "./apps"
    end
    root = ctx.normalize_path(root)
    if not ctx.exists(root) then
        ctx.mkdir_p(root)
    end
    return root
end

--- Загрузка манифеста приложения из app.lua
local function load_manifest(app_dir, app_name)
    local manifest_path = app_dir .. "/app.lua"
    if not ctx.is_file(manifest_path) then
        return nil, "Манифест app.lua не найден: " .. manifest_path
    end

    local chunk, err = loadfile(manifest_path)
    if not chunk then
        return nil, "Ошибка синтаксиса манифеста: " .. tostring(err)
    end

    local ok, res = pcall(chunk)
    if not ok then
        return nil, "Ошибка выполнения манифеста: " .. tostring(res)
    end

    local manifest = (type(res) == "table") and res or {}
    manifest.name = manifest.name or app_name
    manifest.description = manifest.description or ""
    manifest.type = manifest.type or manifest.lang or "generic"
    manifest.box = manifest.box
    manifest.artifact = manifest.artifact
    if not manifest.artifact and manifest.run and type(manifest.run) == "string" and not manifest.run:find(" ") then
        manifest.artifact = manifest.run:gsub("^%./", "")
    end
    manifest.run = manifest.run or manifest.artifact
    manifest.detached = manifest.detached or false
    return manifest
end

--- Проверка статуса артефакта и готовности к запуску
local function check_artifact_status(app_dir, manifest)
    if not manifest.build and not manifest.artifact then
        return "ready", "Готово (скрипт)"
    end

    if not manifest.artifact or manifest.artifact == "" then
        return "no_artifact", "Артефакт не указан"
    end

    local artifact_path = app_dir .. "/" .. manifest.artifact
    if not ctx.exists(artifact_path) then
        return "not_built", "Не собран"
    end

    -- Проверяем, изменились ли исходные файлы после сборки артефакта
    local src_dir = app_dir .. "/src"
    local check_path = ctx.exists(src_dir) and src_dir or app_dir
    if ctx.is_newer(check_path, artifact_path) then
        return "needs_rebuild", "Требует пересборки"
    end

    return "built", "Собран"
end

--- Выполнение сборки приложения
local function build_app(app_name, manifest, app_dir)
    if not manifest.build or manifest.build == "" then
        ctx.log(string.format("Приложение '%s' не требует сборки.", app_name))
        return true
    end

    ctx.log(string.format("==> Сборка приложения '%s'...", app_name))

    local exit_code = 0
    local env = {
        GRIME_APP_NAME = app_name,
    }

    if manifest.box and manifest.box ~= "" then
        ctx.log(string.format("Сборка внутри окружения Distrobox '%s'...", manifest.box))
        local box_cmd
        if type(manifest.build) == "table" then
            box_cmd = { "distrobox", "enter", manifest.box, "--" }
            for _, arg in ipairs(manifest.build) do
                table.insert(box_cmd, arg)
            end
            exit_code = ctx.run_process(box_cmd, app_dir, env)
        else
            local shell_cmd = string.format("distrobox enter %s -- sh -c %q", manifest.box, manifest.build)
            exit_code = ctx.run_shell(shell_cmd, app_dir, env)
        end
    else
        if type(manifest.build) == "table" then
            exit_code = ctx.run_process(manifest.build, app_dir, env)
        else
            exit_code = ctx.run_shell(manifest.build, app_dir, env)
        end
    end

    if exit_code ~= 0 then
        ctx.fail(string.format("Ошибка сборки приложения '%s' (код %d)", app_name, exit_code))
        return false
    end

    if manifest.artifact and manifest.artifact ~= "" then
        local art_path = app_dir .. "/" .. manifest.artifact
        if not ctx.exists(art_path) then
            ctx.fail(string.format("Сборка завершилась, но артефакт '%s' не найден!", manifest.artifact))
            return false
        end
    end

    ctx.log(string.format("✓ Приложение '%s' успешно собрано.", app_name))
    return true
end

--- Запуск приложения
local function run_app(app_name, manifest, app_dir, run_args, is_detach)
    -- 1. Проверяем артефакт и при необходимости собираем
    if manifest.build and manifest.build ~= "" then
        local status, _ = check_artifact_status(app_dir, manifest)
        if status == "not_built" or status == "needs_rebuild" then
            ctx.log("Артефакт приложения отсутствует или устарел. Запуск автоматической сборки...")
            local ok = build_app(app_name, manifest, app_dir)
            if not ok then
                return 1
            end
        end
    end

    -- 2. Определение пути к Unix-сокету Grime
    local socket_path = os.getenv("GRIME_SOCKET")
    if not socket_path or socket_path == "" then
        local xdg = os.getenv("XDG_RUNTIME_DIR")
        if xdg and xdg ~= "" then
            socket_path = xdg .. "/grime.sock"
        else
            socket_path = "/tmp/grime.sock"
        end
    end

    local env = {
        GRIME_SOCKET = socket_path,
        GRIME_APP_NAME = app_name,
    }

    -- 3. Формирование команды запуска
    local run_target = manifest.run or manifest.artifact
    if not run_target or run_target == "" then
        ctx.fail("В манифесте app.lua не указана команда запуска (поле 'run' или 'artifact')!")
        return 1
    end

    local cmd_list = {}
    if type(run_target) == "table" then
        for _, item in ipairs(run_target) do
            table.insert(cmd_list, item)
        end
    else
        if not run_target:find(" ") and not run_target:find("^/") and not run_target:find("^%.") then
            table.insert(cmd_list, "./" .. run_target)
        else
            for word in run_target:gmatch("%S+") do
                table.insert(cmd_list, word)
            end
        end
    end

    for _, arg in ipairs(run_args) do
        table.insert(cmd_list, arg)
    end

    -- Запуск через Distrobox, если указано
    if manifest.box and manifest.box ~= "" then
        local box_cmd = { "distrobox", "enter", manifest.box, "--" }
        for _, c in ipairs(cmd_list) do
            table.insert(box_cmd, c)
        end
        cmd_list = box_cmd
    end

    -- 4. Фоновый запуск (detach)
    local should_detach = is_detach or manifest.detached
    if should_detach then
        local log_file = app_dir .. "/app.log"
        local quoted_cmd = {}
        for _, arg in ipairs(cmd_list) do
            table.insert(quoted_cmd, string.format("%q", arg))
        end
        local full_str = table.concat(quoted_cmd, " ")
        local bg_script = string.format("nohup %s > %q 2>&1 & echo $!", full_str, log_file)
        ctx.log(string.format("Запуск '%s' в фоновом режиме...", app_name))
        local res = ctx.capture(bg_script, app_dir, env)
        local pid = res.stdout:match("%d+")
        ctx.log(string.format("✓ Приложение запущено в фоне (PID: %s). Лог: %s", pid or "unknown", log_file))
        return 0
    end

    -- 5. Интерактивный запуск с пробросом TTY
    return ctx.run_process(cmd_list, app_dir, env)
end

--- Список установленных приложений
local function list_apps(apps_root)
    local dirs = {}
    local p = io.popen(string.format("ls -1 %q 2>/dev/null", apps_root))
    if p then
        for line in p:lines() do
            local item = line:match("^%s*(.-)%s*$")
            if item ~= "" and not item:match("^%.") and ctx.is_dir(apps_root .. "/" .. item) then
                table.insert(dirs, item)
            end
        end
        p:close()
    end

    table.sort(dirs)

    if #dirs == 0 then
        print(string.format("В каталоге %s нет установленных приложений.", apps_root))
        print("Используйте 'grime app new <имя>' для создания приложения.")
        return
    end

    local ANSI_BOLD = "\27[1m"
    local ANSI_RESET = "\27[0m"
    local ANSI_GREEN = "\27[32m"
    local ANSI_YELLOW = "\27[33m"
    local ANSI_RED = "\27[31m"
    local ANSI_CYAN = "\27[36m"
    local ANSI_BLUE = "\27[34m"

    print(string.format("\n%sУстановленные приложения Grime (%s):%s\n", ANSI_BOLD, apps_root, ANSI_RESET))
    local header_format = "%-18s %-10s %-12s %-24s %s"
    print(string.format(ANSI_BOLD .. header_format .. ANSI_RESET, "Имя", "Тип", "Окружение", "Статус", "Описание"))
    print(string.rep("─", 80))

    for _, name in ipairs(dirs) do
        local app_dir = apps_root .. "/" .. name
        local manifest, err = load_manifest(app_dir, name)
        if not manifest then
            print(string.format("%-18s %-10s %-12s %-24s %s", name, "unknown", "host", ANSI_RED .. "Поврежден манифест" .. ANSI_RESET, err or ""))
        else
            local status_code, status_label = check_artifact_status(app_dir, manifest)
            local status_colored = status_label
            if status_code == "built" or status_code == "ready" then
                status_colored = ANSI_GREEN .. status_label .. ANSI_RESET
            elseif status_code == "needs_rebuild" then
                status_colored = ANSI_YELLOW .. status_label .. ANSI_RESET
            else
                status_colored = ANSI_RED .. status_label .. ANSI_RESET
            end

            local env_label = (manifest.box and manifest.box ~= "") and (ANSI_CYAN .. "box:" .. manifest.box .. ANSI_RESET) or "host"
            local type_label = ANSI_BLUE .. (manifest.type or "generic") .. ANSI_RESET
            local desc = manifest.description or ""
            if #desc > 35 then
                desc = desc:sub(1, 32) .. "..."
            end
            print(string.format("%-18s %-19s %-21s %-33s %s", name, type_label, env_label, status_colored, desc))
        end
    end
    print()
end

--- Удаление приложения
local function rm_app(apps_root, app_name)
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
        return
    end

    local ok = ctx.delete(app_dir, true)
    if ok then
        ctx.log(string.format("✓ Приложение '%s' успешно удалено.", app_name))
    else
        ctx.fail(string.format("Не удалось удалить директорию: %s", app_dir))
    end
end

--- Рекурсивная замена плейсхолдеров в каталоге
local function replace_placeholders_in_dir(dir, replacements)
    local p = io.popen(string.format("find %q -type f 2>/dev/null", dir))
    if p then
        for raw_line in p:lines() do
            local file_path = raw_line:match("^%s*(.-)%s*$")
            if file_path ~= "" and ctx.is_file(file_path) then
                local f = io.open(file_path, "r")
                if f then
                    local content = f:read("*a")
                    f:close()
                    local changed = false
                    for placeholder, val in pairs(replacements) do
                        if content:find(placeholder, 1, true) then
                            content = content:gsub(placeholder, val)
                            changed = true
                        end
                    end
                    if changed then
                        local f_out = io.open(file_path, "w")
                        if f_out then
                            f_out:write(content)
                            f_out:close()
                        end
                    end
                end
            end
        end
        p:close()
    end
end

--- Развертывание шаблона и адаптация проекта приложения
local function scaffold_app_structure(app_dir, app_name, lang, prompt)
    if not ctx.exists(app_dir) then
        ctx.mkdir_p(app_dir)
    end

    -- Поиск шаблона
    local templates_root = (ctx.paths and ctx.paths.templates)
        or (ctx.get_path and ctx.get_path("templates"))
        or (ctx.templates_root and ctx.templates_root())
    if not templates_root or templates_root == "" then
        local home = os.getenv("HOME") or ""
        templates_root = (home ~= "" and (home .. "/.config/grime/templates")) or "./templates"
    end
    templates_root = ctx.normalize_path(templates_root)
    local tpl_dir = templates_root .. "/" .. lang
    if not ctx.exists(tpl_dir) then
        local dotfiles_tpl = "/home/danny/dotfiles/grime/templates/" .. lang
        if ctx.exists(dotfiles_tpl) then
            tpl_dir = dotfiles_tpl
        end
    end

    if ctx.exists(tpl_dir) then
        ctx.copy(tpl_dir, app_dir)
        ctx.log(string.format("Каркас проекта скопирован из шаблона '%s'", lang))
    else
        ctx.mkdir_p(app_dir .. "/src")
    end

    local desc = (prompt and prompt ~= "") and prompt or ("Grime application " .. app_name)
    desc = desc:gsub("\n", " "):gsub('"', '\\"')

    local snake_name = helper.to_snake_case(app_name)
    local replacements = {
        ["{{PROJECT_NAME}}"] = app_name,
        ["{{PROJECT_NAME_LOWER}}"] = app_name:lower(),
        ["{{PROJECT_NAME_UPPER}}"] = app_name:upper(),
        ["{{PROJECT_NAME_SNAKE}}"] = snake_name,
        ["{{PROJECT_DESCRIPTION}}"] = desc,
    }
    replace_placeholders_in_dir(app_dir, replacements)

    -- Генерация манифеста app.lua при необходимости
    local manifest_path = app_dir .. "/app.lua"
    if not ctx.is_file(manifest_path) then
        local m_content = ""
        if lang == "cpp" then
            m_content = string.format([[return {
    name = %q,
    description = "%s",
    type = "cpp",
    artifact = "build/%s",
    build = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
    run = "build/%s",
    box = nil,
    detached = false,
}
]], app_name, desc, app_name, app_name)
        elseif lang == "rust" then
            m_content = string.format([[return {
    name = %q,
    description = "%s",
    type = "rust",
    artifact = "target/release/%s",
    build = "cargo build --release",
    run = "target/release/%s",
    box = nil,
    detached = false,
}
]], app_name, desc, snake_name, snake_name)
        elseif lang == "python" then
            m_content = string.format([[return {
    name = %q,
    description = "%s",
    type = "python",
    artifact = "src/main.py",
    run = "python3 src/main.py",
    box = nil,
    detached = false,
}
]], app_name, desc)
        elseif lang == "java" then
            m_content = string.format([[return {
    name = %q,
    description = "%s",
    type = "java",
    artifact = "target/%s-1.0-SNAPSHOT.jar",
    build = "mvn package",
    run = "java -jar target/%s-1.0-SNAPSHOT.jar",
    box = nil,
    detached = false,
}
]], app_name, desc, app_name, app_name)
        elseif lang == "lua" then
            m_content = string.format([[return {
    name = %q,
    description = "%s",
    type = "lua",
    artifact = "src/main.lua",
    run = "lua src/main.lua",
    box = nil,
    detached = false,
}
]], app_name, desc)
        else
            m_content = string.format([[return {
    name = %q,
    description = "%s",
    type = %q,
    artifact = "main.lua",
    run = "lua main.lua",
    box = nil,
    detached = false,
}
]], app_name, desc, lang)
        end

        local f = io.open(manifest_path, "w")
        if f then
            f:write(m_content)
            f:close()
            ctx.log("Сгенерирован манифест app.lua")
        end
    end

    -- Инициализируем Git-репозиторий в каталоге приложения, если отсутствует
    if not ctx.exists(app_dir .. "/.git") then
        ctx.capture({ "git", "init" }, app_dir)
    end
end

--- Создание нового приложения: grime app new <name> [--lang <lang>] [prompt...]
local function new_app(apps_root, args)
    local explicit_lang = nil
    local app_name = nil
    local prompt_tokens = {}

    local i = 2
    while i <= #args do
        local a = args[i]
        if a == "--lang" or a == "-l" then
            if i + 1 <= #args and not args[i + 1]:match("^%-") then
                i = i + 1
                explicit_lang = args[i]:lower()
            end
        elseif not a:match("^%-") then
            if not app_name then
                app_name = a
            else
                table.insert(prompt_tokens, a)
            end
        end
        i = i + 1
    end

    if not app_name or app_name == "" then
        ctx.fail("Использование: grime app new <app_name> [--lang <lang>] [описание...]")
        return
    end

    local user_prompt = table.concat(prompt_tokens, " ")
    local app_dir = apps_root .. "/" .. app_name

    -- 1. Выбор стека технологий
    local selected_lang = explicit_lang
    if not selected_lang or selected_lang == "" then
        if user_prompt ~= "" then
            local config_aider = ctx.get_config("aider", "auto")
            local aider_bin = (config_aider ~= "" and config_aider ~= "auto") and config_aider or "aider"
            local classify_prompt = string.format([[Выбери оптимальный язык программирования для следующей задачи консольного приложения:
"%s"

Допустимые варианты: cpp, rust, python, java, lua.
Критерии выбора:
1. Ноль внешних зависимостей (zero external dependencies).
2. Максимальная скорость исполнения и производительность.
3. Минимальный вес артефакта и потребление ресурсов.

Ответь СТРОГО ОДНИМ СЛОВОМ из списка: cpp, rust, python, java, lua. Не добавляй никаких пояснений, знаков препинания или другого текста.]], user_prompt)
            ctx.log("Aider-Архитектор определяет оптимальный стек технологий...")
            local cres = ctx.capture({ aider_bin, "--no-git", "--exit", "--yes-always", "--no-fancy-input", "-m", classify_prompt })
            if cres.code == 0 and cres.stdout and cres.stdout ~= "" then
                local out_l = cres.stdout:lower()
                for _, l in ipairs({ "cpp", "rust", "python", "java", "lua" }) do
                    if out_l:find(l, 1, true) then
                        selected_lang = l
                        break
                    end
                end
            end
        end
        if not selected_lang or selected_lang == "" then
            selected_lang = "cpp"
        end
    end

    ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, selected_lang))

    -- 2. Скаффолдинг проекта
    scaffold_app_structure(app_dir, app_name, selected_lang, user_prompt)

    -- 3. Запуск субагента Aider внутри созданной папки приложения
    local grime_bin = os.getenv("GRIME_BIN")
    if not grime_bin or grime_bin == "" then
        local home = os.getenv("HOME") or ""
        local local_bin = home .. "/.local/bin/grime"
        if ctx.exists(local_bin) then
            grime_bin = local_bin
        else
            grime_bin = "grime"
        end
    end

    if user_prompt ~= "" then
        local dev_prompt = string.format("%s\n\n[GRIME APP REQUIREMENT]: Реализуй запрошенное консольное приложение. Убедись, что код компилируется и манифест app.lua содержит верное описание и команды сборки/запуска.", user_prompt)
        ctx.log(string.format("Запуск субагента Aider для реализации '%s'...", app_name))
        local code = ctx.run_process({ grime_bin, "aider", "-m", dev_prompt }, app_dir)
        if code ~= 0 then
            ctx.warn(string.format("Aider завершился с кодом %d", code))
        end
    else
        ctx.log("Запуск интерактивной сессии Aider для проектирования приложения...")
        ctx.run_process({ grime_bin, "aider" }, app_dir)
    end

    ctx.log(string.format("✓ Приложение '%s' создано в %s", app_name, app_dir))
    ctx.log(string.format("Для запуска выполните: grime app %s", app_name))
end

function main()
    local apps_root = get_apps_root()
    local raw_args = ctx.args or {}

    -- Извлекаем флаги --detach / -d
    local is_detach = false
    local filtered_args = {}
    for _, a in ipairs(raw_args) do
        if a == "--detach" or a == "-d" then
            is_detach = true
        else
            table.insert(filtered_args, a)
        end
    end

    if #filtered_args == 0 or filtered_args[1] == "list" or filtered_args[1] == "ls" then
        list_apps(apps_root)
        return
    end

    local subcmd = filtered_args[1]

    if subcmd == "new" or subcmd == "create" or subcmd == "init" then
        new_app(apps_root, filtered_args)
        return
    end

    if subcmd == "build" then
        local app_name = filtered_args[2]
        if not app_name or app_name == "" then
            ctx.fail("Укажите имя приложения: grime app build <app_name>")
            return
        end
        local app_dir = apps_root .. "/" .. app_name
        if not ctx.exists(app_dir) then
            ctx.fail(string.format("Приложение '%s' не найдено в %s", app_name, apps_root))
            return
        end
        local manifest, err = load_manifest(app_dir, app_name)
        if not manifest then
            ctx.fail(err)
            return
        end
        local ok = build_app(app_name, manifest, app_dir)
        if not ok then
            ctx.fail("Сборка не удалась.")
        end
        return
    end

    if subcmd == "rm" or subcmd == "remove" or subcmd == "delete" then
        local app_name = filtered_args[2]
        if not app_name or app_name == "" then
            ctx.fail("Укажите имя приложения: grime app rm <app_name>")
            return
        end
        rm_app(apps_root, app_name)
        return
    end

    -- Запуск приложения: grime app <app_name> [args]
    local app_name = subcmd
    local app_dir = apps_root .. "/" .. app_name
    if not ctx.exists(app_dir) then
        ctx.fail(string.format("Приложение '%s' не найдено в %s.\nИспользуйте 'grime app new %s' для его создания.", app_name, apps_root, app_name))
        return
    end

    local manifest, err = load_manifest(app_dir, app_name)
    if not manifest then
        ctx.fail(err)
        return
    end

    local app_run_args = {}
    for i = 2, #filtered_args do
        table.insert(app_run_args, filtered_args[i])
    end

    local code = run_app(app_name, manifest, app_dir, app_run_args, is_detach)
    if code ~= 0 then
        ctx.fail(string.format("Приложение '%s' завершилось с кодом %d", app_name, code))
    end
end
