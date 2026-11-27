--[[
    Grime Shared Utilities Module (utils.lua)
    Централизованный модуль общих утилит для модулей и языковых адаптеров GRIME:
    - Цветовые ANSI константы
    - Выравнивание и обработка строк UTF-8
    - Проверка прав суперпользователя и наличия бинарников
    - Аудит и защита фундаментальных путей хоста
    - Разделение пакетов и универсальная генерация Flakes devShell
    - Разрешение путей приложений и проектов
]]

local utils = {}

utils.ANSI = {
    BOLD = "\27[1m",
    RESET = "\27[0m",
    DIM = "\27[90m",
    GRAY = "\27[90m",
    GREEN = "\27[32m",
    YELLOW = "\27[33m",
    RED = "\27[31m",
    CYAN = "\27[36m",
    PURPLE = "\27[35m",
    BLUE = "\27[34m",
    WHITE = "\27[37m",
}

--- Подсчет длины строки с учетом UTF-8 символов
function utils.utf8_len(s)
    local len = 0
    for _ in (s or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        len = len + 1
    end
    return len
end

--- Выравнивание строки пробелами до заданной длины в видимых символах UTF-8
function utils.pad_utf8(str, width)
    str = tostring(str or "")
    local len = utils.utf8_len(str)
    if len >= width then return str end
    return str .. string.rep(" ", width - len)
end

--- Проверка существования файла
function utils.file_exists(p)
    if not p or p == "" then return false end
    if grime and grime.fs and grime.fs.exists then
        return grime.fs.exists(p)
    end
    local f = io.open(p, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local binary_cache = {}
local BINARY_CACHE_TTL = 30

--- Текущее время в секундах (для TTL кэша)
local function now_sec()
    return os.time()
end

--- Проверка доступности бинарной утилиты на хосте с кэшированием
--- (положительные результаты кэшируются на TTL, отрицательные не кэшируются)
function utils.has_binary(bin, ctx)
    if not bin or bin == "" then return false end
    local cached = binary_cache[bin]
    if cached and (now_sec() - cached) < BINARY_CACHE_TTL then
        return true
    end
    binary_cache[bin] = nil
    local found = false
    local native_which = grime and grime.process and grime.process.which
    if native_which then
        -- Нативный поиск по $PATH без порождения процессов: ответ окончательный
        local p = native_which(bin)
        found = (p ~= nil and #p > 0)
    else
        -- Запасной путь только для окружений без grime.process.which
        local c = ctx or (grime and grime.ctx)
        if c and c.capture then
            local res = c.capture({ "which", bin })
            found = (res.code == 0 and res.stdout and res.stdout:match("%S") ~= nil) or false
        end
    end
    if found then binary_cache[bin] = now_sec() end
    return found
end

local root_cache = nil

--- Определение, выполняется ли команда от суперпользователя root (id -u == 0, кэш на процесс)
function utils.is_root_user(ctx)
    if root_cache ~= nil then return root_cache end
    local c = ctx or (grime and grime.ctx)
    if c and c.capture then
        local res = c.capture({ "id", "-u" })
        if res.code == 0 and res.stdout then
            root_cache = (res.stdout:match("^%s*0%s*$") ~= nil)
            return root_cache
        end
    end
    return os.getenv("USER") == "root"
end

--- Экранирование строкового аргумента для передачи в shell
function utils.shell_escape(arg)
    local escaped = tostring(arg or ""):gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end

--- Нормализация пути файловой системы с раскрытием ~ и относительных сегментов . и ..
function utils.normalize_path(path, cwd, ctx)
    if not path or path == "" then return "" end
    local home = os.getenv("HOME") or ""
    if path == "~" then
        path = home
    elseif path:sub(1, 2) == "~/" then
        path = home .. path:sub(2)
    end

    if path:sub(1, 1) ~= "/" then
        local base_dir = cwd or os.getenv("PWD") or ""
        if base_dir == "" then
            local c = ctx or (grime and grime.ctx)
            if c and c.capture then
                local res = c.capture({ "pwd" })
                if res.code == 0 then base_dir = res.stdout:gsub("%s+$", "") end
            end
        end
        path = (base_dir ~= "" and (base_dir .. "/" .. path)) or path
    end

    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == "." then
            -- текущий каталог
        elseif part == ".." then
            if #parts > 0 then
                table.remove(parts)
            end
        else
            table.insert(parts, part)
        end
    end
    return "/" .. table.concat(parts, "/")
end

--- Список фундаментальных директорий хоста, закрытых от неконтролируемой модификации
utils.FORBIDDEN_HOST_ROOTS = {
    { prefix = "/etc", desc = "системные конфигурации хоста (/etc)" },
    { prefix = "/boot", desc = "ядро и загрузчик хоста (/boot)" },
    { prefix = "/var/lib", desc = "системные базы данных и службы хоста (/var/lib)" },
    { prefix = "/usr", desc = "системные бинарники и библиотеки хоста (/usr)" },
    { prefix = "/root", desc = "каталог суперпользователя хоста (/root)" },
}

--- Проверка, принадлежит ли нормализованный путь к запрещенным зонам хоста
function utils.is_path_forbidden(normalized_path)
    if not normalized_path or normalized_path == "" then
        return false, nil
    end
    for _, rule in ipairs(utils.FORBIDDEN_HOST_ROOTS) do
        local forbidden = rule.prefix
        if normalized_path == forbidden or normalized_path:sub(1, #forbidden + 1) == forbidden .. "/" then
            return true, rule.desc
        end
    end
    return false, nil
end

--- Аудит команды и аргументов на безопасность обращения к директориям хоста
function utils.classify_paths(cmd, args, cwd, ctx)
    local c = ctx or (grime and grime.ctx)
    local cur_cwd = cwd or os.getenv("PWD") or ""
    if cur_cwd == "" and c and c.capture then
        local res = c.capture({ "pwd" })
        if res.code == 0 then cur_cwd = res.stdout:gsub("%s+$", "") end
    end
    local norm_cwd = utils.normalize_path(cur_cwd, "/", c)

    -- 1. Проверка текущей рабочей директории
    local cwd_forbidden, cwd_desc = utils.is_path_forbidden(norm_cwd)
    if cwd_forbidden then
        return false, string.format(
            "Текущая рабочая директория '%s' находится в фундаментальной зоне хоста (%s). " ..
            "Изменение системного фундамента хоста изолированным пакетом из Nix вне NixOS недопустимо. Запуск через Nix заблокирован.",
            norm_cwd, cwd_desc
        )
    end

    -- 2. Проверка команды cmd (если это путь)
    if cmd and type(cmd) == "string" and (cmd:find("/") or cmd:sub(1, 1) == "~") then
        local norm_cmd = utils.normalize_path(cmd, norm_cwd, c)
        local forbidden, desc = utils.is_path_forbidden(norm_cmd)
        if forbidden then
            return false, string.format(
                "Попытка обращения к фундаментальной директории хоста '%s' (%s). " ..
                "Изменение системного фундамента хоста изолированным пакетом из Nix вне NixOS недопустимо. Запуск через Nix заблокирован.",
                norm_cmd, desc
            )
        end
    end

    -- 3. Проверка аргументов команды
    for _, arg in ipairs(args or {}) do
        if type(arg) == "string" and arg ~= "" then
            local candidates = {}
            local eq_val = arg:match("^[-%w_]+=(.+)$")
            if eq_val then
                table.insert(candidates, eq_val)
            end
            table.insert(candidates, arg)

            for _, cand in ipairs(candidates) do
                local clean_cand = cand:match('^["\']?(.-)["\']?$') or cand
                if clean_cand:sub(1, 1) == "/" or clean_cand:sub(1, 1) == "~" or
                   clean_cand:sub(1, 2) == "./" or clean_cand:sub(1, 3) == "../" or
                   clean_cand:find("/") or clean_cand == "." or clean_cand == ".." then
                    local norm = utils.normalize_path(clean_cand, norm_cwd, c)
                    local forbidden, desc = utils.is_path_forbidden(norm)
                    if forbidden then
                        return false, string.format(
                            "Попытка обращения к фундаментальной директории хоста '%s' (%s). " ..
                            "Изменение системного фундамента хоста изолированным пакетом из Nix вне NixOS недопустимо. Запуск через Nix заблокирован.",
                            norm, desc
                        )
                    end
                end
            end
        end
    end

    return true, nil
end

--- Разделение пакетов на nativeBuildInputs (тулчейн) и buildInputs (библиотеки)
function utils.split_packages(packages, scanner_mod)
    local scan = scanner_mod
    if not scan then
        local ok, s = pcall(require, "languages.scanner")
        if ok then scan = s end
    end

    local native = {}
    local libs = {}
    local native_set = {}
    local libs_set = {}

    for _, p in ipairs(packages or {}) do
        local clean = p:gsub("^pkgs%.", "")
        if scan and scan.is_toolchain_package and scan.is_toolchain_package(clean) then
            if not native_set[clean] then
                native_set[clean] = true
                table.insert(native, clean)
            end
        else
            if not libs_set[clean] then
                libs_set[clean] = true
                table.insert(libs, clean)
            end
        end
    end

    if #native == 0 then
        table.insert(native, "bashInteractive")
    end

    return native, libs
end

--- Разрешены ли проприетарные (unfree) пакеты Nix. По умолчанию да;
--- отключается ключом конфига nix_allow_unfree = false|0|no|off (регистр не важен).
function utils.nix_allow_unfree()
    local v = nil
    if grime and grime.config and grime.config.get then
        v = grime.config.get("nix_allow_unfree")
    end
    if v == nil then return true end
    if v == false then return false end
    local s = tostring(v):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return not (s == "false" or s == "0" or s == "no" or s == "off")
end

--- Окружение для nix-команд с flake-ссылками (nixpkgs#X): {NIXPKGS_ALLOW_UNFREE="1"} или nil.
function utils.nix_unfree_env()
    if utils.nix_allow_unfree() then return { NIXPKGS_ALLOW_UNFREE = "1" } end
    return nil
end

--- Флаги nix-команд, нужные для чтения NIXPKGS_ALLOW_UNFREE: {"--impure"} или {}.
function utils.nix_unfree_flags()
    if utils.nix_allow_unfree() then return { "--impure" } end
    return {}
end

--- Команда установки в профиль: `nix profile add [--impure] nixpkgs#X ...` и env для запуска.
--- Короткие имена получают префикс nixpkgs#, ссылки с [:#/] остаются как есть.
function utils.nix_profile_add_cmd(packages)
    local cmd = { "nix", "profile", "add" }
    for _, f in ipairs(utils.nix_unfree_flags()) do cmd[#cmd + 1] = f end
    for _, p in ipairs(packages or {}) do
        cmd[#cmd + 1] = p:find("[:#/]") and p or ("nixpkgs#" .. p)
    end
    return cmd, utils.nix_unfree_env()
end

--- Единый чистый генератор шаблона flake.nix (Flakes-only стандарт)
function utils.generate_flake_nix(name, native_pkgs, lib_pkgs, desc)
    name = name or "app"
    desc = desc or ("⚡ Окружение разработки Grime Flake DevShell для " .. name)

    local native_lines = {}
    for _, p in ipairs(native_pkgs or {}) do
        local clean = p:gsub("^pkgs%.", "")
        if utils.valid_pkg_name(clean) then
            table.insert(native_lines, "            " .. clean)
        else
            utils.warn_invalid_pkg(clean)
        end
    end
    if #native_lines == 0 then
        table.insert(native_lines, "            bashInteractive")
    end

    local clean_libs = {}
    local lib_lines = {}
    for _, p in ipairs(lib_pkgs or {}) do
        local clean = p:gsub("^pkgs%.", "")
        if utils.valid_pkg_name(clean) then
            table.insert(clean_libs, clean)
            table.insert(lib_lines, "            " .. clean)
        else
            utils.warn_invalid_pkg(clean)
        end
    end

    local safe_name = tostring(name):gsub("''", "'''"):gsub('[\\"$`]', "\\%0")
    local hook_lines = {
        string.format('echo "⚡ [Grime Flake DevShell] Окружение \'%s\' активировано"', safe_name)
    }
    if #clean_libs > 0 then
        local libs_str = table.concat(clean_libs, " ")
        table.insert(hook_lines, 'export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [ ' .. libs_str .. ' ])}:$LD_LIBRARY_PATH"')
        table.insert(hook_lines, 'export PKG_CONFIG_PATH="${pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (with pkgs; [ ' .. libs_str .. ' ])}:$PKG_CONFIG_PATH"')
    end

    local build_inputs_block = ""
    if #clean_libs > 0 then
        build_inputs_block = string.format([[

          buildInputs = with pkgs; [
%s
          ];]], table.concat(lib_lines, "\n"))
    end

    local for_all
    if utils.nix_allow_unfree() then
        for_all = "forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; config.allowUnfree = true; }));"
    else
        for_all = "forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});"
    end

    return string.format([[{
  description = %q;

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      %s
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
%s
          ];%s

          shellHook = ''
            %s
          '';
        };
      });
    };
}
]], desc, for_all, table.concat(native_lines, "\n"), build_inputs_block, table.concat(hook_lines, "\n            "))
end

--- Формирование обертки запуска с авто-детектом nixGL (GPU/OpenGL/Vulkan) и sudo
function utils.build_nixgl_wrapper(cmd, args, use_sudo)
    local escaped_args = {}
    for _, a in ipairs(args or {}) do
        table.insert(escaped_args, utils.shell_escape(a))
    end
    local args_str = #escaped_args > 0 and (" " .. table.concat(escaped_args, " ")) or ""
    local sudo_prefix = use_sudo and "sudo -E " or ""

    return string.format(
        'c=%s; b=$(command -v "$c" 2>/dev/null); ' ..
        'if [ -z "$b" ]; then b=$(find $(echo "$PATH" | tr ":" " ") -maxdepth 1 -iname "$c" 2>/dev/null | head -n 1); fi; ' ..
        'if [ -z "$b" ]; then b="$c"; fi; ' ..
        'r="$b"; [ -f "$(dirname "$b")/.$(basename "$b")-wrapped" ] && r="$(dirname "$b")/.$(basename "$b")-wrapped"; ' ..
        'k="$HOME/.local/share/grime/nixgl_path"; g=$(cat "$k" 2>/dev/null); ' ..
        '[ ! -x "$g" ] && g="$HOME/.local/share/grime/nixGL/bin/nixGL"; ' ..
        '[ ! -x "$g" ] && g=$(ls -d /nix/store/*-nixGL/bin/nixGL 2>/dev/null | tail -n 1); ' ..
        'if [ ! -x "$g" ]; then mkdir -p "$HOME/.local/share/grime" && nix build --impure github:nix-community/nixGL#nixGLDefault --out-link "$HOME/.local/share/grime/nixGL" >/dev/null 2>&1 && g="$HOME/.local/share/grime/nixGL/bin/nixGL"; fi; ' ..
        '[ -x "$g" ] && { mkdir -p "$HOME/.local/share/grime"; printf %%s "$g" > "$k" 2>/dev/null; }; ' ..
        'w=""; ' ..
        'if [ -x "$g" ] && command -v readelf >/dev/null 2>&1 && [ -f "$r" ] && readelf -d "$r" 2>/dev/null | grep -Eiq "libGL|libvulkan|libEGL|libX11|libwayland|libglvnd"; then w="$g"; fi; ' ..
        'exec %s$w "$b"%s',
        utils.shell_escape(cmd), sudo_prefix, args_str
    )
end

--- Единое разрешение именованного пути GRIME (ctx.paths / ctx.get_path) с нормализацией
function utils.get_named_path(name, fallback, ctx)
    local c = ctx or (grime and grime.ctx)
    local root = (c and c.paths and c.paths[name])
        or (c and c.get_path and c.get_path(name))
    if not root or root == "" then root = fallback end
    if not root or root == "" then return "" end
    if c and c.normalize_path then
        root = c.normalize_path(root)
    else
        root = utils.normalize_path(root)
    end
    return root
end

--- Определение корня каталога Grime Apps
function utils.get_apps_root(ctx)
    return utils.get_named_path("apps", (os.getenv("HOME") or "") .. "/.config/grime/apps", ctx)
end

--- Определение корня каталога проектов GRIME
--- Без настроенного пути (конфиг/аннотация `--@grime path.projects`) возвращает nil и сообщение об ошибке.
function utils.get_projects_root(ctx)
    local root = utils.get_named_path("projects", nil, ctx)
    if root == "" then
        return nil, "не настроен путь к проектам: задайте path.projects в конфиге GRIME (GRIME_CONFIG)"
    end
    return root
end

--- Путь к текущему исполняемому файлу grime (для самозапуска в том же окружении).
--- Для запуска внутри другой среды (box/nix) используйте имя "grime".
function utils.self_exe()
    if grime and grime.process and grime.process.exe_path then
        local ok, p = pcall(grime.process.exe_path)
        if ok and type(p) == "string" and p ~= "" then return p end
    end
    return "grime"
end

utils.LANG_ALIASES = {
    cpp = "cpp", ["c++"] = "cpp", cxx = "cpp", c = "cpp",
    python = "python", py = "python", python3 = "python",
    rust = "rust", rs = "rust",
    java = "java", jav = "java",
    lua = "lua", luajit = "lua",
    bash = "bash", sh = "bash", shell = "bash",
    fish = "fish",
}

--- Единая таблица каталогов-«корзин» языков в корне проектов: канонический язык -> варианты имён каталога
--- (первый элемент — предпочтительное имя для создания, остальные — исторические варианты регистра).
utils.LANG_BUCKETS = {
    cpp    = { "cpp", "C++", "c++", "Cpp", "CPP" },
    rust   = { "rust", "Rust", "RUST" },
    python = { "python", "Python", "PYTHON" },
    java   = { "java", "Java", "JAVA" },
    lua    = { "lua", "Lua", "LUA" },
    bash   = { "bash", "Bash", "BASH" },
    fish   = { "fish", "Fish", "FISH" },
}

--- Канонический порядок языков для обхода корзин
utils.LANG_ORDER = { "cpp", "rust", "python", "java", "lua", "bash", "fish" }

--- Имена каталогов-корзин: для языка (алиасы допустимы) — его варианты; без аргумента —
--- плоский список всех вариантов всех языков в каноническом порядке (без дублей).
function utils.lang_dir_names(lang)
    if lang ~= nil then
        local canon = utils.LANG_ALIASES[tostring(lang):lower()] or tostring(lang):lower()
        local list = utils.LANG_BUCKETS[canon] or {}
        local out = {}
        for i, n in ipairs(list) do out[i] = n end
        return out
    end
    local out, seen = {}, {}
    for _, l in ipairs(utils.LANG_ORDER) do
        for _, n in ipairs(utils.LANG_BUCKETS[l]) do
            if not seen[n] then
                seen[n] = true
                out[#out + 1] = n
            end
        end
    end
    return out
end

local SHEBANG_LANG_MAP = {
    python = "python", python3 = "python", python2 = "python",
    luajit = "lua", lua = "lua", ["lua5.1"] = "lua", ["lua5.4"] = "lua",
    bash = "bash", sh = "bash", dash = "bash", zsh = "bash", ash = "bash",
    fish = "fish",
    node = "nodejs", nodejs = "nodejs", deno = "nodejs", bun = "nodejs",
}

--- Разбор shebang (#!) и мета-комментариев первых 15 строк файла
function utils.parse_script_header(filepath)
    if not filepath or filepath == "" then return nil, false end
    local f = io.open(filepath, "rb")
    if not f then return nil, false end
    local chunk = f:read(4096)
    f:close()
    if not chunk or chunk == "" then
        return { shebang = nil, interp = nil, lang = nil, meta = {}, is_binary = false }, false
    end

    if chunk:sub(1, 4) == "\127ELF" or chunk:sub(1, 512):find("\0", 1, true) then
        return nil, true
    end

    local lines = {}
    for line in chunk:gmatch("[^\r\n]+") do
        table.insert(lines, line)
        if #lines >= 15 then break end
    end

    local res = {
        shebang = nil,
        interp = nil,
        lang = nil,
        meta = {},
        is_binary = false,
    }

    if lines[1] and lines[1]:match("^#!") then
        local raw_sb = lines[1]:sub(3):match("^%s*(.-)%s*$")
        res.shebang = raw_sb
        local tokens = {}
        for tok in raw_sb:gmatch("%S+") do
            table.insert(tokens, tok)
        end
        if #tokens > 0 then
            local first_base = tokens[1]:match("([^/]+)$") or tokens[1]
            local interp = first_base
            if first_base == "env" then
                interp = nil
                for i = 2, #tokens do
                    local t = tokens[i]
                    if not t:match("^%-") and not t:match("^[%w_]+=") then
                        interp = t:match("([^/]+)$") or t
                        break
                    end
                end
            end
            if interp and interp ~= "" then
                res.interp = interp
                local ilow = interp:lower()
                res.lang = SHEBANG_LANG_MAP[ilow]
                if not res.lang then
                    if ilow:match("^python") then
                        res.lang = "python"
                    elseif ilow:match("^lua") then
                        res.lang = "lua"
                    end
                end
            end
        end
    end

    for i = 1, #lines do
        local ln = lines[i]
        local body = ln:match("^%s*#%s*(.+)$") or ln:match("^%s*%-%-%s*(.+)$") or ln:match("^%s*//%s*(.+)$")
        if body and not ln:match("^#!") then
            local key, val = body:match("^([%w_%-]+)%s*:%s*(.+)$")
            if key and val then
                key = key:lower()
                val = val:match("^%s*(.-)%s*$")
                if key == "description" or key == "desc" then
                    res.meta.description = val
                elseif key == "nix" or key == "deps" or key == "dependencies" or key == "special_dependencies" then
                    local deps = res.meta.special_dependencies or {}
                    for dep in val:gsub(",", " "):gmatch("%S+") do
                        table.insert(deps, dep)
                    end
                    res.meta.special_dependencies = deps
                elseif key == "detach" or key == "detached" then
                    local vlow = val:lower()
                    res.meta.detached = (vlow == "true" or vlow == "1" or vlow == "yes")
                elseif key == "build" then
                    res.meta.build = val
                elseif key == "run" then
                    res.meta.run = val
                elseif key == "test" then
                    res.meta.test = val
                end
            end
        end
    end

    return res, false
end

--- Формирование лёгкой команды проверки синтаксиса для скриптового языка
function utils.build_syntax_check_cmd(lang, interp, rel_path)
    local l = (lang or ""):lower()
    local i = (interp or ""):lower()
    local escaped = utils.shell_escape(rel_path)
    if l == "fish" or i == "fish" then
        return "fish -n " .. escaped
    elseif l == "bash" or i == "bash" or i == "sh" or i == "dash" or i == "zsh" then
        return "bash -n " .. escaped
    elseif l == "python" or i:match("^python") then
        return "python3 -m py_compile " .. escaped
    elseif l == "lua" or i == "luajit" or i:match("^lua") then
        return "luajit -bl " .. escaped .. " >/dev/null"
    end
    return nil
end

--- Чтение мета-файла внешней привязки (.grime_app.json или .grime_link.json)
function utils.read_app_link_meta(app_dir)
    if not app_dir or app_dir == "" then return nil end
    for _, fname in ipairs({ ".grime_app.json", ".grime_link.json" }) do
        local p = app_dir .. "/" .. fname
        if utils.file_exists(p) then
            local f = io.open(p, "r")
            if f then
                local content = f:read("*a")
                f:close()
                if content and content ~= "" and grime and grime.json and grime.json.decode then
                    local ok, decoded = pcall(grime.json.decode, content)
                    if ok and type(decoded) == "table" then
                        return decoded
                    end
                end
            end
        end
    end
    return nil
end

-- ============================================================================
-- Общие хелперы (используются project/git/log/bus/daemon/ai/app/pkg)
-- ============================================================================

--- Экранирование спецсимволов Lua-паттерна
function utils.escape_pattern(s)
    return (tostring(s or ""):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- Корректная TOML-строка (basic string) с экранированием \\, ", управляющих символов
function utils.toml_string(s)
    s = tostring(s or "")
    s = s:gsub("[%c\\\"]", function(ch)
        local map = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
        return map[ch] or string.format("\\u%04X", ch:byte())
    end)
    return '"' .. s .. '"'
end

--- Валидация имени приложения/проекта: возвращает true либо false, сообщение
function utils.valid_name(name)
    if type(name) ~= "string" or name == "" then
        return false, "имя не может быть пустым"
    end
    if name:sub(1, 1) == "." then
        return false, "имя не может начинаться с '.' (включая '.' и '..')"
    end
    if name:find("..", 1, true) then
        return false, "имя не может содержать '..'"
    end
    if name:find("[/\\]") then
        return false, "имя не может содержать '/' или '\\'"
    end
    if name:sub(1, 1) == "-" then
        return false, "имя не может начинаться с '-'"
    end
    if name:find("[%c]") then
        return false, "имя не может содержать управляющие символы"
    end
    return true, nil
end

--- Валидация имени nix-пакета (с необязательным префиксом pkgs.)
--- Стоп-слова: имена каталогов/команд, которые не являются nix-пакетами
--- (принимаются только при явном объявлении в deps: explicit == true)
utils.PKG_STOPWORDS = {
    build = true, src = true, lib = true, bin = true, test = true, tests = true,
    docs = true, doc = true, include = true, dist = true, out = true, target = true,
    obj = true, examples = true, example = true, scripts = true, tools = true,
}

function utils.valid_pkg_name(name, explicit)
    if type(name) ~= "string" or name == "" then return false end
    if name:match("^[%w_%-%.+]+$") == nil then return false end
    if not explicit and utils.PKG_STOPWORDS[name:lower()] then return false end
    return true
end

--- Предупреждение об отброшенном невалидном имени пакета
function utils.warn_invalid_pkg(name)
    local msg = string.format("Пропущено недопустимое имя nix-пакета: '%s'", tostring(name))
    if grime and grime.ctx and grime.ctx.warn then
        grime.ctx.warn(msg)
    elseif grime and grime.ui and grime.ui.warn then
        grime.ui.warn(msg)
    else
        io.stderr:write(msg .. "\n")
    end
end

--- Проверка, что каталог находится в git-репозитории (.git или git rev-parse)
function utils.is_git_repo(dir, ctx)
    if not dir or dir == "" then return false end
    if utils.file_exists(dir .. "/.git") then return true end
    local c = ctx or (grime and grime.ctx)
    if c and c.capture then
        local res = c.capture({ "git", "-C", dir, "rev-parse", "--is-inside-work-tree" })
        return res.code == 0 and res.stdout ~= nil and res.stdout:match("true") ~= nil
    end
    return false
end

--- Определение интерактивного терминала на stdin (подменяется в тестах).
function utils.stdin_is_tty()
    local r = os.execute("test -t 0")
    return r == true or r == 0
end

--- Выделяет флаг подтверждения (-y/--yes/-yes) из списка аргументов: возвращает yes, остальные_аргументы.
function utils.extract_yes_flag(args)
    local yes, rest = false, {}
    for _, a in ipairs(args or {}) do
        if a == "-y" or a == "--yes" or a == "-yes" then yes = true else rest[#rest + 1] = a end
    end
    return yes, rest
end

--- Подтверждение необратимого действия. true — если assume_yes или пользователь ответил y/yes/д/да.
--- В неинтерактивном режиме без assume_yes — ctx.fail и false.
function utils.confirm_destructive(prompt, assume_yes, ctx)
    local c = ctx or (grime and grime.ctx)
    if assume_yes then return true end
    if not utils.stdin_is_tty() then
        if c and c.fail then c.fail("Требуется подтверждение: в неинтерактивном режиме добавьте --yes (-y)") end
        return false
    end
    io.stdout:write(prompt .. " [y/N]: ")
    io.stdout:flush()
    local ans = io.read()
    local low = ans and ans:match("^%s*(.-)%s*$"):lower() or ""
    if low == "y" or low == "yes" or low == "д" or low == "да" then
        return true
    end
    if c and c.fail then c.fail("Действие отменено пользователем") end
    return false
end

--- Создание приватного (0600) временного файла. Возвращает path, cleanup_fn (либо nil, err)
function utils.make_tempfile(content, ctx)
    local c = ctx or (grime and grime.ctx)
    local path
    if grime and grime.ephemeral and grime.ephemeral.file then
        -- Файл создаётся ядром (0600) и удаляется автоматически в конце конвейера
        local ok, p = pcall(grime.ephemeral.file, content or "")
        if not ok or not p or p == "" then return nil, "не удалось создать временный файл" end
        path = p
    else
        -- Запасной вариант без grime.ephemeral: mktemp
        if not (c and c.capture) then return nil, "ctx.capture недоступен" end
        local res = c.capture({ "mktemp", "-t", "grime.XXXXXXXX" })
        path = res.code == 0 and res.stdout and res.stdout:match("^%s*(.-)%s*$") or nil
        if not path or path == "" then return nil, "не удалось создать временный файл" end
        local f = io.open(path, "wb")
        if not f then
            c.capture({ "rm", "-f", path })
            return nil, "не удалось открыть временный файл на запись"
        end
        f:write(content or "")
        f:close()
    end
    local cleaned = false
    return path, function()
        if not cleaned then
            cleaned = true
            os.remove(path)
        end
    end
end

--- Выполнение fn(path) с приватным временным файлом; файл удаляется всегда (pcall-обёртка)
function utils.with_tempfile(content, fn, ctx)
    local path, cleanup = utils.make_tempfile(content, ctx)
    if not path then return nil, cleanup end
    local ok, res = pcall(fn, path)
    cleanup()
    if not ok then error(res, 0) end
    return res
end

--- Путь сокета демона GRIME: единый источник правды — ядро (grime.process.daemon_socket,
--- src/daemon.rs get_socket_path). Резерв ниже нужен только для окружений без этой функции.
function utils.daemon_socket_path(ctx)
    local native = grime and grime.process and grime.process.daemon_socket
    if native then return native() end
    local c = ctx or (grime and grime.ctx)
    local xdg = os.getenv("XDG_RUNTIME_DIR")
    if xdg and #xdg > 0 then
        return xdg .. "/grime.sock"
    end
    local uid = "default"
    local res = c and c.capture and c.capture({ "id", "-u" })
    if res and res.code == 0 and res.stdout then
        local u = res.stdout:match("%d+")
        if u and #u > 0 then uid = u end
    end
    if c and c.exists and c.exists("/run/user/" .. uid) then
        return "/run/user/" .. uid .. "/grime.sock"
    end
    return "/tmp/grime-" .. uid .. ".sock"
end

--- Единый фоновый запуск через nohup setsid. tokens — массив аргументов (или готовая строка);
--- возвращает pid (число-строка) либо nil
function utils.spawn_background(tokens, cwd, logfile, env, ctx)
    local c = ctx or (grime and grime.ctx)
    if not (c and c.capture) then return nil end
    local cmd_str
    if type(tokens) == "table" then
        local parts = {}
        for _, t in ipairs(tokens) do table.insert(parts, utils.shell_escape(t)) end
        cmd_str = table.concat(parts, " ")
    else
        cmd_str = tostring(tokens or "")
    end
    if cmd_str == "" then return nil end
    local out = (logfile and logfile ~= "") and utils.shell_escape(logfile) or "/dev/null"
    local res = c.capture(
        string.format("nohup setsid %s > %s 2>&1 < /dev/null & echo $!", cmd_str, out), cwd, env)
    return res.stdout and res.stdout:match("%d+") or nil
end

--- Проверка, жив ли процесс (через /proc, без shell; зомби считается мёртвым)
function utils.is_pid_alive(pid)
    pid = tostring(pid or "")
    if not pid:match("^%d+$") then return false end
    local f = io.open("/proc/" .. pid .. "/stat", "r")
    if not f then return false end
    local stat = f:read("*l") or ""
    f:close()
    local state = stat:match("^%d+ %(.*%) (%a)")
    return state ~= nil and state ~= "Z" and state ~= "X"
end

--- Единый CMake-генератор (адаптер cpp и генерируемый app.lua должны использовать одно и то же)
utils.CMAKE_GENERATOR = "Ninja"

--- Команда конфигурации CMake с единым генератором
function utils.cmake_configure_cmd()
    return "cmake -G " .. utils.CMAKE_GENERATOR .. " -B build -DCMAKE_BUILD_TYPE=Release"
end

--- Shebang-строки по языку
utils.SHEBANGS = {
    python = "#!/usr/bin/env python3",
    lua    = "#!/usr/bin/env luajit",
    bash   = "#!/usr/bin/env bash",
    fish   = "#!/usr/bin/env fish",
    nodejs = "#!/usr/bin/env node",
}

--- Соответствие расширений файлов языкам
utils.EXT_TO_LANG = {
    [".py"] = "python", [".lua"] = "lua",
    [".sh"] = "bash", [".bash"] = "bash", [".fish"] = "fish",
    [".rs"] = "rust",
    [".cpp"] = "cpp", [".cc"] = "cpp", [".cxx"] = "cpp", [".c"] = "cpp",
    [".java"] = "java", [".go"] = "go",
    [".js"] = "nodejs", [".ts"] = "nodejs",
}

--- Сборочные манифесты и их языки
utils.BUILD_MANIFEST_LANG = {
    ["Cargo.toml"] = "rust", ["CMakeLists.txt"] = "cpp", ["Makefile"] = "cpp",
    ["meson.build"] = "cpp", ["pom.xml"] = "java", ["build.gradle"] = "java",
    ["build.gradle.kts"] = "java", ["pyproject.toml"] = "python",
    ["go.mod"] = "go", ["build.zig"] = "zig",
}

--- Служебные файлы, которые не могут быть точкой входа
utils.IGNORED_ENTRY_FILES = {
    ["app.lua"] = true, ["flake.nix"] = true, ["flake.lock"] = true,
    ["app.log"] = true, ["app.pid"] = true, ["app.sock"] = true,
    ["README.md"] = true, ["readme.md"] = true, ["grime.json"] = true,
    ["meta.json"] = true, ["Cargo.lock"] = true, [".gitignore"] = true,
    [".grime_app.json"] = true, [".grime_link.json"] = true,
}

--- Кандидаты точки входа по языку
utils.ENTRY_CANDIDATES = {
    python = { "main.py", "src/main.py" },
    lua    = { "main.lua", "src/main.lua" },
    fish   = { "main.fish", "src/main.fish" },
    bash   = { "main.sh", "main.bash", "src/main.sh", "src/main.bash" },
    rust   = { "src/main.rs", "main.rs" },
    cpp    = { "src/main.cpp", "main.cpp", "main.c", "src/main.c" },
    java   = { "src/Main.java", "Main.java" },
    go     = { "main.go" },
}

-- Общий порядок кандидатов (без привязки к языку)
local ENTRY_ORDER = {
    "main.py", "main.lua", "main.fish", "main.sh", "main.bash",
    "main.rs", "main.cpp", "main.c", "Main.java", "main.go",
    "src/main.py", "src/main.lua", "src/main.fish", "src/main.sh", "src/main.bash",
    "src/main.rs", "src/main.cpp", "src/main.c", "src/Main.java",
}

--- Поиск главного файла приложения.
--- opts: { app_name = "...", explicit_entry = "относительный путь" }.
--- Возвращает rel_path, is_binary, найденный_сборочный_манифест
function utils.find_main_entry(dir, lang, opts)
    opts = opts or {}
    if not dir or not utils.file_exists(dir) then return nil, false, nil end

    -- io.open успешно открывает и каталоги; различаем через попытку чтения
    local function is_regular(p)
        local f = io.open(p, "rb")
        if not f then return false end
        local _, err = f:read(1)
        f:close()
        return err == nil
    end

    local explicit = opts.explicit_entry
    if explicit and explicit ~= "" then
        local rel = explicit
        local base = dir:gsub("/+$", "") .. "/"
        if rel:sub(1, #base) == base then rel = rel:sub(#base + 1) end
        if is_regular(dir .. "/" .. rel) then
            local _, is_bin = utils.parse_script_header(dir .. "/" .. rel)
            return rel, is_bin, nil
        end
    end

    local order = {}
    local seen = {}
    local function push(rel)
        if not seen[rel] then seen[rel] = true; table.insert(order, rel) end
    end
    local l = (lang or ""):lower()
    for _, rel in ipairs(utils.ENTRY_CANDIDATES[l] or {}) do push(rel) end
    for _, rel in ipairs(ENTRY_ORDER) do push(rel) end
    local app_name = opts.app_name
    if app_name and app_name ~= "" then
        for _, ext in ipairs({ ".py", ".lua", ".fish", ".sh", ".bash", ".rs", ".cpp", ".c", ".go", "" }) do
            push(app_name .. ext)
            push("src/" .. app_name .. ext)
        end
    end
    for _, rel in ipairs(order) do
        local full = dir .. "/" .. rel
        if is_regular(full) then
            local _, is_bin = utils.parse_script_header(full)
            return rel, is_bin, nil
        end
    end

    local found_build = nil
    for _, bname in ipairs({ "Cargo.toml", "CMakeLists.txt", "meson.build", "Makefile", "build.zig", "go.mod", "pom.xml", "build.gradle", "build.gradle.kts", "pyproject.toml" }) do
        if is_regular(dir .. "/" .. bname) then found_build = bname; break end
    end

    local scan_dirs = { { dir = dir, prefix = "" }, { dir = dir .. "/src", prefix = "src/" } }
    for _, sd in ipairs(scan_dirs) do
        local items = (grime and grime.fs and grime.fs.list and grime.fs.list(sd.dir)) or {}
        table.sort(items)
        for _, item in ipairs(items) do
            if not item:match("^%.") and not utils.IGNORED_ENTRY_FILES[item] and not utils.BUILD_MANIFEST_LANG[item] then
                local full = sd.dir .. "/" .. item
                if is_regular(full) then
                    local ext = item:match("(%.[%a%d_]+)$")
                    if ext and utils.EXT_TO_LANG[ext:lower()] then
                        return sd.prefix .. item, false, found_build
                    end
                    local hdr, is_bin = utils.parse_script_header(full)
                    if is_bin or (hdr and hdr.shebang) then
                        return sd.prefix .. item, is_bin, found_build
                    end
                end
            end
        end
    end
    return nil, false, found_build
end

--- Основной файл по языку (для промптов/шаблонов): первый существующий кандидат либо дефолт языка
function utils.entry_file_for_lang(lang, dir)
    local defaults = {
        python = "main.py", java = "src/Main.java", rust = "src/main.rs",
        lua = "main.lua", bash = "main.sh", fish = "main.fish", cpp = "src/main.cpp",
    }
    local cand = defaults[(lang or "python"):lower()] or "main.py"
    if dir and utils.file_exists(dir .. "/" .. cand) then return cand end
    for _, rel in ipairs(ENTRY_ORDER) do
        if dir and utils.file_exists(dir .. "/" .. rel) then return rel end
    end
    return cand
end

--- Признак файла-скрипта/исходника, у которого имеет смысл читать shebang и заголовки deps/nix
function utils.is_script_file(fname)
    if not fname or fname == "" then return false end
    local ext = fname:match("(%.[%a%d_]+)$")
    if ext then return utils.EXT_TO_LANG[ext:lower()] ~= nil end
    return not utils.IGNORED_ENTRY_FILES[fname] and not fname:match("^%.")
end

--- Генерация flake.nix по плоскому списку пакетов.
--- opts: { name, packages = {...}, desc, scanner }. Невалидные имена отбрасываются с предупреждением
function utils.generate_flake(opts)
    opts = opts or {}
    local native, libs = utils.split_packages(opts.packages or {}, opts.scanner)
    return utils.generate_flake_nix(opts.name, native, libs, opts.desc)
end

-- ============================================================================
-- Общие функции для app/nix/ai/project/list/pkg (замена локальных дублей)
-- ============================================================================

--- Хеш djb2 строки в виде 8 hex-символов (стабильный ключ кэша эфемерных flake)
function utils.djb2_hex(s)
    s = tostring(s or "")
    local h = 5381
    for i = 1, #s do
        h = ((h * 33) + s:byte(i)) % 4294967296
    end
    return string.format("%08x", h)
end

--- Корень каталога шаблонов (ctx.paths.templates / ctx.get_path) с запасным ~/.config/grime/templates
function utils.templates_root(ctx)
    local home = os.getenv("HOME") or ""
    local fallback = (home ~= "") and (home .. "/.config/grime/templates") or "./templates"
    return utils.get_named_path("templates", fallback, ctx)
end

--- Единая точка записи flake.nix через generate_flake_nix.
--- opts: { desc = строка описания, mkdir = true (создать dir), git_add = true (git add -N flake.nix), ctx = ctx }.
--- Возвращает true, flake_path либо false, сообщение об ошибке.
function utils.write_flake(dir, name, native, libs, opts)
    opts = opts or {}
    if not dir or dir == "" then return false, "не указан каталог flake" end
    local c = opts.ctx or (grime and grime.ctx)
    if opts.mkdir and c and c.mkdir_p then
        c.mkdir_p(dir)
    end
    local path = dir .. "/flake.nix"
    local content = utils.generate_flake_nix(name, native, libs, opts.desc)
    local f, err = io.open(path, "w")
    if not f then return false, "не удалось записать " .. path .. ": " .. tostring(err) end
    f:write(content)
    f:close()
    if opts.git_add and c and c.capture then
        pcall(function() c.capture({ "git", "add", "-N", "flake.nix" }, dir) end)
    end
    return true, path
end

--- Гарантирует shebang (#!) в первой строке скрипта; ctx нужен только для лога (необязателен).
--- Бинарные файлы пропускаются, UTF-8 BOM удаляется. Возвращает true, если shebang есть/добавлен.
function utils.ensure_shebang(path, lang, ctx)
    local f = io.open(path, "rb")
    if not f then return false end
    local content = f:read("*a") or ""
    f:close()

    if content:sub(1, 4) == "\127ELF" or content:sub(1, 512):find("\0", 1, true) then
        return false
    end

    local bom_stripped = false
    if content:sub(1, 3) == "\239\187\191" then
        content = content:sub(4)
        bom_stripped = true
    end

    if content:sub(1, 2) == "#!" then
        if bom_stripped then
            local wf = io.open(path, "wb")
            if wf then wf:write(content); wf:close() end
        end
        return true
    end

    local ext = path:match("(%.[%a%d_]+)$")
    local inferred = (ext and utils.EXT_TO_LANG[ext:lower()]) or lang
    local sb = utils.SHEBANGS[(inferred or ""):lower()]
    if not sb then return false end

    local wf = io.open(path, "wb")
    if not wf then return false end
    wf:write(sb .. "\n" .. content)
    wf:close()
    local c = ctx or (grime and grime.ctx)
    if c and c.log then
        c.log(string.format("Добавлен shebang '%s' в %s", sb, path))
    end
    return true
end

--- Результат хука `wraps: pipeline`: { args = { "-run", <target_args...>, "--", <rest_argv...> } }.
--- target_args — токены между "-run" и "--" (для box — имя контейнера; для nix — пусто/nil).
--- Возвращает nil, если подконвейер пуст.
function utils.wrap_pipeline_run(rest_argv, target_args)
    if type(rest_argv) ~= "table" or #rest_argv == 0 then return nil end
    local res = { "-run" }
    for _, t in ipairs(target_args or {}) do res[#res + 1] = t end
    res[#res + 1] = "--"
    for _, t in ipairs(rest_argv) do res[#res + 1] = t end
    return { args = res }
end

--- Безопасная загрузка манифеста app.lua (каталог приложения или путь к файлу) в ограниченном окружении.
--- Доступно в манифесте: os.getenv (только эта функция os), string, table, math, type, tostring, tonumber,
--- pairs, ipairs, select. НЕДОСТУПНО: io, require, load/loadfile/dofile, остальной os, debug, grime.
--- Только текстовые чанки; число инструкций ограничено хуком (защита от бесконечных циклов).
--- Возвращает таблицу манифеста либо nil, сообщение об ошибке.
function utils.load_manifest_sandboxed(dir_or_file)
    if type(dir_or_file) ~= "string" or dir_or_file == "" then
        return nil, "не указан путь к манифесту"
    end
    local path = dir_or_file
    if not path:match("%.lua$") then path = path:gsub("/+$", "") .. "/app.lua" end
    if not utils.file_exists(path) then return nil, "манифест не найден: " .. path end

    local env = {
        os = { getenv = os.getenv },
        string = string, table = table, math = math,
        type = type, tostring = tostring, tonumber = tonumber,
        pairs = pairs, ipairs = ipairs, select = select,
    }
    local chunk, err = loadfile(path, "t", env)
    if not chunk then return nil, tostring(err) end

    -- Глобал `debug` в рантайме ядра отсутствует (безопасный набор stdlib), поэтому лимит инструкций
    -- включается только там, где он есть (обычный lua5.4, тесты). В ядре от бесконечного цикла
    -- защищает хук отмены (Ctrl+C / watchdog), который срабатывает каждые 10 000 инструкций.
    local limit_hit = false
    local has_hook = type(debug) == "table" and type(debug.sethook) == "function"
    if has_hook then
        debug.sethook(function() limit_hit = true; error("превышен лимит инструкций манифеста", 0) end, "", 5000000)
    end
    local ok, m = pcall(chunk)
    if has_hook then debug.sethook() end
    if not ok then return nil, tostring(m) end
    if limit_hit then return nil, "превышен лимит инструкций манифеста" end
    if type(m) ~= "table" then return nil, "манифест должен возвращать таблицу" end
    return m
end

--- Сбор nix-пакетов проекта: toolchain + special_dependencies сканера + зависимости манифеста + user_packages.
--- manifest: таблица либо nil (тогда читается <dir>/app.lua в песочнице, если он есть);
--- scan: результат scanner.scan_project либо nil (будет выполнен скан); ctx нужен только для скана.
--- Невалидные имена отбрасываются с предупреждением, префикс `pkgs.` снимается, дубли убираются.
--- Возвращает { native = {...}, libs = {...}, user = {...} }, где user — валидные пакеты манифеста и user_packages.
function utils.collect_nix_packages(dir, manifest, scan, user_packages, ctx)
    if scan == nil then
        local ok, scanner = pcall(require, "languages.scanner")
        if ok and scanner and scanner.scan_project then
            scan = scanner.scan_project(dir, ctx or (grime and grime.ctx))
        end
    end
    scan = scan or {}
    if manifest == nil and dir and utils.file_exists(dir .. "/app.lua") then
        manifest = utils.load_manifest_sandboxed(dir)
    end

    local seen, all, user = {}, {}, {}
    local function add(p, is_user, explicit)
        if type(p) ~= "string" or p == "" then return end
        local clean = p:gsub("^pkgs%.", "")
        if not utils.valid_pkg_name(clean, explicit) then
            utils.warn_invalid_pkg(clean)
            return
        end
        if is_user and not user[clean] then
            user[clean] = true
            user[#user + 1] = clean
        end
        if not seen[clean] then
            seen[clean] = true
            all[#all + 1] = clean
        end
    end
    local function add_list(list, is_user)
        if type(list) == "table" then
            for _, v in ipairs(list) do add(v, is_user, is_user == true) end
        elseif type(list) == "string" then
            for s in list:gmatch("%S+") do add(s, is_user, is_user == true) end
        end
    end

    add_list(scan.toolchain)
    add_list(scan.special_dependencies)
    if type(manifest) == "table" then
        add_list(manifest.special_dependencies, true)
        add_list(manifest.dependencies, true)
        add_list(manifest.extra_packages, true)
        if type(manifest.nix) == "table" then
            add_list(manifest.nix.special_dependencies, true)
            add_list(manifest.nix.dependencies, true)
            add_list(manifest.nix.packages, true)
        elseif type(manifest.nix) == "string" then
            add_list(manifest.nix, true)
        end
    end
    add_list(user_packages, "cli") -- CLI-токены: не явная аннотация, стоп-слова отфильтровываются

    local native, libs = utils.split_packages(all)
    -- служебная хеш-часть списка user не нужна потребителям
    local user_list = {}
    for i, v in ipairs(user) do user_list[i] = v end
    return { native = native, libs = libs, user = user_list }
end

--- Токены команды `nix develop [path:<dir>] --command <cmd...>`.
--- dir_or_flake: каталог (получит префикс path:), готовая flake-ссылка (содержит ':' или '#') либо nil.
--- opts: { impure = true } добавляет --impure.
function utils.develop_cmd(dir_or_flake, cmd_tokens, opts)
    opts = opts or {}
    local t = { "nix", "develop" }
    if dir_or_flake and dir_or_flake ~= "" then
        local ref = dir_or_flake
        if not ref:find("[:#]") then ref = "path:" .. ref:gsub("/+$", "") end
        t[#t + 1] = ref
    end
    if opts.impure then t[#t + 1] = "--impure" end
    t[#t + 1] = "--command"
    for _, tok in ipairs(cmd_tokens or {}) do t[#t + 1] = tostring(tok) end
    return t
end

return utils
