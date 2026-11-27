-- Проверка аннотаций `--@grime requires:` в modules/*.lua: ссылки на существующие модули
-- и отсутствие циклов по обязательным module:-зависимостям.
-- Запуск из корня репозитория: lua5.4 tests/lua/requires_annotations_test.lua
local p = io.popen('ls modules/*.lua')
local mods, deps = {}, {}
for path in p:lines() do mods[path:match("modules/(.+)%.lua$")] = path end
p:close()

for name, path in pairs(mods) do
  deps[name] = {}
  local f = assert(io.open(path, "r"))
  for line in f:lines() do
    if not line:match("^%-%-") then break end -- только шапка файла
    local val = line:match("^%-%-@grime%s+requires:%s*(.-)%s*$")
    if val then
      for item in val:gmatch("[^,]+") do
        item = item:match("^%s*(.-)%s*$")
        local optional = item:sub(-1) == "?"
        if optional then item = item:sub(1, -2) end
        local kind, dep = item:match("^(%a+):(.+)$")
        if not kind then kind, dep = "module", item end
        dep = dep:lower()
        assert(kind == "module" or kind == "bin" or kind == "nix",
          name .. ": неизвестный вид зависимости '" .. item .. "'")
        if kind == "module" then
          assert(mods[dep], name .. ": зависимость от несуществующего модуля '" .. dep .. "'")
          assert(dep ~= name, name .. ": зависимость от самого себя")
          deps[name][#deps[name] + 1] = { name = dep, optional = optional }
        end
      end
    end
  end
  f:close()
end

-- Поиск цикла (DFS) по обязательным зависимостям
local state = {}
local function visit(n, stack)
  if state[n] == 2 then return end
  assert(state[n] ~= 1, "цикл зависимостей: " .. table.concat(stack, " -> ") .. " -> " .. n)
  state[n] = 1
  stack[#stack + 1] = n
  for _, d in ipairs(deps[n]) do
    if not d.optional then visit(d.name, stack) end
  end
  stack[#stack] = nil
  state[n] = 2
end
for n in pairs(mods) do visit(n, {}) end
print("ok")
