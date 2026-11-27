--[[
    Адаптер Claude Code (modules/agents/claude.lua)
    Формирует команды для CLI `claude` (без --bare, с сохранением OAuth ~/.claude/.credentials.json).
]]

local BaseAgent = require("agents.base")

local ClaudeAgent = BaseAgent.new({
    name = "claude",
    aliases = { "claude", "claude-code", "cc" },
    config_key = "claude",
    default_bin = "claude",
    supports_headless = true,
    supports_interactive = true,
})

--- Добавление уникальных директорий через --add-dir
local function append_unique_dirs(cmd, dirs)
    if type(dirs) ~= "table" then return end
    local seen = {}
    for _, dir in ipairs(dirs) do
        if type(dir) == "string" and dir ~= "" and not seen[dir] then
            seen[dir] = true
            table.insert(cmd, "--add-dir")
            table.insert(cmd, dir)
        end
    end
end

--- Формирование текстового блока со списком целевых и read-only файлов
local function build_files_context_block(files, read_files)
    local blocks = {}
    if type(files) == "table" and #files > 0 then
        local lines = { "[ЦЕЛЕВЫЕ ФАЙЛЫ ДЛЯ РЕДАКТИРОВАНИЯ]:" }
        for _, f in ipairs(files) do
            if type(f) == "string" and f ~= "" then
                table.insert(lines, "- " .. f)
            end
        end
        if #lines > 1 then
            table.insert(blocks, table.concat(lines, "\n"))
        end
    end
    if type(read_files) == "table" and #read_files > 0 then
        local lines = { "[ФАЙЛЫ КОНТЕКСТА (ТОЛЬКО ЧТЕНИЕ)]:" }
        for _, rf in ipairs(read_files) do
            if type(rf) == "string" and rf ~= "" then
                table.insert(lines, "- " .. rf)
            end
        end
        if #lines > 1 then
            table.insert(blocks, table.concat(lines, "\n"))
        end
    end
    if #blocks == 0 then
        return nil
    end
    return table.concat(blocks, "\n\n")
end

--- Команда быстрого one-shot планирования стека (без инструментов и записи сессии)
function ClaudeAgent:build_architect_cmd(opts, ctx)
    opts = opts or {}
    local bin = self:resolve_binary(ctx)
    local cmd = {
        "timeout", tostring(opts.timeout or 30),
        bin,
        "-p", opts.prompt or "",
        "--tools", "",
        "--no-session-persistence",
        "--output-format", "text",
        "--disable-slash-commands",
    }
    if opts.model and opts.model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, opts.model)
    end
    return cmd
end

--- Команда headless-запуска Claude Code
function ClaudeAgent:build_headless_cmd(opts, ctx)
    opts = opts or {}
    local c = ctx or (grime and grime.ctx)
    local bin = self:resolve_binary(c)

    local prompt_parts = {}
    if opts.prompt and opts.prompt ~= "" then
        table.insert(prompt_parts, opts.prompt)
    end
    local files_block = build_files_context_block(opts.files, opts.read_files)
    if files_block then
        table.insert(prompt_parts, files_block)
    end
    local full_prompt = table.concat(prompt_parts, "\n\n")

    local cmd = {
        bin,
        "-p", full_prompt,
        "--output-format", "text",
        "--no-session-persistence",
    }

    if opts.system_prompt and opts.system_prompt ~= "" then
        table.insert(cmd, "--append-system-prompt")
        table.insert(cmd, opts.system_prompt)
    end

    local perm = opts.permission_mode or ((c and c.force) and "bypassPermissions" or "acceptEdits")
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, perm)

    if type(opts.allowed_tools) == "string" and opts.allowed_tools ~= "" then
        table.insert(cmd, "--allowedTools")
        table.insert(cmd, opts.allowed_tools)
    elseif type(opts.allowed_tools) == "table" and #opts.allowed_tools > 0 then
        table.insert(cmd, "--allowedTools")
        table.insert(cmd, table.concat(opts.allowed_tools, ","))
    end

    append_unique_dirs(cmd, opts.read_dirs)

    if opts.model and opts.model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, opts.model)
    end

    if type(opts.passthrough_args) == "table" then
        for _, a in ipairs(opts.passthrough_args) do
            table.insert(cmd, a)
        end
    end

    return cmd
end

--- Команда интерактивного запуска Claude Code
function ClaudeAgent:build_interactive_cmd(opts, ctx)
    opts = opts or {}
    local c = ctx or (grime and grime.ctx)
    local bin = self:resolve_binary(c)
    local cmd = { bin }

    if opts.system_prompt and opts.system_prompt ~= "" then
        table.insert(cmd, "--append-system-prompt")
        table.insert(cmd, opts.system_prompt)
    end

    if opts.model and opts.model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, opts.model)
    end

    if opts.permission_mode and opts.permission_mode ~= "" then
        table.insert(cmd, "--permission-mode")
        table.insert(cmd, opts.permission_mode)
    end

    append_unique_dirs(cmd, opts.read_dirs)

    if type(opts.passthrough_args) == "table" then
        for _, a in ipairs(opts.passthrough_args) do
            table.insert(cmd, a)
        end
    end

    -- Позиционный стартовый контекст/промпт (объединяется в один аргумент [prompt])
    local start_parts = {}
    if opts.prompt and opts.prompt ~= "" then
        table.insert(start_parts, opts.prompt)
    end
    local files_block = build_files_context_block(opts.files, opts.read_files)
    if files_block then
        table.insert(start_parts, files_block)
    end
    if #start_parts > 0 then
        table.insert(cmd, table.concat(start_parts, "\n\n"))
    end

    return cmd
end

return ClaudeAgent
