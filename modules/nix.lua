local classifier = require("classifier")
local ctx = grime.ctx

local ACTIONS = {
    init = "init", create = "init", new = "init", make = "init",
    flake = "flake", f = "flake",
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

local function detect_project_packages(root)
    local adapters = {
        require("languages.cpp"),
        require("languages.python"),
        require("languages.rust"),
        require("languages.java"),
    }
    for _, adp in ipairs(adapters) do
        if adp:detect(root) then
            return adp:get_nix_packages(root)
        end
    end
    return { "bashInteractive" }
end

local function generate_shell_nix(packages)
    local pkgs_str = ""
    for _, p in ipairs(packages) do
        local name = p:gsub("^pkgs%.", "")
        pkgs_str = pkgs_str .. "    " .. name .. "\n"
    end
    if pkgs_str == "" then pkgs_str = "    bashInteractive\n" end

    return string.format([[{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = with pkgs; [
%s  ];

  shellHook = ''
    echo "⚡ [Grime Nix DevShell] Окружение разработки активировано"
  '';
}
]], pkgs_str)
end

local function generate_flake_nix(packages)
    local pkgs_str = ""
    for _, p in ipairs(packages) do
        local name = p:gsub("^pkgs%.", "")
        pkgs_str = pkgs_str .. "            " .. name .. "\n"
    end
    if pkgs_str == "" then pkgs_str = "            bashInteractive\n" end

    return string.format([[{
  description = "⚡ Окружение разработки Grime Flake DevShell";

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
          buildInputs = with pkgs; [
%s          ];

          shellHook = ''
            echo "⚡ [Grime Nix Flake DevShell] Окружение активировано"
          '';
        };
      });
    };
}
]], pkgs_str)
end

local function handle_init(target_dir, packages, force)
    local shell_path = target_dir .. "/shell.nix"
    if ctx.exists(shell_path) and not force then
        ctx.log("Файл shell.nix уже существует. Используйте -f / --force для перезаписи.")
        return
    end

    local pkgs = packages
    if not pkgs or #pkgs == 0 then
        pkgs = detect_project_packages(target_dir)
    end

    local content = generate_shell_nix(pkgs)
    local f = io.open(shell_path, "w")
    if f then
        f:write(content)
        f:close()
        ctx.log("Создан shell.nix в " .. target_dir .. " со стеком: " .. table.concat(pkgs, ", "))
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

    local pkgs = packages
    if not pkgs or #pkgs == 0 then
        pkgs = detect_project_packages(target_dir)
    end

    local content = generate_flake_nix(pkgs)
    local f = io.open(flake_path, "w")
    if f then
        f:write(content)
        f:close()
        ctx.log("Создан flake.nix в " .. target_dir .. " со стеком: " .. table.concat(pkgs, ", "))
    else
        ctx.fail("Не удалось записать " .. flake_path)
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

local function print_help()
    print(string.format([[
%s%sGrime Nix%s — Управление Nix-окружениями разработки и профилями

%sИСПОЛЬЗОВАНИЕ:%s
    grime nix [команда] [аргументы/пакеты...]

%sКОМАНДЫ:%s
    %sinit, create, new%s      Создать shell.nix для проекта (с автоопределением зависимостей)
                          grime nix init [пакеты...] [--force]
    %sflake%s                  Создать flake.nix для проекта
                          grime nix flake [пакеты...] [--force]
    %senter, shell, sh%s      Войти в изолированный devShell (nix develop / nix-shell)
                          grime nix enter [--pure]
    %srun, exec%s             Выполнить команду в Nix-окружении
                          grime nix run <команда...> [--pure]
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

%sПРИМЕРЫ:%s
    grime nix init cmake ninja gcc          # Создание shell.nix для C++ проекта
    grime nix enter                         # Вход в devShell
    grime nix run -- ninja build            # Сборка внутри devShell
    grime nix gc                            # Очистка мусора Nix store
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
    "\27[1m", "\27[0m",
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

    local target_dir = ctx.normalize_path(ctx.target_dir)
    local cls = classifier.new({
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

    if action == "init" then
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
    elseif action == "install" then
        handle_install(command_tokens)
    elseif action == "uninstall" then
        handle_uninstall(command_tokens)
    elseif action == "check" then
        handle_check(target_dir)
    else
        ctx.fail("Неизвестное действие: " .. action)
    end
end
