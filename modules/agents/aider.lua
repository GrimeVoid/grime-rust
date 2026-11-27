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

local has_arg = BaseAgent.has_arg

--- Aider в режиме --yes-always автоматически подтверждает и ВЫПОЛНЕНИЕ предложенных shell-команд,
--- минуя проверки безопасности GRIME (validate_command_security). Поэтому всегда отключаем
--- предложение shell-команд, если пользователь явно не включил его через passthrough.
local function disable_shell_suggestions(cmd, extra)
    if not has_arg(extra, "--suggest-shell-commands") and not has_arg(extra, "--no-suggest-shell-commands") then
        table.insert(cmd, "--no-suggest-shell-commands")
    end
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
        "--no-suggest-shell-commands", -- --yes-always не должен исполнять shell в обход GRIME
        "--no-fancy-input",
        "--no-pretty",
    }
    BaseAgent.append_model(cmd, opts.model)
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

    disable_shell_suggestions(cmd, extra)

    BaseAgent.append_model(cmd, opts.model, extra)
    BaseAgent.append_repeated(cmd, "--read", opts.read_files)
    BaseAgent.append_positional(cmd, opts.files)

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

    BaseAgent.append_passthrough(cmd, extra)

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

    -- Если пользователь включил автоподтверждение, shell-команды тоже не должны выполняться молча
    if has_arg(extra, "--yes-always") or has_arg(extra, "--yes") then
        disable_shell_suggestions(cmd, extra)
    end

    BaseAgent.append_model(cmd, opts.model, extra)
    BaseAgent.append_repeated(cmd, "--read", opts.read_files)

    -- У aider нет флага --system-prompt: правила GRIME и контекст терминала передаются
    -- как read-only файл (--read) со временным содержимым, которым владеет вызывающий код
    if opts.tmp_term_file and opts.tmp_term_file ~= "" then
        table.insert(cmd, "--read")
        table.insert(cmd, opts.tmp_term_file)
    end

    BaseAgent.append_positional(cmd, opts.files)
    BaseAgent.append_passthrough(cmd, extra)

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
