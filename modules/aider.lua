local ctx = grime.ctx

local GRIME_CONVENTIONS = [[

[GRIME AGENT CONVENTIONS]:
1. ВЫПОЛНЕНИЕ СИСТЕМНЫХ ДЕЙСТВИЙ (ОБЯЗАТЕЛЬНО):
При запросах на системные действия (копирование 'cp', перемещение 'mv', создание директорий 'mkdir', удаление, архивация, запуск утилит) модель ОБЯЗАНА не просто советовать команду текстом, а РЕАЛЬНО ВЫПОЛНИТЬ её в одну строку через системный тег:
<grime_spawn module="cmd">cp -r . /home/danny/Temp</grime_spawn>
или
<grime_exec>cp -r . /home/danny/Temp</grime_exec>
ВНИМАНИЕ: Команда выполняется непосредственно в текущей рабочей директории ('.'). Указывайте пути относительно текущей директории '.' или абсолютные пути внутри $HOME. Команды формируйте компактно в одну строку. Использование sudo и изменение системных файлов за пределами $HOME строго запрещены!

2. Для сохранения структурированных данных или состояния в шину Grime используйте тег:
<grime_bus key="pipeline.<key>" type="json">
{"field": "value"}
</grime_bus>
(Допустимые пространства имен: 'pipeline.*', 'modules.<name>.*').

3. Для порождения субагента Grime (вызова другого модуля) используйте тег:
<grime_spawn module="<module_name>" cwd="<optional_cwd>">
инструкция или аргументы для модуля
</grime_spawn>

4. Для передачи промпта следующему шагу конвейера:
<next_agent_prompt>
инструкция для следующего агента
</next_agent_prompt>
]]

--- Проверка, является ли директория частью Git-репозитория
local function is_git_repo(dir)
    if not dir or dir == "" then return false end
    if ctx.exists(dir .. "/.git") then
        return true
    end
    local res = ctx.capture({ "git", "-C", dir, "rev-parse", "--is-inside-work-tree" })
    if res.code == 0 and res.stdout and res.stdout:match("true") then
        return true
    end
    return false
end

--- Разрешение пути или проекта по имени
local function resolve_dir_or_project(arg)
    if not arg or arg == "" or arg:match("^%-") then
        return nil
    end

    -- 1. Проверяем, существует ли как директория на диске
    if ctx.is_dir(arg) then
        return arg
    end

    local norm_arg = ctx.normalize_path and ctx.normalize_path(arg)
    if norm_arg and ctx.is_dir(norm_arg) then
        return norm_arg
    end

    -- 2. Проверяем в projects_root
    local projects_root = (ctx.paths and ctx.paths.projects)
        or (ctx.get_path and ctx.get_path("projects"))
        or (ctx.projects_root and ctx.projects_root())
    if not projects_root or projects_root == "" then
        local home = os.getenv("HOME") or ""
        projects_root = (home ~= "" and (home .. "/Projects")) or "./projects"
    end
    projects_root = ctx.normalize_path(projects_root)
    if projects_root and ctx.exists(projects_root) then
        for _, lang in ipairs({ "cpp", "python", "rust", "java", "lua", "C++" }) do
            local cand = projects_root .. "/" .. lang .. "/" .. arg
            if ctx.is_dir(cand) then
                return cand
            end
        end
        local direct = projects_root .. "/" .. arg
        if ctx.is_dir(direct) then
            return direct
        end
    end

    return nil
end

--- Рекурсивная замена плейсхолдеров в директории
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

--- Определение оптимального стека через Aider
local function classify_stack(user_prompt)
    if not user_prompt or user_prompt == "" then
        return "cpp"
    end
    local low = user_prompt:lower()
    if low:find("python") or low:find("питон") then return "python" end
    if low:find("rust") or low:find("раст") then return "rust" end
    if low:find("cpp") or low:find("c%+%+") or low:find("си%+%+") then return "cpp" end
    if low:find("java") or low:find("джава") then return "java" end
    if low:find("lua") or low:find("луа") then return "lua" end

    local config_aider = ctx.get_config and ctx.get_config("aider", "auto") or "auto"
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
    local cres = ctx.capture({ "timeout", "5", aider_bin, "--no-git", "--exit", "--yes-always", "--no-fancy-input", "-m", classify_prompt })
    if cres.code == 0 and cres.stdout and cres.stdout ~= "" then
        local out_l = cres.stdout:lower()
        for _, l in ipairs({ "cpp", "rust", "python", "java", "lua" }) do
            if out_l:find(l, 1, true) then
                return l
            end
        end
    end
    return "cpp"
end

--- Запуск субагента Aider для реализации приложения
local function run_dev(app_dir, prompt, app_name)
    local grime_bin = os.getenv("GRIME_BIN") or "grime"
    if prompt and prompt ~= "" then
        local dev_prompt = string.format("%s\n\n[GRIME APP REQUIREMENT]: Реализуй запрошенное консольное приложение. Убедись, что код компилируется и манифест app.lua содержит верное описание и команды сборки/запуска.", prompt)
        ctx.log(string.format("Запуск субагента Aider для реализации '%s'...", app_name or "app"))
        local code = ctx.run_process({ "timeout", "5", grime_bin, "aider", "-m", dev_prompt }, app_dir)
        if code ~= 0 then
            ctx.warn(string.format("Aider завершился с кодом %d (продолжаем с базовым шаблоном)", code))
        end
        return code
    else
        ctx.log("Запуск интерактивной сессии Aider для проектирования приложения...")
        return ctx.run_process({ grime_bin, "aider" }, app_dir)
    end
end

--- Получение корня каталога приложений
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

--- Скаффолдинг структуры приложения
local function scaffold_app(app_dir, app_name, lang, prompt)
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

    -- Плейсхолдеры для замены
    local snake_name = grime.str.to_snake_case(app_name)
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

    -- Инициализируем Git-репозиторий в папке приложения, если он еще не инициализирован
    if not is_git_repo(app_dir) then
        ctx.capture({ "git", "init" }, app_dir)
    end
end

--- Проверка безопасности команд перед исполнением
local function validate_command_security(cmd_str, target_dir)
    if not cmd_str or cmd_str == "" then
        return false, "[Grime Security] Команда отклонена: пустая команда."
    end

    local lower = " " .. cmd_str:lower() .. " "
    local normalized = lower:gsub("[|&;()<>]", " ")

    -- 1. БЕЗУСЛОВНЫЙ ЗАПРЕТ SUDO / ПОВЫШЕНИЯ ПРИВИЛЕГИЙ
    if normalized:match("%s+sudo%s+")
        or normalized:match("%s+su%s+")
        or normalized:match("%s+doas%s+")
        or normalized:match("%s+pkexec%s+")
        or normalized:match("%s+chown%s+.*root")
        or normalized:match("%s+chmod%s+.*%s+/")
        or normalized:match("%s+chmod%s+777") then
        return false, "[Grime Security] Команда отклонена: вызовы с правами суперпользователя (sudo) запрещены."
    end

    -- 2. ЗАПРЕТ ОПАСНЫХ ШАБЛОНОВ
    if normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+/%s*$")
        or normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+/%*")
        or normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+~")
        or normalized:match("rm%s+.*%-[a-z]*r[a-z]*%s+%$home")
        or normalized:match("%f[%a]mkfs%f[%A]")
        or normalized:match("%f[%a]fdisk%f[%A]")
        or normalized:match("%f[%a]parted%f[%A]")
        or normalized:match("%f[%a]dd%s+.*of=%s*/dev/")
        or lower:match(">+%s*/dev/[a-z0-9]") then
        return false, "[Grime Security] Команда отклонена: обнаружен опасный деструктивный шаблон."
    end

    -- 3. БЕЗУСЛОВНЫЙ ЗАПРЕТ НА ИЗМЕНЕНИЕ СИСТЕМНЫХ ФАЙЛОВ
    local home = os.getenv("HOME") or "/home/danny"
    local sys_dirs = { "/etc", "/usr", "/var", "/boot", "/opt", "/root", "/nix", "/sys", "/proc", "/dev", "/bin", "/sbin", "/lib", "/lib64" }

    local eff_cwd = target_dir or "."
    for _, sdir in ipairs(sys_dirs) do
        if eff_cwd == "/" or eff_cwd == sdir or eff_cwd:sub(1, #sdir + 1) == (sdir .. "/") then
            return false, "[Grime Security] Команда отклонена: попытка модификации системных файлов за пределами домашней директории."
        end
    end

    for token in cmd_str:gmatch("[^%s|;&()]+") do
        local clean = token:gsub("^['\"]+", ""):gsub("['\"]+$", ""):gsub("^>+", "")
        if clean:sub(1, 1) == "/" then
            if not clean:find(home, 1, true) then
                if clean == "/" then
                    return false, "[Grime Security] Команда отклонена: попытка модификации системных файлов за пределами домашней директории."
                end
                for _, sdir in ipairs(sys_dirs) do
                    if clean == sdir or clean:sub(1, #sdir + 1) == (sdir .. "/") then
                        return false, "[Grime Security] Команда отклонена: попытка модификации системных файлов за пределами домашней директории."
                    end
                end
            end
        end
    end

    return true, nil
end

--- Выполнение системного действия с информированием и валидацией безопасности
local function execute_ai_action(cmd_str, target_dir, source_tag)
    cmd_str = cmd_str:match("^%s*(.-)%s*$")
    if not cmd_str or cmd_str == "" then
        return false
    end

    -- Нормализация soft-wrap от rich/aider консоли: склеиваем строки, разорванные форматированием
    local clean_lines = {}
    for line in cmd_str:gmatch("[^\r\n]+") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" then
            table.insert(clean_lines, trimmed)
        end
    end

    local normalized_cmd = ""
    for i, line in ipairs(clean_lines) do
        if i == 1 then
            normalized_cmd = line
        else
            local prev_ends_with_op = normalized_cmd:match("[;&|]$") or normalized_cmd:match("&&$") or normalized_cmd:match("\\$")
            local is_continuation = line:match("^[%-~/%.]") or (not prev_ends_with_op and not line:match("^[%a_][%w_]*%s"))
            if is_continuation and not prev_ends_with_op then
                normalized_cmd = normalized_cmd .. " " .. line
            else
                normalized_cmd = normalized_cmd .. "\n" .. line
            end
        end
    end
    cmd_str = normalized_cmd

    local ok, err_msg = validate_command_security(cmd_str, target_dir)
    if not ok then
        io.stderr:write(string.format("\27[1;31m%s\27[0m\n", err_msg))
        ctx.warn(err_msg)
        return false, err_msg
    end

    io.stdout:write(string.format("\27[1;32m[Grime AI Execution] Выполняю действие: %s\27[0m\n", cmd_str))
    ctx.log(string.format("[Grime AI Execution] Выполняю действие: %s (cwd=%s)", cmd_str, target_dir or "."))

    local home = os.getenv("HOME") or "/home/danny"
    local shell_cmd = cmd_str:gsub("~/", home .. "/")

    -- Если Aider вывел относительный путь от корня git-репозитория (например 'ghostty/config.ghostty'),
    -- а рабочей директорией уже является эта самая папка 'ghostty', устраняем лишний префикс
    if target_dir then
        local folder_name = target_dir:match("([^/]+)$")
        if folder_name and folder_name ~= "" then
            local prefix_pattern = "%f[%w]" .. folder_name .. "/"
            if shell_cmd:find(prefix_pattern) then
                -- Проверяем, существует ли файл без префикса
                local cand_cmd = shell_cmd:gsub(prefix_pattern, "")
                shell_cmd = cand_cmd
            end
        end
    end

    local res = ctx.capture({ "sh", "-c", shell_cmd }, target_dir)
    if res.stdout and res.stdout ~= "" then
        io.stdout:write(res.stdout)
        if not res.stdout:match("\n$") then
            io.stdout:write("\n")
        end
    end
    if res.stderr and res.stderr ~= "" then
        io.stderr:write(res.stderr)
        if not res.stderr:match("\n$") then
            io.stderr:write("\n")
        end
    end

    if res.code == 0 then
        ctx.log(string.format("✓ Действие успешно выполнено: %s", cmd_str))
        return true, nil
    else
        local fail_msg = string.format("Действие завершилось с кодом %d: %s", res.code, res.stderr or "")
        ctx.warn(fail_msg)
        return false, fail_msg
    end
end

--- Умный фоллбэк: если пользователь просит действие, а модель вывела shell-команду в markdown без тега
local function handle_action_fallback(user_prompt, output, working_dir, has_executed_action)
    if has_executed_action then
        return
    end
    if not user_prompt or user_prompt == "" or not output or output == "" then
        return
    end

    local p_low = user_prompt:lower()
    local is_action_request = false
    local action_keywords = {
        "скопируй", "скопировать", "копируй", "копировать",
        "перемести", "переместить", "перенеси", "перенести",
        "создай", "создать", "удали", "удалить",
        "архивируй", "заархивируй", "распакуй", "распаковать",
        "запусти", "выполни", "сделай",
        "copy", "move", "create", "delete", "remove", "archive", "extract", "run", "execute"
    }
    for _, kw in ipairs(action_keywords) do
        if p_low:find(kw, 1, true) then
            is_action_request = true
            break
        end
    end

    if not is_action_request then
        return
    end

    for block_type, code_block in output:gmatch("```([a-zA-Z0-9_-]*)\r?\n(.-)```") do
        local b_low = block_type:lower()
        if b_low == "sh" or b_low == "bash" or b_low == "shell" or b_low == "zsh" or b_low == "" then
            for line in code_block:gmatch("[^\r\n]+") do
                local trimmed = line:match("^%s*(.-)%s*$")
                if trimmed ~= "" and not trimmed:match("^#") then
                    trimmed = trimmed:gsub("^%$%s+", "")
                    execute_ai_action(trimmed, working_dir, "markdown_fallback")
                end
            end
        end
    end
end

--- Парсинг вывода Aider с поддержкой тегов <grime_bus>, <grime_spawn>, <grime_exec> и <next_agent_prompt>
local function parse_aider_tags(output, working_dir, user_prompt)
    if not output or output == "" then
        return nil
    end

    local has_executed_action = false

    -- 1. Обработка тегов <grime_bus key="..." [type="json"]>...</grime_bus>
    for open_tag, content in output:gmatch("<grime_bus(.-)>(.-)</grime_bus>") do
        local key = open_tag:match('key%s*=%s*"([^"]+)"') or open_tag:match("key%s*=%s*'([^']+)'")
        local b_type = open_tag:match('type%s*=%s*"([^"]+)"') or open_tag:match("type%s*=%s*'([^']+)'")
        if key and key ~= "" then
            local raw_val = content:match("^%s*(.-)%s*$")
            local val = raw_val
            if b_type == "json" or raw_val:match("^[%[{]") then
                local decoded = grime.json.decode(raw_val)
                if decoded ~= nil then
                    val = decoded
                end
            end
            if grime and grime.bus and grime.bus.set then
                local ok, err = pcall(function() grime.bus.set(key, val) end)
                if ok then
                    ctx.log(string.format("Шина grime.bus: сохранено значение по ключу '%s'", key))
                else
                    ctx.warn(string.format("Ошибка сохранения в grime.bus по ключу '%s': %s", key, tostring(err)))
                end
            end
        end
    end

    -- 2. Обработка тегов <grime_exec [cwd="..."]>...</grime_exec>
    for open_tag, exec_content in output:gmatch("<grime_exec(.-)>(.-)</grime_exec>") do
        local target_cwd = open_tag:match('cwd%s*=%s*"([^"]+)"') or open_tag:match("cwd%s*=%s*'([^']+)'") or working_dir
        target_cwd = ctx.normalize_path(target_cwd)
        local cmd_str = exec_content:match("^%s*(.-)%s*$")
        if cmd_str and cmd_str ~= "" then
            has_executed_action = true
            execute_ai_action(cmd_str, target_cwd, "grime_exec")
        end
    end

    -- 3. Обработка тегов <grime_spawn module="..." [cwd="..."]>...</grime_spawn>
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

    for open_tag, spawn_content in output:gmatch("<grime_spawn(.-)>(.-)</grime_spawn>") do
        local target_mod = open_tag:match('module%s*=%s*"([^"]+)"') or open_tag:match("module%s*=%s*'([^']+)'")
        local target_cwd = open_tag:match('cwd%s*=%s*"([^"]+)"') or open_tag:match("cwd%s*=%s*'([^']+)'")
        target_cwd = target_cwd or working_dir

        local prompt = spawn_content:match("^%s*(.-)%s*$")
        if target_mod and target_mod ~= "" then
            target_cwd = ctx.normalize_path(target_cwd)

            if target_mod == "cmd" then
                has_executed_action = true
                execute_ai_action(prompt, target_cwd, "grime_spawn")
            else
                ctx.log(string.format("Порождение субагента Grime: модуль '%s', cwd='%s'...", target_mod, target_cwd))

                local spawn_cmd = { grime_bin, target_mod }
                if prompt ~= "" then
                    if target_mod == "aider" then
                        table.insert(spawn_cmd, "-m")
                        table.insert(spawn_cmd, prompt)
                    else
                        for tok in prompt:gmatch("%S+") do
                            table.insert(spawn_cmd, tok)
                        end
                    end
                end

                local sres = ctx.capture(spawn_cmd, target_cwd)
                if sres.code == 0 then
                    ctx.log(string.format("✓ Субагент '%s' успешно завершил работу.", target_mod))
                    if sres.stdout and sres.stdout ~= "" then
                        parse_aider_tags(sres.stdout, target_cwd, prompt)
                    end
                else
                    ctx.warn(string.format("Субагент '%s' завершился с кодом %d: %s", target_mod, sres.code, sres.stderr))
                end
            end
        end
    end

    -- 4. Умный фоллбэк: если пользователь просит действие, а модель вывела shell-команду в markdown без тега
    if not has_executed_action and user_prompt then
        handle_action_fallback(user_prompt, output, working_dir, has_executed_action)
    end

    -- 5. Извлечение мастер-промпта следующего шага
    local next_prompt = output:match("<next_agent_prompt>(.-)</next_agent_prompt>")
    if next_prompt then
        local extracted = next_prompt:match("^%s*(.-)%s*$")
        ctx.log("Извлечен мастер-промпт для следующего шага конвейера (<next_agent_prompt>).")
        return extracted
    end

    return nil
end

local function print_help()
    print(string.format([[
%s%sGrime Aider%s — AI-ассистент парного программирования и генерации кода

%sИСПОЛЬЗОВАНИЕ:%s
    grime aider [путь_или_проект] [файлы...] [промпт...]
    grime aider [опции] -m "сообщение"
    grime aider --app <имя> [--lang <язык>] [промпт...]
    grime <модуль_с_контекстом> : aider [файлы...] [промпт...]

%sРЕЖИМЫ РАБОТЫ:%s
    %sИнтерактивный%s         grime aider [проект] [файлы...]
    %sHeadless (-m)%s         grime aider "Добавь тесты для функции парсинга"
    %sСоздание приложения%s   grime aider --app MyTool --lang rust "CLI утилита"
    %sКонвейерный%s           grime project MyProj path : aider "Рефакторинг CMake"

%sФЛАГИ:%s
    %s--app <name>%s          Создание и скаффолдинг приложения Grime App
    %s-l, --lang <lang>%s     Язык шаблона (cpp, rust, python, java, lua)
    %s-m, --message <msg>%s   Сообщение / промпт для неинтерактивного режима
    %s--model <model>%s       Модель LLM (например, claude-3-5-sonnet, gpt-4o)
    %shelp, -h, --help%s      Показать эту справку

%sИНТЕГРАЦИЯ С ШИНОЙ GRIME:%s
    Aider автоматически поддерживает теги в выводе:
    • <grime_bus key="..." type="json">...</grime_bus> — запись в шину состояния
    • <grime_spawn module="...">...</grime_spawn>       — вызов других модулей
    • <next_agent_prompt>...</next_agent_prompt>       — передача следующему шагу
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    local raw_cli_args = {}
    for _, a in ipairs(ctx.args or {}) do
        table.insert(raw_cli_args, a)
    end

    local first_arg = raw_cli_args[1]
    local first_flag = (type(first_arg) == "string" and first_arg:match("^%-")) and grime.fuzzy.match_flag(first_arg, { "--help", "-h" }, 0.75) or first_arg
    if (#raw_cli_args == 0 and not ctx.pipeline_input) or first_flag == "--help" or first_flag == "-h" or first_arg == "help" then
        print_help()
        return
    end

    local target_dir = nil
    local incoming_pipeline_text = nil

    -- 0. Проверка режима создания приложения (--app <app_name> [--lang <lang>])
    local is_app_mode = false
    local app_name = nil
    local app_lang = nil
    local app_dir = nil
    local filtered_args = {}

    local idx = 1
    while idx <= #raw_cli_args do
        local a = raw_cli_args[idx]
        local matched = (type(a) == "string" and a:match("^%-")) and grime.fuzzy.match_flag(a, { "--app", "--lang", "-l" }, 0.75) or a
        if matched == "--app" then
            is_app_mode = true
            if idx + 1 <= #raw_cli_args and not raw_cli_args[idx + 1]:match("^%-") then
                idx = idx + 1
                app_name = raw_cli_args[idx]
            end
        elseif matched == "--lang" or matched == "-l" then
            if idx + 1 <= #raw_cli_args and not raw_cli_args[idx + 1]:match("^%-") then
                idx = idx + 1
                app_lang = raw_cli_args[idx]:lower()
            end
        else
            table.insert(filtered_args, a)
        end
        idx = idx + 1
    end

    local remaining_args = filtered_args

    if is_app_mode then
        if not app_name or app_name == "" then
            ctx.fail("Укажите имя приложения: grime aider --app <app_name> [--lang <lang>] [prompt]")
            return
        end

        local apps_root = get_apps_root()
        app_dir = apps_root .. "/" .. app_name
        target_dir = app_dir

        -- Сбор пользовательского промпта
        local collected_prompt = {}
        for _, arg in ipairs(remaining_args) do
            if not arg:match("^%-") then
                table.insert(collected_prompt, arg)
            end
        end
        local user_prompt = table.concat(collected_prompt, " ")

        -- Классификация стека при необходимости
        local final_lang = app_lang or classify_stack(user_prompt)

        ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, final_lang))
        scaffold_app(app_dir, app_name, final_lang, user_prompt)

        if user_prompt ~= "" then
            local master_prompt = string.format("%s\n\n[GRIME APP REQUIREMENT]: Реализуй запрошенное консольное приложение. Убедись, что код компилируется и манифест app.lua содержит верное описание и параметры сборки/запуска.", user_prompt)
            remaining_args = { "-m", master_prompt }
        else
            remaining_args = {}
        end
    end

    -- 1. Проверяем входные данные из конвейера
    local pipe_in = ctx.input or ctx.pipeline_input
    if pipe_in then
        local raw = pipe_in:match("^%s*(.-)%s*$")
        if ctx.is_dir(raw) then
            target_dir = raw
        elseif ctx.exists(raw) then
            target_dir = ctx.target_dir
        else
            incoming_pipeline_text = raw
        end
    end

    -- 2. Проверяем, передан ли путь или имя проекта первым аргументом (если не в режиме --app)
    if not is_app_mode and #remaining_args > 0 and not target_dir then
        local first_arg = remaining_args[1]
        local resolved = resolve_dir_or_project(first_arg)
        if resolved then
            target_dir = resolved
            table.remove(remaining_args, 1)
        end
    end

    local working_dir = ctx.normalize_path(target_dir or ctx.target_dir)

    -- 3. Обработка флага -m / --message и сбор свободных слов промпта без кавычек
    local msg_flag_idx = nil
    for i, arg in ipairs(remaining_args) do
        if arg == "-m" or arg == "--message" then
            msg_flag_idx = i
            break
        end
    end

    local user_message = ""
    if msg_flag_idx then
        local collected = {}
        local i = msg_flag_idx + 1
        while i <= #remaining_args do
            local tok = remaining_args[i]
            if tok:match("^%-[a-zA-Z]") then
                break
            end
            table.insert(collected, tok)
            i = i + 1
        end
        user_message = table.concat(collected, " ")
        local new_args = {}
        for k = 1, msg_flag_idx - 1 do
            table.insert(new_args, remaining_args[k])
        end
        table.insert(new_args, "-m")
        table.insert(new_args, user_message)
        for k = i, #remaining_args do
            table.insert(new_args, remaining_args[k])
        end
        remaining_args = new_args
    elseif #remaining_args > 0 and not is_app_mode then
        local flags_part = {}
        local positional = {}
        local i = 1
        local flags_with_value = {
            ["--model"] = true,
            ["--openai-api-key"] = true,
            ["--anthropic-api-key"] = true,
            ["--editor"] = true,
            ["--encoding"] = true,
            ["--chat-history-file"] = true,
            ["--restore-chat-history-file"] = true,
            ["--input-history-file"] = true,
            ["--voice-input-device"] = true,
            ["--message-file"] = true,
            ["--load"] = true,
            ["--read"] = true,
            ["--commit-prompt"] = true,
            ["-c"] = true,
        }

        while i <= #remaining_args do
            local arg = remaining_args[i]
            if arg:match("^%-") then
                table.insert(flags_part, arg)
                if flags_with_value[arg] and i + 1 <= #remaining_args and not remaining_args[i + 1]:match("^%-") then
                    i = i + 1
                    table.insert(flags_part, remaining_args[i])
                end
            else
                table.insert(positional, arg)
            end
            i = i + 1
        end

        local files = {}
        local prompt_tokens = {}
        local found_prompt = false

        for _, tok in ipairs(positional) do
            if found_prompt then
                table.insert(prompt_tokens, tok)
            else
                local is_file = ctx.is_file(tok) or ctx.is_file(working_dir .. "/" .. tok)
                if is_file then
                    table.insert(files, tok)
                else
                    found_prompt = true
                    table.insert(prompt_tokens, tok)
                end
            end
        end

        if #prompt_tokens > 0 then
            user_message = table.concat(prompt_tokens, " ")
            local new_args = {}
            for _, f in ipairs(flags_part) do
                table.insert(new_args, f)
            end
            for _, f in ipairs(files) do
                table.insert(new_args, f)
            end
            table.insert(new_args, "-m")
            table.insert(new_args, user_message)
            remaining_args = new_args
        end
    end

    -- 4. Объединение с контекстом от предыдущего шага конвейера
    if incoming_pipeline_text then
        local combined_message = ""
        if user_message and user_message ~= "" then
            combined_message = string.format("Контекст от предыдущего шага:\n```\n%s\n```\n\nТекущая задача:\n%s", incoming_pipeline_text, user_message)
        else
            combined_message = incoming_pipeline_text
        end

        local m_found = false
        for i, a in ipairs(remaining_args) do
            if a == "-m" then
                remaining_args[i + 1] = combined_message
                m_found = true
                break
            end
        end
        if not m_found then
            table.insert(remaining_args, "-m")
            table.insert(remaining_args, combined_message)
        end
    end

    local is_headless = false
    for _, a in ipairs(remaining_args) do
        if a == "-m" or a == "--message" then
            is_headless = true
            break
        end
    end

    -- Добавление системных конвенций Grime (<grime_bus>, <grime_spawn>, <next_agent_prompt>)
    if is_headless then
        for i, a in ipairs(remaining_args) do
            if a == "-m" and remaining_args[i + 1] then
                remaining_args[i + 1] = remaining_args[i + 1] .. GRIME_CONVENTIONS
                break
            end
        end
    end

    -- 5. Prompt Chaining: если есть следующий шаг в конвейере Grime
    if is_headless and ctx.has_next_step then
        local chain_instruction = "\n\n[СИСТЕМНОЕ ТРЕБОВАНИЕ GRIME]: Сформируйте мастер-промпт для следующего шага и ОБЯЗАТЕЛЬНО оберните его в тег:\n<next_agent_prompt>\nинструкция\n</next_agent_prompt>"
        for i, a in ipairs(remaining_args) do
            if a == "-m" and remaining_args[i + 1] then
                remaining_args[i + 1] = remaining_args[i + 1] .. chain_instruction
                break
            end
        end
    end

    local config_aider = ctx.get_config("aider", "auto")
    local aider_bin = (config_aider ~= "" and config_aider ~= "auto") and config_aider or "aider"
    local aider_cmd = { aider_bin }

    -- 6. Проверка наличия Git-репозитория в целевой рабочей директории
    local has_explicit_git_flag = false
    for _, a in ipairs(remaining_args) do
        if a == "--no-git" or a == "--git" then
            has_explicit_git_flag = true
            break
        end
    end

    if not has_explicit_git_flag then
        local in_git = is_git_repo(working_dir)
        if in_git then
            ctx.log("Обнаружен Git-репозиторий в " .. working_dir .. " -> запуск со стандартным контролем версий Git")
        else
            table.insert(aider_cmd, "--no-git")
            ctx.log("Git-репозиторий отсутствует в " .. working_dir .. " -> добавлен флаг --no-git")
        end
    end

    if is_headless then
        local has_exit = false
        local has_yes = false
        local has_fancy = false
        local has_pretty = false
        for _, a in ipairs(remaining_args) do
            if a == "--exit" then has_exit = true end
            if a == "--yes-always" or a == "--yes" then has_yes = true end
            if a == "--no-fancy-input" or a == "--fancy-input" then has_fancy = true end
            if a == "--no-pretty" or a == "--pretty" then has_pretty = true end
        end
        if not has_exit then table.insert(aider_cmd, "--exit") end
        if not has_yes then table.insert(aider_cmd, "--yes-always") end
        if not has_fancy then table.insert(aider_cmd, "--no-fancy-input") end
        if not has_pretty then table.insert(aider_cmd, "--no-pretty") end
    end

    -- Подключение файлов проекта по умолчанию (если явно не указаны)
    if target_dir and ctx.exists(target_dir) then
        local has_explicit = false
        for _, a in ipairs(remaining_args) do
            if not a:match("^%-") and ctx.exists(working_dir .. "/" .. a) then
                has_explicit = true
                break
            end
        end
        if not has_explicit then
            local candidates = { "src/main.py", "src/main.cpp", "src/Main.java", "src/main.rs", "src/main.lua", "main.py", "main.lua", "app.lua" }
            for _, c in ipairs(candidates) do
                if ctx.exists(working_dir .. "/" .. c) then
                    table.insert(aider_cmd, c)
                    break
                end
            end
        end
    end

    for _, a in ipairs(remaining_args) do
        table.insert(aider_cmd, a)
    end

    if is_headless then
        ctx.log("Вызов Aider...")
        local res = ctx.capture(aider_cmd, working_dir)
        io.stdout:write(res.stdout)
        local cleaned_stderr = res.stderr:gsub("Warning: Input is not a terminal %(fd=0%)%.\r?\n?", "")
        io.stderr:write(cleaned_stderr)

        if res.code == 0 then
            -- Парсинг тегов взаимодействия Grime (<grime_bus>, <grime_spawn>, <grime_exec>, <next_agent_prompt>)
            local extracted = parse_aider_tags(res.stdout, working_dir, user_message)
            if not extracted or extracted == "" then
                extracted = res.stdout:match("^%s*(.-)%s*$")
            end

            if is_app_mode then
                ctx.log(string.format("✓ Приложение '%s' создано в %s", app_name, app_dir))
                ctx.log(string.format("Для запуска выполните: grime app %s", app_name))
            end

            if ctx.has_next_step and extracted and extracted ~= "" then
                ctx.module_return(extracted)
            elseif ctx.has_next_step and target_dir then
                ctx.module_return(target_dir)
            else
                ctx.module_return(nil)
            end
        else
            ctx.fail("Aider завершился с кодом " .. tostring(res.code))
        end
    else
        local ret = ctx.run_process(aider_cmd, working_dir)
        if ret == 0 then
            if is_app_mode then
                ctx.log(string.format("✓ Приложение '%s' настроено в %s", app_name, app_dir))
                ctx.log(string.format("Для запуска выполните: grime app %s", app_name))
            end
            if ctx.has_next_step and target_dir then
                ctx.module_return(target_dir)
            else
                ctx.module_return(nil)
            end
        else
            ctx.fail("Aider завершился с кодом " .. tostring(ret))
        end
    end
end

local M = {
    classify_stack = classify_stack,
    run_dev = run_dev,
    validate_command_security = validate_command_security,
    execute_ai_action = execute_ai_action,
    parse_aider_tags = parse_aider_tags,
}
return M

