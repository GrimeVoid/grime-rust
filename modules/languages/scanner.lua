--[[
    Grime Intelligent Project Scanner (Auto-Toolchain & Multi-Language Detection)
    Интеллектуальный сканер структуры проектов, распознающий сборочные манифесты,
    активные языки программирования и синтезирующий точный тулчейн зависимостей.
]]

local Scanner = {}

local ADAPTERS = {
    cpp = require("languages.cpp"),
    python = require("languages.python"),
    rust = require("languages.rust"),
    java = require("languages.java"),
}

-- Известные утилиты сборочного тулчейна (попадают в nativeBuildInputs)
local KNOWN_TOOLCHAIN_PACKAGES = {
    ["gcc"] = true,
    ["clang"] = true,
    ["gnumake"] = true,
    ["cmake"] = true,
    ["ninja"] = true,
    ["pkg-config"] = true,
    ["pkgconfig"] = true,
    ["cargo"] = true,
    ["rustc"] = true,
    ["rust-analyzer"] = true,
    ["python3"] = true,
    ["python"] = true,
    ["uv"] = true,
    ["pip"] = true,
    ["jdk"] = true,
    ["jdk17"] = true,
    ["jdk21"] = true,
    ["maven"] = true,
    ["gradle"] = true,
    ["go"] = true,
    ["nodejs"] = true,
    ["bashInteractive"] = true,
    ["coreutils"] = true,
}

--- Проверка, относится ли пакет к сборочному тулчейну (компиляторы, сборщики, LSP)
function Scanner.is_toolchain_package(pkg)
    local clean = pkg:gsub("^pkgs%.", "")
    return KNOWN_TOOLCHAIN_PACKAGES[clean] == true
end

--- Быстрое получение списка файлов проекта с умной фильтрацией служебных каталогов
function Scanner.get_project_files(root, c)
    local files = {}

    -- 1. Попытка получить срез через git ls-files
    local cmd_git = "git -C \"" .. root .. "\" ls-files 2>/dev/null"
    local p_git = io.popen(cmd_git)
    if p_git then
        for line in p_git:lines() do
            local trimmed = line:match("^%s*(.-)%s*$")
            if #trimmed > 0 then
                table.insert(files, trimmed)
            end
        end
        p_git:close()
        if #files > 0 then
            return files
        end
    end

    -- 2. Fallback: интеллектуальный обход через find
    local cmd_find = "find \"" .. root .. "\" -maxdepth 5 -type f " ..
        "! -path '*/.*' " ..
        "! -path '*/build/*' " ..
        "! -path '*/target/*' " ..
        "! -path '*/node_modules/*' " ..
        "! -path '*/.venv/*' " ..
        "! -path '*/venv/*' " ..
        "! -path '*/bin/*' " ..
        "! -path '*/obj/*' " ..
        "! -path '*/dist/*' " ..
        "! -path '*/__pycache__/*' 2>/dev/null"
    local p_find = io.popen(cmd_find)
    if p_find then
        local prefix = root:gsub("/+$", "") .. "/"
        for line in p_find:lines() do
            local rel = line
            if rel:find(prefix, 1, true) == 1 then
                rel = rel:sub(#prefix + 1)
            end
            local trimmed = rel:match("^%s*(.-)%s*$")
            if #trimmed > 0 then
                table.insert(files, trimmed)
            end
        end
        p_find:close()
        if #files > 0 then
            return files
        end
    end

    -- 3. Базовый fallback: чтение через fs
    if grime and grime.fs and grime.fs.list then
        local list = grime.fs.list(root) or {}
        for _, f in ipairs(list) do
            if f ~= "." and f ~= ".." then
                table.insert(files, f)
            end
        end
    end

    return files
end

--- Анализ проекта и синтез полного сборочного профиля
function Scanner.scan_project(root, c)
    c = c or (grime and grime.ctx)
    root = (c and c.normalize_path and c.normalize_path(root)) or root

    local files = Scanner.get_project_files(root, c)
    local found_manifests = {}
    local detected_langs_set = {}
    local detected_langs = {}

    -- Таблица соответствия манифестов и языков
    local manifest_map = {
        ["CMakeLists.txt"] = "cpp",
        ["Makefile"] = "cpp",
        ["meson.build"] = "cpp",
        ["Cargo.toml"] = "rust",
        ["pyproject.toml"] = "python",
        ["requirements.txt"] = "python",
        ["setup.py"] = "python",
        ["Pipfile"] = "python",
        ["pom.xml"] = "java",
        ["build.gradle"] = "java",
        ["build.gradle.kts"] = "java",
        ["go.mod"] = "go",
        ["package.json"] = "nodejs",
    }

    -- Таблица соответствия расширений файлов
    local ext_map = {
        [".cpp"] = "cpp", [".hpp"] = "cpp", [".cc"] = "cpp", [".cxx"] = "cpp", [".c"] = "cpp", [".h"] = "cpp",
        [".rs"] = "rust",
        [".py"] = "python",
        [".java"] = "java",
        [".go"] = "go",
        [".js"] = "nodejs", [".ts"] = "nodejs",
    }

    -- Сканирование файлов
    for _, f in ipairs(files) do
        local fname = f:match("([^/\\]+)$") or f
        if manifest_map[fname] then
            local lang = manifest_map[fname]
            table.insert(found_manifests, f)
            if not detected_langs_set[lang] then
                detected_langs_set[lang] = true
                table.insert(detected_langs, lang)
            end
        end

        local ext = fname:match("(%.[%a%d_]+)$")
        if ext and ext_map[ext] then
            local lang = ext_map[ext]
            if not detected_langs_set[lang] then
                detected_langs_set[lang] = true
                table.insert(detected_langs, lang)
            end
        end
    end

    -- Дополнительная проверка манифеста app.lua (если есть)
    local app_lua = root .. "/app.lua"
    local f_app = io.open(app_lua, "r")
    if f_app then
        local content = f_app:read("*all") or ""
        f_app:close()
        -- Поиск languages = { "...", "..." }
        for lang in content:gmatch('"([%a%d_%+]+)"') do
            if ADAPTERS[lang] and not detected_langs_set[lang] then
                detected_langs_set[lang] = true
                table.insert(detected_langs, lang)
            end
        end
    end

    -- Дополнительная проверка адаптеров через :detect()
    for lang, adp in pairs(ADAPTERS) do
        if not detected_langs_set[lang] and adp.detect and adp:detect(root) then
            detected_langs_set[lang] = true
            table.insert(detected_langs, lang)
        end
    end

    -- Сбор тулчейна со всех активных языковых адаптеров
    local toolchain_pkgs = {}
    local toolchain_set = {}
    local required_binaries = {}
    local req_bin_set = {}

    local function add_toolchain_pkg(pkg)
        if pkg and not toolchain_set[pkg] then
            toolchain_set[pkg] = true
            table.insert(toolchain_pkgs, pkg)
        end
    end

    local function add_required_binary(bin)
        if bin and not req_bin_set[bin] then
            req_bin_set[bin] = true
            table.insert(required_binaries, bin)
        end
    end

    for _, lang in ipairs(detected_langs) do
        local adp = ADAPTERS[lang]
        if adp then
            -- Опрос адаптера на пакеты для Nix
            if adp.get_nix_packages then
                local pkgs = adp:get_nix_packages(root) or {}
                for _, p in ipairs(pkgs) do
                    add_toolchain_pkg(p)
                end
            end
            -- Опрос адаптера на бинарники для хоста
            if adp.required_binaries then
                for _, b in ipairs(adp.required_binaries) do
                    add_required_binary(b)
                end
            end
        elseif lang == "go" then
            add_toolchain_pkg("go")
            add_required_binary("go")
        elseif lang == "nodejs" then
            add_toolchain_pkg("nodejs")
            add_required_binary("node")
        end
    end

    -- Гарантируем базовый шелл
    if #toolchain_pkgs == 0 then
        add_toolchain_pkg("bashInteractive")
    end

    return {
        root = root,
        languages = detected_langs,
        manifests = found_manifests,
        toolchain = toolchain_pkgs,
        required_binaries = required_binaries,
        files = files,
        has_language = function(self, lang)
            return detected_langs_set[lang] == true
        end,
        check_host_dependencies = function(self, ctx_in)
            local check_ctx = ctx_in or c or (grime and grime.ctx)
            local missing = {}
            for _, bin in ipairs(self.required_binaries) do
                local found = false
                if grime and grime.process and grime.process.which then
                    local p = grime.process.which(bin)
                    if p and #p > 0 then found = true end
                end
                if not found and check_ctx and check_ctx.capture then
                    local res = check_ctx.capture("which " .. bin .. " 2>/dev/null")
                    if res and res.code == 0 and res.stdout and #res.stdout > 0 then
                        found = true
                    end
                end
                if not found then
                    local p = io.popen("which " .. bin .. " 2>/dev/null")
                    if p then
                        local out = p:read("*all")
                        p:close()
                        if out and #out > 0 then found = true end
                    end
                end
                if not found then
                    table.insert(missing, bin)
                end
            end
            return (#missing == 0), missing
        end,
    }
end

return Scanner
