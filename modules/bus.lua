local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Bus%s — Управление разделяемым состоянием (StateBus) и событиями (EventBus)

%sИСПОЛЬЗОВАНИЕ:%s
    grime bus get <ключ>
    grime bus set <ключ> <значение>
    grime bus has <ключ>
    grime bus rm <ключ>
    grime bus list [префикс]
    grime bus emit <событие> [json_данные]

%sОПИСАНИЕ:%s
    Предоставляет интерфейс командной строки для чтения и записи разделяемого
    состояния Grime, а также для публикации событий шины конвейера.

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime bus set pipeline.target "release" : cmd cargo build
    grime bus get pipeline.counter
    grime bus list
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function get_state_file()
    local dir = (ctx.config_dir and ctx.config_dir()) or ((os.getenv("HOME") or "") .. "/.config/grime")
    if not ctx.exists(dir) then ctx.mkdir_p(dir) end
    return dir .. "/state.json"
end

local function load_persisted_state()
    local sfile = get_state_file()
    if ctx.exists(sfile) then
        local content = grime.fs.read(sfile)
        if content and #content > 0 then
            local ok, data = pcall(grime.json.decode, content)
            if ok and type(data) == "table" then return data end
        end
    end
    return {}
end

local function write_state_atomic(data)
    local sfile = get_state_file()
    local tmp = sfile .. ".tmp." .. tostring(os.time())
    local f = io.open(tmp, "w")
    if f then
        f:write(grime.json.encode(data))
        f:close()
        os.rename(tmp, sfile)
    end
end

local function save_persisted_key(key, val)
    if key:match("^pipeline%.") then return end
    local data = load_persisted_state()
    data[key] = val
    write_state_atomic(data)
end

local function remove_persisted_key(key)
    local data = load_persisted_state()
    if data[key] ~= nil then
        data[key] = nil
        write_state_atomic(data)
        return true
    end
    return false
end

local function normalize_bus_key(key)
    if not key or type(key) ~= "string" then return key end
    local trimmed = grime.str.trim(key)
    if #trimmed > 0 and not trimmed:find("%.") then
        return "user." .. trimmed
    end
    return trimmed
end

function main()
    local args = ctx.args or {}
    if #args == 0 then
        print_help()
        return
    end

    local action = args[1]
    if action == "help" or action == "-h" or action == "--help" then
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
        if (not ok or val == nil) and not key:match("^pipeline%.") then
            local persisted = load_persisted_state()
            if persisted[key] ~= nil then
                val = persisted[key]
                pcall(grime.bus.set, key, val)
                ok = true
            elseif raw_key and persisted[raw_key] ~= nil then
                val = persisted[raw_key]
                pcall(grime.bus.set, key, val)
                ok = true
            end
        end

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
            save_persisted_key(key, val)
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
        if (not ok or not exists) and not key:match("^pipeline%.") then
            local persisted = load_persisted_state()
            if persisted[key] ~= nil or (raw_key and persisted[raw_key] ~= nil) then
                exists = true
                ok = true
            end
        end
        if not ok then
            ctx.fail("Не удалось проверить ключ '" .. key .. "' в шине: " .. tostring(exists))
            return
        end
        ctx.success(tostring(exists))
    elseif action == "rm" or action == "delete" or action == "del" then
        local raw_key = args[2] or ctx.input or ctx.pipeline_input
        local key = normalize_bus_key(raw_key)
        if not key or #key == 0 then
            ctx.fail("Укажите ключ для удаления: grime bus rm <key>")
            return
        end
        if grime.bus.delete then
            pcall(grime.bus.delete, key)
        end
        remove_persisted_key(key)
        if raw_key and raw_key ~= key then
            remove_persisted_key(raw_key)
        end
        ctx.log("Ключ '" .. key .. "' удален из шины")
        ctx.success(key)
    elseif action == "list" or action == "ls" or action == "keys" then
        local prefix = args[2]
        local keys_map = {}
        if grime.bus.keys then
            local ok, klist = pcall(grime.bus.keys, prefix)
            if ok and type(klist) == "table" then
                for _, k in ipairs(klist) do keys_map[k] = true end
            end
        end
        local persisted = load_persisted_state()
        for k, _ in pairs(persisted) do
            if not prefix or k:sub(1, #prefix) == prefix then
                keys_map[k] = true
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
    else
        ctx.fail("Неизвестная команда bus: " .. action)
    end
end
