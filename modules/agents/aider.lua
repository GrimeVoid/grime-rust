--[[
    Адаптер Aider (modules/agents/aider.lua)
    Формирует команды запуска Aider в режимах архитектора, headless и интерактива,
    а также очищает сервисный шум вывода.
]]

local BaseAgent = require("agents.base")

local AiderAgent = BaseAgent.new({
    name = "aider",
    aliases = { "aider" },
    config_key = "aider",
    default_bin = "aider",
    supports_headless = true,
    supports_interactive = true,
})

local function has_arg(list, target)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == target then
            return true
        end
    end
    return false
end

--- Команда быстрого one-shot планирования стека через Aider
function AiderAgent:build_architect_cmd(opts, ctx)
    opts = opts or {}
    local bin = self:resolve_binary(ctx)
    local cmd = {
        "timeout", tostring(opts.timeout or 20),
        bin,
        "--no-git",
        "--map-tokens", "0",
        "--exit",
        "--yes-always",
        "--no-fancy-input",
        "--no-pretty",
    }
    if opts.model and opts.model ~= "" then
        table.insert(cmd, "--model")
        table.insert(cmd, opts.model)
    end
    table.insert(cmd, "-m")
    table.insert(cmd, opts.prompt or "")
    return cmd
end

--- Команда headless-запуска Aider
function AiderAgent:build_headless_cmd(opts, ctx)
    opts = opts or {}
    local bin = self:resolve_binary(ctx)
    local cmd = { bin }
    local extra = opts.passthrough_args or {}

    if not opts.is_git and not has_arg(extra, "--git") and not has_arg(extra, "--no-git") then
        table.insert(cmd, "--no-git")
    end

    if not has_arg(extra, "--exit") then
        table.insert(cmd, "--exit")
    end
    if not has_arg(extra, "--yes-always") and not has_arg(extra, "--yes") then
        table.insert(cmd, "--yes-always")
    end
    if not has_arg(extra, "--no-fancy-input") and not has_arg(extra, "--fancy-input") then
        table.insert(cmd, "--no-fancy-input")
    end
    if not has_arg(extra, "--no-pretty") and not has_arg(extra, "--pretty") then
        table.insert(cmd, "--no-pretty")
    end

    if opts.model and opts.model ~= "" and not has_arg(extra, "--model") then
        table.insert(cmd, "--model")
        table.insert(cmd, opts.model)
    end

    if type(opts.read_files) == "table" then
        for _, rf in ipairs(opts.read_files) do
            if type(rf) == "string" and rf ~= "" then
                table.insert(cmd, "--read")
                table.insert(cmd, rf)
            end
        end
    end

    if type(opts.files) == "table" then
        for _, f in ipairs(opts.files) do
            if type(f) == "string" and f ~= "" then
                table.insert(cmd, f)
            end
        end
    end

    local combined_prompt = opts.prompt or ""
    if opts.system_prompt and opts.system_prompt ~= "" then
        if combined_prompt ~= "" then
            combined_prompt = combined_prompt .. "\n" .. opts.system_prompt
        else
            combined_prompt = opts.system_prompt
        end
    end
    table.insert(cmd, "-m")
    table.insert(cmd, combined_prompt)

    for _, a in ipairs(extra) do
        table.insert(cmd, a)
    end

    return cmd
end

--- Команда интерактивного запуска Aider
function AiderAgent:build_interactive_cmd(opts, ctx)
    opts = opts or {}
    local bin = self:resolve_binary(ctx)
    local cmd = { bin }
    local extra = opts.passthrough_args or {}

    if not opts.is_git and not has_arg(extra, "--git") and not has_arg(extra, "--no-git") then
        table.insert(cmd, "--no-git")
    end

    if opts.model and opts.model ~= "" and not has_arg(extra, "--model") then
        table.insert(cmd, "--model")
        table.insert(cmd, opts.model)
    end

    if type(opts.read_files) == "table" then
        for _, rf in ipairs(opts.read_files) do
            if type(rf) == "string" and rf ~= "" then
                table.insert(cmd, "--read")
                table.insert(cmd, rf)
            end
        end
    end

    if opts.tmp_term_file and opts.tmp_term_file ~= "" then
        table.insert(cmd, "--read")
        table.insert(cmd, opts.tmp_term_file)
    end

    if type(opts.files) == "table" then
        for _, f in ipairs(opts.files) do
            if type(f) == "string" and f ~= "" then
                table.insert(cmd, f)
            end
        end
    end

    for _, a in ipairs(extra) do
        table.insert(cmd, a)
    end

    return cmd
end

--- Очистка консольного шума Aider в stdout и stderr
function AiderAgent:clean_output(stdout, stderr)
    local clean_err = (stderr or ""):gsub("Warning: Input is not a terminal %(fd=0%)%.\r?\n?", "")

    local raw_out = stdout or ""
    if raw_out == "" then
        return "", clean_err
    end

    local kept = {}
    for line in (raw_out .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        local is_noise = trimmed:match("^Tokens:%s")
            or trimmed:match("^Cost:%s")
            or trimmed:match("^Aider%s+v?%d")
            or trimmed:match("^Model:%s")
            or trimmed:match("^Main model:%s")
            or trimmed:match("^Weak model:%s")
            or trimmed:match("^Git repo:%s")
            or trimmed:match("^Repo%-map:%s")
        if not is_noise then
            table.insert(kept, line)
        end
    end

    -- Убираем завершающую пустую строку, добавленную циклом с "\n"
    if #kept > 0 and kept[#kept] == "" then
        table.remove(kept, #kept)
    end

    return table.concat(kept, "\n"), clean_err
end

return AiderAgent
