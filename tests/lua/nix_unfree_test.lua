-- Тесты unfree-поддержки Nix. Запуск из корня: lua5.4 tests/lua/nix_unfree_test.lua
package.path = "modules/?.lua;" .. package.path

local cfg_value = nil
grime = { config = { get = function(k) if k == "nix_allow_unfree" then return cfg_value end end } }
local u = require("languages.utils")

local function eq(a, b, msg) assert(a == b, (msg or "") .. ": ожидалось " .. tostring(b) .. ", получено " .. tostring(a)) end

-- по умолчанию включено
cfg_value = nil
eq(u.nix_allow_unfree(), true, "умолчание")
eq(u.nix_unfree_env().NIXPKGS_ALLOW_UNFREE, "1", "env")
eq(u.nix_unfree_flags()[1], "--impure", "флаг")
for _, v in ipairs({ "true", "1", "yes", "on", "" }) do
    cfg_value = v
    eq(u.nix_allow_unfree(), true, "значение " .. v)
end

-- отключение
for _, v in ipairs({ "false", "FALSE", "False", "0", "no", "NO", "off", "Off", " off ", false }) do
    cfg_value = v
    eq(u.nix_allow_unfree(), false, "значение " .. tostring(v))
    eq(u.nix_unfree_env(), nil, "env выкл")
    eq(#u.nix_unfree_flags(), 0, "флаги выкл")
end

-- генерация flake
cfg_value = nil
local fl = u.generate_flake_nix("demo", { "gcc" }, {})
assert(fl:find("allowUnfree = true", 1, true), "flake без allowUnfree")
assert(not fl:find("legacyPackages", 1, true), "legacyPackages при unfree")
cfg_value = "false"
fl = u.generate_flake_nix("demo", { "gcc" }, {})
assert(not fl:find("allowUnfree", 1, true), "allowUnfree при выключенном")
assert(fl:find("legacyPackages", 1, true), "нет legacyPackages")

-- команда установки: nix profile add
cfg_value = nil
local cmd, env = u.nix_profile_add_cmd({ "vscode", "github:foo/bar", "nixpkgs#hello" })
eq(table.concat(cmd, " "), "nix profile add --impure nixpkgs#vscode github:foo/bar nixpkgs#hello", "cmd")
eq(env.NIXPKGS_ALLOW_UNFREE, "1", "env установки")
cfg_value = "off"
cmd, env = u.nix_profile_add_cmd({ "vscode" })
eq(table.concat(cmd, " "), "nix profile add nixpkgs#vscode", "cmd выкл")
eq(env, nil, "env выкл")

print("nix_unfree_test: OK")
