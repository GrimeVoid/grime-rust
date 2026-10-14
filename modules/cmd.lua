local helper = require("helper")
local ctx = helper.ctx

-- Hot-reload test comment
function main()
    local args = ctx.args
    if not args or #args == 0 then
        ctx.log("Использование: cmd <команда/программа> [аргументы/файлы...]")
        ctx.log("Примеры:")
        ctx.log("  grime project MyGame path : cmd nvim CMakeLists.txt")
        ctx.log("  grime project MyGame path : cmd git status")
        ctx.fail("Не указана команда для выполнения")
        return
    end

    local program = args[1]
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
        ctx.success(base_dir)
    else
        ctx.fail("Программа '" .. program .. "' завершилась с кодом " .. tostring(ret))
    end
end
