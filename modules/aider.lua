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
    local projects_root = ctx.projects_root()
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

function main()
    local target_dir = nil
    local incoming_pipeline_text = nil
    local remaining_args = {}
    for _, a in ipairs(ctx.args) do
        table.insert(remaining_args, a)
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

    -- 2. Проверяем, передан ли путь или имя проекта первым аргументом
    if #remaining_args > 0 and not target_dir then
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
    for idx, arg in ipairs(remaining_args) do
        if arg == "-m" or arg == "--message" then
            msg_flag_idx = idx
            break
        end
    end

    local user_message = ""
    if msg_flag_idx then
        -- Случай А: флаг -m явно указан. Собираем все последующие токены до следующего флага (-*)
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
    elseif #remaining_args > 0 then
        -- Случай Б: флаг -m НЕ указан.
        -- Разделяем флаги Aider и позиционные аргументы.
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
        for idx, a in ipairs(remaining_args) do
            if a == "-m" then
                remaining_args[idx + 1] = combined_message
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
        for idx, a in ipairs(remaining_args) do
            if a == "-m" and remaining_args[idx + 1] then
                remaining_args[idx + 1] = remaining_args[idx + 1] .. chain_instruction
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
            local candidates = { "src/main.py", "src/main.cpp", "src/Main.java", "src/main.rs", "main.py" }
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
