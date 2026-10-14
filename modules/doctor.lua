local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Doctor%s — Диагностика системного окружения, путей и зависимостей Grime

%sИСПОЛЬЗОВАНИЕ:%s
    grime doctor [help|-h|--help]

%sОПИСАНИЕ:%s
    Проверяет доступность ключевых утилит (git, nix, distrobox, aider, cargo),
    корректность путей в реестре конфигурации и статус сервисов.
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    for _, a in ipairs(ctx.args or {}) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    grime.ui.log("Запуск диагностики окружения Grime Doctor...")

    local checks = {
        { name = "git", category = "Инструменты" },
        { name = "nix", category = "Пакеты/Окружение" },
        { name = "distrobox", category = "Контейнеры" },
        { name = "cargo", category = "Сборка" },
        { name = "aider", category = "ИИ/Разработка" },
    }

    local rows = {}
    local all_ok = true

    for _, c in ipairs(checks) do
        local res = ctx.capture("which " .. c.name)
        local status = res.code == 0 and "Доступен" or "Не найден"
        local path = res.code == 0 and grime.str.trim(res.stdout) or "-"
        table.insert(rows, { c.category, c.name, status, path })
        if res.code ~= 0 and c.name == "git" then
            all_ok = false
        end
    end

    -- Проверка путей реестра
    local paths_to_check = {
        { name = "Конфигурация", path = ctx.config_dir() },
        { name = "Проекты", path = ctx.projects_root() },
        { name = "Шаблоны", path = ctx.templates_root() },
        { name = "Приложения", path = ctx.apps_root() },
    }

    for _, p in ipairs(paths_to_check) do
        local exists = ctx.exists(p.path)
        local status = exists and "Существует" or "Отсутствует"
        table.insert(rows, { "Каталог", p.name, status, p.path })
    end

    -- Печать отчета через grime.ui.print_table
    local headers = { "Категория", "Компонент", "Статус", "Путь" }
    grime.ui.print_table(rows, headers)

    if all_ok then
        grime.ui.success("Диагностика Grime Doctor завершена успешно: критические компоненты в порядке!")
        ctx.success("doctor_ok")
    else
        grime.ui.warn("Обнаружены отсутствующие компоненты. Рекомендуется установить недостающие утилиты.")
        ctx.success("doctor_warnings")
    end
end
