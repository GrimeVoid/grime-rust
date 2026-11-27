-- Запуск из корня репозитория: lua5.4 tests/lua/valid_name_test.lua
package.path = "modules/?.lua;" .. package.path
local u = require("languages.utils")
for _, n in ipairs({".", "..", "", ".hidden", "./x", "a/b", "a\\b", "a..b", "-x", "a\0b", "a\nb"}) do
  assert(not u.valid_name(n), "должно быть отвергнуто: " .. n:gsub("%c","?"))
end
for _, n in ipairs({"proj", "my-app_1", "a.b"}) do assert(u.valid_name(n), n) end
print("ok")
