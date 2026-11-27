--@grime description: Унифицированный менеджер пакетов хоста, Nix, Flatpak, Cargo и Distrobox
--@grime requires: module:box?, module:app?


local utils = require("languages.utils")

-- Модульные переменные file-scope
local ctx = grime.ctx
local fs = grime.fs
local HOME = os.getenv("HOME") or ""
local pad_utf8 = utils.pad_utf8

local has_binary = function(bin) return utils.has_binary(bin, ctx) end
local get_apps_root = function() return utils.get_named_path("apps", HOME .. "/.config/grime/apps", ctx) end
local is_root_user = function() return utils.is_root_user(ctx) end

-- Флаги выбора GPU, которые не относятся к запускаемой утилите
local GPU_FLAGS = {
    ["--nv"] = true, ["--prime"] = true, ["--nvidia"] = true,
    ["--gl"] = true, ["--gpu"] = true, ["--no-gpu"] = true,
}

--- Копия списка токенов без GPU-флагов
local function strip_gpu_flags(tokens)
    local out = {}
    for _, t in ipairs(tokens or {}) do
        if not GPU_FLAGS[t] then table.insert(out, t) end
    end
    return out
end

-- Менеджеры, опрашиваемые в сводке и сквозном поиске (порядок вывода)
local SCAN_MANAGERS = { "pacman", "yay", "dnf", "apt", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx" }

-- Кэши результатов в пределах одного вызова (сбрасываются в начале main/handle_not_found)
local pkg_cache = {}
local distrobox_cache = nil

local function reset_caches()
    pkg_cache = {}
    distrobox_cache = nil
end

local ACTIONS = {
    ["-list"] = "list", ["--list"] = "list", ["-ls"] = "list", ["--ls"] = "list", ["-l"] = "list",
    ["-install"] = "install", ["--install"] = "install", ["-i"] = "install", ["-add"] = "install", ["--add"] = "install",
    ["-update"] = "update", ["--update"] = "update", ["-u"] = "update", ["--upgrade"] = "update", ["-upgrade"] = "update", ["-up"] = "update", ["--up"] = "update",
    ["-remove"] = "remove", ["--remove"] = "remove", ["-rm"] = "remove", ["--rm"] = "remove", ["-uninstall"] = "remove", ["--uninstall"] = "remove", ["-del"] = "remove", ["--del"] = "remove",
    ["-run"] = "run", ["--run"] = "run", ["-r"] = "run",
    ["-init"] = "init", ["--init"] = "init", ["-shell"] = "init", ["--shell"] = "init",
    ["-search"] = "search", ["--search"] = "search", ["-s"] = "search", ["-find"] = "search", ["--find"] = "search",
    ["-not-found"] = "not_found", ["--not-found"] = "not_found", ["-cnf"] = "not_found",
    ["-help"] = "help", ["--help"] = "help", ["-h"] = "help",
}

local CANONICAL_MANAGERS = {
    "pacman", "yay", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx", "dnf", "apt", "host"
}

local MANAGER_ALIASES = {
    pacman = "pacman", pac = "pacman", arch = "pacman",
    yay = "yay", aur = "yay", y = "yay",
    flatpak = "flatpak", flat = "flatpak", flt = "flatpak", fp = "flatpak",
    nix = "nix", nixpkgs = "nix", nx = "nix",
    distrobox = "distrobox", dbox = "distrobox", box = "distrobox", distro = "distrobox", dist = "distrobox",
    apps = "apps", app = "apps", application = "apps", applications = "apps",
    cargo = "cargo", crg = "cargo", rust = "cargo",
    pipx = "pipx", pip = "pipx", python = "pipx",
    dnf = "dnf", fedora = "dnf",
    apt = "apt", debian = "apt", ubuntu = "apt",
    host = "host", sys = "host", system = "host",
}

local MANAGER_BINARIES = {
    pacman = "pacman",
    yay = "yay",
    flatpak = "flatpak",
    nix = "nix",
    distrobox = "distrobox",
    cargo = "cargo",
    pipx = "pipx",
    dnf = "dnf",
    apt = "apt",
}

-- Нечеткое сопоставление строк (Fuzzy Matching)
local function fuzzy_match(pattern, text)
    if not pattern or pattern == "" then return true, 0 end
    if not text or text == "" then return false, 0 end
    local p = pattern:lower()
    local t = text:lower()

    if p == t then return true, 1000 end

    local s, _ = t:find(p, 1, true)
    if s then
        local bonus = (s == 1) and 600 or 400
        return true, bonus - s
    end

    local p_len = #p
    local t_len = #t

    -- Для коротких запросов (1-3 символа) проверяем акроним по первым буквам слов
    if p_len <= 3 then
        local acronym = ""
        for word in t:gmatch("[^%s_%-%.]+") do
            acronym = acronym .. word:sub(1, 1)
        end
        if acronym:find(p, 1, true) then
            return true, 250
        end
        return false, 0
    end

    -- Для запросов длиннее 3 символов — полноценный fuzzy со штрафами
    local p_idx = 1
    local score = 0
    local prev_match_idx = 0
    local consecutive = 0

    for t_idx = 1, t_len do
        if p_idx <= p_len and t:sub(t_idx, t_idx) == p:sub(p_idx, p_idx) then
            if prev_match_idx > 0 and t_idx == prev_match_idx + 1 then
                consecutive = consecutive + 1
                score = score + 20 + (consecutive * 5)
            else
                consecutive = 0
                score = score + 10
            end
            if t_idx == 1 or t:sub(t_idx - 1, t_idx - 1):match("[_%-%.%s/]") then
                score = score + 25
            end
            prev_match_idx = t_idx
            p_idx = p_idx + 1
        end
    end

    if p_idx > p_len and score >= p_len * 15 then
        return true, score
    end
    return false, 0
end

-- Разрешение имени менеджера по нечеткому запросу
local function resolve_manager(query)
    if not query or query == "" then return nil end
    local q = tostring(query):lower():gsub("^%-+", "")
    if q == "" then return nil end

    -- 1. Точный алиас
    if MANAGER_ALIASES[q] then
        return MANAGER_ALIASES[q]
    end

    -- 2. Префикс среди канонических
    if #q >= 2 then
        for _, mgr in ipairs(CANONICAL_MANAGERS) do
            if mgr:sub(1, #q) == q then
                return mgr
            end
        end
    end

    -- 3. Подстрока среди канонических (от 3-х символов)
    if #q >= 3 then
        for _, mgr in ipairs(CANONICAL_MANAGERS) do
            if mgr:find(q, 1, true) then
                return mgr
            end
        end
    end

    -- 4. Унифицированный нечеткий поиск менеджеров с высоким порогом (порог 0.75)
    local best_mgr, score = grime.fuzzy.find_best_match(q, CANONICAL_MANAGERS, 0.75)
    if best_mgr then
        return best_mgr
    end

    return nil
end

-- Сбор пакетов: pacman
local function get_pacman_packages(all_mode)
    if not has_binary("pacman") then return nil, "pacman не установлен" end
    local q_flag = all_mode and "-Q" or "-Qe"
    local res = ctx.capture({ "pacman", q_flag })
    if res.code ~= 0 then return nil, "Ошибка выполнения pacman " .. q_flag end
    local list = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s+(%S+)")
        if name then
            table.insert(list, { name = name, version = ver or "", details = "" })
        end
    end
    return list
end

-- Сбор пакетов: yay (AUR)
local function get_yay_packages(all_mode)
    if not has_binary("yay") then return nil, "yay не установлен" end
    local q_flag = all_mode and "-Q" or "-Qm"
    local res = ctx.capture({ "yay", q_flag })
    if res.code ~= 0 then return nil, "Ошибка выполнения yay " .. q_flag end
    local list = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s+(%S+)")
        if name then
            table.insert(list, { name = name, version = ver or "", details = all_mode and "" or "AUR" })
        end
    end
    return list
end

-- Сбор пакетов: flatpak
local function get_flatpak_packages(all_mode)
    if not has_binary("flatpak") then return nil, "flatpak не установлен" end
    local cache_key = "flatpak:" .. (all_mode and "all" or "user")
    if pkg_cache[cache_key] then return pkg_cache[cache_key] end
    local args = { "flatpak", "list" }
    if not all_mode then
        table.insert(args, "--app")
    end
    table.insert(args, "--columns=name,application,version")
    local res = ctx.capture(args)
    if res.code ~= 0 then return nil, "Ошибка выполнения flatpak list" end
    local list = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        local parts = {}
        for p in (line .. "\t"):gmatch("(.-)\t") do
            table.insert(parts, p:match("^%s*(.-)%s*$"))
        end
        if #parts >= 2 and parts[1] ~= "Name" then
            table.insert(list, {
                name = parts[1],
                version = parts[3] or "",
                details = parts[2] or ""
            })
        end
    end
    pkg_cache[cache_key] = list
    return list
end

-- Сбор пакетов: nix
local function get_nix_packages(all_mode)
    if not has_binary("nix") then return nil, "nix не установлен" end
    if not all_mode then
        local res = ctx.capture({ "nix", "profile", "list" })
        if res.code ~= 0 then return nil, "Ошибка выполнения nix profile list" end
        local list = {}
        local current = nil
        for line in res.stdout:gmatch("[^\r\n]+") do
            local key, val = line:match("^([^:]+):%s*(.*)$")
            if key and val then
                key = key:match("^%s*(.-)%s*$")
                val = val:match("^%s*(.-)%s*$")
                if key == "Name" or key:match("^Index%s*%d+") then
                    if current and current.name then
                        table.insert(list, current)
                    end
                    current = { name = val, version = "", details = "", path = "" }
                elseif current then
                    if key == "Flake attribute" then
                        current.details = val
                        if not current.name or current.name == "" then
                            current.name = val:match("packages%S+%.(%S+)") or val:match("legacyPackages%S+%.(%S+)") or val
                        end
                    elseif key == "Store paths" then
                        current.path = val
                        local v = val:match("%-(%d+%.?[%d%.%-_]*)") or val:match("%-(%d+)")
                        if v then
                            v = v:gsub("%-man$", ""):gsub("%-bin$", ""):gsub("%-+$", "")
                            current.version = v
                        end
                    end
                end
            end
        end
        if current and current.name then
            table.insert(list, current)
        end
        return list
    else
        -- all_mode: все замыкания/зависимости профиля
        local profile_path = (os.getenv("HOME") or "") .. "/.nix-profile"
        local res = ctx.capture({ "nix", "path-info", "-r", profile_path })
        if res.code ~= 0 or not res.stdout or res.stdout:match("%S") == nil then
            res = ctx.capture({ "nix-store", "-qR", profile_path })
        end
        if res.code ~= 0 or not res.stdout then
            return nil, "Ошибка получения зависимостей nix profile"
        end
        local list = {}
        local seen = {}
        for line in res.stdout:gmatch("[^\r\n]+") do
            local p = line:match("^%s*(.-)%s*$")
            if p ~= "" and not seen[p] then
                seen[p] = true
                local store_base = p:match("^/nix/store/[0-9a-z]+%-(.+)$") or p:match("^/nix/store/(.+)$") or p
                local base_nosuffix, suffix = store_base:match("^(.-)%-(%a+)$")
                local name, ver
                if base_nosuffix then
                    name, ver = base_nosuffix:match("^(.-)%-(%d+[%d%.%-_]*)$")
                    if name and ver then
                        ver = ver .. " (" .. suffix .. ")"
                    end
                end
                if not name then
                    name, ver = store_base:match("^(.-)%-(%d+[%d%.%-_]*)$")
                end
                if not name then
                    name = store_base
                    ver = ""
                end
                table.insert(list, {
                    name = name,
                    version = ver or "",
                    details = "замыкание nix-profile",
                    path = p
                })
            end
        end
        table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
        return list
    end
end

-- Модуль box (экспорт get_containers/get_default_box/get_current_container/exec); nil, если недоступен
local function box_module()
    local ok, m = pcall(require, "box")
    if ok and type(m) == "table" then return m end
    return nil
end

-- Информация об активном контейнере Distrobox: { name, running }. Один `distrobox list` на вызов
local function get_distrobox_info()
    if distrobox_cache ~= nil then return distrobox_cache or nil end
    distrobox_cache = false
    local bx = box_module()
    if not bx then return nil end
    if not (has_binary("distrobox") or has_binary("distrobox-host-exec")) then return nil end
    local containers = bx.get_containers()
    local name = bx.get_default_box(containers)
    if not name then return nil end
    for _, c in ipairs(containers) do
        if c.name == name then
            local st = string.lower(c.status or "")
            distrobox_cache = { name = name, running = (st:find("up") or st:find("running")) ~= nil }
            return distrobox_cache
        end
    end
    return nil
end

-- Выполнение shell-команды в контейнере с захватом вывода: изнутри этого же контейнера — напрямую,
-- иначе через distrobox enter (при отсутствии distrobox в контейнере — через distrobox-host-exec)
local function box_capture(box_name, argv)
    local bx = box_module()
    local current = bx and bx.get_current_container() or nil
    if current ~= nil and current == box_name then
        return ctx.capture(argv)
    end
    local full = {}
    if current ~= nil and not has_binary("distrobox") and has_binary("distrobox-host-exec") then
        full[#full + 1] = "distrobox-host-exec"
    end
    for _, t in ipairs({ "distrobox", "enter", box_name, "--" }) do full[#full + 1] = t end
    for _, t in ipairs(argv) do full[#full + 1] = t end
    return ctx.capture(full)
end

-- Определение активного контейнера Distrobox
local function get_distrobox_target()
    local info = get_distrobox_info()
    return info and info.name or nil
end

-- Сбор пакетов: distrobox
local function get_distrobox_packages(box_name, all_mode)
    box_name = box_name or get_distrobox_target()
    if not box_name then return nil, "Контейнер distrobox не найден" end
    local qcmd
    if not all_mode then
        -- По умолчанию: только установленные непосредственно пользователем пакеты
        local b64_script = "aW1wb3J0IHNxbGl0ZTMsIHN1YnByb2Nlc3MsIG9zCmRiID0gIi91c3IvbGliL3N5c2ltYWdlL2xpYmRuZjUvdHJhbnNhY3Rpb25faGlzdG9yeS5zcWxpdGUiCmlmIG9zLnBhdGguZXhpc3RzKGRiKToKICAgIHRyeToKICAgICAgICBjb24gPSBzcWxpdGUzLmNvbm5lY3QoZGIpCiAgICAgICAgY3VyID0gY29uLmN1cnNvcigpCiAgICAgICAgYmFzZV9pZHMgPSBbclswXSBmb3IgciBpbiBjdXIuZXhlY3V0ZSgiU0VMRUNUIGlkIEZST00gdHJhbnMgV0hFUkUgZGVzY3JpcHRpb24gTElLRSAnJWtpd2klJyBPUiBpZCA9IDEiKS5mZXRjaGFsbCgpXQogICAgICAgIGJhc2VfaWQgPSBtYXgoYmFzZV9pZHMpIGlmIGJhc2VfaWRzIGVsc2UgMQogICAgICAgIHEgPSAiU0VMRUNUIERJU1RJTkNUIHBuLm5hbWUgRlJPTSB0cmFucyB0IEpPSU4gdHJhbnNfaXRlbSB0aSBPTiB0aS50cmFuc19pZCA9IHQuaWQgSk9JTiB0cmFuc19pdGVtX2FjdGlvbiB0aWEgT04gdGlhLmlkID0gdGkuYWN0aW9uX2lkIEpPSU4gdHJhbnNfaXRlbV9yZWFzb24gdGlyIE9OIHRpci5pZCA9IHRpLnJlYXNvbl9pZCBKT0lOIGl0ZW0gaXQgT04gaXQuaWQgPSB0aS5pdGVtX2lkIEpPSU4gcnBtIHIgT04gci5pdGVtX2lkID0gaXQuaWQgSk9JTiBwa2dfbmFtZSBwbiBPTiBwbi5pZCA9IHIubmFtZV9pZCBXSEVSRSB0LmlkID4gPyBBTkQgdGlhLm5hbWUgPSAnSW5zdGFsbCcgQU5EIHRpci5uYW1lID0gJ1VzZXInIgogICAgICAgIHBrZ3MgPSBbclswXSBmb3IgciBpbiBjdXIuZXhlY3V0ZShxLCAoYmFzZV9pZCwpKS5mZXRjaGFsbCgpXQogICAgICAgIGlmIHBrZ3M6CiAgICAgICAgICAgIHJlcyA9IHN1YnByb2Nlc3MucnVuKFsicnBtIiwgIi1xIiwgIi0tcWYiLCAiJXtOQU1FfSAle1ZFUlNJT059XG4iXSArIHBrZ3MsIGNhcHR1cmVfb3V0cHV0PVRydWUsIHRleHQ9VHJ1ZSkKICAgICAgICAgICAgZm9yIGxpbmUgaW4gcmVzLnN0ZG91dC5zdHJpcCgpLnNwbGl0KCJcbiIpOgogICAgICAgICAgICAgICAgaWYgbGluZSBhbmQgIm5vdCBpbnN0YWxsZWQiIG5vdCBpbiBsaW5lOgogICAgICAgICAgICAgICAgICAgIHByaW50KGxpbmUpCiAgICBleGNlcHQgRXhjZXB0aW9uOgogICAgICAgIHBhc3MK"
        qcmd = 'if [ -f /usr/lib/sysimage/libdnf5/transaction_history.sqlite ] && command -v python3 >/dev/null 2>&1; then ' ..
               'echo "' .. b64_script .. '" | base64 -d | python3; ' ..
               'elif command -v dnf >/dev/null 2>&1 && dnf history userinstalled >/dev/null 2>&1; then ' ..
               'dnf history userinstalled 2>/dev/null; ' ..
               'elif command -v pacman >/dev/null 2>&1; then ' ..
               'pacman -Qe 2>/dev/null; ' ..
               'elif command -v apt-mark >/dev/null 2>&1; then ' ..
               '(apt-mark showmanual 2>/dev/null | xargs -r dpkg-query -W -f="${Package} ${Version}\n" 2>/dev/null); ' ..
               'else ' ..
               'dnf -C repoquery --userinstalled --qf "%{NAME} %{VERSION}\n" 2>/dev/null || dnf repoquery --userinstalled --qf "%{NAME} %{VERSION}\n" 2>/dev/null; ' ..
               'fi'
    else
        -- Если флаг -a / --all: все установленные пакеты
        qcmd = 'rpm -qa --qf "%{NAME} %{VERSION}-%{RELEASE}\n" 2>/dev/null || ' ..
               'pacman -Q 2>/dev/null || ' ..
               'dpkg-query -f "${Package} ${Version}\n" -W 2>/dev/null'
    end
    local res = box_capture(box_name, { "sh", "-c", qcmd })
    if res.code ~= 0 or not res.stdout then return nil, "Ошибка получения пакетов из " .. box_name end
    local list = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s+(%S+)")
        if not name then name = line:match("^(%S+)") end
        if name and name ~= "" then
            table.insert(list, {
                name = name,
                version = ver or "",
                details = "контейнер: " .. box_name
            })
        end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list, box_name
end

-- Сбор пакетов: apps
local function get_apps_packages(_all_mode)
    local apps_root = get_apps_root()
    if not ctx.exists(apps_root) then return {} end
    local ok_app, app_mod = pcall(require, "app")
    if not ok_app or type(app_mod) ~= "table" or type(app_mod.collect_apps) ~= "function" then return {} end
    local list = {}
    for _, a in ipairs(app_mod.collect_apps(apps_root)) do
        local has_flake = ctx.exists(a.path .. "/flake.nix")
        local desc = ""
        local ver = has_flake and "flake" or "local"
        local m = a.m
        if m then
            desc = m.description or ""
            if m.version then
                ver = m.version
            elseif not has_flake and m.type and m.type ~= "generic" then
                ver = m.type
            end
        end
        table.insert(list, { name = a.name, version = ver, details = desc, path = a.path })
    end
    table.sort(list, function(x, y) return x.name:lower() < y.name:lower() end)
    return list
end

-- Сбор пакетов: cargo
local function get_cargo_packages(_all_mode)
    if not has_binary("cargo") then return nil, "cargo не установлен" end
    local res = ctx.capture({ "cargo", "install", "--list" })
    if res.code ~= 0 then return nil, "Ошибка выполнения cargo install --list" end
    local list = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        if not line:match("^%s") and line:match(":") then
            local name, ver = line:match("^([%w%-_]+)%s+v?([%d%.%-_]+):")
            if not name then name = line:match("^([%w%-_]+)") end
            if name then
                table.insert(list, { name = name, version = ver or "", details = "" })
            end
        end
    end
    return list
end

-- Сбор пакетов: pipx
local function get_pipx_packages(_all_mode)
    if not has_binary("pipx") then return nil, "pipx не установлен" end
    local res = ctx.capture({ "pipx", "list", "--short" })
    if res.code ~= 0 then return nil, "Ошибка выполнения pipx list" end
    local list = {}
    for line in res.stdout:gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s+(%S+)")
        if name then
            table.insert(list, { name = name, version = ver or "", details = "" })
        end
    end
    return list
end

-- Сбор пакетов: dnf
local function get_dnf_packages(all_mode)
    if not has_binary("dnf") then return nil, "dnf не установлен" end
    local cmd = all_mode and { "rpm", "-qa", "--qf", "%{NAME} %{VERSION}-%{RELEASE}\n" } or { "dnf", "repoquery", "--userinstalled", "--qf", "%{name} %{version}" }
    local res = ctx.capture(cmd)
    if res.code ~= 0 then return nil, "Ошибка выполнения dnf/rpm" end
    local list = {}
    for line in (res.stdout or ""):gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s+(%S+)")
        if name then table.insert(list, { name = name, version = ver or "", details = "" }) end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

-- Сбор пакетов: apt
local function get_apt_packages(all_mode)
    if not has_binary("apt-mark") and not has_binary("dpkg-query") then return nil, "apt не установлен" end
    local cmd = all_mode and { "dpkg-query", "-f", "${Package} ${Version}\n", "-W" } or { "apt-mark", "showmanual" }
    local res = ctx.capture(cmd)
    if res.code ~= 0 then return nil, "Ошибка выполнения apt/dpkg" end
    local list = {}
    for line in (res.stdout or ""):gmatch("[^\r\n]+") do
        local name, ver = line:match("^(%S+)%s*(%S*)")
        if name and #name > 0 then table.insert(list, { name = name, version = ver or "", details = "" }) end
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

-- Обобщенный диспетчер получения пакетов (без кэша)
local function fetch_packages_for_manager(mgr, all_mode)
    if mgr == "pacman" then
        return get_pacman_packages(all_mode)
    elseif mgr == "yay" then
        return get_yay_packages(all_mode)
    elseif mgr == "dnf" then
        return get_dnf_packages(all_mode)
    elseif mgr == "apt" then
        return get_apt_packages(all_mode)
    elseif mgr == "host" then
        if has_binary("pacman") then return get_pacman_packages(all_mode)
        elseif has_binary("dnf") then return get_dnf_packages(all_mode)
        elseif has_binary("apt") then return get_apt_packages(all_mode)
        end
        return nil, "Системный пакетный менеджер хоста не обнаружен"
    elseif mgr == "flatpak" then
        return get_flatpak_packages(all_mode)
    elseif mgr == "nix" then
        return get_nix_packages(all_mode)
    elseif mgr == "distrobox" then
        return get_distrobox_packages(nil, all_mode)
    elseif mgr == "apps" or mgr == "app" then
        return get_apps_packages(all_mode)
    elseif mgr == "cargo" then
        return get_cargo_packages(all_mode)
    elseif mgr == "pipx" then
        return get_pipx_packages(all_mode)
    end
    return nil, "Неизвестный менеджер: " .. tostring(mgr)
end

-- Диспетчер получения пакетов с кэшем результата в пределах вызова
local function get_packages_for_manager(mgr, all_mode)
    local key = "mgr:" .. tostring(mgr) .. ":" .. (all_mode and "all" or "user")
    local hit = pkg_cache[key]
    if hit then return hit.list, hit.extra end
    local list, extra = fetch_packages_for_manager(mgr, all_mode)
    if list then pkg_cache[key] = { list = list, extra = extra } end
    return list, extra
end

--- Нечёткий фильтр списка пакетов по запросу (имя и детали) с сортировкой по релевантности.
--- Возвращает массив { pkg, score }
local function fuzzy_filter(pkgs, query)
    local matches = {}
    for _, pkg in ipairs(pkgs) do
        local m1, s1 = fuzzy_match(query, pkg.name)
        local m2, s2 = fuzzy_match(query, pkg.details or "")
        if m1 or m2 then
            table.insert(matches, { pkg = pkg, score = math.max(s1 or 0, s2 or 0) })
        end
    end
    table.sort(matches, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.pkg.name:lower() < b.pkg.name:lower()
    end)
    return matches
end

--- Нужно ли опрашивать менеджер без явного запроса: distrobox только если контейнер уже запущен
--- (иначе `distrobox enter` запустит контейнер ради сводки/поиска)
local function should_scan_manager(mgr, explicit)
    if mgr ~= "distrobox" or explicit then return true end
    local info = get_distrobox_info()
    return info ~= nil and info.running
end

-- 1. Сводная таблица активных пакетных менеджеров
local function handle_summary(all_mode, show_all_managers)
    local mode_badge = all_mode and "\27[33m[ВСЕ ПАКЕТЫ И ЗАВИСИМОСТИ]\27[0m" or "\27[32m[ПОЛЬЗОВАТЕЛЬСКИЕ]\27[0m"
    if show_all_managers then
        mode_badge = mode_badge .. " \27[36m[ВСЕ МЕНЕДЖЕРЫ]\27[0m"
    end
    io.stdout:write(string.format("\n\27[1m📦 Обзор активных пакетных менеджеров системы %s:\27[0m\n", mode_badge))
    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write(string.format("  \27[1m%s %s %s %s\27[0m\n",
        pad_utf8("МЕНЕДЖЕР", 24),
        pad_utf8("СТАТУС", 16),
        pad_utf8("ПАКЕТЫ", 10),
        "ПРЕВЬЮ"))
    io.stdout:write(string.rep("─", 80) .. "\n")

    local active_count = 0
    local shown_managers = {}

    for _, mgr in ipairs(SCAN_MANAGERS) do
        local bin = MANAGER_BINARIES[mgr]
        local is_installed = true
        if bin then
            is_installed = has_binary(bin)
        end

        if is_installed or show_all_managers then
            local display_name = mgr
            local status_raw = "Активен"
            local status_color = "\27[32m"
            local count_str = "-"
            local preview_str = ""

            if not is_installed then
                status_raw = "Не установлен"
                status_color = "\27[90m"
            elseif not should_scan_manager(mgr, show_all_managers) then
                -- Контейнер не запущен: не стартуем его ради сводки
                status_raw = "Остановлен"
                status_color = "\27[33m"
                preview_str = "\27[90mgrime pkg box (или -v) — запросить явно\27[0m"
                table.insert(shown_managers, mgr)
            else
                local pkgs, extra = get_packages_for_manager(mgr, all_mode)
                if pkgs then
                    active_count = active_count + 1
                    table.insert(shown_managers, mgr)
                    local count = #pkgs
                    count_str = string.format("%d", count)
                    if mgr == "distrobox" and extra then
                        display_name = string.format("distrobox (%s)", extra)
                    end

                    if count > 0 then
                        local p_names = {}
                        for i = 1, math.min(count, 4) do
                            table.insert(p_names, pkgs[i].name)
                        end
                        preview_str = table.concat(p_names, ", ")
                        if count > 4 then preview_str = preview_str .. "..." end
                    else
                        preview_str = "\27[90m(нет пакетов)\27[0m"
                    end
                else
                    status_raw = "Недоступен"
                    status_color = "\27[31m"
                    preview_str = "\27[90m" .. tostring(extra or "") .. "\27[0m"
                    table.insert(shown_managers, mgr)
                end
            end

            local status_col = status_color .. pad_utf8(status_raw, 16) .. "\27[0m"
            io.stdout:write(string.format("  %-24s %s %-10s %s\n", display_name, status_col, count_str, preview_str))
        end
    end

    if active_count == 0 and not show_all_managers then
        io.stdout:write("  \27[90m(не обнаружено активных пакетных менеджеров)\27[0m\n")
    end

    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write("\27[90mПодсказки:\27[0m\n")
    if not all_mode then
        io.stdout:write("  • Показать вообще все пакеты/зависимости : \27[36mgrime pkg -a\27[0m (или \27[36mgrime pkg --all\27[0m)\n")
    else
        io.stdout:write("  • Показать только пользовательские пакеты : \27[36mgrime pkg\27[0m\n")
    end
    if not show_all_managers then
        io.stdout:write("  • Показать все поддерживаемые менеджеры  : \27[36mgrime pkg -v\27[0m (или \27[36mgrime pkg --all-managers\27[0m)\n")
    else
        io.stdout:write("  • Скрыть не установленные менеджеры      : \27[36mgrime pkg\27[0m\n")
    end
    io.stdout:write("  • Список пакетов менеджера               : \27[36mgrime pkg <менеджер> [-a]\27[0m (например: \27[36mgrime pkg pacman\27[0m, \27[36mgrime pkg box -a\27[0m)\n")
    io.stdout:write("  • Сквозной поиск пакета                  : \27[36mgrime pkg <имя_пакета> [-a]\27[0m (например: \27[36mgrime pkg git\27[0m, \27[36mgrime pkg nvim -a\27[0m)\n")
    io.stdout:write("  • Подробная справка                      : \27[36mgrime pkg --help\27[0m\n\n")

    return shown_managers
end

-- 2. Детальный список установленных пакетов для указанного менеджера
local function handle_detailed_list(mgr, filter_tokens, all_mode)
    local pkgs, err = get_packages_for_manager(mgr, all_mode)
    if not pkgs then
        io.stdout:write(string.format("\n\27[31m❌ Не удалось получить пакеты для %s: %s\27[0m\n\n", mgr, tostring(err)))
        return
    end

    local filter_query = (filter_tokens and #filter_tokens > 0) and table.concat(filter_tokens, " ") or nil
    local display_pkgs
    if filter_query and filter_query ~= "" then
        display_pkgs = fuzzy_filter(pkgs, filter_query)
    else
        display_pkgs = {}
        for _, pkg in ipairs(pkgs) do
            table.insert(display_pkgs, { pkg = pkg, score = 0 })
        end
    end

    local count_total = #pkgs
    local count_matched = #display_pkgs
    local title_extra = ""
    local mode_desc = all_mode and "все пакеты/зависимости" or "пользовательские"
    if filter_query and filter_query ~= "" then
        title_extra = string.format(" [%s, фильтр: '%s', найдено %d из %d]", mode_desc, filter_query, count_matched, count_total)
    else
        title_extra = string.format(" [%s, всего: %d]", mode_desc, count_total)
    end

    io.stdout:write(string.format("\n\27[1m📦 Пакетный менеджер: \27[32m%s\27[0m%s:\27[0m\n", mgr, title_extra))
    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write(string.format("  \27[1m%s %s %s\27[0m\n",
        pad_utf8("ПАКЕТ", 32),
        pad_utf8("ВЕРСИЯ", 20),
        "ОПИСАНИЕ / ДЕТАЛИ"))
    io.stdout:write(string.rep("─", 80) .. "\n")

    if count_matched == 0 then
        io.stdout:write("  \27[90m(пакеты не найдены)\27[0m\n")
    else
        for _, item in ipairs(display_pkgs) do
            local p = item.pkg
            local extra_info = p.details or ""
            if p.path and p.path ~= "" then
                if extra_info ~= "" then
                    extra_info = extra_info .. " (" .. p.path .. ")"
                else
                    extra_info = p.path
                end
            end
            io.stdout:write(string.format("  \27[1;36m%s\27[0m \27[32m%s\27[0m \27[90m%s\27[0m\n",
                pad_utf8(p.name, 32),
                pad_utf8(p.version ~= "" and p.version or "-", 20),
                extra_info))
        end
    end

    io.stdout:write(string.rep("─", 80) .. "\n")
    local hint_all = ""
    if not all_mode then
        hint_all = string.format(" Для отображения всех зависимостей: grime pkg %s -a.", mgr)
    end
    io.stdout:write(string.format("\27[90mПоказано: %d пакетов.%s Для запуска: grime pkg run <имя>\27[0m\n\n", count_matched, hint_all))
    if ctx.has_next_step then
        local names = {}
        for _, item in ipairs(display_pkgs) do
            table.insert(names, item.pkg.name)
        end
        ctx.module_return(table.concat(names, "\n"))
    end
end

-- 3. Сквозной нечеткий поиск пакета по всем менеджерам
local function handle_search(query_tokens, all_mode)
    if not query_tokens or #query_tokens == 0 then
        ctx.fail("Укажите поисковый запрос (например: grime pkg search git)")
        return
    end

    local query = table.concat(query_tokens, " ")
    local mode_label = all_mode and "\27[33m[ВСЕ ПАКЕТЫ И ЗАВИСИМОСТИ]\27[0m" or "\27[32m[ПОЛЬЗОВАТЕЛЬСКИЕ]\27[0m"
    io.stdout:write(string.format("\n\27[1m🔍 Сквозной нечеткий поиск пакета '\27[33m%s\27[0m\27[1m' %s:\27[0m\n", query, mode_label))
    io.stdout:write(string.rep("─", 80) .. "\n")

    local total_found = 0
    local managers_found = 0
    local all_matched_names = {}
    local skipped_distrobox = false

    for _, mgr in ipairs(SCAN_MANAGERS) do
        local bin = MANAGER_BINARIES[mgr]
        local is_installed = true
        if bin then
            is_installed = has_binary(bin)
        end

        if is_installed and not should_scan_manager(mgr, false) then
            skipped_distrobox = true
        elseif is_installed then
            local pkgs, extra = get_packages_for_manager(mgr, all_mode)
            if pkgs and #pkgs > 0 then
                local matches = fuzzy_filter(pkgs, query)

                if #matches > 0 then

                    local mgr_label = mgr
                    if mgr == "distrobox" and extra then
                        mgr_label = string.format("distrobox:%s", extra)
                    end

                    io.stdout:write(string.format("\n  \27[1;33m[%s]\27[0m \27[90m(найдено: %d)\27[0m\n", mgr_label, #matches))
                    for _, item in ipairs(matches) do
                        local p = item.pkg
                        table.insert(all_matched_names, p.name)
                        local extra_info = p.details or ""
                        if p.path and p.path ~= "" then
                            if extra_info ~= "" then
                                extra_info = extra_info .. " [" .. p.path .. "]"
                            else
                                extra_info = p.path
                            end
                        end
                        io.stdout:write(string.format("    • \27[1;36m%-30s\27[0m \27[32m%-18s\27[0m \27[90m%s\27[0m\n",
                            p.name, p.version ~= "" and p.version or "-", extra_info))
                    end

                    total_found = total_found + #matches
                    managers_found = managers_found + 1
                end
            end
        end
    end

    io.stdout:write("\n" .. string.rep("─", 80) .. "\n")
    if skipped_distrobox then
        io.stdout:write("  \27[90mDistrobox пропущен (контейнер не запущен). Поиск в нём: grime pkg box " .. query .. "\27[0m\n")
    end
    if total_found == 0 then
        io.stdout:write(string.format("  \27[31m❌ Пакеты по запросу '%s' не найдены ни в одном из активных менеджеров.\27[0m\n", query))
        if not all_mode then
            io.stdout:write(string.format("  \27[90mПопробуйте повторить поиск со всеми пакетами и зависимостями: grime pkg %s -a\27[0m\n", query))
        end
        io.stdout:write("\n")
    else
        io.stdout:write(string.format("\27[32m✔ Найдено совпадений: %d в %d менеджерах.\27[0m\n", total_found, managers_found))
        if not all_mode then
            io.stdout:write("  \27[90m(Поиск только среди пользовательских пакетов. Для поиска по всем зависимостям добавьте -a)\27[0m\n")
        end
        io.stdout:write("\n")
    end

    if ctx.has_next_step then
        ctx.module_return(table.concat(all_matched_names, "\n"))
    end
end

-- Системный менеджер хоста по умолчанию для `-i <pkg>`
local function default_host_manager()
    for _, mgr in ipairs({ "pacman", "dnf", "apt" }) do
        if has_binary(mgr) then return mgr end
    end
    return "pacman"
end

-- 4. Установка пакетов
local function handle_install(manager, packages)
    if not packages or #packages == 0 then
        ctx.fail("Не указаны пакеты для установки")
        return
    end

    local cmd = {}
    local nix_env = nil
    local cmd_has_packages = false
    if manager == "yay" then
        cmd = { "yay", "-S" }
    elseif manager == "pacman" then
        cmd = { "sudo", "pacman", "-S" }
    elseif manager == "dnf" then
        cmd = { "sudo", "dnf", "install", "-y" }
    elseif manager == "apt" then
        cmd = { "sudo", "apt", "install", "-y" }
    elseif manager == "flatpak" then
        cmd = { "flatpak", "install", "-y" }
    elseif manager == "nix" then
        -- `nix profile add` (install устарел); пакеты и флаги unfree собирает utils
        local nix_cmd
        nix_cmd, nix_env = utils.nix_profile_add_cmd(packages)
        cmd = nix_cmd
        cmd_has_packages = true
    elseif manager == "cargo" then
        cmd = { "cargo", "install" }
    elseif manager == "pipx" then
        cmd = { "pipx", "install" }
    elseif manager == "distrobox" then
        local target_box = table.remove(packages, 1)
        if not target_box then
            ctx.fail("Укажите имя контейнера Distrobox")
            return
        end
        cmd = { "distrobox", "enter", target_box, "--", "sudo", "dnf", "install", "-y" }
    else
        ctx.fail("Неизвестный пакетный менеджер: " .. tostring(manager))
        return
    end

    if not cmd_has_packages then
        for _, p in ipairs(packages) do
            table.insert(cmd, p)
        end
    end

    ctx.log("Установка через " .. manager .. ": " .. table.concat(packages, " ") .. "...")
    local ret
    if manager == "yay" or manager == "pacman" then
        ret = ctx.run_interactive(cmd)
    else
        ret = ctx.run_process(cmd, nil, nix_env)
    end
    if ret == 0 then
        ctx.log("Установка успешно завершена.")
    else
        ctx.fail("Установка завершилась ошибкой (код " .. tostring(ret) .. ")")
    end
end

--- Интерактивный запуск команды с контролем кода возврата: при ошибке вызывает ctx.fail (ненулевой итоговый код)
local function run_checked(cmd, what)
    local ret = ctx.run_interactive(cmd)
    if ret ~= 0 then
        ctx.fail(string.format("%s завершилось с ошибкой (код %s)", what, tostring(ret)))
    end
    return ret
end

--- Копия базовой команды с добавленными аргументами
local function with_args(base, args)
    local cmd = {}
    for _, t in ipairs(base) do table.insert(cmd, t) end
    for _, a in ipairs(args or {}) do table.insert(cmd, a) end
    return cmd
end

--- Баннер этапа обновления
local function banner(color, title, text)
    io.stdout:write(string.format("\n\27[%sm[%s]\27[0m \27[1m%s\27[0m\n", color, title, text))
    io.stdout:flush()
end

local CARGO_UPDATE_HINT = {
    "  \27[33mℹ Для автообновления всех бинарников Cargo требуется cargo-install-update.\27[0m\n",
    "  \27[90mУстановить: grime pkg yay install cargo-update (или cargo install cargo-update)\27[0m\n",
}

local function has_cargo_install_update()
    if has_binary("cargo-install-update") then return true end
    return ctx.capture({ "cargo", "install-update", "--version" }).code == 0
end

-- 4.1. Сквозное обновление всех активных менеджеров с учётом кодов возврата каждого этапа
local function handle_update_all()
    io.stdout:write("\n\27[1;32m🔄 Сквозное обновление активных пакетных менеджеров системы...\27[0m\n")
    io.stdout:write(string.rep("═", 80) .. "\n")

    local failures = {}
    local function step(cmd, label)
        local ret = ctx.run_interactive(cmd)
        if ret ~= 0 then
            table.insert(failures, string.format("%s (код %s)", label, tostring(ret)))
        end
        return ret
    end

    -- 1. Системные пакеты хоста: Yay (приоритет на Arch) -> Pacman -> DNF -> APT
    if has_binary("yay") then
        banner("1;35", "Yay / AUR", "Обновление системных и AUR пакетов Arch Linux...")
        step({ "yay", "-Syu" }, "yay")
    elseif has_binary("pacman") then
        banner("1;32", "Pacman", "Обновление системных пакетов Arch Linux...")
        io.stdout:write("\27[90mЗапуск sudo pacman -Syu с интерактивным терминалом...\27[0m\n")
        io.stdout:flush()
        step({ "sudo", "pacman", "-Syu" }, "pacman")
    elseif has_binary("dnf") then
        banner("1;34", "DNF", "Обновление системных пакетов Fedora...")
        step({ "sudo", "dnf", "upgrade", "-y" }, "dnf")
    elseif has_binary("apt") then
        banner("1;31", "APT", "Обновление системных пакетов Debian/Ubuntu...")
        if step({ "sudo", "apt", "update" }, "apt update") == 0 then
            step({ "sudo", "apt", "upgrade", "-y" }, "apt upgrade")
        end
    end

    -- 2. Flatpak
    if has_binary("flatpak") then
        banner("1;34", "Flatpak", "Обновление Flatpak-приложений и runtime...")
        step({ "flatpak", "update", "-y" }, "flatpak")
    end

    -- 3. Nix
    if has_binary("nix") then
        banner("1;36", "Nix", "Обновление пакетов Nix-профиля...")
        step({ "nix", "profile", "upgrade", ".*" }, "nix")
    end

    -- 4. Distrobox
    if has_binary("distrobox") then
        local target_box = get_distrobox_target()
        if target_box then
            banner("1;35", "Distrobox: " .. target_box, "Обновление пакетов контейнера...")
            step({ "distrobox", "enter", target_box, "--", "sudo", "dnf", "upgrade", "-y" }, "distrobox:" .. target_box)
        end
    end

    -- 5. Pipx
    if has_binary("pipx") then
        banner("1;33", "Pipx", "Обновление Python CLI пакетов (pipx)...")
        step({ "pipx", "upgrade-all" }, "pipx")
    end

    -- 6. Cargo
    if has_binary("cargo") then
        banner("1;31", "Cargo", "Обновление установленных Rust бинарников...")
        if has_cargo_install_update() then
            step({ "cargo", "install-update", "-a" }, "cargo")
        else
            for _, line in ipairs(CARGO_UPDATE_HINT) do io.stdout:write(line) end
            io.stdout:flush()
        end
    end

    io.stdout:write("\n" .. string.rep("═", 80) .. "\n")
    if #failures == 0 then
        io.stdout:write("\27[1;32m✔ Сквозное обновление завершено.\27[0m\n\n")
    else
        io.stdout:write(string.format("\27[1;31m✘ Сквозное обновление завершено с ошибками: %s\27[0m\n\n", table.concat(failures, ", ")))
        ctx.fail("Обновление завершилось с ошибками: " .. table.concat(failures, ", "))
    end
end

-- 4.1. Обновление пакетов
local function handle_update(manager, args)
    args = args or {}

    if not manager or manager == "all" then
        return handle_update_all()
    end

    -- Обновление конкретного менеджера
    if manager == "flatpak" then
        if not has_binary("flatpak") then
            ctx.fail("Flatpak не установлен в системе")
            return
        end
        banner("1;34", "Flatpak", "Обновление пакетов Flatpak...")
        run_checked(with_args({ "flatpak", "update", "-y" }, args), "Обновление Flatpak")
    elseif manager == "yay" then
        if not has_binary("yay") then
            ctx.fail("yay не установлен в системе")
            return
        end
        banner("1;35", "Yay / AUR", "Обновление системных и AUR пакетов Arch Linux...")
        run_checked(with_args({ "yay", "-Syu" }, args), "Обновление через yay")
    elseif manager == "pacman" or manager == "host" then
        if not has_binary("pacman") then
            ctx.fail("pacman не установлен в системе")
            return
        end
        banner("1;32", "Pacman", "Обновление системных пакетов Arch Linux...")
        io.stdout:write("\27[90mЗапуск sudo pacman -Syu с интерактивным терминалом...\27[0m\n")
        io.stdout:flush()
        run_checked(with_args({ "sudo", "pacman", "-Syu" }, args), "Обновление pacman")
    elseif manager == "nix" then
        if not has_binary("nix") then
            ctx.fail("Nix не установлен в системе")
            return
        end
        banner("1;36", "Nix", "Обновление пакетов Nix-профиля...")
        run_checked(with_args({ "nix", "profile", "upgrade" }, #args > 0 and args or { ".*" }), "Обновление Nix-профиля")
    elseif manager == "distrobox" or manager == "box" then
        if not has_binary("distrobox") then
            ctx.fail("distrobox не установлен в системе")
            return
        end
        local target_box = get_distrobox_target()
        if not target_box then
            ctx.fail("Активный контейнер Distrobox не найден")
            return
        end
        banner("1;35", "Distrobox: " .. target_box, "Обновление пакетов контейнера...")
        run_checked(with_args({ "distrobox", "enter", target_box, "--", "sudo", "dnf", "upgrade", "-y" }, args), "Обновление в Distrobox")
    elseif manager == "pipx" then
        if not has_binary("pipx") then
            ctx.fail("pipx не установлен в системе")
            return
        end
        if #args > 0 then
            for _, p in ipairs(args) do
                banner("1;33", "Pipx", "Обновление " .. p .. "...")
                run_checked({ "pipx", "upgrade", p }, "Обновление pipx (" .. p .. ")")
            end
        else
            banner("1;33", "Pipx", "Обновление всех пакетов pipx...")
            run_checked({ "pipx", "upgrade-all" }, "Обновление pipx")
        end
    elseif manager == "cargo" then
        if not has_binary("cargo") then
            ctx.fail("Cargo не установлен в системе")
            return
        end
        local has_cargo_update = has_cargo_install_update()
        if #args > 0 then
            local base = has_cargo_update and { "cargo", "install-update" } or { "cargo", "install" }
            run_checked(with_args(base, args), "Обновление Cargo")
        elseif has_cargo_update then
            run_checked({ "cargo", "install-update", "-a" }, "Обновление Cargo")
        else
            for _, line in ipairs(CARGO_UPDATE_HINT) do io.stdout:write(line) end
            io.stdout:flush()
        end
    elseif manager == "dnf" then
        run_checked(with_args({ "sudo", "dnf", "upgrade", "-y" }, args), "Обновление dnf")
    elseif manager == "apt" then
        if run_checked({ "sudo", "apt", "update" }, "apt update") == 0 then
            run_checked(with_args({ "sudo", "apt", "upgrade", "-y" }, args), "Обновление apt")
        end
    elseif manager == "apps" or manager == "app" then
        io.stdout:write("  \27[33mℹ Локальные микросервисы Grime Apps (~/.config/grime/apps) управляются через Git и Flakes.\27[0m\n")
        io.stdout:write("  \27[90mДля обновления используйте: grime nix update или grime git pull\27[0m\n")
        io.stdout:flush()
    else
        ctx.fail("Обновление для менеджера '" .. tostring(manager) .. "' не поддерживается")
    end
end

-- 4.2. Удаление пакетов
local function handle_remove(manager, packages)
    if not packages or #packages == 0 then
        ctx.fail("Не указаны пакеты для удаления.\nИспользование: grime pkg remove <менеджер> <пакеты...>\nПример: grime pkg remove flatpak com.spotify.Client")
        return
    end

    local cmd = {}
    if manager == "yay" then
        cmd = { "yay", "-R" }
    elseif manager == "pacman" or manager == "host" then
        cmd = { "sudo", "pacman", "-R" }
    elseif manager == "dnf" then
        cmd = { "sudo", "dnf", "remove", "-y" }
    elseif manager == "apt" then
        cmd = { "sudo", "apt", "remove", "-y" }
    elseif manager == "flatpak" then
        cmd = { "flatpak", "uninstall", "-y" }
    elseif manager == "nix" then
        cmd = { "nix", "profile", "remove" }
    elseif manager == "cargo" then
        cmd = { "cargo", "uninstall" }
    elseif manager == "pipx" then
        cmd = { "pipx", "uninstall" }
    elseif manager == "distrobox" or manager == "box" then
        local target_box = get_distrobox_target()
        if not target_box then
            ctx.fail("Активный контейнер Distrobox не найден")
            return
        end
        cmd = { "distrobox", "enter", target_box, "--", "sudo", "dnf", "remove", "-y" }
    else
        ctx.fail("Удаление для менеджера '" .. tostring(manager) .. "' не поддерживается")
        return
    end

    for _, p in ipairs(packages) do
        table.insert(cmd, p)
    end

    ctx.log(string.format("Удаление пакетов через %s: %s...", manager, table.concat(packages, " ")))
    local ret = ctx.run_interactive(cmd)
    if ret == 0 then
        ctx.log(string.format("Удаление пакетов через %s успешно завершено.", manager))
    else
        ctx.fail(string.format("Удаление через %s завершилось с ошибкой (код %d)", manager, ret))
    end
end

-- Маппинг распространенных консольных утилит в их пакеты в nixpkgs
local NIX_PACKAGE_MAPPINGS = {
    -- coreutils
    du = "coreutils", df = "coreutils", ls = "coreutils", cat = "coreutils",
    cp = "coreutils", mv = "coreutils", rm = "coreutils", mkdir = "coreutils",
    rmdir = "coreutils", touch = "coreutils", chmod = "coreutils", chown = "coreutils",
    head = "coreutils", tail = "coreutils", wc = "coreutils", sort = "coreutils",
    uniq = "coreutils", cut = "coreutils", tr = "coreutils", tee = "coreutils",
    env = "coreutils", echo = "coreutils", date = "coreutils", sleep = "coreutils",
    uname = "coreutils", whoami = "coreutils", basename = "coreutils", dirname = "coreutils",
    realpath = "coreutils", readlink = "coreutils", stat = "coreutils", sync = "coreutils",
    truncate = "coreutils", ln = "coreutils", md5sum = "coreutils", sha256sum = "coreutils",
    base64 = "coreutils", nproc = "coreutils", timeout = "coreutils",

    -- findutils
    find = "findutils", xargs = "findutils", locate = "findutils",

    -- diffutils
    diff = "diffutils", cmp = "diffutils",

    -- procps & psmisc
    ps = "procps", top = "procps", free = "procps", uptime = "procps",
    kill = "procps", pgrep = "procps", pkill = "procps", watch = "procps",
    killall = "psmisc", pstree = "psmisc",

    -- util-linux
    lsblk = "util-linux", fdisk = "util-linux", mount = "util-linux",
    umount = "util-linux", dmesg = "util-linux",

    -- net-tools & iproute2
    ifconfig = "net-tools", netstat = "net-tools", ip = "iproute2", ss = "iproute2",

    -- grep / sed / gawk / архиваторы
    grep = "gnugrep", egrep = "gnugrep", fgrep = "gnugrep",
    sed = "gnused", awk = "gawk",
    tar = "gnutar", gzip = "gzip", gunzip = "gzip", bzip2 = "bzip2", xz = "xz",

    -- Популярные CLI инструменты
    nvim = "neovim", rg = "ripgrep", fd = "fd", bat = "bat", eza = "eza",
    btm = "bottom", htop = "htop", btop = "btop", jq = "jq",
    curl = "curl", wget = "wget", git = "git", tmux = "tmux", zellij = "zellij",
    fzf = "fzf", tree = "tree", gh = "gh", dig = "bind", nslookup = "bind",
    ping = "iputils", traceroute = "traceroute", strace = "strace", lsof = "lsof",
    ncdu = "ncdu", duf = "duf", dust = "dust", tokei = "tokei",
    hyperfine = "hyperfine", cowsay = "cowsay", sl = "sl", figlet = "figlet",
    lolcat = "lolcat", fastfetch = "fastfetch", neofetch = "neofetch",
    glxinfo = "mesa-demos", glxgears = "mesa-demos",

    -- Сетевой аудит и утилиты повышенных привилегий
    nmap = "nmap", masscan = "masscan", tcpdump = "tcpdump", wireshark = "wireshark",
    tshark = "wireshark-cli", ["aircrack-ng"] = "aircrack-ng", reaver = "reaver-wps-fork-t6x",
    kismet = "kismet", bettercap = "bettercap", ettercap = "ettercap",
    ["arp-scan"] = "arp-scan", fping = "fping", hping3 = "hping",
    tcptraceroute = "tcptraceroute", wavemon = "wavemon",
    ["wireguard-tools"] = "wireguard-tools", wg = "wireguard-tools", openvpn = "openvpn",
    iptables = "iptables", ip6tables = "iptables", nftables = "nftables", ebtables = "ebtables",
    parted = "parted", gparted = "gparted",
    fdisk = "util-linux", cfdisk = "util-linux", sfdisk = "util-linux",
    gdisk = "gptfdisk", cgdisk = "gptfdisk",
    smartctl = "smartmontools", ethtool = "ethtool", iotop = "iotop", hdparm = "hdparm",
}

-- Поиск системного бинарника на хосте (с исключением ~/.nix-profile и ~/.cargo для чистого разделения)
local function find_host_binary(bin)
    if not bin or bin == "" then return nil end
    local candidate_paths = {
        "/usr/bin/" .. bin,
        "/usr/local/bin/" .. bin,
        "/bin/" .. bin,
        "/usr/sbin/" .. bin,
        "/sbin/" .. bin,
    }
    for _, p in ipairs(candidate_paths) do
        if ctx.exists(p) then return p end
    end

    local res = ctx.capture({ "which", bin })
    if res.code == 0 and res.stdout then
        local p = res.stdout:match("^(%S+)")
        if p and p ~= "" and ctx.exists(p) then
            local home = os.getenv("HOME") or ""
            if not (home ~= "" and (p:find(home .. "/.nix-profile", 1, true) or p:find(home .. "/.cargo", 1, true))) then
                return p
            end
        end
    end
    return nil
end

-- Поиск установленного Flatpak-приложения по имени или app_id
local function find_flatpak_app(target_name)
    if not has_binary("flatpak") then return nil end
    local pkgs = get_flatpak_packages(false)
    if not pkgs then return nil end
    local t_lower = target_name:lower()

    -- 1. Точное совпадение с app_id или именем (без учета регистра)
    for _, item in ipairs(pkgs) do
        local app_id = item.details or ""
        local name = item.name or ""
        if app_id:lower() == t_lower or name:lower() == t_lower then
            return app_id, name
        end
    end

    -- 2. Совпадение суффикса app_id (например, "obsidian" -> "md.obsidian.Obsidian")
    for _, item in ipairs(pkgs) do
        local app_id = item.details or ""
        local name = item.name or ""
        local id_lower = app_id:lower()
        local dotted = "." .. t_lower
        if id_lower:sub(-#dotted) == dotted or id_lower:find(dotted .. ".", 1, true) then
            return app_id, name
        end
    end

    -- 3. Подстрока в имени или app_id
    for _, item in ipairs(pkgs) do
        local app_id = item.details or ""
        local name = item.name or ""
        if name:lower():find(t_lower, 1, true) or app_id:lower():find(t_lower, 1, true) then
            return app_id, name
        end
    end

    -- 4. Нечеткий поиск (fuzzy)
    local best_item = nil
    local best_score = 0
    for _, item in ipairs(pkgs) do
        local m1, s1 = fuzzy_match(t_lower, item.name or "")
        local m2, s2 = fuzzy_match(t_lower, item.details or "")
        local score = math.max(m1 and s1 or 0, m2 and s2 or 0)
        if score > best_score and score >= 300 then
            best_score = score
            best_item = item
        end
    end
    if best_item then
        return best_item.details, best_item.name
    end

    return nil
end

-- Поиск бинарника в Nix-профиле
local function find_nix_profile_binary(bin)
    if not bin or bin == "" then return nil end
    local p = (os.getenv("HOME") or "") .. "/.nix-profile/bin/" .. bin
    if ctx.exists(p) then return p end
    return nil
end

-- Поиск бинарника в Cargo / Pipx / Local bin
local function find_cargo_or_pipx_binary(bin)
    if not bin or bin == "" then return nil, nil end
    local cargo_bin = (os.getenv("HOME") or "") .. "/.cargo/bin/" .. bin
    if ctx.exists(cargo_bin) then return cargo_bin, "cargo" end
    local local_bin = (os.getenv("HOME") or "") .. "/.local/bin/" .. bin
    if ctx.exists(local_bin) then return local_bin, "local" end
    local go_bin = (os.getenv("HOME") or "") .. "/go/bin/" .. bin
    if ctx.exists(go_bin) then return go_bin, "go" end
    return nil, nil
end

-- Поиск утилиты в активном или указанном контейнере Distrobox
local function find_distrobox_binary(cmd, box_name)
    if not cmd or cmd == "" or not (has_binary("distrobox") or has_binary("distrobox-host-exec")) then return nil, nil end
    local target_box = box_name or get_distrobox_target()
    if not target_box then return nil, nil end
    local res = box_capture(target_box, { "sh", "-c", "command -v " .. utils.shell_escape(cmd) })
    if res.code == 0 and res.stdout and res.stdout:match("%S") then
        local found = res.stdout:match("^%s*(.-)%s*$")
        if found and #found > 0 then
            return target_box, found
        end
    else
        local err_str = res.stderr or ""
        if res.code == 125
            or err_str:find("unable to start container", 1, true)
            or err_str:find("OCI permission denied", 1, true)
            or err_str:find("Error:", 1, true)
        then
            ctx.log(string.format(
                "[Grime Pkg] ⚠ Контейнер '%s' не смог запуститься (код %s). Проверьте состояние podman/distrobox.%s",
                target_box,
                tostring(res.code or "?"),
                err_str ~= "" and (" Детали: " .. err_str:gsub("%s+$", "")) or ""
            ))
        end
    end
    return nil, nil
end

-- Запуск локального микросервиса Grime App
local function run_grime_app(target_name, run_args)
    local name_ok, name_why = utils.valid_name(target_name)
    if not name_ok then
        return false, string.format("Недопустимое имя приложения '%s': %s", tostring(target_name), name_why)
    end
    local apps_root = get_apps_root()
    local app_dir = apps_root .. "/" .. target_name
    if not ctx.exists(app_dir) or not ctx.is_dir(app_dir) then
        return false, string.format("Приложение '%s' не найдено в %s", target_name, apps_root)
    end
    ctx.log(string.format("[Grime Pkg] Запуск локального Grime App: %s...", target_name))
    local ok, app_mod = pcall(require, "app")
    if ok and type(app_mod) == "table" and app_mod.run_app and app_mod.load_manifest then
        local m, err = app_mod.load_manifest(app_dir, target_name)
        if not m then
            return false, err or ("Не удалось загрузить манифест приложения: " .. target_name)
        end
        if app_mod.reset_failed then app_mod.reset_failed() end
        local ret = app_mod.run_app(target_name, m, app_dir, run_args, false)
        if ret ~= 0 then
            return false, string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret)
        end
        return true
    else
        local proc = { utils.self_exe(), "app", target_name }
        for _, a in ipairs(run_args) do
            table.insert(proc, a)
        end
        local ret = ctx.run_process(proc)
        if ret ~= 0 then
            return false, string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret)
        end
        return true
    end
end

local classify_paths = function(cmd, args) return utils.classify_paths(cmd, args, nil, ctx) end
local build_nix_shell_command = utils.build_nixgl_wrapper

-- Утилиты, требующие повышенных привилегий (root / CAP_NET_RAW / прямой доступ к оборудованию) по умолчанию
local ROOT_PRIVILEGE_COMMANDS = {
    masscan = true,
    tcpdump = true,
    wireshark = true,
    tshark = true,
    ["aircrack-ng"] = true,
    reaver = true,
    kismet = true,
    bettercap = true,
    ettercap = true,
    ["arp-scan"] = true,
    fping = true,
    hping3 = true,
    traceroute = true,
    tcptraceroute = true,
    iptables = true,
    ip6tables = true,
    nftables = true,
    ebtables = true,
    parted = true,
    gparted = true,
    fdisk = true,
    cfdisk = true,
    sfdisk = true,
    gdisk = true,
    cgdisk = true,
    smartctl = true,
    hdparm = true,
    nvme = true,
    ethtool = true,
    wavemon = true,
    ["wireguard-tools"] = true,
    wg = true,
    openvpn = true,
    iotop = true,
}

-- Специфические утилиты, требующие повышенных привилегий при наличии определенных флагов
local SPECIFIC_ROOT_FLAGS = {
    nmap = {
        flags = {
            ["-O"] = true,
            ["-A"] = true,
            ["-sS"] = true,
            ["-sU"] = true,
            ["-sA"] = true,
            ["-sF"] = true,
            ["-sM"] = true,
            ["-sN"] = true,
            ["-sX"] = true,
            ["-sW"] = true,
            ["-sI"] = true,
            ["-sO"] = true,
            ["-sY"] = true,
            ["-sZ"] = true,
            ["--traceroute"] = true,
            ["--badsum"] = true,
            ["--packet-trace"] = true,
            ["--send-ip"] = true,
            ["--send-eth"] = true,
        },
        matcher = function(arg)
            if not arg or type(arg) ~= "string" then return false end
            if arg:sub(1, 1) == "-" and arg:sub(2, 2) ~= "-" then
                -- Сканирования RAW-сокетов: -sS, -sU, -sA, -sF, -sM, -sN, -sX, -sW, -sI, -sO, -sY, -sZ
                if arg:match("^%-s[SUAFMNXWIOYZsuafmnxwioyz]") then
                    return true
                end
                -- Определение ОС (-O) или агрессивный режим (-A), включая сгруппированные флаги вроде -vO, -PnA, -sVO
                if arg:match("[OA]") then
                    return true
                end
            elseif arg:sub(1, 2) == "--" then
                if arg == "--traceroute" or arg == "--badsum" or arg == "--packet-trace"
                   or arg == "--send-ip" or arg == "--send-eth" or arg:match("^%-%-osscan") then
                    return true
                end
            end
            return false
        end,
    },
}

-- Интеллектуальная проверка необходимости root-привилегий
local function needs_root_privileges(cmd, args)
    if not cmd or cmd == "" then return false end
    local base_cmd = (cmd:match("([^/]+)$") or cmd):lower()

    -- 1. Безусловные утилиты повышенных привилегий
    if ROOT_PRIVILEGE_COMMANDS[base_cmd] then
        return true
    end

    -- 2. Специфические утилиты со специфическими флагами (например, nmap)
    local spec = SPECIFIC_ROOT_FLAGS[base_cmd]
    if spec and args and #args > 0 then
        for _, arg in ipairs(args) do
            if spec.flags and spec.flags[arg] then
                return true
            end
            if spec.matcher and spec.matcher(arg) then
                return true
            end
        end
    end

    return false
end

-- Честная проверка доступности пакета в Nixpkgs
local function is_nixpkgs_package(pkg_name)
    if not pkg_name or pkg_name == "" then return nil end
    if NIX_PACKAGE_MAPPINGS[pkg_name] then
        return NIX_PACKAGE_MAPPINGS[pkg_name]
    end
    if not has_binary("nix") then return nil end
    local eval_cmd = { "nix", "eval" }
    for _, f in ipairs(utils.nix_unfree_flags()) do eval_cmd[#eval_cmd + 1] = f end
    for _, a in ipairs({ "--raw", "nixpkgs#" .. pkg_name .. ".name" }) do eval_cmd[#eval_cmd + 1] = a end
    local res = ctx.capture(eval_cmd, nil, utils.nix_unfree_env())
    if res.code == 0 and res.stdout and #res.stdout > 0 then
        return pkg_name
    end
    return nil
end

-- Изолированный запуск через Nix Flake с умным маппингом пакетов, авто-GPU и поддержкой sudo
local function run_nix_shell(target_name, run_args, explicit_sudo)
    -- 1. Аудит безопасности путей хоста: НАИВЫСШИЙ ПРИОРИТЕТ
    local allowed, reason = classify_paths(target_name, run_args)
    if not allowed then
        ctx.fail(string.format("[Grime Pkg] Отказ: %s", reason))
        return 1
    end

    local nix_pkg = NIX_PACKAGE_MAPPINGS[target_name] or target_name
    local auto_sudo = not explicit_sudo and not is_root_user() and needs_root_privileges(target_name, run_args)
    if auto_sudo then
        ctx.log(string.format("[Grime Pkg] Утилита '%s' требует повышенных привилегий (RAW-сокеты/доступ к оборудованию). Запуск через sudo -E...", target_name))
    end
    local use_sudo = explicit_sudo or auto_sudo or is_root_user()
    local shell_cmd = build_nix_shell_command(target_name, run_args, use_sudo)
    local cmd = { "nix", "shell", "nixpkgs#" .. nix_pkg }
    for _, f in ipairs(utils.nix_unfree_flags()) do cmd[#cmd + 1] = f end
    for _, a in ipairs({ "--command", "bash", "-c", shell_cmd }) do cmd[#cmd + 1] = a end

    ctx.log(string.format("[Grime Pkg] Изолированный Flake-запуск [nixpkgs#%s%s]: %s...", nix_pkg, use_sudo and " (sudo -E)" or "", target_name))
    local ret = ctx.run_process(cmd, nil, utils.nix_unfree_env())
    if ret ~= 0 then
        ctx.fail(string.format("Выполнение утилиты '%s' через nix shell завершилось ошибкой (код %d)", target_name, ret))
    end
    return ret
end

-- Сквозной опрос всех локальных окружений хоста и контейнеров
local function find_locally_installed(cmd)
    if not cmd or cmd == "" then return nil end

    -- 1. Grime Apps (~/.config/grime/apps/<cmd>)
    local apps_root = get_apps_root()
    local app_dir = apps_root .. "/" .. cmd
    if utils.valid_name(cmd) and ctx.exists(app_dir) and ctx.is_dir(app_dir) then
        return { type = "app", name = cmd, dir = app_dir }
    end

    -- 2. Хост $PATH и бинарники хоста
    local host_bin = find_host_binary(cmd)
    if host_bin then
        return { type = "host", binary = host_bin }
    end

    -- 3. Flatpak (поиск по имени, app_id или последнему сегменту)
    local flatpak_id, flatpak_name = find_flatpak_app(cmd)
    if flatpak_id then
        return { type = "flatpak", id = flatpak_id, name = flatpak_name }
    end

    -- 4. Пользовательские бинарники (Cargo ~/.cargo/bin, Local ~/.local/bin, Go ~/go/bin)
    local user_bin, bin_type = find_cargo_or_pipx_binary(cmd)
    if user_bin then
        return { type = bin_type, binary = user_bin }
    end

    -- 5. Контейнеры Distrobox (активный/дефолтный fedora-box)
    local box_name, box_bin = find_distrobox_binary(cmd)
    if box_name and box_bin then
        return { type = "distrobox", box = box_name, binary = box_bin }
    end

    -- 6. Nix Profile (~/.nix-profile/bin/<cmd>) — строго в конце локального списка
    local nix_bin = find_nix_profile_binary(cmd)
    if nix_bin then
        return { type = "nix_profile", binary = nix_bin }
    end

    return nil
end

-- Унифицированное исполнение найденной (или явно выбранной) утилиты.
-- Возвращает код возврата и признак того, что ошибка уже сообщена через fail
local function execute_local_target(target, run_args, is_sudo, run_ctx)
    local c = run_ctx or ctx
    run_args = run_args or {}
    local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
    local sudo_label = is_sudo and " (sudo -E)" or ""

    --- Запуск команды: argv = [sudo -E] binary args...
    local function run_binary(binary)
        local proc = is_sudo and { "sudo", "-E", binary } or { binary }
        for _, a in ipairs(run_args) do table.insert(proc, a) end
        return c.run_interactive(proc)
    end

    if target.type == "app" then
        local ok, err = run_grime_app(target.name, run_args)
        if not ok and err then
            c.fail(err)
            return 1, true
        end
        return 0
    elseif target.type == "host" then
        c.log(string.format("[Grime Pkg] Запуск системной утилиты [хост%s]: %s%s...", sudo_label, target.binary, args_str))
        return run_binary(target.binary)
    elseif target.type == "flatpak" then
        c.log(string.format("[Grime Pkg] Запуск Flatpak-приложения [%s]: %s%s...", target.id, target.id, args_str))
        local proc = is_sudo and { "sudo", "-E", "flatpak", "run", target.id } or { "flatpak", "run", target.id }
        for _, a in ipairs(run_args) do table.insert(proc, a) end
        return c.run_interactive(proc)
    elseif target.type == "nix_profile" then
        local allowed, reason = classify_paths(target.binary, run_args)
        if not allowed then
            c.fail(string.format("[Grime Pkg] Отказ: %s", reason))
            return 1, true
        end
        local use_sudo = is_sudo or is_root_user()
        local shell_cmd = build_nix_shell_command(target.binary, run_args, use_sudo)
        c.log(string.format("[Grime Pkg] Запуск из Nix-профиля [%s%s]: %s...", target.binary, use_sudo and " (sudo -E)" or "", target.binary))
        return c.run_interactive({ "sh", "-c", shell_cmd })
    elseif target.type == "distrobox" then
        c.log(string.format("[Grime Pkg] Запуск утилиты в Distrobox [%s]: %s%s...", target.box, target.binary, args_str))
        local proc = { target.binary }
        for _, a in ipairs(run_args) do table.insert(proc, a) end
        local bx = box_module()
        if bx then return bx.exec(target.box, proc) end
        return c.run_interactive({ "distrobox", "enter", target.box, "--", table.unpack(proc) })
    else
        -- cargo, local, go
        c.log(string.format("[Grime Pkg] Запуск утилиты [%s%s]: %s%s...", target.type, sudo_label, target.binary, args_str))
        return run_binary(target.binary)
    end
end

--- Цель запуска для явно указанного менеджера. Возвращает target либо nil, сообщение об ошибке.
--- Для nix без бинарника в профиле возвращает nil без сообщения (запуск через nix shell).
local function explicit_target(manager, name)
    if manager == "flatpak" then
        return { type = "flatpak", id = (find_flatpak_app(name)) or name }
    elseif manager == "apps" or manager == "app" then
        return { type = "app", name = name }
    elseif manager == "pacman" or manager == "host" then
        return { type = "host", binary = name }
    elseif manager == "nix" then
        local nix_bin = find_nix_profile_binary(name)
        if nix_bin then return { type = "nix_profile", binary = nix_bin } end
        return nil
    elseif manager == "cargo" then
        local cargo_bin = HOME .. "/.cargo/bin/" .. name
        local local_bin = HOME .. "/.local/bin/" .. name
        local bin = ctx.exists(cargo_bin) and cargo_bin or (ctx.exists(local_bin) and local_bin or nil)
        if bin then return { type = "cargo", binary = bin } end
        return nil, string.format("Утилита Cargo '%s' не найдена в ~/.cargo/bin или ~/.local/bin", name)
    elseif manager == "distrobox" or manager == "box" then
        local box = get_distrobox_target()
        if not box then return nil, "Активный контейнер Distrobox не найден" end
        return { type = "distrobox", box = box, binary = name }
    end
    return nil, "Неизвестный менеджер для запуска: " .. tostring(manager)
end

-- Справка по запуску утилит
local function print_run_help()
    print(string.format([[
%s%sGrime Pkg Run%s — Мультипакетный запуск утилит, приложений и сред

%sИСПОЛЬЗОВАНИЕ:%s
    grime pkg run <утилита> [аргументы...]     # Сквозной автопоиск по приоритету
    grime pkg run <менеджер> <утилита> [args] # Запуск через конкретный менеджер

%sПРИОРИТЕТ АВТОПОИСКА:%s
    1. Локальные Grime Apps (~/.config/grime/apps/<имя>)
    2. Системный PATH на хосте (Pacman/Host: /usr/bin, /usr/local/bin)
    3. Flatpak-приложения (поиск по имени или app_id)
    4. Cargo / Pipx / Local (~/.cargo/bin, ~/.local/bin, ~/go/bin)
    5. Контейнеры Distrobox (активный/дефолтный fedora-box)
    6. Nix Profile (~/.nix-profile/bin/<имя>)
    7. Изолированный Nix Flake (с умным маппингом пакетов, авто-GPU и sudo)


%sПОДДЕРЖИВАЕМЫЕ МЕНЕДЖЕРЫ ДЛЯ ЯВНОГО ЗАПУСКА:%s
    • host / pacman  — Запуск системной утилиты хоста через $PATH
    • flatpak        — Запуск Flatpak-приложения по имени или app_id
    • apps / app     — Запуск локального микросервиса Grime App
    • nix            — Запуск из ~/.nix-profile/bin либо через nix-shell
    • cargo          — Запуск установленного бинарника Cargo (~/.cargo/bin)
    • box / distrobox— Запуск внутри контейнера Distrobox

%sПРИМЕРЫ:%s
    grime pkg run du -h                       # Системный du на хосте
    grime pkg run btop                        # Системный btop на хосте
    grime pkg run obsidian                    # Flatpak md.obsidian.Obsidian
    grime pkg run flatpak Obsidian            # Явный запуск Flatpak
    grime pkg run box htop                    # Запуск htop внутри Distrobox
    grime pkg run host git status             # Явный запуск git с хоста
    grime pkg run glow README.md              # Запуск утилиты с nix fallback
    grime pkg run glxgears                    # Авто-GPU через nixGL в Nix
    grime pkg run aircrack-ng                 # Сетевая утилита с авто-sudo
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

-- 5. Мультипакетный запуск утилит и приложений
local function handle_run(manager, packages, command_tokens)
    packages = strip_gpu_flags(packages)
    command_tokens = strip_gpu_flags(command_tokens)

    if #packages == 0 then
        ctx.fail("Укажите имя пакета или приложения для запуска\nИспользование: grime pkg run [менеджер] <утилита> [аргументы...]\nДля подробной справки: grime pkg run --help")
        return
    end

    local target_name = packages[1]
    local run_args = {}
    for i = 2, #packages do
        table.insert(run_args, packages[i])
    end
    for _, ct in ipairs(command_tokens) do
        table.insert(run_args, ct)
    end

    local is_sudo = false
    if target_name == "sudo" and #run_args > 0 then
        is_sudo = true
        target_name = table.remove(run_args, 1)
    end
    if not is_sudo and is_root_user() then
        is_sudo = true
    end

    -- 1. Аудит безопасности путей хоста: НАИВЫСШИЙ ПРИОРИТЕТ
    local allowed, reason = classify_paths(target_name, run_args)
    if not allowed then
        ctx.fail(string.format("[Grime Pkg] Отказ: %s", reason))
        return
    end

    -- 2. Интеллектуальная авто-элевация привилегий (Auto-Elevate to Root)
    if not is_sudo and needs_root_privileges(target_name, run_args) then
        is_sudo = true
        ctx.log(string.format("[Grime Pkg] Утилита '%s' требует повышенных привилегий (RAW-сокеты/доступ к оборудованию). Запуск через sudo -E...", target_name))
    end

    -- Менеджер указан явно
    if manager then
        local target, err = explicit_target(manager, target_name)
        if not target then
            if err then
                ctx.fail(err)
            else
                run_nix_shell(target_name, run_args, is_sudo)
            end
            return
        end
        local ret, reported = execute_local_target(target, run_args, is_sudo, ctx)
        if ret ~= 0 and not reported then
            ctx.fail(string.format("Запуск '%s' через %s завершился с ошибкой (код %s)", target_name, manager, tostring(ret)))
        end
        return
    end

    -- Менеджер НЕ указан: сквозной опрос ВСЕХ локальных окружений хоста и контейнеров
    local local_target = find_locally_installed(target_name)
    if local_target then
        local ret, reported = execute_local_target(local_target, run_args, is_sudo, ctx)
        if ret ~= 0 and not reported then
            ctx.fail(string.format("Выполнение '%s' завершилось с кодом ошибки %s", target_name, tostring(ret)))
        end
        return
    end

    -- Не найдено нигде локально -> Fallback в Nixpkgs
    ctx.log(string.format("[Grime Pkg] Утилита '%s' не найдена среди установленных пакетов и контейнеров. Запуск в изолированном Nix-окружении...", target_name))
    run_nix_shell(target_name, run_args, is_sudo)
end

-- ============================================================================
-- 6. Обработчик Command-Not-Found (Умный перехват отсутствующих команд)
-- ============================================================================

local function handle_not_found(args, run_ctx)
    local context = run_ctx or ctx
    reset_caches()
    if not args or #args == 0 then
        context.fail("Не указана команда для поиска (код 127)")
        return
    end

    -- 0. Извлечение флагов --no-confirm, -y, --yes и поддержка разделителей '--' и '//'
    local no_confirm = false
    local clean_args = {}
    local after_dash = false
    for _, a in ipairs(args) do
        if not after_dash and (a == "--" or a == "//") then
            after_dash = true
        elseif not after_dash and (a == "--no-confirm" or a == "-y" or a == "--yes") then
            no_confirm = true
        else
            table.insert(clean_args, a)
        end
    end
    args = clean_args

    if #args == 0 then
        context.fail("Не указана команда для поиска (код 127)")
        return
    end

    local cmd = args[1]
    local cmd_args = {}
    for i = 2, #args do
        table.insert(cmd_args, args[i])
    end

    local is_sudo = false
    if cmd == "sudo" and #cmd_args > 0 then
        is_sudo = true
        cmd = table.remove(cmd_args, 1)
    end
    if not is_sudo and is_root_user() then
        is_sudo = true
    end

    -- 1. Аудит безопасности путей хоста: НАИВЫСШИЙ ПРИОРИТЕТ
    local allowed, reason = classify_paths(cmd, cmd_args)
    if not allowed then
        context.fail(string.format("[Grime] Отказ: %s", reason))
        return
    end

    -- 2. Интеллектуальная авто-элевация привилегий (Auto-Elevate to Root)
    if not is_sudo and needs_root_privileges(cmd, cmd_args) then
        is_sudo = true
        io.stdout:write(string.format("[Grime Pkg] Утилита '%s' требует повышенных привилегий (RAW-сокеты/доступ к оборудованию). Запуск через sudo -E...\n", cmd))
        io.stdout:flush()
    end

    -- 3. СКВОЗНОЙ ОПРОС ВСЕХ ЛОКАЛЬНЫХ СРЕД И КОНТЕЙНЕРОВ
    local local_target = find_locally_installed(cmd)
    if local_target then
        local code, reported = execute_local_target(local_target, cmd_args, is_sudo, context)
        if code and code ~= 0 and not reported then
            context.fail(string.format("Команда '%s' завершилась с кодом %d", cmd, code))
        end
        return
    end

    -- 4. ТОЛЬКО ЕСЛИ УТИЛИТА НЕ НАЙДЕНА ВО ВСЕХ ЛОКАЛЬНЫХ СРЕД И КОНТЕЙНЕРАХ:
    local nix_pkg = is_nixpkgs_package(cmd)

    if nix_pkg then
        local use_sudo = is_sudo
        local prompt_root = use_sudo and " (с правами root через sudo -E)" or ""

        local should_run = no_confirm
        if not should_run then
            io.stdout:write(string.format("[Grime] Команда '%s' не найдена среди установленных утилит и контейнеров.\nНайдена в репозитории Nixpkgs. Запустить во Flake-окружении (nixpkgs#%s)%s? [Y/n]: ", cmd, nix_pkg, prompt_root))
            io.stdout:flush()

            local ans = io.read()
            if ans == nil then
                io.stdout:write("\n[Grime] Запуск отменён.\n")
                context.fail("Запуск отменён (код 127)")
                return
            end

            local trimmed = ans:match("^%s*(.-)%s*$"):lower()
            if trimmed == "" or trimmed == "y" or trimmed == "yes" or trimmed == "да" or trimmed == "д" then
                should_run = true
            else
                io.stdout:write("[Grime] Запуск отменён.\n")
                context.fail("Запуск отменён (код 127)")
                return
            end
        end

        if should_run then
            local shell_cmd = build_nix_shell_command(cmd, cmd_args, use_sudo)
            local proc = { "nix", "shell", "nixpkgs#" .. nix_pkg }
            for _, f in ipairs(utils.nix_unfree_flags()) do proc[#proc + 1] = f end
            for _, a in ipairs({ "--command", "bash", "-c", shell_cmd }) do proc[#proc + 1] = a end
            local code = context.run_interactive(proc, nil, utils.nix_unfree_env())
            if code and code ~= 0 then
                context.fail(string.format("Команда '%s' завершилась с кодом %d", cmd, code))
            end
            return
        end
    end

    -- 3. Если не найдена в Nixpkgs: проверим, есть ли в официальных репозиториях Arch
    if has_binary("pacman") then
        local pac_check = context.capture({ "pacman", "-Si", cmd })
        if pac_check.code == 0 and pac_check.stdout and pac_check.stdout:match("%S") then
            io.stdout:write(string.format("[Grime] Команда '%s' не установлена в системе.\n💡 Доступна в репозитории Arch: sudo pacman -S %s\n", cmd, cmd))
            context.fail(string.format("Команда '%s' не установлена в системе (код 127)", cmd))
            return
        end
    end

    -- 4. Нечеткий поиск опечаток (fuzzy did-you-mean) по установленным утилитам
    local candidates = {}
    local seen_dirs, seen_names = {}, {}
    local function add_candidate(name)
        if name and name ~= "" and not seen_names[name] then
            seen_names[name] = true
            table.insert(candidates, name)
        end
    end
    local path_env = os.getenv("PATH") or ""
    for dir in path_env:gmatch("[^:]+") do
        if not seen_dirs[dir] then
            seen_dirs[dir] = true
            local ok, files = pcall(fs.list, dir)
            if ok and type(files) == "table" then
                for _, f in ipairs(files) do add_candidate(f) end
            end
        end
    end
    local flatpaks = get_flatpak_packages(false)
    if flatpaks then
        for _, f in ipairs(flatpaks) do
            add_candidate(f.name)
            add_candidate(f.details:match("%.([^%.]+)$"))
        end
    end

    local best_match = nil
    if grime and grime.fuzzy and grime.fuzzy.find_best_match then
        best_match = grime.fuzzy.find_best_match(cmd, candidates, 0.65)
    end
    if not best_match and grime and grime.fuzzy and grime.fuzzy.match_best then
        best_match = grime.fuzzy.match_best(cmd, candidates)
    end

    if best_match and best_match ~= "" and best_match ~= cmd then
        io.stdout:write(string.format("💡 Возможно, вы имели в виду: %s?\n", best_match))
    end
    context.fail(string.format("Команда '%s' не найдена в системе и контейнерах.", cmd))
end

-- 7. Справка
local function print_help()
    print(string.format([[
%s%sGrime Pkg%s — Унифицированное управление пакетами хоста, контейнеров и окружений

%sИСПОЛЬЗОВАНИЕ (все команды поддерживают запись с '-' / '--' и без):%s
    grime pkg [-l, --list] [-a, --all] [-v, --all-managers] # Сводная таблица пакетов
    grime pkg <менеджер> [-l] [-a] [фильтр] # Список пакетов менеджера (по умолчанию: пользовательские; -a: все)
    grime pkg <пакет> [-a]                  # Сквозной нечеткий поиск пакета
    grime pkg -s, --search <запрос> [-a]    # Явный сквозной нечеткий поиск
    grime pkg -i, --install <менеджер> <pkg># Установка пакетов через выбранный менеджер
    grime pkg -u, --update [менеджер] [pkg] # Обновление пакетов (по умолчанию: сквозное обновление всех)
    grime pkg -rm, --remove <менеджер> <pkg># Удаление пакетов через выбранный менеджер
    grime pkg -r, --run <утилита> [args...] # Сквозной мультипакетный запуск утилиты или приложения
    grime pkg -r, --run <менеджер> <утилита># Явный запуск утилиты через конкретный менеджер
    grime pkg run --help                    # Справка по правилам запуска
    grime pkg -not-found <команда> [args]   # Умный обработчик command-not-found (системный шелл)
    grime pkg -h, --help, help              # Показать эту справку

%sФЛАГИ:%s
    -a, --all, --deps                       # Выводить или искать среди ВСЕХ пакетов и зависимостей системы
                                            # (по умолчанию отображаются только явно установленные пользователем)
    -v, --verbose, --all-managers           # Показывать все поддерживаемые менеджеры в сводке (включая не установленные)
                                            # (по умолчанию отображаются только установленные и активные)

%sПОДДЕРЖИВАЕМЫЕ МЕНЕДЖЕРЫ (и их нечеткие алиасы, также с '-' / '--'):%s
    • host      (pacman, arch, sys)         # Хост / Системный PATH (/usr/bin, pacman)
    • yay       (aur, y)                    # Pacman + AUR хелпер (yay -Qm по умолчанию, yay -Q с -a)
    • flatpak   (flat, flt, fp)             # Flatpak: только приложения (по умолчанию) vs с runtime (-a)
    • nix       (nixpkgs, nx)               # Nix: nix profile (по умолчанию) vs все замыкания (-a)
    • distrobox (box, dbox, dist, distro)   # Distrobox: dnf userinstalled (по умолчанию) vs rpm -qa (-a)
    • apps      (app, applications)         # Локальные приложения grime (~/.config/grime/apps)
    • cargo     (crg, rust)                 # Cargo: cargo install --list
    • pipx      (pip, python)               # Pipx: pipx list --short

%sПРИМЕРЫ:%s
    grime pkg                               # Сводная таблица активных менеджеров
    grime pkg -yay                          # Список пакетов AUR (yay -Qm)
    grime pkg -pacman -list                 # Список пакетов, явно установленных в pacman
    grime pkg -u                            # Сквозное обновление всех активных менеджеров (yay, flatpak, nix...)
    grime pkg flatpak --update              # Обновление всех приложений Flatpak
    grime pkg -remove flatpak obsidian      # Удаление Flatpak-пакета
    grime pkg -run btop                     # Системный btop на хосте
    grime pkg -run nix glow                 # Запуск утилиты из Nix-профиля / Flake (nixpkgs)
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

local function lookup_pkg_action(tok)
    if not tok or type(tok) ~= "string" then return nil end
    if not grime.args.is_flag(tok) then return nil end
    local low = tok:lower()
    if ACTIONS[low] then return ACTIONS[low] end
    local stripped = low:gsub("^%-+", "")
    if ACTIONS["-" .. stripped] then
        return ACTIONS["-" .. stripped]
    end
    return nil
end

local function main()
    reset_caches()
    local raw_args = ctx.args or {}

    -- Проверка явного вызова общей справки: grime pkg -h, grime pkg --help, grime pkg -flatpak --help
    if #raw_args > 0 then
        local first_action = lookup_pkg_action(raw_args[1])
        if first_action ~= "run" and first_action ~= "not_found" then
            for _, a in ipairs(raw_args) do
                if a == "--" or a == "//" then break end
                if a == "--help" or a == "-h" or a == "-help" then
                    print_help()
                    return
                end
            end
        end
    end

    -- Специальная изолированная обработка действия 'not-found' / 'cnf'
    if #raw_args > 0 then
        local first_action = lookup_pkg_action(raw_args[1])
        if first_action == "not_found" then
            local not_found_args = {}
            for i = 2, #raw_args do
                table.insert(not_found_args, raw_args[i])
            end
            handle_not_found(not_found_args, ctx)
            return
        end
    end

    -- Специальная изолированная обработка действия '-run' / '--run' / '-r'
    -- (гарантирует, что флаги утилиты вроде -h, -a, -v не перехватываются как флаги Grime Pkg)
    if #raw_args > 0 then
        local first_action = lookup_pkg_action(raw_args[1])
        if first_action == "run" then
            if #raw_args == 1 then
                handle_run(nil, {}, {})
                return
            end

            local second = raw_args[2]
            if second == "--help" or second == "-h" or second == "-help" then
                print_run_help()
                return
            end

            -- Разделение на токены до '--' / '//' и после '--' / '//' через нативный движок
            local raw_slice = {}
            for i = 2, #raw_args do table.insert(raw_slice, raw_args[i]) end
            local run_tokens, cmd_tokens = grime.args.split_passthrough(raw_slice)

            -- Очистка от устаревших флагов при необходимости (только до разделителя)
            run_tokens = strip_gpu_flags(run_tokens)

            -- Проверяем, является ли первый токен именем менеджера СО ЗНАКОМ МИНУС (-nix, -pacman, -flatpak, -box)
            -- Без знака минус токены (например python, cargo, man) считаются именем бинарника!
            local mgr = nil
            if run_tokens[1] and grime.args.is_flag(run_tokens[1]) then
                local resolved = resolve_manager(run_tokens[1])
                if resolved and #run_tokens > 1 then
                    mgr = resolved
                    table.remove(run_tokens, 1)
                end
            end

            handle_run(mgr, run_tokens, cmd_tokens)
            return
        end
    end

    -- Также поддерживаем случай `grime pkg -<mgr> -run <cmd>` до общего парсера
    if #raw_args >= 2 then
        if grime.args.is_flag(raw_args[1]) then
            local mgr_first = resolve_manager(raw_args[1])
            local act_second = lookup_pkg_action(raw_args[2])
            if mgr_first and act_second == "run" then
                local raw_slice = {}
                for i = 3, #raw_args do table.insert(raw_slice, raw_args[i]) end
                local run_tokens, cmd_tokens = grime.args.split_passthrough(raw_slice)
                handle_run(mgr_first, run_tokens, cmd_tokens)
                return
            end
        end
    end

    local parsed = ctx.parse_args({
        actions = ACTIONS,
        default_action = "list",
        flags = {
            all = { "-a", "--all", "-all", "--deps", "-deps" },
            all_managers = { "-v", "--verbose", "-verbose", "--all-managers", "-all-managers" },
        },
        categories = {
            manager = MANAGER_ALIASES,
        },
    }, raw_args)
    local action = parsed.action or "list"
    local cat_mgr = parsed.categories and parsed.categories.manager or nil

    if action == "help" then
        print_help()
        return
    end

    local all_mode = (parsed.flags and parsed.flags.all == true) or false
    local show_all_managers = (parsed.flags and parsed.flags.all_managers == true) or false

    local raw_tokens = {}
    for _, tok in ipairs(parsed.args) do
        if tok == "-a" or tok == "--all" or tok == "--deps" then
            all_mode = true
        elseif tok == "-v" or tok == "--verbose" or tok == "--all-managers" then
            show_all_managers = true
        else
            table.insert(raw_tokens, tok)
        end
    end
    for _, t in ipairs(parsed.command_tokens) do
        table.insert(raw_tokens, t)
    end

    if action == "update" then
        local target_mgr = cat_mgr
        local update_args = {}
        for _, tok in ipairs(raw_tokens) do
            local t_lower = tok:lower():gsub("^%-+", "")
            if t_lower ~= "u" and t_lower ~= "update" and t_lower ~= "upgrade" and t_lower ~= "up" then
                table.insert(update_args, tok)
            end
        end

        if #update_args > 0 and not target_mgr then
            local first_tok = update_args[1]
            if first_tok:lower():gsub("^%-+", "") == "all" then
                table.remove(update_args, 1)
                target_mgr = nil
            else
                local resolved = resolve_manager(first_tok)
                if resolved then
                    target_mgr = resolved
                    table.remove(update_args, 1)
                end
            end
        elseif #update_args > 0 and target_mgr and update_args[1]:lower():gsub("^%-+", "") == "all" then
            table.remove(update_args, 1)
            target_mgr = nil
        end

        handle_update(target_mgr, update_args)
        return
    end

    if action == "remove" then
        local target_mgr = cat_mgr
        local remove_pkgs = {}
        for _, tok in ipairs(raw_tokens) do
            local t_lower = tok:lower():gsub("^%-+", "")
            if t_lower ~= "rm" and t_lower ~= "remove" and t_lower ~= "uninstall" and t_lower ~= "del" and t_lower ~= "delete" then
                table.insert(remove_pkgs, tok)
            end
        end

        if not target_mgr and #remove_pkgs > 0 then
            local resolved = resolve_manager(remove_pkgs[1])
            if resolved then
                target_mgr = resolved
                table.remove(remove_pkgs, 1)
            end
        end

        if not target_mgr then
            ctx.fail("Укажите менеджер пакетов для удаления.\nИспользование: grime pkg remove <менеджер> <пакеты...>\nПример: grime pkg remove flatpak com.spotify.Client")
            return
        end

        handle_remove(target_mgr, remove_pkgs)
        return
    end

    if action == "search" then
        if cat_mgr and #raw_tokens == 0 then
            handle_search({ cat_mgr }, all_mode)
        else
            handle_search(raw_tokens, all_mode)
        end
        return
    end

    if action == "install" then
        -- Форматы: `-i <pkg...>` (менеджер хоста по умолчанию) и `-i <менеджер> <pkg...>`.
        -- Первый токен считается менеджером только при наличии пакетов после него.
        local mgr = cat_mgr
        if not mgr and #raw_tokens >= 2 then
            mgr = resolve_manager(raw_tokens[1])
            if mgr then table.remove(raw_tokens, 1) end
        end
        handle_install(mgr or default_host_manager(), raw_tokens)
        return
    end

    if action == "run" then
        local mgr = cat_mgr
        if not mgr and #raw_tokens > 0 then
            local resolved = resolve_manager(raw_tokens[1])
            if resolved then
                mgr = resolved
                table.remove(raw_tokens, 1)
            end
        end
        handle_run(mgr, raw_tokens, {})
        return
    end

    if action == "init" then
        ctx.run_process({ utils.self_exe(), "nix", "init" }, ctx.target_dir or ".")
        return
    end

    -- Обработка действия list / вызова без аргументов / вызова по имени менеджера или поиску пакета
    if cat_mgr then
        handle_detailed_list(cat_mgr, raw_tokens, all_mode)
        return
    end

    if #raw_tokens == 0 then
        local shown_mgrs = handle_summary(all_mode, show_all_managers)
        if ctx.has_next_step then
            ctx.module_return(table.concat(shown_mgrs, "\n"))
        end
        return
    end

    -- Проверяем первый токен (на случай нечеткого имени менеджера):
    local first_tok = raw_tokens[1]
    local resolved_mgr = resolve_manager(first_tok)

    if resolved_mgr then
        table.remove(raw_tokens, 1)
        if #raw_tokens > 0 then
            local next_action = lookup_pkg_action(raw_tokens[1])
            if next_action == "run" then
                table.remove(raw_tokens, 1)
                handle_run(resolved_mgr, raw_tokens, {})
                return
            elseif next_action == "update" then
                table.remove(raw_tokens, 1)
                handle_update(resolved_mgr, raw_tokens)
                return
            elseif next_action == "remove" then
                table.remove(raw_tokens, 1)
                handle_remove(resolved_mgr, raw_tokens)
                return
            end
        end
        handle_detailed_list(resolved_mgr, raw_tokens, all_mode)
    else
        handle_search(raw_tokens, all_mode)
    end
end

return {
    main = main,
}
