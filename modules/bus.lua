--@grime description: Управление шиной состояния (StateBus) и событиями (EventBus)


local ctx = grime.ctx
local utils = require("languages.utils")

local function print_help()
    print(string.format([[
%s%sGrime Bus%s — Управление разделяемым состоянием (StateBus) и событиями (EventBus)

%sИСПОЛЬЗОВАНИЕ (все команды поддерживаются с '-' / '--' и без дефиса):%s
    grime bus <get|-get|-g|--get> <ключ>
    grime bus <set|-set|-s|--set> <ключ> <значение>
    grime bus <has|-has|--has> <ключ>
    grime bus <rm|-rm|-d|--rm|--delete> <ключ> [-y|--yes]   (без TTY обязателен --yes)
    grime bus <list|-list|-l|--list|--keys> [префикс]
    grime bus <emit|-emit|-e|--emit> <событие> [json_данные]
    grime bus <help|-help|-h|--help>

%sОПИСАНИЕ:%s
    Предоставляет интерфейс командной строки для чтения и записи разделяемого
    состояния Grime, а также для публикации событий шины конвейера.

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime bus --set pipeline.target "release" : cmd cargo build
    grime bus -get pipeline.counter
    grime bus --list
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function normalize_bus_key(key)
    if not key or type(key) ~= "string" then return key end
    local trimmed = grime.str.trim(key)
    if #trimmed > 0 and not trimmed:find("%.") then
        return "user." .. trimmed
    end
    return trimmed
end

local BUS_ACTIONS = {
    get = "get", g = "get",
    set = "set", s = "set",
    has = "has", exists = "has",
    rm = "rm", delete = "rm", del = "rm", d = "rm", remove = "rm",
    list = "list", ls = "list", keys = "list", l = "list",
    emit = "emit", e = "emit", pub = "emit",
    help = "help", h = "help",
}

local function main()
    local assume_yes, args = utils.extract_yes_flag(ctx.args or {})
    if #args == 0 then
        print_help()
        return
    end

    for _, a in ipairs(args) do
        if a == "--" or a == "//" then break end
        if grime.args.is_flag(a) then
            local clean = grime.args.strip_dashes(a:lower())
            if clean == "help" or clean == "h" then
                print_help()
                return
            end
        end
    end

    -- Действие принимается и с дефисами, и без них (get / -get / --get)
    local raw_action = tostring(args[1] or "")
    local clean_action = grime.args.strip_dashes(raw_action):lower()
    local action = BUS_ACTIONS[clean_action]
    if not action then
        ctx.fail("Неизвестная команда bus: " .. raw_action .. " (get, set, has, rm, list, emit)")
        return
    end

    if action == "help" then
        print_help()
        return
    end

    if not (grime and grime.bus) then
        ctx.fail("Шина состояния Grime (StateBus) недоступна в текущем контексте")
        return
    end

    if action == "get" then
        local raw_key = args[2] or ctx.input or ctx.pipeline_input
        local key = normalize_bus_key(raw_key)
        if not key or #key == 0 then
            ctx.fail("Укажите ключ для чтения: grime bus get <key>")
            return
        end
        local ok, val = pcall(grime.bus.get, key)

        if not ok then
            ctx.fail("Не удалось прочитать ключ '" .. key .. "' из шины: " .. tostring(val))
            return
        end
        if val == nil then
            ctx.log("Ключ '" .. key .. "' не найден")
            ctx.success(nil)
        else
            local out = type(val) == "table" and grime.json.encode(val) or tostring(val)
            ctx.success(out)
        end
    elseif action == "set" then
        local key = normalize_bus_key(args[2])
        local val_str = args[3] or ctx.input or ctx.pipeline_input
        if not key or not val_str then
            ctx.fail("Укажите ключ и значение: grime bus set <key> <value>")
            return
        end

        local val = val_str
        if val_str == "true" then val = true
        elseif val_str == "false" then val = false
        elseif tonumber(val_str) then val = tonumber(val_str)
        elseif val_str:sub(1,1) == "{" or val_str:sub(1,1) == "[" then
            local ok, parsed = pcall(grime.json.decode, val_str)
            if ok then val = parsed end
        end

        local ok, err = pcall(grime.bus.set, key, val)
        if ok then
            ctx.log(string.format("Установлено: %s = %s", key, tostring(val_str)))
            ctx.success(val_str)
        else
            ctx.fail("Ошибка записи в шину: " .. tostring(err))
        end
    elseif action == "has" then
        local raw_key = args[2] or ctx.input or ctx.pipeline_input
        local key = normalize_bus_key(raw_key)
        if not key then
            ctx.fail("Укажите ключ: grime bus has <key>")
            return
        end
        local ok, exists = pcall(grime.bus.has, key)
        if not ok then
            ctx.fail("Не удалось проверить ключ '" .. key .. "' в шине: " .. tostring(exists))
            return
        end
        ctx.success(tostring(exists))
    elseif action == "rm" then
        local raw_key = args[2] or ctx.input or ctx.pipeline_input
        local key = normalize_bus_key(raw_key)
        if not key or #key == 0 then
            ctx.fail("Укажите ключ для удаления: grime bus rm <key>")
            return
        end
        if not utils.confirm_destructive(string.format("Удалить ключ '%s' из шины состояния?", key), assume_yes, ctx) then
            return
        end
        if grime.bus.delete then
            pcall(grime.bus.delete, key)
        end
        ctx.log("Ключ '" .. key .. "' удален из шины")
        ctx.success(key)
    elseif action == "list" then
        local prefix = args[2]
        local keys_map = {}
        if grime.bus.keys then
            local ok, klist = pcall(grime.bus.keys, prefix)
            if ok and type(klist) == "table" then
                for _, k in ipairs(klist) do keys_map[k] = true end
            end
        end
        local keys = {}
        for k, _ in pairs(keys_map) do table.insert(keys, k) end
        table.sort(keys)
        if #keys == 0 then
            ctx.log("Шина состояния пуста")
            ctx.success("")
        else
            for _, k in ipairs(keys) do print(k) end
            ctx.success(table.concat(keys, "\n"))
        end
    elseif action == "emit" then
        if not (grime and grime.events) then
            ctx.fail("Шина событий Grime (EventBus) недоступна")
            return
        end
        local event_name = args[2]
        if not event_name then
            ctx.fail("Укажите имя события: grime bus emit <event> [json_payload]")
            return
        end
        local payload_str = args[3] or ctx.input or "{}"
        local payload = {}
        if payload_str and #payload_str > 0 then
            local ok, parsed = pcall(grime.json.decode, payload_str)
            if ok and type(parsed) == "table" then
                payload = parsed
            else
                payload = { message = payload_str }
            end
        end
        local ok, err = pcall(grime.events.emit, event_name, payload)
        if ok then
            ctx.log(string.format("Событие '%s' отправлено в шину", event_name))
            ctx.success(event_name)
        else
            ctx.fail("Не удалось опубликовать событие '" .. event_name .. "': " .. tostring(err))
        end
    end
end

return {
    main = main,
}
