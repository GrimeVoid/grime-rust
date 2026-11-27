--[[
    Реестр и резолвер ИИ-агентов (modules/agents/registry.lua)
    Управляет доступными адаптерами (Claude Code, Aider) и приоритетом их выбора.
]]

local claude = require("agents.claude")
local aider = require("agents.aider")

local M = {}

local ORDERED_AGENTS = { claude, aider }

local BY_NAME = {}
for _, agent in ipairs(ORDERED_AGENTS) do
    if agent.name and agent.name ~= "" then
        BY_NAME[agent.name:lower()] = agent
    end
    for _, alias in ipairs(agent.aliases or {}) do
        BY_NAME[alias:lower()] = agent
    end
end

--- Поиск адаптера по имени или алиасу (с очисткой ведущих дефисов)
function M.get(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local clean = name:match("^%s*(.-)%s*$"):gsub("^%-+", ""):lower()
    if clean == "" then
        return nil
    end
    return BY_NAME[clean]
end

--- Возвращает список всех зарегистрированных адаптеров
function M.all()
    local list = {}
    for _, agent in ipairs(ORDERED_AGENTS) do
        table.insert(list, agent)
    end
    return list
end

--- Возвращает список установленных и доступных в системе адаптеров
function M.list_available(ctx)
    local c = ctx or (grime and grime.ctx)
    local available = {}
    for _, agent in ipairs(ORDERED_AGENTS) do
        if agent:is_available(c) then
            table.insert(available, agent)
        end
    end
    return available
end

--- Выбор ИИ-агента по приоритету:
--- 1) preferred_name (явный флаг CLI: -claude, -aider, -agent <name>)
--- 2) grime.bus.get("modules.ai.agent")
--- 3) ctx.get_config("ai_agent", "auto")
--- 4) автовыбор первого доступного в системе: claude -> aider
function M.resolve(preferred_name, ctx)
    local c = ctx or (grime and grime.ctx)

    -- 1. Явно переданный агент
    if type(preferred_name) == "string" and preferred_name ~= "" then
        local norm_pref = preferred_name:match("^%s*(.-)%s*$"):gsub("^%-+", ""):lower()
        if norm_pref ~= "" and norm_pref ~= "auto" then
            local found = M.get(norm_pref)
            if found then
                return found, nil
            end
            return nil, string.format("Неизвестный ИИ-агент '%s'. Доступные: claude, aider", preferred_name)
        end
    end

    -- 2. Шина состояния StateBus
    if grime and grime.bus and grime.bus.get then
        local ok, bus_val = pcall(grime.bus.get, "modules.ai.agent")
        if ok and type(bus_val) == "string" then
            local clean_bus = bus_val:match("^%s*(.-)%s*$"):lower()
            if clean_bus ~= "" and clean_bus ~= "auto" then
                local found = M.get(clean_bus)
                if found then
                    return found, nil
                end
            end
        end
    end

    -- 3. Конфигурация gproj.conf
    if c and c.get_config then
        local cfg_val = c.get_config("ai_agent", "auto")
        if type(cfg_val) == "string" then
            local clean_cfg = cfg_val:match("^%s*(.-)%s*$"):lower()
            if clean_cfg ~= "" and clean_cfg ~= "auto" then
                local found = M.get(clean_cfg)
                if found then
                    return found, nil
                end
            end
        end
    end

    -- 4. Автовыбор первого доступного в порядке claude -> aider
    for _, agent in ipairs(ORDERED_AGENTS) do
        if agent:is_available(c) then
            return agent, nil
        end
    end

    return nil, "Ни один ИИ-агент (claude, aider) не найден в $PATH"
end

return M
