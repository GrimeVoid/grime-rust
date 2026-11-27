-- Юнит-тесты общих функций languages.utils. Запуск из корня: lua5.4 tests/lua/utils_common_test.lua
package.path = "modules/?.lua;" .. package.path
local u = require("languages.utils")

local tmp = os.tmpname()
os.remove(tmp)
tmp = tmp .. "_grime_ut"
os.execute("mkdir -p '" .. tmp .. "'")

local function write(p, c) local f = assert(io.open(p, "wb")); f:write(c); f:close() end
local function read(p) local f = assert(io.open(p, "rb")); local c = f:read("*a"); f:close(); return c end

-- djb2_hex: стабильность и формат
assert(u.djb2_hex("abc") == u.djb2_hex("abc"))
assert(u.djb2_hex("abc") ~= u.djb2_hex("abd"))
assert(u.djb2_hex(""):match("^%x%x%x%x%x%x%x%x$"))
assert(u.djb2_hex("") == "00001505")

-- write_flake
local d = tmp .. "/fl"
os.execute("mkdir -p '" .. d .. "'")
local ok, path = u.write_flake(d, "demo", { "gcc" }, { "zlib" }, {})
assert(ok and path == d .. "/flake.nix")
local fl = read(path)
assert(fl:find("gcc", 1, true) and fl:find("zlib", 1, true))
local bad = u.write_flake(tmp .. "/нет/каталога", "x", {}, {}, {})
assert(bad == false)

-- ensure_shebang
write(tmp .. "/a.py", "print(1)\n")
assert(u.ensure_shebang(tmp .. "/a.py", "python"))
assert(read(tmp .. "/a.py"):sub(1, 2) == "#!")
assert(read(tmp .. "/a.py"):find("print(1)", 1, true))
write(tmp .. "/b.sh", "\239\187\191#!/bin/sh\necho\n")
assert(u.ensure_shebang(tmp .. "/b.sh"))
assert(read(tmp .. "/b.sh"):sub(1, 2) == "#!")
write(tmp .. "/c.bin", "\127ELF\0\0")
assert(not u.ensure_shebang(tmp .. "/c.bin", "python"))
write(tmp .. "/d.txt", "x")
assert(not u.ensure_shebang(tmp .. "/d.txt", "unknown"))
assert(not u.ensure_shebang(tmp .. "/нет.py", "python"))

-- wrap_pipeline_run
local r = u.wrap_pipeline_run({ "a", ":", "b" }, { "box1" })
assert(table.concat(r.args, " ") == "-run box1 -- a : b")
r = u.wrap_pipeline_run({ "x" })
assert(table.concat(r.args, " ") == "-run -- x")
assert(u.wrap_pipeline_run({}) == nil)

-- load_manifest_sandboxed: нет доступа к os/io
write(tmp .. "/app.lua", 'return { name = "t", description = "d", home = os.getenv("HOME") ~= nil, '
    .. 'deps = { "gcc" }, io_ok = (io ~= nil), exec_ok = (os.execute ~= nil) }\n')
local m = assert(u.load_manifest_sandboxed(tmp))
assert(m.name == "t" and m.io_ok == false and m.exec_ok == false)
assert(u.load_manifest_sandboxed(tmp .. "/app.lua").name == "t")
write(tmp .. "/evil.lua", 'return { x = os.execute("true") }')
local em, err = u.load_manifest_sandboxed(tmp .. "/evil.lua")
assert(em == nil and err)
write(tmp .. "/loop.lua", 'while true do end')
local lm, lerr = u.load_manifest_sandboxed(tmp .. "/loop.lua")
assert(lm == nil and lerr)
write(tmp .. "/notab.lua", 'return 5')
assert(u.load_manifest_sandboxed(tmp .. "/notab.lua") == nil)
assert(u.load_manifest_sandboxed(tmp .. "/nonexistent") == nil)

-- collect_nix_packages: фильтрация невалидных имён
local warned = 0
local orig = u.warn_invalid_pkg
u.warn_invalid_pkg = function() warned = warned + 1 end
local scan = { toolchain = { "gcc" }, special_dependencies = { "pkgs.zlib", "bad name; rm" } }
local res = u.collect_nix_packages(tmp, { dependencies = { "openssl", "$(evil)" }, special_dependencies = "curl" },
    scan, { "pkgs.sdl2", "a/b" })
u.warn_invalid_pkg = orig
assert(warned == 3, "ожидалось 3 предупреждения, получено " .. warned)
local all = {}
for _, p in ipairs(res.native) do all[p] = true end
for _, p in ipairs(res.libs) do all[p] = true end
for _, want in ipairs({ "gcc", "zlib", "openssl", "curl", "sdl2" }) do assert(all[want], want) end
for k in pairs(all) do assert(u.valid_pkg_name(k), k) end
local us = {}
for _, p in ipairs(res.user) do us[p] = true end
assert(us.openssl and us.curl and us.sdl2 and not us.gcc and not us.zlib)

-- develop_cmd
assert(table.concat(u.develop_cmd("/x/y", { "make", "-j" }), " ") == "nix develop path:/x/y --command make -j")
assert(table.concat(u.develop_cmd(nil, { "ls" }), " ") == "nix develop --command ls")
assert(table.concat(u.develop_cmd("github:o/r#d", { "ls" }), " ") == "nix develop github:o/r#d --command ls")

-- lang_dir_names / алиасы
local all_names = u.lang_dir_names()
assert(all_names[1] == "cpp")
local cpp = u.lang_dir_names("c++")
assert(cpp[1] == "cpp" and #cpp > 1)
assert(#u.lang_dir_names("неизвестно") == 0)
assert(u.LANG_ALIASES.sh == "bash" and u.LANG_ALIASES.fish == "fish")

-- удалённый мёртвый код
assert(u.generate_app_manifest == nil and u.detect_shebang == nil)

os.execute("rm -rf '" .. tmp .. "'")
print("ok")
