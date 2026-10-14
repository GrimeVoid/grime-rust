local ctx = grime.ctx

local DEFAULT_DESCRIPTIONS = {
    project = "Жизненный цикл проектов (C++, Rust, Python, Java)",
    pkg = "Универсальный мета-менеджер пакетов (pacman, nix, flatpak)",
    app = "Изолированные легковесные приложения",
    box = "Оркестрация Distrobox-контейнеров",
    nix = "Воспроизводимые Nix-окружения и Flakes",
    aider = "AI-ассистент разработчика",
    cmd = "Выполнение системных команд и TUI-утилит",
    host = "Модуль-рубеж возврата на хост-машину",
    doctor = "Диагностика окружения, путей и зависимостей Grime",
    bus = "Шина разделяемого состояния (StateBus) и событий",
    daemon = "Управление фоновым сервисом-демоном (grimed)",
    list = "Вывод списка доступных модулей (алиасы: ls, modules)",
    git = "Полноценное управление Git-репозиториями и версионированием",
    log = "Централизованный сбор, хранение и фильтрация логов",
    benchmark = "Стресс-тестирование, бенчмаркинг конвейеров и замеры задержек",
}

local function print_help()
    print(string.format([[
%s%sGrime Modules List%s — Вывод полного списка зарегистрированных модулей

%sИСПОЛЬЗОВАНИЕ:%s
    grime list [фильтр]
    grime ls [фильтр]
    grime modules [фильтр]

%sОПИСАНИЕ:%s
    Сканирует директории модулей Grime, отображает их статус,
    краткое описание и физический путь к файлу реализации.
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function extract_summary(file_path, mod_name)
    if DEFAULT_DESCRIPTIONS[mod_name] then
        return DEFAULT_DESCRIPTIONS[mod_name]
    end

    local content = grime.fs.read(file_path)
    if content then
        -- Поиск строки вида "-- Summary: ..." или "-- Описание: ..."
        local summary = content:match("%-%-%s*[Ss]ummary:%s*([^\r\n]+)")
        if not summary then
            summary = content:match("%-%-%s*Описание:%s*([^\r\n]+)")
        end
        if summary and #summary > 0 then
            return grime.str.trim(summary)
        end
    end
    return "Пользовательский модуль конвейера"
end

function main()
    local args = ctx.args or {}
    for _, a in ipairs(args) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local query = args[1]
    if query then
        query = grime.str.trim(query:lower())
    end

    local search_dirs = {
        "modules",
        ctx.config_dir() .. "/modules",
        (os.getenv("HOME") or "") .. "/dotfiles/grime/modules",
    }

    local found_modules = {}
    local seen = {}

    for _, dir in ipairs(search_dirs) do
        local norm_dir = grime.fs.normalize(dir)
        if grime.fs.is_dir(norm_dir) then
            local files = grime.fs.list(norm_dir) or {}
            for _, f in ipairs(files) do
                if f:sub(-4) == ".lua" then
                    local name = f:sub(1, -5)
                    if not seen[name] then
                        seen[name] = true
                        local full_path = grime.fs.join(norm_dir, f)
                        local is_valid_file = grime.fs.is_file(full_path)
                        local status = is_valid_file and "Активен" or "Поврежденный симлинк"
                        local desc = is_valid_file and extract_summary(full_path, name) or "Файл или симлинк недоступен"
                        table.insert(found_modules, {
                            name = name,
                            desc = desc,
                            path = full_path,
                            status = status,
                        })
                    end
                end
            end
        end
    end

    -- Дополняем стандартными модулями, если они еще не добавлены
    for name, desc in pairs(DEFAULT_DESCRIPTIONS) do
        if not seen[name] then
            seen[name] = true
            table.insert(found_modules, {
                name = name,
                desc = desc,
                path = "встроенный",
                status = "Доступен",
            })
        end
    end

    table.sort(found_modules, function(a, b) return a.name < b.name end)

    local rows = {}
    for _, m in ipairs(found_modules) do
        local match = true
        if query and #query > 0 then
            local name_l = m.name:lower()
            local desc_l = m.desc:lower()
            if not name_l:find(query, 1, true) and not desc_l:find(query, 1, true) then
                local sim = grime.fuzzy.similarity(query, name_l)
                if sim < 0.65 then
                    match = false
                end
            end
        end

        if match then
            table.insert(rows, { m.name, m.status, m.desc, m.path })
        end
    end

    grime.ui.log(string.format("Зарегистрировано модулей Grime: %d", #rows))
    local headers = { "Модуль", "Статус", "Описание", "Путь к файлу" }
    grime.ui.print_table(rows, headers)

    if ctx.has_next_step then
        local lines = {}
        for _, r in ipairs(rows) do
            table.insert(lines, string.format("%-12s %s", r[1], r[3]))
        end
        ctx.done(true, table.concat(lines, "\n"))
    else
        ctx.done(true, tostring(#rows))
    end
end
