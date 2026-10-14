local ctx = grime.ctx

-- Hot-reload test comment
local function print_help()
    print(string.format([[
%s%sGrime Cmd%s — Выполнение внешних команд и запуск программ в контексте директории

%sИСПОЛЬЗОВАНИЕ:%s
    grime cmd <команда/программа> [аргументы/файлы...]
    grime <модуль_с_путем> : cmd <программа> [аргументы...]

%sОПИСАНИЕ:%s
    Выполняет указанную команду в рабочей директории (target_dir), полученной от
    предыдущего шага конвейера или из текущего каталога. Если аргумент совпадает с
    относительным файлом в целевой директории, путь к нему автоматически разрешается.

%sКОМАНДЫ И ФЛАГИ:%s
    %shelp, -h, --help%s       Показать эту справку

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime project MyGame path : cmd nvim CMakeLists.txt
    grime project MyGame path : cmd git status
    grime app MyTool : cmd ls -la
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    local args = ctx.args
    if not args or #args == 0 then
        print_help()
        return
    end

    local program = args[1]
    if program == "--help" or program == "-h" or program == "help" then
        print_help()
        return
    end

    local base_dir = ctx.target_dir

    local final_args = {}
    for i = 2, #args do
        local a = args[i]
        local candidate = base_dir .. "/" .. a
        if ctx.exists(candidate) then
            table.insert(final_args, candidate)
        else
            table.insert(final_args, a)
        end
    end

    local cmd = { program }
    for _, a in ipairs(final_args) do
        table.insert(cmd, a)
    end

    ctx.log("Запуск: " .. table.concat(cmd, " ") .. " (директория: " .. base_dir .. ")")
    local ret = ctx.run_process(cmd, base_dir)

    if ret == 0 then
        if ctx.has_next_step then
            ctx.success(base_dir)
        end
    else
        ctx.fail("Программа '" .. program .. "' завершилась с кодом " .. tostring(ret))
    end
end
