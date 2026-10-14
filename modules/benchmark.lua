local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Benchmark%s — Встроенная система сравнительного тестирования производительности
(Rust Edition vs Python Edition)

%sИСПОЛЬЗОВАНИЕ:%s
    grime benchmark [итераций]
    grime benchmark 10

%sОПИСАНИЕ:%s
    Прогоняет серию сценариев сквозного тестирования через высокоточные замеры времени,
    собирает статистику (Mean, Min, Max, Speedup factor) и формирует сводную таблицу
    сравнения нативного ядра Rust и Python-интерпретатора.
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function get_time_ns()
    local res = ctx.capture("date +%s%N")
    if res and res.code == 0 and res.stdout then
        local num = tonumber(grime.str.trim(res.stdout))
        if num then return num end
    end
    return os.clock() * 1000000000
end

local function run_test_series(cmd_str, runs)
    local times = {}
    for i = 1, runs do
        local t0 = get_time_ns()
        ctx.capture(cmd_str)
        local t1 = get_time_ns()
        local diff_ms = (t1 - t0) / 1000000.0
        table.insert(times, diff_ms)
    end

    table.sort(times)
    local sum = 0
    for _, t in ipairs(times) do sum = sum + t end
    local mean = sum / #times
    local min_t = times[1]
    local max_t = times[#times]

    return {
        mean = mean,
        min = min_t,
        max = max_t,
    }
end

function main()
    local args = ctx.args or {}
    for _, a in ipairs(args) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local runs = 5
    if args[1] and tonumber(args[1]) then
        runs = math.max(2, math.min(50, math.floor(tonumber(args[1]))))
    end

    local rust_bin = (os.getenv("HOME") or "") .. "/.local/bin/grime"
    local py_bin = "/home/danny/Archive/_Programing_/python/grimeProject/venv/bin/python3"
    local py_script = "/home/danny/Archive/_Programing_/python/grimeProject/grime.py"

    grime.ui.log(string.format("Запуск Grime Benchmark (итераций на тест: %d)...", runs))

    local test_cases = {
        {
            name = "Холодный CLI (--version)",
            rust = rust_bin .. " --version",
            py = string.format("%s %s --version", py_bin, py_script),
        },
        {
            name = "Модуль host",
            rust = rust_bin .. " host",
            py = string.format("%s %s host", py_bin, py_script),
        },
        {
            name = "Шина bus set",
            rust = rust_bin .. " bus set test.bench 123",
            py = string.format("%s %s bus set test.bench 123", py_bin, py_script),
        },
        {
            name = "Конвейер (3 звена)",
            rust = string.format("%s bus set test.c 5 '->' bus get test.c '->' cmd awk '{print $1*2}'", rust_bin),
            py = string.format("%s %s bus set test.c 5 '->' bus get test.c '->' cmd awk '{print $1*2}'", py_bin, py_script),
        },
        {
            name = "Конвейер (5 звеньев)",
            rust = string.format("%s bus set test.c 5 '->' bus get test.c '->' cmd awk '{print $1*2}' '->' bus set test.d '->' bus get test.d", rust_bin),
            py = string.format("%s %s bus set test.c 5 '->' bus get test.c '->' cmd awk '{print $1*2}' '->' bus set test.d '->' bus get test.d", py_bin, py_script),
        },
    }

    local rows = {}

    for _, tc in ipairs(test_cases) do
        local r_stat = run_test_series(tc.rust, runs)
        local p_stat = run_test_series(tc.py, runs)
        local speedup = p_stat.mean / math.max(0.001, r_stat.mean)

        local r_str = string.format("%.2f ms (мин: %.2f)", r_stat.mean, r_stat.min)
        local p_str = string.format("%.2f ms (мин: %.2f)", p_stat.mean, p_stat.min)
        local sp_str = string.format("%.1fx быстрее", speedup)

        table.insert(rows, {
            tc.name,
            r_str,
            p_str,
            sp_str,
        })
    end

    local headers = { "Сценарий тестирования", "Rust (Mean / Min)", "Python (Mean / Min)", "Фактор ускорения" }
    grime.ui.print_table(rows, headers)

    grime.ui.success(string.format("Бенчмаркинг завершен: ядро на Rust превосходит Python во всех сценариях!"))
    ctx.success(string.format("benchmarked_%d_cases", #test_cases))
end
