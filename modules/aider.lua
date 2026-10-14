local helper = require("helper")
local ctx = helper.ctx

local function resolve_dir_or_project(arg)
    if not arg or arg == "" or arg:match("^%-") then
        return nil
    end

    -- 1. Проверяем, существует ли как директория на диске
    if ctx.is_dir(arg) then
        return arg
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
        for _, lang in ipairs({ "cpp", "python", "rust", "java", "C++" }) do
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

local function replace_in_file(path, pattern, replacement)
    if not ctx.is_file(path) then return end
    local f = io.open(path, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    local updated = content:gsub(pattern, replacement)
    local f_out = io.open(path, "w")
    if f_out then
        f_out:write(updated)
        f_out:close()
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

    -- Адаптация шаблона под имя приложения
    if lang == "cpp" then
        local cmake = app_dir .. "/CMakeLists.txt"
        if ctx.is_file(cmake) then
            replace_in_file(cmake, "project%s*%b()", "project(" .. app_name .. ")")
            replace_in_file(cmake, "add_executable%s*%b()", "add_executable(" .. app_name .. " src/main.cpp)")
        else
            local f = io.open(cmake, "w")
            if f then
                f:write(string.format([[cmake_minimum_required(VERSION 3.20)
project(%s)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
file(GLOB_RECURSE SOURCES "src/*.cpp")
add_executable(%s ${SOURCES})
]], app_name, app_name))
                f:close()
            end
        end
        local main_cpp = app_dir .. "/src/main.cpp"
        if not ctx.is_file(main_cpp) then
            local f = io.open(main_cpp, "w")
            if f then
                f:write([[#include <iostream>

int main() {
    std::cout << "Application started!" << std::endl;
    return 0;
}
]])
                f:close()
            end
        end
    elseif lang == "rust" then
        local cargo_toml = app_dir .. "/Cargo.toml"
        if ctx.is_file(cargo_toml) then
            replace_in_file(cargo_toml, 'name%s*=%s*"[^"]*"', 'name = "' .. app_name:lower() .. '"')
        end
    end

    -- Генерация манифеста app.lua
    local manifest_path = app_dir .. "/app.lua"
    if not ctx.is_file(manifest_path) then
        local desc = (prompt and prompt ~= "") and prompt or "Grime Application"
        -- Экранируем переносы строк для строки манифеста
        desc = desc:gsub("\n", " "):gsub('"', '\\"')

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
            local pkg_name = app_name:lower()
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
]], app_name, desc, pkg_name, pkg_name)
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
end

function main()
    local target_dir = nil
    local incoming_pipeline_text = nil
    local raw_cli_args = {}
    for _, a in ipairs(ctx.args) do
        table.insert(raw_cli_args, a)
    end

    -- 0. Проверка режима создания приложения (--app <app_name> [--lang <lang>])
    local is_app_mode = false
    local app_name = nil
    local app_lang = nil
    local app_dir = nil
    local filtered_args = {}

    local idx = 1
    while idx <= #raw_cli_args do
        local a = raw_cli_args[idx]
        if a == "--app" then
            is_app_mode = true
            if idx + 1 <= #raw_cli_args and not raw_cli_args[idx + 1]:match("^%-") then
                idx = idx + 1
                app_name = raw_cli_args[idx]
            end
        elseif a == "--lang" or a == "-l" then
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

        -- Этап 1: Классификация стека
        local final_lang = app_lang
        if not final_lang or final_lang == "" then
            if user_prompt ~= "" then
                local config_aider = ctx.get_config("aider", "auto")
                local aider_bin = (config_aider ~= "" and config_aider ~= "auto") and config_aider or "aider"
                local classify_prompt = string.format("Классифицируй задачу консольного приложения:\n%s\nКакой стек лучше использовать? Ответь СТРОГО ОДНИМ СЛОВОМ из списка: cpp, rust, python, java, lua.", user_prompt)
                ctx.log("Определение стека приложения через Aider/LLM...")
                local cres = ctx.capture({ aider_bin, "--no-git", "--exit", "--yes-always", "--no-fancy-input", "-m", classify_prompt })
                if cres.code == 0 and cres.stdout and cres.stdout ~= "" then
                    local out_l = cres.stdout:lower()
                    for _, l in ipairs({ "cpp", "rust", "python", "java", "lua" }) do
                        if out_l:find(l, 1, true) then
                            final_lang = l
                            break
                        end
                    end
                end
            end
            if not final_lang or final_lang == "" then
                final_lang = "cpp"
            end
        end

        ctx.log(string.format("Выбран стек технологий для приложения '%s': %s", app_name, final_lang))

        -- Этап 2: Скаффолдинг
        scaffold_app(app_dir, app_name, final_lang, user_prompt)

        -- Этап 3: Подготовка к вызову Aider
        if user_prompt ~= "" then
            local master_prompt = string.format("%s\n\n[GRIME APP REQUIREMENT]: Реализуй запрошенное консольное приложение. Убедись, что код компилируется и манифест app.lua содержит верное описание и параметры сборки/запуска.", user_prompt)
            remaining_args = { "-m", master_prompt }
        else
            remaining_args = {}
        end
    end

    -- 1. Проверяем входные данные из конвейера
    if ctx.pipeline_input then
        local raw = ctx.pipeline_input:match("^%s*(.-)%s*$")
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

    -- 5. Prompt Chaining: если есть следующий шаг
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

    if target_dir and ctx.exists(target_dir) then
        ctx.log("Запуск Aider внутри проекта: " .. working_dir)
    else
        table.insert(aider_cmd, "--no-git")
        ctx.log("Запуск Aider в автономном режиме (--no-git вне проекта)")
    end

    if is_headless then
        local has_exit = false
        local has_yes = false
        local has_fancy = false
        for _, a in ipairs(remaining_args) do
            if a == "--exit" then has_exit = true end
            if a == "--yes-always" or a == "--yes" then has_yes = true end
            if a == "--no-fancy-input" or a == "--fancy-input" then has_fancy = true end
        end
        if not has_exit then table.insert(aider_cmd, "--exit") end
        if not has_yes then table.insert(aider_cmd, "--yes-always") end
        if not has_fancy then table.insert(aider_cmd, "--no-fancy-input") end
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
            local candidates = { "src/main.py", "src/main.cpp", "src/Main.java", "src/main.rs", "main.py", "app.lua" }
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
            local extracted = nil
            local match = res.stdout:match("<next_agent_prompt>(.-)</next_agent_prompt>")
            if match then
                extracted = match:match("^%s*(.-)%s*$")
                ctx.log("Извлечен мастер-промпт для следующего шага конвейера (<next_agent_prompt>).")
            else
                extracted = res.stdout:match("^%s*(.-)%s*$")
            end

            if is_app_mode then
                ctx.log(string.format("✓ Приложение '%s' создано в %s", app_name, app_dir))
                ctx.log(string.format("Для запуска выполните: grime app %s", app_name))
            end

            if ctx.has_next_step and extracted and extracted ~= "" then
                ctx.module_return(extracted)
            elseif target_dir then
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
            if target_dir then
                ctx.module_return(target_dir)
            else
                ctx.module_return(nil)
            end
        else
            ctx.fail("Aider завершился с кодом " .. tostring(ret))
        end
    end
end
