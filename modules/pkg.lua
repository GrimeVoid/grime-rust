local helper = require("helper")
local classifier = require("classifier")
local ctx = helper.ctx

local ACTIONS = {
    list = "list", ls = "list", l = "list", show = "list",
    install = "install", i = "install", ["in"] = "install", add = "install", get = "install",
    run = "run", r = "run", ["try"] = "run",
    init = "init", shell = "init", sh = "init", new = "init",
    search = "search", find = "search", s = "search", f = "search",
    help = "help",
}

local CANONICAL_MANAGERS = {
    "pacman", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx", "dnf", "apt"
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

    -- 4. Нечеткий поиск (только если длина q >= 3 и score >= 35)
    if #q >= 3 then
        local best_mgr = nil
        local best_score = 0
        for _, mgr in ipairs(CANONICAL_MANAGERS) do
            local matched, score = fuzzy_match(q, mgr)
            if matched and score > best_score then
                best_score = score
                best_mgr = mgr
            end
        end
        if best_mgr and best_score >= 35 then
            return best_mgr
        end
    end

    return nil
end

-- Сбор пакетов: pacman
local function get_pacman_packages()
    if not has_binary("pacman") then return nil, "pacman не установлен" end
    local res = ctx.capture({ "pacman", "-Qe" })
    if res.code ~= 0 then return nil, "Ошибка выполнения pacman -Qe" end
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
local function get_flatpak_packages()
    if not has_binary("flatpak") then return nil, "flatpak не установлен" end
    local res = ctx.capture({ "flatpak", "list", "--app", "--columns=name,application,version" })
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
local function get_nix_packages()
    if not has_binary("nix") then return nil, "nix не установлен" end
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
local function get_distrobox_packages(box_name)
    box_name = box_name or get_distrobox_target()
    if not box_name then return nil, "Контейнер distrobox не найден" end
    local qcmd = 'rpm -qa --qf "%{NAME} %{VERSION}-%{RELEASE}\n" 2>/dev/null || pacman -Q 2>/dev/null || dpkg-query -f "${Package} ${Version}\n" -W 2>/dev/null'
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
local function get_apps_packages()
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
local function get_cargo_packages()
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
local function get_pipx_packages()
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
local function get_packages_for_manager(mgr)
    if mgr == "pacman" then
        return get_pacman_packages()
    elseif mgr == "flatpak" then
        return get_flatpak_packages()
    elseif mgr == "nix" then
        return get_nix_packages()
    elseif mgr == "distrobox" then
        return get_distrobox_packages()
    elseif mgr == "apps" or mgr == "app" then
        return get_apps_packages()
    elseif mgr == "cargo" then
        return get_cargo_packages()
    elseif mgr == "pipx" then
        return get_pipx_packages()
    end
    return nil, "Неизвестный менеджер: " .. tostring(mgr)
end

-- 1. Сводная таблица активных пакетных менеджеров
local function handle_summary()
    io.stdout:write("\n\27[1m📦 Обзор активных пакетных менеджеров системы:\27[0m\n")
    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write(string.format("  \27[1m%s %s %s %s\27[0m\n",
        pad_utf8("МЕНЕДЖЕР", 24),
        pad_utf8("СТАТУС", 16),
        pad_utf8("ПАКЕТЫ", 10),
        "ПРЕВЬЮ"))
    io.stdout:write(string.rep("─", 80) .. "\n")

    local managers = { "pacman", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx" }
    local active_count = 0

    for _, mgr in ipairs(managers) do
        local bin = MANAGER_BINARIES[mgr]
        local is_installed = true
        if bin then
            is_installed = has_binary(bin)
        end

        local display_name = mgr
        local status_raw = "Активен"
        local status_color = "\27[32m"
        local count_str = "-"
        local preview_str = ""

        if not is_installed then
            status_raw = "Не установлен"
            status_color = "\27[90m"
        else
            local pkgs, extra = get_packages_for_manager(mgr)
            if pkgs then
                active_count = active_count + 1
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
            end
        end

        local status_col = status_color .. pad_utf8(status_raw, 16) .. "\27[0m"
        io.stdout:write(string.format("  %-24s %s %-10s %s\n", display_name, status_col, count_str, preview_str))
    end

    io.stdout:write(string.rep("─", 80) .. "\n")
    io.stdout:write("\27[90mПодсказки:\27[0m\n")
    io.stdout:write("  • Список пакетов менеджера : \27[36mgrime pkg <менеджер>\27[0m (например: \27[36mgrime pkg pacman\27[0m, \27[36mgrime pkg box\27[0m)\n")
    io.stdout:write("  • Сквозной поиск пакета    : \27[36mgrime pkg <имя_пакета>\27[0m (например: \27[36mgrime pkg git\27[0m, \27[36mgrime pkg nvim\27[0m)\n")
    io.stdout:write("  • Подробная справка        : \27[36mgrime pkg --help\27[0m\n\n")
end

-- 2. Детальный список установленных пакетов для указанного менеджера
local function handle_detailed_list(mgr, filter_tokens)
    local pkgs, err = get_packages_for_manager(mgr)
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
    if filter_query and filter_query ~= "" then
        title_extra = string.format(" [фильтр: '%s', найдено %d из %d]", filter_query, count_matched, count_total)
    else
        title_extra = string.format(" [всего: %d пакетов]", count_total)
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
    io.stdout:write(string.format("\27[90mПоказано: %d пакетов. Для запуска: grime pkg run <имя>\27[0m\n\n", count_matched))
end

-- 3. Сквозной нечеткий поиск пакета по всем менеджерам
local function handle_search(query_tokens)
    if not query_tokens or #query_tokens == 0 then
        ctx.fail("Укажите поисковый запрос (например: grime pkg search git)")
        return
    end

    local query = table.concat(query_tokens, " ")
    io.stdout:write(string.format("\n\27[1m🔍 Сквозной нечеткий поиск пакета '\27[33m%s\27[0m\27[1m' по всем менеджерам:\27[0m\n", query))
    io.stdout:write(string.rep("─", 80) .. "\n")

    local managers = { "pacman", "flatpak", "nix", "distrobox", "apps", "cargo", "pipx" }
    local total_found = 0
    local managers_found = 0

    for _, mgr in ipairs(managers) do
        local bin = MANAGER_BINARIES[mgr]
        local is_installed = true
        if bin then
            is_installed = has_binary(bin)
        end

        if is_installed then
            local pkgs, extra = get_packages_for_manager(mgr)
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
        io.stdout:write(string.format("  \27[31m❌ Пакеты по запросу '%s' не найдены ни в одном из активных менеджеров.\27[0m\n\n", query))
    else
        io.stdout:write(string.format("\27[32m✔ Найдено совпадений: %d в %d менеджерах.\27[0m\n\n", total_found, managers_found))
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

-- 5. Изолированный запуск
local function handle_run(manager, packages, command_tokens)
    if not packages or #packages == 0 then
        ctx.fail("Укажите имя пакета или приложения для запуска")
        return
    end

    local target_name = packages[1]
    local apps_root = get_apps_root()
    local app_dir = apps_root .. "/" .. target_name
    local is_app = (manager == "apps" or manager == "app") or (ctx.exists(app_dir) and ctx.is_dir(app_dir))

    if is_app then
        if not ctx.exists(app_dir) then
            ctx.fail(string.format("Приложение '%s' не найдено в %s", target_name, apps_root))
            return
        end

        local run_args = {}
        for i = 2, #packages do
            table.insert(run_args, packages[i])
        end
        for _, ct in ipairs(command_tokens or {}) do
            table.insert(run_args, ct)
        end

        local ok, app_mod = pcall(require, "app")
        if ok and type(app_mod) == "table" and app_mod.run_app and app_mod.load_manifest then
            local m, err = app_mod.load_manifest(app_dir, target_name)
            if not m then
                ctx.fail(err or ("Не удалось загрузить манифест приложения: " .. target_name))
                return
            end
            local ret = app_mod.run_app(target_name, m, app_dir, run_args, false)
            if ret ~= 0 then
                ctx.fail(string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret))
            end
        else
            local proc = { "grime", "app", target_name }
            for _, a in ipairs(run_args) do
                table.insert(proc, a)
            end
            local ret = ctx.run_process(proc)
            if ret ~= 0 then
                ctx.fail(string.format("Приложение '%s' завершилось с ошибкой (код %d)", target_name, ret))
            end
        end
        return
    end

    local pkg = target_name
    local cmd = { "nix-shell", "-p", pkg, "--run" }
    local inner_tokens = {}
    for i = 2, #packages do
        table.insert(inner_tokens, packages[i])
    end
    for _, ct in ipairs(command_tokens or {}) do
        table.insert(inner_tokens, ct)
    end
    local inner = (#inner_tokens > 0) and table.concat(inner_tokens, " ") or pkg
    table.insert(cmd, inner)

    ctx.log(string.format("Изолированный запуск [%s]: %s...", pkg, inner))
    local ret = ctx.run_process(cmd)
    if ret ~= 0 then
        ctx.fail("Выполнение завершилось ошибкой")
    end
end

-- 6. Справка
local function print_help()
    print(string.format([[
%s%sGrime Pkg%s — Унифицированное управление пакетами хоста, контейнеров и окружений

%sИСПОЛЬЗОВАНИЕ:%s
    grime pkg                               # Сводная таблица активных пакетных менеджеров
    grime pkg <менеджер> [фильтр]           # Список пакетов менеджера (поддерживает нечеткие имена)
    grime pkg <пакет>                       # Сквозной нечеткий поиск пакета по всем менеджерам
    grime pkg search <запрос>               # Явный сквозной нечеткий поиск
    grime pkg install <менеджер> <пакеты...># Установка пакетов через выбранный менеджер
    grime pkg run <пакет_или_приложение>    # Изолированный запуск приложения или пакета
    grime pkg help, -h, --help              # Показать эту справку

%sПОДДЕРЖИВАЕМЫЕ МЕНЕДЖЕРЫ (и их нечеткие алиасы):%s
    • pacman    (pac, arch)
    • flatpak   (flat, flt, fp)
    • nix       (nixpkgs, nx)
    • distrobox (box, dbox, dist, distro)
    • apps      (app, applications)
    • cargo     (crg, rust)
    • pipx      (pip, python)

%sПРИМЕРЫ:%s
    grime pkg                               # Сводная таблица всех пакетных менеджеров
    grime pkg pacman                        # Список всех пакетов pacman
    grime pkg pac                           # Список пакетов pacman (через нечеткое имя)
    grime pkg flat                          # Список установленных Flatpak-приложений
    grime pkg box                           # Список пакетов внутри контейнера Distrobox
    grime pkg pac alsa                      # Фильтрация пакетов alsa в pacman
    grime pkg git                           # Сквозной нечеткий поиск 'git' по всем пакетникам
    grime pkg search nvim                   # Сквозной поиск Neovim во всех менеджерах
    grime pkg install pac ripgrep           # Установка ripgrep через pacman
    grime pkg run htop                      # Изолированный запуск через nix-shell
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    for _, a in ipairs(ctx.args or {}) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local cls = classifier.new({
        actions = ACTIONS,
        default_action = "list",
        flags = { all = { "-a", "--all", "--deps" } },
    })

    local parsed = cls:parse(ctx.args)
    local action = parsed.action or "list"

    if action == "help" then
        print_help()
        return
    end

    local raw_tokens = {}
    for _, tok in ipairs(parsed.args) do
        table.insert(raw_tokens, tok)
    end
    for _, t in ipairs(parsed.command_tokens) do
        table.insert(raw_tokens, t)
    end

    if action == "search" then
        handle_search(raw_tokens)
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
        -- Вызов grime pkg или grime pkg list без аргументов -> сводная таблица
        handle_summary()
        if ctx.has_next_step then
            ctx.module_return(ctx.target_dir)
        end
        return
    end

    -- Проверяем первый токен: является ли он пакетным менеджером?
    local first_tok = raw_tokens[1]
    local resolved_mgr = resolve_manager(first_tok)

    if resolved_mgr then
        -- Первый аргумент — менеджер пакетов (например: grime pkg pacman, grime pkg box, grime pkg flat)
        table.remove(raw_tokens, 1)
        handle_detailed_list(resolved_mgr, raw_tokens)
    else
        -- Первый аргумент не совпал с менеджером — выполняем сквозной нечеткий поиск пакета
        handle_search(raw_tokens)
    end

    if ctx.has_next_step then
        ctx.module_return(ctx.target_dir)
    end
end
