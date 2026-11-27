--[[
    Базовый адаптер ИИ-агента (modules/agents/base.lua)
    Определяет общий контракт и методы запуска для CLI-агентов (Claude Code, Aider и др.).
]]

local utils = require("languages.utils")

local BaseAgent = {}
BaseAgent.__index = BaseAgent

--- Создание нового экземпляра адаптера ИИ-агента
function BaseAgent.new(spec)
    spec = spec or {}
    local self = setmetatable({}, BaseAgent)
    self.name = spec.name or ""
    self.aliases = spec.aliases or {}
    self.config_key = spec.config_key or self.name
    self.default_bin = spec.default_bin or self.name
    if spec.supports_headless == nil then
        self.supports_headless = true
    else
        self.supports_headless = spec.supports_headless
    end
    if spec.supports_interactive == nil then
        self.supports_interactive = true
    else
        self.supports_interactive = spec.supports_interactive
    end
    return self
end

--- Проверка наличия точного значения в списке аргументов
function BaseAgent.has_arg(list, target)
    if type(list) ~= "table" then return false end
    for _, v in ipairs(list) do
        if v == target then
            return true
        end
    end
    return false
end

--- Общий helper: добавляет `flag value` для каждого уникального непустого значения списка
--- (используется для --read у aider и --add-dir у claude)
function BaseAgent.append_repeated(cmd, flag, values)
    if type(values) ~= "table" then return end
    local seen = {}
    for _, v in ipairs(values) do
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            table.insert(cmd, flag)
            table.insert(cmd, v)
        end
    end
end

--- Общий helper: добавляет уникальные непустые строки позиционными аргументами (файлы для редактирования)
function BaseAgent.append_positional(cmd, values)
    if type(values) ~= "table" then return end
    local seen = {}
    for _, v in ipairs(values) do
        if type(v) == "string" and v ~= "" and not seen[v] then
            seen[v] = true
            table.insert(cmd, v)
        end
    end
end

--- Общий helper: добавляет `--model <m>`, если модель задана и не переопределена в passthrough
function BaseAgent.append_model(cmd, model, extra)
    if type(model) == "string" and model ~= "" and not BaseAgent.has_arg(extra, "--model") then
        table.insert(cmd, "--model")
        table.insert(cmd, model)
    end
end

--- Общий helper: дописывает passthrough-аргументы в конец команды
function BaseAgent.append_passthrough(cmd, extra)
    if type(extra) ~= "table" then return end
    for _, a in ipairs(extra) do
        table.insert(cmd, a)
    end
end

--- Разрешение пути/имени бинарника агента из конфигурации (по умолчанию self.default_bin)
function BaseAgent:resolve_binary(ctx)
    local c = ctx or (grime and grime.ctx)
    local cfg = nil
    if c and c.get_config and self.config_key and self.config_key ~= "" then
        cfg = c.get_config(self.config_key, "auto")
    end
    if cfg and cfg ~= "" and cfg ~= "auto" then
        return cfg
    end
    return self.default_bin
end

--- Проверка доступности бинарника агента в $PATH
function BaseAgent:is_available(ctx)
    local c = ctx or (grime and grime.ctx)
    local bin = self:resolve_binary(c)
    return utils.has_binary(bin, c)
end

--- Сборка команды быстрого one-shot планирования (переопределяется в адаптерах)
function BaseAgent:build_architect_cmd(opts, ctx)
    return nil
end

--- Сборка команды для headless-запуска (переопределяется в адаптерах)
function BaseAgent:build_headless_cmd(opts, ctx)
    return nil
end

--- Сборка команды для интерактивного запуска
function BaseAgent:build_interactive_cmd(opts, ctx)
    local bin = self:resolve_binary(ctx)
    return { bin }
end

--- Очистка консольного шума в выводе агента
function BaseAgent:clean_output(stdout, stderr)
    return stdout or "", stderr or ""
end

--- Запуск агента в неинтерактивном (headless) режиме через ctx.capture
function BaseAgent:run_headless(opts, ctx)
    local c = ctx or (grime and grime.ctx)
    opts = opts or {}
    local cmd = opts.cmd or self:build_headless_cmd(opts, c)
    if not cmd or #cmd == 0 then
        return {
            ok = false,
            code = 1,
            stdout = "",
            stderr = "Не удалось сформировать команду headless-запуска для агента " .. tostring(self.name),
            text = "",
        }
    end
    local res = c.capture(cmd, opts.working_dir)
    local raw_stdout = (res and res.stdout) or ""
    local raw_stderr = (res and res.stderr) or ""
    local code = (res and res.code) or 1
    local cleaned_stdout, cleaned_stderr = self:clean_output(raw_stdout, raw_stderr)
    return {
        ok = (code == 0),
        code = code,
        stdout = raw_stdout,
        stderr = cleaned_stderr,
        text = cleaned_stdout,
    }
end

--- Запуск агента в интерактивном режиме (PTY) через ctx.run_interactive
function BaseAgent:run_interactive(opts, ctx)
    local c = ctx or (grime and grime.ctx)
    opts = opts or {}
    local cmd = opts.cmd or self:build_interactive_cmd(opts, c)
    if not cmd or #cmd == 0 then
        return 1
    end
    if c and c.run_interactive then
        return c.run_interactive(cmd, opts.working_dir)
    elseif c and c.run_process then
        return c.run_process(cmd, opts.working_dir)
    end
    return 1
end

return BaseAgent
