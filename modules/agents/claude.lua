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
    BaseAgent.append_model(cmd, opts.model)
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

    BaseAgent.append_repeated(cmd, "--add-dir", opts.read_dirs)

    BaseAgent.append_model(cmd, opts.model)
    BaseAgent.append_passthrough(cmd, opts.passthrough_args)

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

    BaseAgent.append_model(cmd, opts.model)

    if opts.permission_mode and opts.permission_mode ~= "" then
        table.insert(cmd, "--permission-mode")
        table.insert(cmd, opts.permission_mode)
    end

    BaseAgent.append_repeated(cmd, "--add-dir", opts.read_dirs)

    BaseAgent.append_passthrough(cmd, opts.passthrough_args)

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
