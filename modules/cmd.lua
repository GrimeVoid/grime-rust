local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Cmd%s — Выполнение внешних команд и запуск программ в контексте директории

%sИСПОЛЬЗОВАНИЕ:%s
    grime cmd <команда/программа> [аргументы/файлы...]
    grime <модуль_с_путем> -> cmd <программа> [аргументы...]

%sОПИСАНИЕ:%s
    Выполняет указанную команду в рабочей директории (target_dir), полученной от
    предыдущего шага конвейера или из текущего каталога. Если аргумент совпадает с
    относительным файлом в целевой директории, путь к нему автоматически разрешается.
    Поддерживает сквозной ввод из конвейера через ctx.input.

%sКОМАНДЫ И ФЛАГИ:%s
    %shelp, -h, --help%s       Показать эту справку

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime project MyGame path -> cmd nvim CMakeLists.txt
    grime project MyGame path -> cmd git status
    grime app MyTool -> cmd ls -la
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
    local args = ctx.args or {}
    local input = ctx.input or ctx.pipeline_input

    -- Если аргументы не переданы напрямую, но есть входные данные из конвейера:
    if (#args == 0) and input and type(input) == "string" and #input > 0 then
        local raw_parts = grime.str.split(input, " ")
        local trimmed_parts = {}
        for _, p in ipairs(raw_parts) do
            local t = grime.str.trim(p)
            if #t > 0 then
                table.insert(trimmed_parts, t)
            end
        end
        if #trimmed_parts > 0 then
            args = trimmed_parts
        end
    end

    if not args or #args == 0 then
        print_help()
        return
    end

    local program = args[1]
    if program == "--help" or program == "-h" or program == "help" then
        print_help()
        return
    end

    local base_dir = ctx.target_dir or "."

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

    local is_interactive_target = (program == "nvim" or program == "vim" or program == "nano" or program == "yazi" or program == "fzf" or program == "aider")
    local should_stream = (input ~= nil and #input > 0) or ctx.has_next_step

    if should_stream and not is_interactive_target then
        local stdin_data = input
        if stdin_data and #stdin_data > 0 and not stdin_data:match("\n$") then
            stdin_data = stdin_data .. "\n"
        end
        local res = ctx.capture(cmd, base_dir, nil, stdin_data)
        if res.code == 0 then
            local trimmed_out = grime.str.trim(res.stdout or "")
            ctx.module_return(trimmed_out)
        else
            local err_msg = res.stderr and grime.str.trim(res.stderr) or ""
            if #err_msg == 0 then
                err_msg = string.format("Программа '%s' завершилась с кодом %d", program, res.code)
            end
            ctx.fail(err_msg)
        end
    else
        ctx.log("Запуск: " .. table.concat(cmd, " ") .. " (директория: " .. base_dir .. ")")
        local ret = ctx.run_interactive(cmd, base_dir)

        if ret == 0 then
            ctx.success(base_dir)
        else
            ctx.fail("Программа '" .. program .. "' завершилась с кодом " .. tostring(ret))
        end
    end
end
