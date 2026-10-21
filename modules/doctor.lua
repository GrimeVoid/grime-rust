-- Summary: Комплексная диагностика системного окружения, путей и журнала сбоев
-- Description: Комплексная диагностика системного окружения, путей и журнала сбоев
-- Описание: Проверка утилит, каталогов конфигурации, состояния логов и недавних ошибок системы
description = "Комплексная диагностика системного окружения, путей и журнала сбоев"

local ctx = grime.ctx
local log = require("log")

local ANSI = {
    BOLD = "\27[1m",
    RESET = "\27[0m",
    GREEN = "\27[32m",
    YELLOW = "\27[33m",
    RED = "\27[31m",
    CYAN = "\27[36m",
    DIM = "\27[90m",
}

local function print_help()
    print(string.format([[
%s%sGrime Doctor%s — Диагностика системного окружения, путей, зависимостей и журнала сбоев

%sИСПОЛЬЗОВАНИЕ:%s
    grime doctor [help|-h|--help]

%sОПИСАНИЕ:%s
    Проверяет доступность ключевых утилит (git, nix, distrobox, aider, cargo),
    корректность путей в реестре конфигурации, статус журнала логов и
    отображает недавние ошибки и сбои из централизованного хранилища StateBus.
]],
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

function main()
    for _, a in ipairs(ctx.args or {}) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    grime.ui.log("Запуск комплексной диагностики окружения Grime Doctor...")

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
    local cfg_dir = ctx.config_dir()
    local log_dir = cfg_dir .. "/logs"
    local log_file = log_dir .. "/grime.jsonl"

    local paths_to_check = {
        { name = "Конфигурация", path = cfg_dir },
        { name = "Проекты", path = ctx.projects_root() },
        { name = "Шаблоны", path = ctx.templates_root() },
        { name = "Приложения", path = ctx.apps_root() },
        { name = "Журнал логов", path = log_dir },
    }

    for _, p in ipairs(paths_to_check) do
        local exists = ctx.exists(p.path)
        local status = exists and "Существует" or "Отсутствует"
        table.insert(rows, { "Каталог", p.name, status, p.path })
    end

    -- Печать отчета компонентов через grime.ui.print_table
    local headers = { "Категория", "Компонент", "Статус", "Путь" }
    print()
    grime.ui.print_table(rows, headers)
    print()

    -- Проверка состояния подсистемы логов и недавних ошибок
    local recent_errors = log.get_errors(5)
    local log_exists = ctx.exists(log_file)
    local history = log.get_history(100)

    print(string.format("%sСостояние подсистемы логирования и здоровья системы:%s", ANSI.BOLD, ANSI.RESET))
    print(string.format("  • Файл логов: %s (%s)", log_file, log_exists and (ANSI.GREEN .. "Активен" .. ANSI.RESET) or (ANSI.YELLOW .. "Не создан" .. ANSI.RESET)))
    print(string.format("  • Записей в истории: %d", #history))
    print(string.format("  • Зафиксировано ошибок/сбоев: %s%d%s", #recent_errors > 0 and ANSI.RED or ANSI.GREEN, #recent_errors, ANSI.RESET))

    if #recent_errors > 0 then
        print(string.format("\n%sПоследние недавние сбои в системе (StateBus):%s", ANSI.RED .. ANSI.BOLD, ANSI.RESET))
        for i, err_item in ipairs(recent_errors) do
            local ts = err_item.timestamp or "-"
            if #ts > 19 then ts = ts:sub(1, 19):gsub("T", " ") end
            print(string.format("  %d. [%s] [%s] %s: %s", i, ts, err_item.level or "ERROR", err_item.source or "unknown", err_item.message or ""))
        end
        print()
    else
        print(string.format("  • Недавние системные сбои: %sотсутствуют (система стабильна)%s\n", ANSI.GREEN, ANSI.RESET))
    end

    if all_ok and #recent_errors == 0 then
        grime.ui.success("Диагностика Grime Doctor завершена: окружение и журнал ошибок в идеальном порядке!")
        log.info("Диагностика Doctor завершена успешно: все компоненты в порядке", "doctor")
        ctx.success("doctor_ok")
    elseif all_ok and #recent_errors > 0 then
        grime.ui.warn(string.format("Диагностика компонентов пройдена, но в журнале зафиксировано %d сбоев.", #recent_errors))
        log.warn(string.format("Диагностика Doctor: обнаружены недавние сбои (%d)", #recent_errors), "doctor")
        ctx.success("doctor_with_errors")
    else
        grime.ui.warn("Обнаружены отсутствующие критические компоненты. Рекомендуется установить недостающие утилиты.")
        log.warn("Диагностика Doctor: отсутствуют критические компоненты", "doctor")
        ctx.success("doctor_warnings")
    end
end

return {
    main = main,
    description = description,
}
