local argparse = require("languages.argparse")
local ctx = grime.ctx

local ACTIONS = {
    list = "list", ls = "list", l = "list", show = "list",
    install = "install", i = "install", ["in"] = "install", add = "install", get = "install",
    run = "run", r = "run", ["try"] = "run",
    init = "init", shell = "init", sh = "init", new = "init",
    search = "search", find = "search", s = "search", f = "search",
    ["not-found"] = "not_found", ["not_found"] = "not_found", cnf = "not_found",
    help = "help",
}

local CANONICAL_MANAGERS = {
    "pacman", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx", "dnf", "apt", "host"
}

local MANAGER_ALIASES = {
    pacman = "pacman", pac = "pacman", arch = "pacman",
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
    flatpak = "flatpak",
    nix = "nix",
    distrobox = "distrobox",
    cargo = "cargo",
    pipx = "pipx",
    dnf = "dnf",
    apt = "apt",
}

local binary_cache = {}
local function has_binary(bin)
    if not bin or bin == "" then return false end
    if binary_cache[bin] ~= nil then
        return binary_cache[bin]
    end
    local res = ctx.capture({ "which", bin })
    local exists = (res.code == 0 and res.stdout and res.stdout:match("%S") ~= nil) or false
    binary_cache[bin] = exists
    return exists
end

local function get_apps_root()
    local root = (ctx.paths and ctx.paths.apps)
        or (ctx.get_path and ctx.get_path("apps"))
        or (ctx.apps_root and ctx.apps_root())
        or ((os.getenv("HOME") or "") .. "/.config/grime/apps")
    return ctx.normalize_path(root)
end

-- Подсчет видимой длины строки UTF-8 (для точного выравнивания колонок)
local function utf8_len(s)
    local len = 0
    for _ in (s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        len = len + 1
    end
    return len
end

local function pad_utf8(str, width)
    local len = utf8_len(str)
    if len >= width then return str end
    return str .. string.rep(" ", width - len)
end

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
    local q = query:lower()

    -- 1. Точный алиас
    if MANAGER_ALIASES[q] then
        return MANAGER_ALIASES[q]
    end

    -- 2. Префикс среди канонических
    if #q >= 2 then
        for _, mgr in ipairs(CANONICAL_MANAGERS) do
            if mgr:find("^" .. q) then
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

-- Сбор пакетов: flatpak
local function get_flatpak_packages(all_mode)
    if not has_binary("flatpak") then return nil, "flatpak не установлен" end
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

-- Определение активного контейнера Distrobox
local function get_distrobox_target()
    if not has_binary("distrobox") then return nil end
    local res = ctx.capture({ "distrobox", "list", "--no-color" })
    if res.code ~= 0 or not res.stdout then return nil end
    local lines = {}
    for line in res.stdout:gmatch("[^\r\n]+") do table.insert(lines, line) end
    local target_box = nil
    for i = 2, #lines do
        local line = lines[i]:match("^%s*(.-)%s*$")
        if line ~= "" then
            local parts = {}
            for part in line:gmatch("[^|]+") do
                table.insert(parts, part:match("^%s*(.-)%s*$"))
            end
            if #parts >= 3 and parts[1] ~= "ID" then
                local bname = parts[2]
                local bstatus = parts[3]
                if not target_box then target_box = bname end
                if bstatus:match("Up") or bname == "fedora-box" then
                    target_box = bname
                    break
                end
            end
        end
    end
    return target_box
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
    local res = ctx.capture({ "distrobox", "enter", box_name, "--", "sh", "-c", qcmd })
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
    local list = {}
    local p = io.popen(string.format("ls -1 %q 2>/dev/null", apps_root))
    if p then
        for l in p:lines() do
            local item = l:match("^%s*(.-)%s*$")
            local app_dir = apps_root .. "/" .. item
            if item ~= "" and not item:match("^%.") and ctx.is_dir(app_dir) then
                local has_flake = ctx.exists(app_dir .. "/flake.nix")
                local has_manifest = ctx.exists(app_dir .. "/app.lua")
                local desc = ""
                local ver = has_flake and "flake" or "local"
                if has_manifest then
                    local ok, app_mod = pcall(require, "app")
                    if ok and app_mod and app_mod.load_manifest then
                        local m = app_mod.load_manifest(app_dir, item)
                        if m then
                            desc = m.description or ""
                            if m.version then ver = m.version end
                        end
                    end
                end
                table.insert(list, {
                    name = item,
                    version = ver,
                    details = desc,
                    path = app_dir
                })
            end
        end
        p:close()
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
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

-- Обобщенный диспетчер получения пакетов
local function get_packages_for_manager(mgr, all_mode)
    if mgr == "pacman" then
        return get_pacman_packages(all_mode)
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

    local managers = { "pacman", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx" }
    local active_count = 0
    local shown_managers = {}

    for _, mgr in ipairs(managers) do
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
    local display_pkgs = {}

    if filter_query and filter_query ~= "" then
        for _, pkg in ipairs(pkgs) do
            local m1, s1 = fuzzy_match(filter_query, pkg.name)
            local m2, s2 = fuzzy_match(filter_query, pkg.details or "")
            if m1 or m2 then
                local best_s = math.max(s1 or 0, s2 or 0)
                table.insert(display_pkgs, { pkg = pkg, score = best_s })
            end
        end
        table.sort(display_pkgs, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.pkg.name:lower() < b.pkg.name:lower()
        end)
    else
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

    local managers = { "pacman", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx" }
    local total_found = 0
    local managers_found = 0
    local all_matched_names = {}

    for _, mgr in ipairs(managers) do
        local bin = MANAGER_BINARIES[mgr]
        local is_installed = true
        if bin then
            is_installed = has_binary(bin)
        end

        if is_installed then
            local pkgs, extra = get_packages_for_manager(mgr, all_mode)
            if pkgs and #pkgs > 0 then
                local matches = {}
                for _, pkg in ipairs(pkgs) do
                    local m1, s1 = fuzzy_match(query, pkg.name)
                    local m2, s2 = fuzzy_match(query, pkg.details or "")
                    if m1 or m2 then
                        local best_s = math.max(s1 or 0, s2 or 0)
                        table.insert(matches, { pkg = pkg, score = best_s })
                    end
                end

                if #matches > 0 then
                    table.sort(matches, function(a, b)
                        if a.score ~= b.score then return a.score > b.score end
                        return a.pkg.name:lower() < b.pkg.name:lower()
                    end)

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

-- 4. Установка пакетов
local function handle_install(manager, packages)
    if not packages or #packages == 0 then
        ctx.fail("Не указаны пакеты для установки")
        return
    end

    local cmd = {}
    if manager == "pacman" then
        cmd = { "sudo", "pacman", "-S" }
    elseif manager == "dnf" then
        cmd = { "sudo", "dnf", "install", "-y" }
    elseif manager == "apt" then
        cmd = { "sudo", "apt", "install", "-y" }
    elseif manager == "flatpak" then
        cmd = { "flatpak", "install", "-y" }
    elseif manager == "nix" then
        cmd = { "nix", "profile", "install" }
        for i, p in ipairs(packages) do
            if not p:find("[:#/]") then
                packages[i] = "nixpkgs#" .. p
            end
        end
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

    for _, p in ipairs(packages) do
        table.insert(cmd, p)
    end

    ctx.log("Установка через " .. manager .. ": " .. table.concat(packages, " ") .. "...")
    local ret = ctx.run_process(cmd)
    if ret == 0 then
        ctx.log("Установка успешно завершена.")
    else
        ctx.fail("Установка завершилась ошибкой (код " .. tostring(ret) .. ")")
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
        if app_id:lower():match("%." .. t_lower .. "$") or app_id:lower():match("%." .. t_lower .. "%..*") then
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
    return nil, nil
end

-- Запуск локального микросервиса Grime App
local function run_grime_app(target_name, run_args)
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
        local ret = app_mod.run_app(target_name, m, app_dir, run_args, false)
        if ret ~= 0 then
            return false, string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret)
        end
        return true
    else
        local proc = { "grime", "app", target_name }
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

-- Изолированный запуск через nix-shell с умным маппингом пакетов
local function run_nix_shell(target_name, run_args)
    local nix_pkg = NIX_PACKAGE_MAPPINGS[target_name] or target_name
    local inner_parts = { target_name }
    for _, a in ipairs(run_args) do
        table.insert(inner_parts, "'" .. tostring(a):gsub("'", "'\\''") .. "'")
    end
    local inner_cmd = table.concat(inner_parts, " ")
    local cmd = { "nix-shell", "-p", nix_pkg, "--run", inner_cmd }

    ctx.log(string.format("[Grime Pkg] Изолированный запуск [%s]: %s...", nix_pkg, inner_cmd))
    local ret = ctx.run_process(cmd)
    if ret ~= 0 then
        ctx.fail(string.format("Выполнение утилиты '%s' через nix-shell завершилось ошибкой (код %d)", target_name, ret))
    end
    return ret
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
    4. Nix Profile (~/.nix-profile/bin/<имя>)
    5. Cargo / Pipx (~/.cargo/bin, ~/.local/bin)
    6. Изолированный Nix-shell (с умным маппингом coreutils/findutils/etc.)

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
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

-- 5. Мультипакетный запуск утилит и приложений
local function handle_run(manager, packages, command_tokens)
    if not packages or #packages == 0 then
        ctx.fail("Укажите имя пакета или приложения для запуска\nИспользование: grime pkg run [менеджер] <утилита> [аргументы...]\nДля подробной справки: grime pkg run --help")
        return
    end

    local target_name = packages[1]
    local run_args = {}
    for i = 2, #packages do
        table.insert(run_args, packages[i])
    end
    for _, ct in ipairs(command_tokens or {}) do
        table.insert(run_args, ct)
    end

    -- Если менеджер явно указан
    if manager then
        if manager == "flatpak" then
            local flatpak_id = find_flatpak_app(target_name) or target_name
            local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
            ctx.log(string.format("[Grime Pkg] Запуск Flatpak-приложения [%s]: %s%s...", flatpak_id, flatpak_id, args_str))
            local proc = { "flatpak", "run", flatpak_id }
            for _, a in ipairs(run_args) do
                table.insert(proc, a)
            end
            local ret = ctx.run_process(proc)
            if ret ~= 0 then
                ctx.fail(string.format("Flatpak-приложение '%s' завершилось с ошибкой (код %d)", flatpak_id, ret))
            end
            return
        elseif manager == "apps" or manager == "app" then
            local ok, err = run_grime_app(target_name, run_args)
            if not ok then
                ctx.fail(err)
            end
            return
        elseif manager == "pacman" or manager == "host" then
            local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
            ctx.log(string.format("[Grime Pkg] Запуск системной утилиты [хост]: %s%s...", target_name, args_str))
            local proc = { target_name }
            for _, a in ipairs(run_args) do
                table.insert(proc, a)
            end
            local ret = ctx.run_process(proc)
            if ret ~= 0 then
                ctx.fail(string.format("Системная утилита '%s' завершилась с ошибкой (код %d)", target_name, ret))
            end
            return
        elseif manager == "nix" then
            local nix_bin = find_nix_profile_binary(target_name)
            if nix_bin then
                local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
                ctx.log(string.format("[Grime Pkg] Запуск из Nix-профиля [%s]: %s%s...", nix_bin, target_name, args_str))
                local proc = { nix_bin }
                for _, a in ipairs(run_args) do
                    table.insert(proc, a)
                end
                local ret = ctx.run_process(proc)
                if ret ~= 0 then
                    ctx.fail(string.format("Утилита Nix '%s' завершилась с ошибкой (код %d)", target_name, ret))
                end
                return
            else
                run_nix_shell(target_name, run_args)
                return
            end
        elseif manager == "cargo" then
            local cargo_bin = (os.getenv("HOME") or "") .. "/.cargo/bin/" .. target_name
            local local_bin = (os.getenv("HOME") or "") .. "/.local/bin/" .. target_name
            local target_bin = ctx.exists(cargo_bin) and cargo_bin or (ctx.exists(local_bin) and local_bin or nil)
            if target_bin then
                local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
                ctx.log(string.format("[Grime Pkg] Запуск утилиты Cargo [%s]: %s%s...", target_bin, target_name, args_str))
                local proc = { target_bin }
                for _, a in ipairs(run_args) do
                    table.insert(proc, a)
                end
                local ret = ctx.run_process(proc)
                if ret ~= 0 then
                    ctx.fail(string.format("Утилита '%s' завершилась с ошибкой (код %d)", target_name, ret))
                end
                return
            else
                ctx.fail(string.format("Утилита Cargo '%s' не найдена в ~/.cargo/bin или ~/.local/bin", target_name))
                return
            end
        elseif manager == "distrobox" or manager == "box" then
            local target_box = get_distrobox_target()
            if not target_box then
                ctx.fail("Активный контейнер Distrobox не найден")
                return
            end
            local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
            ctx.log(string.format("[Grime Pkg] Запуск утилиты в Distrobox [%s]: %s%s...", target_box, target_name, args_str))
            local proc = { "distrobox", "enter", target_box, "--", target_name }
            for _, a in ipairs(run_args) do
                table.insert(proc, a)
            end
            local ret = ctx.run_process(proc)
            if ret ~= 0 then
                ctx.fail(string.format("Выполнение утилиты '%s' в Distrobox завершилось с ошибкой (код %d)", target_name, ret))
            end
            return
        else
            ctx.fail("Неизвестный менеджер для запуска: " .. tostring(manager))
            return
        end
    end

    -- Менеджер НЕ указан (сквозной мультипакетный поиск по приоритету)
    -- 1. Локальные Grime Apps
    local apps_root = get_apps_root()
    local app_dir = apps_root .. "/" .. target_name
    if ctx.exists(app_dir) and ctx.is_dir(app_dir) then
        local ok, err = run_grime_app(target_name, run_args)
        if not ok then
            ctx.fail(err)
        end
        return
    end

    -- 2. Системный PATH / Pacman (Хост)
    local host_bin = find_host_binary(target_name)
    if host_bin then
        local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
        ctx.log(string.format("[Grime Pkg] Запуск системной утилиты [хост]: %s%s...", target_name, args_str))
        local proc = { target_name }
        for _, a in ipairs(run_args) do
            table.insert(proc, a)
        end
        local ret = ctx.run_process(proc)
        if ret ~= 0 then
            ctx.fail(string.format("Системная утилита '%s' завершилась с кодом ошибки %d", target_name, ret))
        end
        return
    end

    -- 3. Flatpak
    local flatpak_id, flatpak_name = find_flatpak_app(target_name)
    if flatpak_id then
        local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
        ctx.log(string.format("[Grime Pkg] Запуск Flatpak-приложения [%s]: %s%s...", flatpak_id, flatpak_id, args_str))
        local proc = { "flatpak", "run", flatpak_id }
        for _, a in ipairs(run_args) do
            table.insert(proc, a)
        end
        local ret = ctx.run_process(proc)
        if ret ~= 0 then
            ctx.fail(string.format("Flatpak-приложение '%s' завершилось с кодом ошибки %d", flatpak_id, ret))
        end
        return
    end

    -- 4. Nix Profile
    local nix_bin = find_nix_profile_binary(target_name)
    if nix_bin then
        local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
        ctx.log(string.format("[Grime Pkg] Запуск из Nix-профиля [%s]: %s%s...", nix_bin, target_name, args_str))
        local proc = { nix_bin }
        for _, a in ipairs(run_args) do
            table.insert(proc, a)
        end
        local ret = ctx.run_process(proc)
        if ret ~= 0 then
            ctx.fail(string.format("Утилита Nix '%s' завершилась с кодом ошибки %d", target_name, ret))
        end
        return
    end

    -- 5. Cargo / Pipx
    local user_bin, bin_type = find_cargo_or_pipx_binary(target_name)
    if user_bin then
        local args_str = #run_args > 0 and (" " .. table.concat(run_args, " ")) or ""
        ctx.log(string.format("[Grime Pkg] Запуск утилиты [%s]: %s%s...", bin_type, user_bin, args_str))
        local proc = { user_bin }
        for _, a in ipairs(run_args) do
            table.insert(proc, a)
        end
        local ret = ctx.run_process(proc)
        if ret ~= 0 then
            ctx.fail(string.format("Утилита '%s' завершилась с кодом ошибки %d", target_name, ret))
        end
        return
    end

    -- 6. Fallback в изолированный Nix (только если нигде в системе не найдено)
    ctx.log(string.format("[Grime Pkg] Утилита '%s' не найдена среди установленных пакетов. Запуск в изолированном Nix-окружении...", target_name))
    run_nix_shell(target_name, run_args)
end

-- ============================================================================
-- 6. Обработчик Command-Not-Found (Умный перехват отсутствующих команд)
-- ============================================================================

local function get_all_host_executables()
    local cmds = {}
    local seen = {}
    local path_env = os.getenv("PATH") or ""
    for dir in path_env:gmatch("[^:]+") do
        if dir ~= "" and ctx.is_dir(dir) then
            local entries = grime.fs and grime.fs.list and grime.fs.list(dir)
            if entries then
                for _, name in ipairs(entries) do
                    if not seen[name] then
                        seen[name] = true
                        table.insert(cmds, name)
                    end
                end
            end
        end
    end
    -- Добавим имена установленных Flatpak
    local flatpaks = get_flatpak_packages(false)
    if flatpaks then
        for _, fp in ipairs(flatpaks) do
            if fp.name and not seen[fp.name] then
                seen[fp.name] = true
                table.insert(cmds, fp.name)
            end
        end
    end
    return cmds
end

local function handle_not_found(args, run_ctx)
    local context = run_ctx or ctx
    if not args or #args == 0 then
        io.stderr:write("[Grime] Ошибка: не указана команда для поиска.\n")
        os.exit(127)
    end

    local cmd = args[1]
    local cmd_args = {}
    for i = 2, #args do
        table.insert(cmd_args, args[i])
    end

    -- 1. Первым делом проверить локальные менеджеры: Flatpak, Grime Apps, Nix Profile, Cargo.
    -- Если утилита уже есть на компьютере -> запустить немедленно без вопросов!

    -- 1.1 Flatpak
    local flatpak_id, _ = find_flatpak_app(cmd)
    if flatpak_id then
        local proc = { "flatpak", "run", flatpak_id }
        for _, a in ipairs(cmd_args) do
            table.insert(proc, a)
        end
        local code = context.run_interactive(proc)
        os.exit(code)
    end

    -- 1.2 Grime Apps (~/.config/grime/apps/<cmd>)
    local apps_root = get_apps_root()
    local app_dir = apps_root .. "/" .. cmd
    if context.exists(app_dir) and context.is_dir(app_dir) then
        local ok, err = run_grime_app(cmd, cmd_args)
        if not ok and err then
            io.stderr:write(string.format("[Grime] Ошибка запуска Grime App '%s': %s\n", cmd, err))
            os.exit(1)
        end
        os.exit(0)
    end

    -- 1.3 Nix Profile (~/.nix-profile/bin/<cmd>)
    local nix_bin = find_nix_profile_binary(cmd)
    if nix_bin then
        local proc = { nix_bin }
        for _, a in ipairs(cmd_args) do
            table.insert(proc, a)
        end
        local code = context.run_interactive(proc)
        os.exit(code)
    end

    -- 1.4 Cargo (~/.cargo/bin/<cmd>)
    local cargo_bin = (os.getenv("HOME") or "") .. "/.cargo/bin/" .. cmd
    if context.exists(cargo_bin) then
        local proc = { cargo_bin }
        for _, a in ipairs(cmd_args) do
            table.insert(proc, a)
        end
        local code = context.run_interactive(proc)
        os.exit(code)
    end

    -- 2. Если утилиты нет локально:
    -- Проверить наличие утилиты в репозитории Nixpkgs (через маппинг coreutils, findutils, procps или быструю проверку)
    local nix_pkg = NIX_PACKAGE_MAPPINGS[cmd]
    if not nix_pkg and has_binary("nix-instantiate") then
        local check_expr = string.format('builtins.hasAttr "%s" (import <nixpkgs> {})', cmd)
        local check_res = context.capture({ "nix-instantiate", "--eval", "-E", check_expr })
        if check_res.code == 0 and check_res.stdout and check_res.stdout:match("true") then
            nix_pkg = cmd
        end
    end

    if nix_pkg then
        -- Найдено в Nixpkgs -> запросить интерактивное подтверждение у пользователя
        io.stdout:write(string.format("[Grime] Команда '%s' не найдена на хосте.\nНайдена в репозитории Nixpkgs. Запустить в изолированном окружении? [Y/n]: ", cmd))
        io.stdout:flush()

        local ans = io.read()
        if ans == nil then
            io.stdout:write("\n[Grime] Запуск отменён.\n")
            os.exit(127)
        end

        local trimmed = ans:match("^%s*(.-)%s*$"):lower()
        if trimmed == "" or trimmed == "y" or trimmed == "yes" or trimmed == "да" or trimmed == "д" then
            local inner_parts = { cmd }
            for _, a in ipairs(cmd_args) do
                table.insert(inner_parts, "'" .. tostring(a):gsub("'", "'\\''") .. "'")
            end
            local inner_cmd = table.concat(inner_parts, " ")
            local proc = { "nix-shell", "-p", nix_pkg, "--run", inner_cmd }
            local code = context.run_interactive(proc)
            os.exit(code)
        else
            io.stdout:write("[Grime] Запуск отменён.\n")
            os.exit(127)
        end
    end

    -- 3. Если утилита не найдена ни на хосте, ни в Nixpkgs:
    -- Задействовать модуль нечёткого поиска grime.fuzzy по списку установленных в системе утилит/команд (из $PATH или Flatpak)
    local candidates = get_all_host_executables()
    local best_match = nil
    if grime.fuzzy and grime.fuzzy.find_best_match then
        local matched = grime.fuzzy.find_best_match(cmd, candidates, 0.65)
        if matched and matched ~= "" then
            best_match = matched
        end
    end
    if not best_match and grime.fuzzy and grime.fuzzy.match_best then
        best_match = grime.fuzzy.match_best(cmd, candidates)
    end

    io.stdout:write(string.format("[Grime] Команда '%s' не найдена.\n", cmd))
    if best_match and best_match ~= "" and best_match ~= cmd then
        io.stdout:write(string.format("💡 Возможно, вы имели в виду: %s?\n", best_match))
    end
    os.exit(127)
end

-- 7. Справка
local function print_help()
    print(string.format([[
%s%sGrime Pkg%s — Унифицированное управление пакетами хоста, контейнеров и окружений

%sИСПОЛЬЗОВАНИЕ:%s
    grime pkg [-a, --all] [-v, --all-managers] # Сводная таблица (по умолчанию: пользовательские пакеты; -a: все пакеты)
    grime pkg <менеджер> [-a] [фильтр]      # Список пакетов менеджера (по умолчанию: пользовательские; -a: все)
    grime pkg <пакет> [-a]                  # Сквозной нечеткий поиск пакета (по умолчанию: пользовательские; -a: все)
    grime pkg search <запрос> [-a]          # Явный сквозной нечеткий поиск
    grime pkg install <менеджер> <пакеты...># Установка пакетов через выбранный менеджер
    grime pkg run <утилита> [аргументы...]  # Сквозной мультипакетный запуск утилиты или приложения
    grime pkg run <менеджер> <утилита>      # Явный запуск утилиты через конкретный менеджер
    grime pkg run --help                    # Справка по правилам запуска
    grime pkg not-found <команда> [args]    # Умный обработчик command-not-found (системный шелл)
    grime pkg help, -h, --help              # Показать эту справку

%sФЛАГИ:%s
    -a, --all, --deps                       # Выводить или искать среди ВСЕХ пакетов и зависимостей системы
                                            # (по умолчанию отображаются только явно установленные пользователем)
    -v, --verbose, --all-managers           # Показывать все поддерживаемые менеджеры в сводке (включая не установленные)
                                            # (по умолчанию отображаются только установленные и активные)

%sПОДДЕРЖИВАЕМЫЕ МЕНЕДЖЕРЫ (и их нечеткие алиасы):%s
    • host      (pacman, arch, sys)         # Хост / Системный PATH (/usr/bin, pacman)
    • flatpak   (flat, flt, fp)             # Flatpak: только приложения (по умолчанию) vs с runtime (-a)
    • nix       (nixpkgs, nx)               # Nix: nix profile (по умолчанию) vs все замыкания (-a)
    • distrobox (box, dbox, dist, distro)   # Distrobox: dnf userinstalled (по умолчанию) vs rpm -qa (-a)
    • apps      (app, applications)         # Локальные приложения grime (~/.config/grime/apps)
    • cargo     (crg, rust)                 # Cargo: cargo install --list
    • pipx      (pip, python)               # Pipx: pipx list --short

%sПРИМЕРЫ:%s
    grime pkg                               # Сводная таблица активных менеджеров
    grime pkg pacman                        # Список пакетов, явно установленных в pacman
    grime pkg flat                          # Установленные Flatpak-приложения
    grime pkg run du -h                     # Системный du на хосте
    grime pkg run btop                      # Системный btop на хосте
    grime pkg run obsidian                  # Запуск Flatpak-приложения Obsidian
    grime pkg run host htop                 # Явный запуск утилиты на хосте
    grime pkg run box btop                  # Запуск утилиты внутри контейнера Distrobox
    grime pkg run nix glow                  # Запуск утилиты из Nix-профиля / nix-shell
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    local raw_args = ctx.args or {}

    -- Проверка явного вызова общей справки: grime pkg help, grime pkg -h, grime pkg --help
    if #raw_args > 0 then
        local first = raw_args[1]
        if first == "help" or first == "-h" or first == "--help" then
            print_help()
            return
        end
    end

    -- Специальная изолированная обработка действия 'not-found' / 'cnf'
    if #raw_args > 0 then
        local first_action = ACTIONS[raw_args[1]:lower()]
        if first_action == "not_found" then
            local not_found_args = {}
            for i = 2, #raw_args do
                table.insert(not_found_args, raw_args[i])
            end
            handle_not_found(not_found_args, ctx)
            return
        end
    end

    -- Специальная изолированная обработка действия 'run'
    -- (гарантирует, что флаги утилиты вроде -h, -a, -v не перехватываются как флаги Grime Pkg)
    if #raw_args > 0 then
        local first_action = ACTIONS[raw_args[1]:lower()]
        if first_action == "run" then
            if #raw_args == 1 then
                handle_run(nil, {}, {})
                return
            end

            local second = raw_args[2]
            if second == "--help" or second == "-h" or second == "help" then
                print_run_help()
                return
            end

            -- Разделение на токены до '--' и после '--'
            local run_tokens = {}
            local cmd_tokens = {}
            local after_dash = false
            for i = 2, #raw_args do
                local tok = raw_args[i]
                if not after_dash and tok == "--" then
                    after_dash = true
                elseif after_dash then
                    table.insert(cmd_tokens, tok)
                else
                    table.insert(run_tokens, tok)
                end
            end

            -- Проверяем, является ли первый токен именем менеджера
            local mgr = nil
            local resolved = resolve_manager(run_tokens[1])
            if resolved and #run_tokens > 1 then
                mgr = resolved
                table.remove(run_tokens, 1)
            end

            handle_run(mgr, run_tokens, cmd_tokens)
            return
        end
    end

    local cls = argparse.new({
        actions = ACTIONS,
        default_action = "list",
        flags = {
            all = { "-a", "--all", "--deps" },
            all_managers = { "-v", "--verbose", "--all-managers" },
        },
    })

    local parsed = cls:parse(raw_args)
    local action = parsed.action or "list"

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
        if t == "-a" or t == "--all" or t == "--deps" then
            all_mode = true
        elseif t == "-v" or t == "--verbose" or t == "--all-managers" then
            show_all_managers = true
        else
            table.insert(raw_tokens, t)
        end
    end

    if action == "search" then
        handle_search(raw_tokens, all_mode)
        return
    end

    if action == "install" then
        local first_tok = table.remove(raw_tokens, 1)
        local mgr = resolve_manager(first_tok) or first_tok or "pacman"
        handle_install(mgr, raw_tokens)
        return
    end

    if action == "run" then
        local first_tok = raw_tokens[1]
        local resolved = resolve_manager(first_tok)
        local mgr = nil
        if resolved then
            mgr = resolved
            table.remove(raw_tokens, 1)
        end
        handle_run(mgr, raw_tokens, parsed.command_tokens)
        return
    end

    if action == "init" then
        require("nix")
        return
    end

    -- Обработка действия list / вызова без аргументов / вызова по имени менеджера или поиску пакета
    if #raw_tokens == 0 then
        local shown_mgrs = handle_summary(all_mode, show_all_managers)
        if ctx.has_next_step then
            ctx.module_return(table.concat(shown_mgrs, "\n"))
        end
        return
    end

    -- Проверяем первый токен: является ли он пакетным менеджером?
    local first_tok = raw_tokens[1]
    local resolved_mgr = resolve_manager(first_tok)

    if resolved_mgr then
        table.remove(raw_tokens, 1)
        if #raw_tokens > 0 and ACTIONS[raw_tokens[1]:lower()] == "run" then
            table.remove(raw_tokens, 1)
            handle_run(resolved_mgr, raw_tokens, parsed.command_tokens)
            return
        end
        handle_detailed_list(resolved_mgr, raw_tokens, all_mode)
    else
        handle_search(raw_tokens, all_mode)
    end
end
