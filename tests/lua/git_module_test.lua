-- Запуск из корня репозитория: lua5.4 tests/lua/git_module_test.lua
-- Проверка git.init (идемпотентность), git.add{intent}, git.reset на реальном git во временном каталоге.
package.path = "modules/?.lua;" .. package.path
local function sh(c) local p = io.popen(c .. " 2>&1"); local o = p:read("a"); local ok = p:close(); return o, ok end
local tmp = os.tmpname() .. ".d" -- каталог в /tmp, очищается системой
sh("mkdir -p " .. tmp)
local c = {
  target_dir = tmp,
  exists = function(p) return os.rename(p, p) and true or false end,
  mkdir_p = function(p) sh("mkdir -p '" .. p .. "'") end,
  capture = function(argv, cwd)
    local q = {}
    for _, a in ipairs(argv) do q[#q + 1] = "'" .. a:gsub("'", "'\\''") .. "'" end
    local o, ok = sh("cd '" .. cwd .. "' && " .. table.concat(q, " "))
    return { code = ok and 0 or 1, stdout = o, stderr = "" }
  end,
}
c.is_dir = c.exists
grime = { ctx = c, str = { trim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end,
  split = function(s, d) local r = {} for x in (s .. d):gmatch("(.-)" .. d) do r[#r + 1] = x end return r end } }
package.loaded["languages.utils"] = setmetatable({ is_git_repo = function(d) return c.exists(d .. "/.git") end }, { __index = function() return function() end end })
local git = require("git")
assert(git.init(tmp).success)
local second = git.init(tmp)
assert(second.success and second.already, "init должен быть идемпотентным")
sh("cd " .. tmp .. " && git config user.email t@t && git config user.name t && echo a > a.txt")
assert(git.add(tmp, nil, { intent = true }).success)
assert(sh("cd " .. tmp .. " && git status --porcelain"):find("^ A a.txt"), "ожидался intent-to-add")
assert(git.add(tmp).success)
sh("cd " .. tmp .. " && git commit -qm one && echo b >> a.txt && git commit -qam two")
local ok = git.reset(tmp, "HEAD~1", { hard = true })
assert(ok, "reset")
assert(sh("cat " .. tmp .. "/a.txt") == "a\n", "hard reset не откатил файл")
assert(select(1, git.reset(tmp, "nonexistent_ref")) == false)
print("ok")
