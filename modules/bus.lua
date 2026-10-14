local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Bus%s — Управление разделяемым состоянием (StateBus) и событиями (EventBus)

%sИСПОЛЬЗОВАНИЕ:%s
    grime bus get <ключ>
    grime bus set <ключ> <значение>
    grime bus has <ключ>
    grime bus emit <событие> [json_данные]

%sОПИСАНИЕ:%s
    Предоставляет интерфейс командной строки для чтения и записи разделяемого
    состояния Grime, а также для публикации событий шины конвейера.

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime bus set pipeline.target "release" -> cmd cargo build
    grime bus get pipeline.counter
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
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
        local key = args[2] or ctx.input or ctx.pipeline_input
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
            print(out)
            ctx.success(out)
        end
    elseif action == "set" then
        local key = args[2]
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
        local key = args[2] or ctx.input or ctx.pipeline_input
        if not key then
            ctx.fail("Укажите ключ: grime bus has <key>")
            return
        end
        local ok, exists = pcall(grime.bus.has, key)
        if not ok then
            ctx.fail("Не удалось проверить ключ '" .. key .. "' в шине: " .. tostring(exists))
            return
        end
        print(tostring(exists))
        ctx.success(tostring(exists))
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
