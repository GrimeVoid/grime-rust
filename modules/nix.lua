local argparse = require("languages.argparse")
local scanner = require("languages.scanner")
local ctx = grime.ctx

local ACTIONS = {
    init = "init", create = "init", new = "init", make = "init",
    flake = "flake", f = "flake",
    build = "build", b = "build", compile = "build",
    history = "history", hist = "history", log = "history",
    rollback = "rollback", revert = "rollback",
    update = "update", up = "update",
    bundle = "bundle", pack = "bundle",
    diff = "diff", closures = "diff",
    gc = "gc", clean = "gc", cleanup = "gc", ["garbage-collect"] = "gc",
    optimise = "optimise", optimize = "optimise", opt = "optimise", dedup = "optimise",
    add = "add", append = "add", ["in"] = "add",
    rm = "rm", remove = "rm", del = "rm", delete = "rm",
    install = "install", i = "install", ["profile-install"] = "install", get = "install",
    uninstall = "uninstall", un = "uninstall", ["remove-profile"] = "uninstall", ["rm-profile"] = "uninstall", erase = "uninstall",
    enter = "enter", shell = "enter", sh = "enter",
    run = "run", ["exec"] = "run", ["do"] = "run", ["run-in"] = "run", e = "run",
    check = "check", test = "check", validate = "check",
    help = "help",
}

--- Разделение пакетов на тулчейн (nativeBuildInputs) и библиотеки (buildInputs)
local function split_packages(packages)
    local native = {}
    local libs = {}
    local native_set = {}
    local libs_set = {}

    for _, p in ipairs(packages or {}) do
        local clean = p:gsub("^pkgs%.", "")
        if scanner.is_toolchain_package(clean) then
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

--- Загрузка специальных зависимостей из app.lua (если есть)
local function load_app_special_dependencies(root)
    local app_file = root .. "/app.lua"
    if not ctx.exists(app_file) then return {} end

    local chunk, err = loadfile(app_file)
    if not chunk then return {} end

    local ok, m = pcall(chunk)
    if not ok or type(m) ~= "table" then return {} end

    local deps = {}
    local function add_all(list)
        if type(list) == "table" then
            for _, v in ipairs(list) do
                if type(v) == "string" and #v > 0 then
                    table.insert(deps, v)
                end
            end
        elseif type(list) == "string" then
            for s in list:gmatch("%S+") do
                table.insert(deps, s)
            end
        end
    end

    add_all(m.special_dependencies)
    add_all(m.dependencies)
    add_all(m.extra_packages)
    if type(m.nix) == "table" then
        add_all(m.nix.dependencies)
        add_all(m.nix.packages)
        add_all(m.nix.special_dependencies)
    end

    return deps
end

--- Комплексный сбор всех зависимостей проекта (Auto-Toolchain + Special Dependencies + CLI args)
local function resolve_project_dependencies(target_dir, user_packages)
    local scan = scanner.scan_project(target_dir, ctx)
    local all_packages = {}

    -- 1. Авто-тулчейн от сканера
    for _, p in ipairs(scan.toolchain or {}) do
        table.insert(all_packages, p)
    end

    -- 2. Специальные зависимости из app.lua
    local special_deps = load_app_special_dependencies(target_dir)
    for _, p in ipairs(special_deps) do
        table.insert(all_packages, p)
    end

    -- 3. Пакеты, переданные пользователем через CLI
    for _, p in ipairs(user_packages or {}) do
        table.insert(all_packages, p)
    end

    return split_packages(all_packages)
end

local function generate_shell_nix(native_pkgs, lib_pkgs)
    local native_str = ""
    for _, p in ipairs(native_pkgs) do
        local name = p:gsub("^pkgs%.", "")
        native_str = native_str .. "    " .. name .. "\n"
    end

    local lib_str = ""
    for _, p in ipairs(lib_pkgs) do
        local name = p:gsub("^pkgs%.", "")
        lib_str = lib_str .. "    " .. name .. "\n"
    end

    local hook_lines = {
        'echo "⚡ [Grime Nix DevShell] Окружение разработки активировано"'
    }
    if #lib_pkgs > 0 then
        table.insert(hook_lines, 'export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [ ' .. table.concat(lib_pkgs, " ") .. ' ])}:$LD_LIBRARY_PATH"')
        table.insert(hook_lines, 'export PKG_CONFIG_PATH="${pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (with pkgs; [ ' .. table.concat(lib_pkgs, " ") .. ' ])}:$PKG_CONFIG_PATH"')
    end

    local build_inputs_str = ""
    if #lib_pkgs > 0 then
        build_inputs_str = string.format([[
  buildInputs = with pkgs; [
%s  ];]], lib_str)
    end

    return string.format([[{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
%s  ];%s

  shellHook = ''
    %s
  '';
}
]], native_str, build_inputs_str, table.concat(hook_lines, "\n    "))
end

local function generate_flake_nix(native_pkgs, lib_pkgs, desc)
    desc = desc or "⚡ Окружение разработки Grime Flake DevShell"
    local native_str = ""
    for _, p in ipairs(native_pkgs) do
        local name = p:gsub("^pkgs%.", "")
        native_str = native_str .. "            " .. name .. "\n"
    end

    local lib_str = ""
    for _, p in ipairs(lib_pkgs) do
        local name = p:gsub("^pkgs%.", "")
        lib_str = lib_str .. "            " .. name .. "\n"
    end

    local hook_lines = {
        'echo "⚡ [Grime Nix Flake DevShell] Окружение активировано"'
    }
    if #lib_pkgs > 0 then
        table.insert(hook_lines, 'export LD_LIBRARY_PATH="${pkgs.lib.makeLibraryPath (with pkgs; [ ' .. table.concat(lib_pkgs, " ") .. ' ])}:$LD_LIBRARY_PATH"')
        table.insert(hook_lines, 'export PKG_CONFIG_PATH="${pkgs.lib.makeSearchPathOutput "dev" "lib/pkgconfig" (with pkgs; [ ' .. table.concat(lib_pkgs, " ") .. ' ])}:$PKG_CONFIG_PATH"')
    end

    local build_inputs_block = ""
    if #lib_pkgs > 0 then
        build_inputs_block = string.format([[

          buildInputs = with pkgs; [
%s          ];]], lib_str)
    end

    return string.format([[{
  description = "%s";

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
%s          ];%s

          shellHook = ''
            %s
          '';
        };
      });
    };
}
]], desc, native_str, build_inputs_block, table.concat(hook_lines, "\n            "))
end

local function handle_init(target_dir, packages, force)
    local shell_path = target_dir .. "/shell.nix"
    if ctx.exists(shell_path) and not force then
        ctx.log("Файл shell.nix уже существует. Используйте -f / --force для перезаписи.")
        return
    end

    local native_pkgs, lib_pkgs = resolve_project_dependencies(target_dir, packages)
    local content = generate_shell_nix(native_pkgs, lib_pkgs)
    local f = io.open(shell_path, "w")
    if f then
        f:write(content)
        f:close()
        local total_count = #native_pkgs + #lib_pkgs
        ctx.log(string.format("Создан shell.nix в %s (native: %s%s)",
            target_dir,
            table.concat(native_pkgs, ", "),
            #lib_pkgs > 0 and (", libs: " .. table.concat(lib_pkgs, ", ")) or ""
        ))
    else
        ctx.fail("Не удалось записать " .. shell_path)
    end
end

local function handle_flake(target_dir, packages, force)
    local flake_path = target_dir .. "/flake.nix"
    if ctx.exists(flake_path) and not force then
        ctx.log("Файл flake.nix уже существует. Используйте -f / --force для перезаписи.")
        return
    end

    local native_pkgs, lib_pkgs = resolve_project_dependencies(target_dir, packages)
    local content = generate_flake_nix(native_pkgs, lib_pkgs)
    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
        ctx.log(string.format("Создан flake.nix в %s (native: %s%s)",
            target_dir,
            table.concat(native_pkgs, ", "),
            #lib_pkgs > 0 and (", libs: " .. table.concat(lib_pkgs, ", ")) or ""
        ))
    else
        ctx.fail("Не удалось записать " .. flake_path)
    end
end

--- Сборка проекта в эфемерном Flake-окружении (без загрязнения рабочего дерева)
local function handle_build(target_dir, extra_tokens)
    target_dir = ctx.normalize_path(target_dir)

    -- Анализ extra_tokens: отделяем команду сборки от пакетов зависимостей
    local user_packages = {}
    local custom_build_cmd = nil

    if extra_tokens and #extra_tokens > 0 then
        local is_command = false
        for _, t in ipairs(extra_tokens) do
            if type(t) == "string" then
                if t:find("%s") or t:find("^%-") or t:find("&&") or t:find(";") or t:find("|") or t:find(">") or t:find("<") or t:find("^%./") or t:find("^/") then
                    is_command = true
                    break
                end
            end
        end

        if not is_command then
            local first = extra_tokens[1]
            local known_build_cmds = {
                make = true, cmake = true, ninja = true, cargo = true,
                ["g++"] = true, ["clang++"] = true, gcc = true, clang = true,
                bash = true, sh = true, meson = true, gradle = true, mvn = true
            }
            if known_build_cmds[first] and #extra_tokens > 1 then
                is_command = true
            end
        end

        if is_command then
            custom_build_cmd = table.concat(extra_tokens, " ")
        else
            user_packages = extra_tokens
        end
    end

    -- Если в директории уже есть постоянный flake.nix, используем его
    if ctx.exists(target_dir .. "/flake.nix") then
        ctx.log("⚡ [Grime Nix Build] Сборка через локальный flake.nix в " .. target_dir .. "...")
        local cmd_str = custom_build_cmd or "grime project build"
        local cmd = { "nix", "develop", "--command", "bash", "-c", cmd_str }
        local ret = ctx.run_process(cmd, target_dir)
        ctx.module_return(target_dir)
        if ret ~= 0 then
            ctx.fail("Сборка внутри Nix завершилась с ошибкой (код " .. tostring(ret) .. ")")
        end
        return
    end

    -- Эфемерный режим: синтез flake в каталоге кэша ~/.cache/grime/flakes/<hash>/
    local h = 5381
    for i = 1, #target_dir do
        h = ((h * 33) + target_dir:byte(i)) % 4294967296
    end
    local hash = string.format("%08x", h)
    local cache_dir = ((os.getenv("HOME") or "") .. "/.cache/grime/flakes/" .. hash)
    ctx.mkdir_p(cache_dir)

    local native_pkgs, lib_pkgs = resolve_project_dependencies(target_dir, user_packages)
    local flake_content = generate_flake_nix(native_pkgs, lib_pkgs, "Ephemeral DevShell for " .. target_dir)

    local cache_flake_path = cache_dir .. "/flake.nix"
    local f = io.open(cache_flake_path, "w")
    if f then
        f:write(flake_content)
        f:close()
    else
        ctx.fail("Не удалось создать эфемерный Flake в " .. cache_flake_path)
        return
    end

    ctx.log(string.format("⚡ [Grime Ephemeral Flake] Синтезирован тулчейн в кэше (%s%s)",
        table.concat(native_pkgs, ", "),
        #lib_pkgs > 0 and (", libs: " .. table.concat(lib_pkgs, ", ")) or ""
    ))
    ctx.log("⚡ [Grime Ephemeral Flake] Запуск чистой сборки (рабочее дерево проекта остается нетронутым)...")

    local build_cmd = custom_build_cmd or ("grime project build \"" .. target_dir .. "\"")
    local cmd = {
        "nix", "develop", "path:" .. cache_dir,
        "--command", "bash", "-c",
        "cd \"" .. target_dir .. "\" && " .. build_cmd
    }

    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Сборка в эфемерном Nix Flake завершилась с ошибкой (код " .. tostring(ret) .. ")")
    else
        ctx.log("✓ Сборка в изолированном Nix Flake успешно завершена!")
    end
end

local function handle_gc()
    ctx.log("Запуск очистки мусора Nix (Garbage Collection)...")
    local ret = ctx.run_process({ "nix-collect-garbage", "-d" })
    if ret ~= 0 then
        ret = ctx.run_process({ "nix", "store", "gc" })
    end
    if ret == 0 then
        ctx.log("Очистка хранилища Nix успешно завершена.")
    else
        ctx.fail("Ошибка при сборке мусора Nix (код " .. tostring(ret) .. ")")
    end
end

local function handle_optimise()
    ctx.log("Оптимизация и дедупликация хранилища Nix...")
    local ret = ctx.run_process({ "nix", "store", "optimise" })
    if ret ~= 0 then
        ret = ctx.run_process({ "nix-store", "--optimise" })
    end
    if ret == 0 then
        ctx.log("Дедупликация жестких ссылок Nix завершена.")
    else
        ctx.fail("Ошибка оптимизации хранилища Nix (код " .. tostring(ret) .. ")")
    end
end

local function handle_enter(target_dir, pure)
    local has_flake = ctx.exists(target_dir .. "/flake.nix")
    local cmd = {}
    if has_flake then
        cmd = { "nix", "develop" }
    else
        cmd = { "nix-shell" }
    end
    if pure then table.insert(cmd, "--pure") end

    ctx.log("Активация dev-окружения в " .. target_dir .. "...")
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Сессия Nix завершилась с кодом " .. tostring(ret))
    end
end

local function handle_run(target_dir, command_tokens, pure)
    local has_flake = ctx.exists(target_dir .. "/flake.nix")
    local cmd_str = table.concat(command_tokens, " ")
    if cmd_str == "" then cmd_str = "grime project run" end

    local cmd = {}
    if has_flake then
        cmd = { "nix", "develop" }
        if pure then table.insert(cmd, "--pure") end
        table.insert(cmd, "--command")
        table.insert(cmd, "bash")
        table.insert(cmd, "-c")
        table.insert(cmd, cmd_str)
    else
        cmd = { "nix-shell" }
        if pure then table.insert(cmd, "--pure") end
        table.insert(cmd, "--run")
        table.insert(cmd, cmd_str)
    end

    ctx.log("Запуск внутри Nix devShell: " .. cmd_str .. " (директория: " .. target_dir .. ")")
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret ~= 0 then
        ctx.fail("Команда внутри Nix завершилась с кодом " .. tostring(ret))
    end
end

local function handle_install(packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для установки в профиль Nix")
        return
    end

    local cmd = { "nix", "profile", "install" }
    for _, p in ipairs(packages) do
        if not p:find("[:#/]") then
            table.insert(cmd, "nixpkgs#" .. p)
        else
            table.insert(cmd, p)
        end
    end

    ctx.log("Установка пакетов в профиль Nix: " .. table.concat(packages, ", ") .. "...")
    local ret = ctx.run_process(cmd)
    if ret == 0 then
        ctx.log("Пакеты успешно установлены в профиль Nix.")
    else
        ctx.fail("Ошибка установки пакетов в профиль Nix")
    end
end

local function handle_uninstall(packages)
    if not packages or #packages == 0 then
        ctx.fail("Укажите пакеты для удаления из профиля Nix")
        return
    end

    local cmd = { "nix", "profile", "remove" }
    for _, p in ipairs(packages) do
        table.insert(cmd, p)
    end

    ctx.log("Удаление пакетов из профиля Nix: " .. table.concat(packages, ", ") .. "...")
    local ret = ctx.run_process(cmd)
    if ret == 0 then
        ctx.log("Пакеты успешно удалены из профиля Nix.")
    else
        ctx.fail("Ошибка удаления пакетов из профиля Nix")
    end
end

local function handle_check(target_dir)
    local has_flake = ctx.exists(target_dir .. "/flake.nix")
    local cmd = has_flake and { "nix", "flake", "check" } or { "nix-instantiate", "--parse", target_dir .. "/shell.nix" }

    ctx.log("Проверка конфигурации Nix в " .. target_dir .. "...")
    local ret = ctx.run_process(cmd, target_dir)
    ctx.module_return(target_dir)
    if ret == 0 then
        ctx.log("Конфигурация Nix валидна.")
    else
        ctx.fail("Ошибка валидации конфигурации Nix")
    end
end

local function handle_history()
    ctx.log("Получение истории поколений профиля Nix...")
    local res = ctx.capture({ "nix", "profile", "history" })
    if res.code ~= 0 then
        ctx.fail("Ошибка получения истории профиля Nix: " .. (res.stderr or ""))
        return
    end

    local stdout = res.stdout or ""
    if #grime.str.trim(stdout) == 0 then
        grime.ui.log("История поколений профиля Nix пуста.")
        ctx.success("0 generations")
        return
    end

    local lines = grime.str.split(stdout, "\n")
    local generations = {}
    local current_gen = nil

    for _, raw_line in ipairs(lines) do
        local line = raw_line:gsub("\27%[[%d;]*m", "")
        local v, date = line:match("Version%s+(%d+)%s*%(([%d%-]+)%)")
        if v then
            current_gen = {
                version = v,
                date = date,
                changes = {},
            }
            table.insert(generations, current_gen)
        elseif current_gen and #grime.str.trim(line) > 0 then
            table.insert(current_gen.changes, grime.str.trim(line))
        end
    end

    if #generations == 0 then
        print(stdout)
        ctx.success(stdout)
        return
    end

    local rows = {}
    for _, g in ipairs(generations) do
        local change_summary = tostring(#g.changes) .. " изм."
        if #g.changes > 0 then
            local first = g.changes[1]
            local pkg = first:match("([^%s:]+):") or first:match("([^%s:]+)$") or first
            pkg = pkg:match("([^%.]+)$") or pkg
            change_summary = string.format("%d изм. (%s%s)", #g.changes, pkg, #g.changes > 1 and "..." or "")
        end
        table.insert(rows, { "v" .. g.version, g.date, change_summary })
    end

    print(string.format("\n\27[1mИстория поколений профиля Nix (%d поколений):\27[0m", #generations))
    grime.ui.print_table(rows, { "Версия", "Дата", "Изменения" })
    print()

    if #generations > 0 then
        local latest = generations[#generations]
        print(string.format("\27[1;36mТекущее поколение v%s (%s):\27[0m", latest.version, latest.date))
        for _, ch in ipairs(latest.changes) do
            print(string.format("  \27[32m•\27[0m %s", ch))
        end
        print()
    end

    if ctx.has_next_step then
        ctx.success(generations[#generations].version)
    else
        ctx.success(tostring(#generations))
    end
end

local function handle_rollback(to_generation)
    local cmd = { "nix", "profile", "rollback" }
    local target_desc = "на предыдущее поколение"
    if to_generation and tostring(to_generation):match("^%d+$") then
        table.insert(cmd, "--to")
        table.insert(cmd, tostring(to_generation))
        target_desc = "на поколение " .. tostring(to_generation)
    end

    ctx.log(string.format("Откат профиля Nix %s...", target_desc))
    local res = ctx.capture(cmd)
    if res.code ~= 0 then
        ctx.fail("Ошибка отката профиля Nix: " .. (res.stderr or res.stdout or ""))
        return
    end

    grime.ui.success(string.format("Профиль Nix успешно откатан %s.", target_desc))
    ctx.success(to_generation or "prev")
end

local function handle_update(target_dir)
    target_dir = ctx.normalize_path(target_dir or ".")
    local flake_path = target_dir .. "/flake.nix"
    if not ctx.exists(flake_path) then
        ctx.fail("Файл flake.nix не найден в " .. target_dir)
        return
    end

    ctx.log(string.format("Обновление входных зависимостей флейка (nix flake update) в %s...", target_dir))
    local res = ctx.capture({ "nix", "flake", "update" }, target_dir)
    if res.code ~= 0 then
        ctx.fail("Ошибка обновления flake: " .. (res.stderr or res.stdout or ""))
        return
    end

    local out = (res.stderr or "") .. "\n" .. (res.stdout or "")
    local updated_inputs = {}
    for line in out:gmatch("[^\r\n]+") do
        local input, from, to = line:match("Updated input '([^']+)':%s*'([^']+)'%s*%->%s*'([^']+)'")
        if input then
            table.insert(updated_inputs, { input = input, from = from, to = to })
        end
    end

    if #updated_inputs > 0 then
        print(string.format("\n\27[1;32m✓ Обновлены зависимости flake.lock (%d шт.):\27[0m", #updated_inputs))
        for _, inp in ipairs(updated_inputs) do
            print(string.format("  \27[1m%s\27[0m: \27[90m%s\27[0m -> \27[36m%s\27[0m", inp.input, inp.from, inp.to))
        end
        print()
    else
        grime.ui.success("Зависимости флейка уже находятся в актуальном состоянии.")
    end

    ctx.module_return(target_dir)
end

local function handle_bundle(target_dir, args, out_link)
    target_dir = ctx.normalize_path(target_dir or ".")
    local cmd = { "nix", "bundle" }

    local installable = nil
    if args and #args > 0 then
        installable = args[1]
    elseif ctx.exists(target_dir .. "/flake.nix") then
        installable = "."
    else
        ctx.fail("Укажите цель для сборки бандла (например, '.' или nixpkgs#hello)")
        return
    end

    table.insert(cmd, installable)
    if out_link and #out_link > 0 then
        table.insert(cmd, "-o")
        table.insert(cmd, out_link)
    end

    ctx.log(string.format("⚡ [Grime Nix Bundle] Упаковка '%s' в переносимый бинарник...", installable))
    local ret = ctx.run_process(cmd, target_dir)
    if ret == 0 then
        local bundle_name = out_link or installable:match("([^#/]+)$") or "bundle"
        grime.ui.success(string.format("Автономный переносимый бандл успешно собран: %s", bundle_name))
        ctx.module_return(out_link or target_dir)
    else
        ctx.fail("Ошибка сборки бандла nix bundle (код " .. tostring(ret) .. ")")
    end
end

local function handle_diff()
    ctx.log("Анализ изменений замыканий профиля Nix (diff-closures)...")
    local res = ctx.capture({ "nix", "profile", "diff-closures" })
    if res.code ~= 0 then
        ctx.fail("Ошибка анализа diff-closures: " .. (res.stderr or ""))
        return
    end

    local out = grime.str.trim(res.stdout or "")
    if #out == 0 then
        grime.ui.log("Изменений между версиями профиля Nix не обнаружено.")
        ctx.success("no_diff")
    else
        print(string.format("\n\27[1mИзменения замыканий профиля Nix:\27[0m\n"))
        print(out)
        print()
        ctx.success(out)
    end
end

local function print_help()
    print(string.format([[
%s%sGrime Nix%s — Управление Nix-окружениями разработки и профилями

%sИСПОЛЬЗОВАНИЕ:%s
    grime nix [команда] [аргументы/пакеты...]

%sКОМАНДЫ:%s
    %sbuild, b%s                Сборка проекта в изолированном Nix (эфемерно без изменения репозитория)
                          grime nix build [проект/путь]
    %sinit, create, new%s      Создать shell.nix для проекта (с автоопределением тулчейна)
                          grime nix init [пакеты...] [--force]
    %sflake%s                  Создать постоянный flake.nix в корне проекта
                          grime nix flake [пакеты...] [--force]
    %senter, shell, sh%s      Войти в изолированный devShell (nix develop / nix-shell)
                          grime nix enter [--pure]
    %srun, exec%s             Выполнить команду в Nix-окружении
                          grime nix run <команда...> [--pure]
    %shistory, hist%s          История поколений профиля пользователя Nix
                          grime nix history
    %srollback%s               Откатить профиль Nix на предыдущее или указанное поколение
                          grime nix rollback [--to <N>]
    %supdate, up%s             Обновить входные зависимости флейка (nix flake update)
                          grime nix update [каталог]
    %sbundle%s                 Упаковать цель в автономный переносимый бинарник (nix bundle)
                          grime nix bundle [цель] [-o вывод]
    %sdiff%s                   Анализ изменений замыканий профиля (diff-closures)
                          grime nix diff
    %sinstall, i%s            Установить пакеты в профиль пользователя Nix
                          grime nix install <пакеты...>
    %suninstall%s              Удалить пакеты из профиля пользователя Nix
                          grime nix uninstall <пакеты...>
    %sgc, clean%s              Очистить неиспользуемые пути в Nix store (garbage collector)
                          grime nix gc
    %soptimise, opt%s          Дедупликация жестких ссылок в Nix store
                          grime nix optimise
    %scheck, validate%s        Проверить валидность конфигурации flake.nix или shell.nix
                          grime nix check
    %shelp, -h, --help%s       Показать эту справку

%sФЛАГИ:%s
    %s--force, -f%s           Перезаписать существующий файл shell.nix / flake.nix
    %s--pure%s                Изолированный запуск без переменных хоста
    %s--to <N>%s              Целевое поколение для отката (rollback)
    %s-o, --out-link%s        Путь для сохранения бандла (bundle)

%sПРИМЕРЫ:%s
    grime nix build                         # Эфемерная сборка проекта в Nix Flake
    grime nix history                       # Просмотр истории поколений профиля
    grime nix rollback                      # Откат профиля на предыдущую версию
    grime nix update                        # Обновление зависимостей flake.lock
    grime nix bundle nixpkgs#hello          # Упаковка в автономный переносимый бинарник
    grime nix diff                          # Анализ различий замыканий профиля
    grime nix flake                         # Создание flake.nix с авто-тулчейном
    grime nix enter                         # Вход в devShell
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[36m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[33m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    local raw_args = ctx.args or {}
    if #raw_args == 0 then
        print_help()
        return
    end

    for _, a in ipairs(raw_args) do
        local matched = (type(a) == "string" and a:match("^%-")) and grime.fuzzy.match_flag(a, { "--help", "-h" }, 0.75) or a
        if matched == "--help" or matched == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local raw_target = ctx.target_dir
    if not raw_target or #raw_target == 0 or not ctx.is_dir(raw_target) then
        raw_target = "."
    end
    local target_dir = ctx.normalize_path(raw_target)
    local cls = argparse.new({
        actions = ACTIONS,
        default_action = "init",
        flags = {
            force = { "-f", "--force" },
            pure = { "--pure" },
            flake = { "--flake" },
        },
        detect_dir = true,
    })

    local parsed = cls:parse(ctx.args, target_dir)
    local action = parsed.action or "init"

    if action == "help" then
        print_help()
        return
    end

    if parsed.flags.flake and action == "init" then
        action = "flake"
    end

    local command_tokens = parsed.args
    for _, t in ipairs(parsed.command_tokens) do
        table.insert(command_tokens, t)
    end

    if parsed.target_dir and ctx.is_dir(parsed.target_dir) then
        target_dir = ctx.normalize_path(parsed.target_dir)
    elseif #command_tokens > 0 and ctx.is_dir(command_tokens[1]) then
        target_dir = ctx.normalize_path(table.remove(command_tokens, 1))
    end

    if action == "build" then
        handle_build(target_dir, command_tokens)
    elseif action == "init" then
        handle_init(target_dir, command_tokens, parsed.flags.force)
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
    elseif action == "flake" then
        handle_flake(target_dir, command_tokens, parsed.flags.force)
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
    elseif action == "gc" then
        handle_gc()
    elseif action == "optimise" then
        handle_optimise()
    elseif action == "enter" then
        handle_enter(target_dir, parsed.flags.pure)
    elseif action == "run" then
        handle_run(target_dir, command_tokens, parsed.flags.pure)
        if ctx.has_next_step then
            ctx.module_return(target_dir)
        end
    elseif action == "install" then
        handle_install(command_tokens)
    elseif action == "uninstall" then
        handle_uninstall(command_tokens)
    elseif action == "check" then
        handle_check(target_dir)
    elseif action == "history" then
        handle_history()
    elseif action == "rollback" then
        local to_gen = nil
        for i, a in ipairs(command_tokens) do
            if a == "--to" and command_tokens[i + 1] then
                to_gen = command_tokens[i + 1]
                break
            elseif tostring(a):match("^%d+$") then
                to_gen = a
                break
            end
        end
        handle_rollback(to_gen)
    elseif action == "update" then
        handle_update(target_dir)
    elseif action == "bundle" then
        local out_link = nil
        local clean_tokens = {}
        local skip_next = false
        for i, a in ipairs(command_tokens) do
            if skip_next then
                skip_next = false
            elseif (a == "-o" or a == "--out-link") and command_tokens[i + 1] then
                out_link = command_tokens[i + 1]
                skip_next = true
            else
                table.insert(clean_tokens, a)
            end
        end
        handle_bundle(target_dir, clean_tokens, out_link)
    elseif action == "diff" then
        handle_diff()
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
