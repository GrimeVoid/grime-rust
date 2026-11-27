-- Запуск из корня репозитория: lua5.4 tests/lua/java_run_test.lua
-- Java без maven/gradle: get_run_command должен давать `java -cp <root>/bin Main`, а не nil.
local D = "/tmp/grime_java_unit_J1"
os.execute("rm -rf " .. D .. " && mkdir -p " .. D .. "/src")
package.path = "modules/?.lua;" .. package.path
local function ex(p) local f = io.open(p) if f then f:close() return true end return false end
grime = { fs = { exists = ex } }
local a = require("languages.java")

-- нет ни исходников, ни класса: запускать нечего
assert(a:get_run_command(D) == nil, "пустой проект не должен давать команду")

-- есть исходник: цель-исходник не возвращается, но команда запуска формируется
local f = io.open(D .. "/src/Main.java", "w"); f:write("class Main{}\n"); f:close()
assert(a:get_target(D) == nil, "исходник не является целью")
local cmd = a:get_run_command(D, { "x" })
assert(cmd and cmd[1] == "java" and cmd[2] == "-cp" and cmd[3] == D .. "/bin" and cmd[4] == "Main" and cmd[5] == "x",
    "ожидалась команда java -cp bin Main x")

-- после компиляции цель — bin/Main.class
os.execute("mkdir -p " .. D .. "/bin")
f = io.open(D .. "/bin/Main.class", "w"); f:write("x"); f:close()
assert(a:get_target(D) == D .. "/bin/Main.class")
assert(a:get_run_command(D)[4] == "Main")

os.execute("rm -rf " .. D)
print("java_run_test ok")
