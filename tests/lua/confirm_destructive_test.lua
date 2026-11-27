-- Запуск из корня репозитория: lua5.4 tests/lua/confirm_destructive_test.lua
-- utils.confirm_destructive и utils.extract_yes_flag: все ветки через подмену TTY-детекта и io.read.
package.path = "modules/?.lua;" .. package.path
grime = { ctx = {} }
local utils = require("languages.utils")

local fails = {}
local ctx = { fail = function(msg) fails[#fails + 1] = msg end }

-- assume_yes: true без вопроса и без обращения к TTY
utils.stdin_is_tty = function() error("TTY не должен опрашиваться при assume_yes") end
assert(utils.confirm_destructive("q", true, ctx) == true)
assert(#fails == 0)

-- без TTY и без --yes: false + ctx.fail
utils.stdin_is_tty = function() return false end
assert(utils.confirm_destructive("q", false, ctx) == false)
assert(#fails == 1 and fails[1]:find("--yes", 1, true), "ожидалась подсказка про --yes")

-- интерактивно: y / yes / д / да принимаются, остальное — отказ
utils.stdin_is_tty = function() return true end
local real_read, real_write = io.read, io.stdout
local answers
io.read = function() return table.remove(answers, 1) end
for _, a in ipairs({ "y", "YES", " да ", "д" }) do
    answers = { a }
    assert(utils.confirm_destructive("q", false, ctx) == true, "ответ '" .. a .. "' должен подтверждать")
end
fails = {}
for _, a in ipairs({ "n", "", "no", "yep" }) do
    answers = { a }
    assert(utils.confirm_destructive("q", false, ctx) == false, "ответ '" .. a .. "' должен отклонять")
end
assert(#fails == 4 and fails[1]:find("отменено", 1, true))
answers = {}  -- EOF
assert(utils.confirm_destructive("q", false, ctx) == false)
io.read = real_read

-- extract_yes_flag
local yes, rest = utils.extract_yes_flag({ "rm", "-y", "key" })
assert(yes == true and #rest == 2 and rest[1] == "rm" and rest[2] == "key")
yes, rest = utils.extract_yes_flag({ "rm", "key" })
assert(yes == false and #rest == 2)
assert(select(1, utils.extract_yes_flag({ "--yes" })) == true)

print("confirm_destructive_test ok")
