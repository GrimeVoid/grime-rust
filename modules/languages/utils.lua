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

--- Проверка доступности бинарной утилиты на хосте с кэшированием
function utils.has_binary(bin, ctx)
    if not bin or bin == "" then return false end
    if binary_cache[bin] ~= nil then
        return binary_cache[bin]
    end
    if grime and grime.process and grime.process.which then
        local p = grime.process.which(bin)
        if p and #p > 0 then
            binary_cache[bin] = true
            return true
        end
    end
    local c = ctx or (grime and grime.ctx)
    if c and c.capture then
        local res = c.capture({ "which", bin })
        local exists = (res.code == 0 and res.stdout and res.stdout:match("%S") ~= nil) or false
        binary_cache[bin] = exists
        return exists
    end
    return false
end

--- Определение, выполняется ли команда от суперпользователя root
function utils.is_root_user(ctx)
    if os.getenv("USER") == "root" or os.getenv("SUDO_USER") ~= nil then
        return true
    end
    local c = ctx or (grime and grime.ctx)
    if c and c.capture then
        local res = c.capture({ "id", "-u" })
        return res.code == 0 and res.stdout and res.stdout:match("^0%s*$") ~= nil
    end
    return false
end

--- Экранирование строкового аргумента для передачи в shell
function utils.shell_escape(arg)
    return "'" .. tostring(arg or ""):gsub("'", "'\\''") .. "'"
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

--- Единый чистый генератор шаблона flake.nix (Flakes-only стандарт)
function utils.generate_flake_nix(name, native_pkgs, lib_pkgs, desc)
    name = name or "app"
    desc = desc or ("⚡ Окружение разработки Grime Flake DevShell для " .. name)

    local native_lines = {}
    for _, p in ipairs(native_pkgs or {}) do
        local clean = p:gsub("^pkgs%.", "")
        table.insert(native_lines, "            " .. clean)
    end
    if #native_lines == 0 then
        table.insert(native_lines, "            bashInteractive")
    end

    local clean_libs = {}
    local lib_lines = {}
    for _, p in ipairs(lib_pkgs or {}) do
        local clean = p:gsub("^pkgs%.", "")
        table.insert(clean_libs, clean)
        table.insert(lib_lines, "            " .. clean)
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

    return string.format([[{
  description = %q;

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
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
]], desc, table.concat(native_lines, "\n"), build_inputs_block, table.concat(hook_lines, "\n            "))
end

--- Универсальный генератор манифеста app.lua для всех поддерживаемых языков
function utils.generate_app_manifest(name, lang, desc)
    name = name or "app"
    lang = (lang or "cpp"):lower()
    local clean_desc = (desc and desc ~= "") and desc:gsub("\n", " ") or ("Приложение " .. name)
    local snake_name = name:lower():gsub("[%s%-]", "_")

    local profiles = {
        cpp = {
            artifact = "build/" .. name,
            build = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
            run = "build/" .. name,
        },
        rust = {
            artifact = "target/release/" .. snake_name,
            build = "cargo build --release",
            run = "target/release/" .. snake_name,
        },
        python = {
            artifact = "src/main.py",
            build = "python3 -m py_compile src/main.py",
            run = "python3 src/main.py",
        },
        java = {
            artifact = "target/" .. name .. "-1.0-SNAPSHOT.jar",
            build = "mvn -q package",
            run = "java -jar target/" .. name .. "-1.0-SNAPSHOT.jar",
        },
        lua = {
            artifact = "src/main.lua",
            build = "luajit -bl src/main.lua >/dev/null",
            run = "luajit src/main.lua",
        },
    }

    local p = profiles[lang] or {
        artifact = "src/main.lua",
        run = "luajit src/main.lua",
    }

    local lines = {
        "return {",
        string.format("    name = %q,", name),
        string.format("    description = %q,", clean_desc),
        string.format("    type = %q,", lang),
        string.format("    artifact = %q,", p.artifact),
    }
    if p.build then
        table.insert(lines, string.format("    build = %q,", p.build))
    end
    table.insert(lines, string.format("    run = %q,", p.run))
    table.insert(lines, "    special_dependencies = {},")
    table.insert(lines, "    detached = false,")
    table.insert(lines, "}")
    return table.concat(lines, "\n") .. "\n"
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
        'c=%q; b=$(command -v "$c" 2>/dev/null); ' ..
        'if [ -z "$b" ]; then b=$(find $(echo "$PATH" | tr ":" " ") -maxdepth 1 -iname "$c" 2>/dev/null | head -n 1); fi; ' ..
        'if [ -z "$b" ]; then b="$c"; fi; ' ..
        'r="$b"; [ -f "$(dirname "$b")/.$(basename "$b")-wrapped" ] && r="$(dirname "$b")/.$(basename "$b")-wrapped"; ' ..
        'g="$HOME/.local/share/grime/nixGL/bin/nixGL"; [ ! -x "$g" ] && g=$(ls -d /nix/store/*-nixGL/bin/nixGL 2>/dev/null | tail -n 1); ' ..
        'if [ ! -x "$g" ]; then mkdir -p "$HOME/.local/share/grime" && nix build --impure github:nix-community/nixGL#nixGLDefault --out-link "$HOME/.local/share/grime/nixGL" >/dev/null 2>&1 && g="$HOME/.local/share/grime/nixGL/bin/nixGL"; fi; ' ..
        'w=""; ' ..
        'if [ -x "$g" ] && command -v readelf >/dev/null 2>&1 && [ -f "$r" ] && readelf -d "$r" 2>/dev/null | grep -Eiq "libGL|libvulkan|libEGL|libX11|libwayland|libglvnd"; then w="$g"; fi; ' ..
        'exec %s$w "$b"%s',
        cmd, sudo_prefix, args_str
    )
end

--- Определение корня каталога Grime Apps
function utils.get_apps_root(ctx)
    local c = ctx or (grime and grime.ctx)
    local root = (c and c.paths and c.paths.apps)
        or (c and c.get_path and c.get_path("apps"))
        or (c and c.apps_root and c.apps_root())
        or ((os.getenv("HOME") or "") .. "/.config/grime/apps")
    if c and c.normalize_path then
        root = c.normalize_path(root)
    else
        root = utils.normalize_path(root)
    end
    return root
end

--- Определение корня каталога проектов GRIME
function utils.get_projects_root(ctx)
    local c = ctx or (grime and grime.ctx)
    local root = (c and c.paths and c.paths.projects)
        or (c and c.get_path and c.get_path("projects"))
        or (c and c.projects_root and c.projects_root())
    if not root or root == "" then
        local home = os.getenv("HOME") or ""
        root = (home ~= "" and (home .. "/Projects")) or "./projects"
    end
    if c and c.normalize_path then
        root = c.normalize_path(root)
    else
        root = utils.normalize_path(root)
    end
    return root
end

return utils
