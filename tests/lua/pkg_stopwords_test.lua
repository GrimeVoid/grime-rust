-- Запуск из корня репозитория: lua5.4 tests/lua/pkg_stopwords_test.lua
package.path = "modules/?.lua;" .. package.path
local u = require("languages.utils")
for _, n in ipairs({ "build", "src", "lib", "bin", "test", "tests", "docs" }) do
  assert(not u.valid_pkg_name(n), "стоп-слово должно отвергаться: " .. n)
  assert(u.valid_pkg_name(n, true), "явное объявление допустимо: " .. n)
end
for _, n in ipairs({ "cmake", "gcc", "pkg-config", "SDL2" }) do assert(u.valid_pkg_name(n), n) end
-- CLI-токен build не попадает в пакеты, манифестный попадает
local r = u.collect_nix_packages(nil, { dependencies = { "lib" } }, { toolchain = { "gcc" } }, { "build", "ninja" }, nil)
local all = table.concat(r.native, " ") .. " " .. table.concat(r.libs, " ")
assert(not all:find("build", 1, true), all)
assert(all:find("ninja", 1, true) and all:find("gcc", 1, true), all)
print("ok")
