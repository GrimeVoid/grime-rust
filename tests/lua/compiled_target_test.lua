-- Запуск из корня репозитория: lua5.4 tests/lua/compiled_target_test.lua
local D = "/tmp/grime_cpp_unit_C1"
os.execute("mkdir -p " .. D .. "/src")
local f = io.open(D .. "/CMakeLists.txt", "w"); f:write("project(C1)\n"); f:close()
f = io.open(D .. "/src/main.cpp", "w"); f:write("int main(){}\n"); f:close()
package.path = "modules/?.lua;" .. package.path
local function ex(p) local f=io.open(p) if f then f:close() return true end return false end
grime = { fs = { exists = ex } }
local a = require("languages.cpp")
local t = a:get_target("/tmp/grime_cpp_unit_C1")
assert(t == D .. "/build/grime_cpp_unit_C1", t)
local logs = {}
local code = a:run("/tmp/grime_cpp_unit_C1", {}, { log = function(m) logs[#logs+1]=m end, exists = ex, run_process = function() error("не должен запускаться") end })
assert(code == 1 and logs[1]:find("не собран"), logs[1])
local py = require("languages.python")
os.execute("rm -rf " .. D)
print(a.compiled, py.compiled, "ok")
