--[[
    Grime Intelligent Project Scanner (Auto-Toolchain & Multi-Language Detection)
    Интеллектуальный сканер структуры проектов, распознающий сборочные манифесты,
    активные языки программирования и синтезирующий точный тулчейн зависимостей.
]]

local utils = require("languages.utils")

local Scanner = {}

local ADAPTERS = {
    cpp = require("languages.cpp"),
    python = require("languages.python"),
    rust = require("languages.rust"),
    java = require("languages.java"),
    lua = require("languages.lua"),
}

local LANG_PACKAGES = {
    cpp = { "cmake", "gcc", "ninja", "pkg-config" },
    rust = { "cargo", "rustc", "rust-analyzer" },
    python = { "python3" },
    java = { "jdk" },
    lua = { "luajit" },
    go = { "go" },
    nodejs = { "nodejs" },
}

-- Известные утилиты сборочного тулчейна (попадают в nativeBuildInputs)
local TOOLCHAIN_SET = {
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
    ["luajit"] = true,
    ["lua"] = true,
    ["lua5_4"] = true,
    ["go"] = true,
    ["nodejs"] = true,
    ["bashInteractive"] = true,
    ["coreutils"] = true,
}

Scanner.LANG_PACKAGES = LANG_PACKAGES
Scanner.TOOLCHAIN_SET = TOOLCHAIN_SET

local function run_capture(argv, c)
    local ctx_obj = c or (grime and grime.ctx)
    if ctx_obj and ctx_obj.capture then
        return ctx_obj.capture(argv)
    end
    if grime and grime.process and grime.process.capture then
        return grime.process.capture(argv)
    end
    return { code = 1, stdout = "", stderr = "" }
end

--- Проверка, относится ли пакет к сборочному тулчейну (компиляторы, сборщики, LSP)
function Scanner.is_toolchain_package(pkg)
    local clean = pkg:gsub("^pkgs%.", "")
    return TOOLCHAIN_SET[clean] == true
end

--- Быстрое получение списка файлов проекта с умной фильтрацией служебных каталогов
function Scanner.get_project_files(root, c)
    local files = {}

    -- 1. Попытка получить срез через git ls-files
    local res_git = run_capture({ "git", "-C", root, "ls-files" }, c)
    if res_git and res_git.code == 0 and res_git.stdout and #res_git.stdout > 0 then
        for line in res_git.stdout:gmatch("[^\r\n]+") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if #trimmed > 0 then
                table.insert(files, trimmed)
            end
        end
        if #files > 0 then
            return files
        end
    end

    -- 2. Fallback: интеллектуальный обход через find (массив аргументов без шелл-инъекций)
    local res_find = run_capture({
        "find", root, "-maxdepth", "5", "-type", "f",
        "!", "-path", "*/.*",
        "!", "-path", "*/build/*",
        "!", "-path", "*/target/*",
        "!", "-path", "*/node_modules/*",
        "!", "-path", "*/.venv/*",
        "!", "-path", "*/venv/*",
        "!", "-path", "*/bin/*",
        "!", "-path", "*/obj/*",
        "!", "-path", "*/dist/*",
        "!", "-path", "*/__pycache__/*",
    }, c)
    if res_find and res_find.code == 0 and res_find.stdout and #res_find.stdout > 0 then
        local prefix = root:gsub("/+$", "") .. "/"
        for line in res_find.stdout:gmatch("[^\r\n]+") do
            local rel = line
            if rel:find(prefix, 1, true) == 1 then
                rel = rel:sub(#prefix + 1)
            end
            local trimmed = rel:match("^%s*(.-)%s*$")
            if #trimmed > 0 then
                table.insert(files, trimmed)
            end
        end
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

    local function register_lang(lang)
        if type(lang) == "string" and #lang > 0 and not detected_langs_set[lang] then
            if ADAPTERS[lang] or LANG_PACKAGES[lang] then
                detected_langs_set[lang] = true
                table.insert(detected_langs, lang)
            end
        end
    end

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
        [".lua"] = "lua",
        [".go"] = "go",
        [".js"] = "nodejs", [".ts"] = "nodejs",
    }

    -- Сканирование файлов
    for _, f in ipairs(files) do
        local fname = f:match("([^/\\]+)$") or f
        if manifest_map[fname] then
            local lang = manifest_map[fname]
            table.insert(found_manifests, f)
            register_lang(lang)
        end

        local ext = fname:match("(%.[%a%d_]+)$")
        if ext and ext_map[ext] and fname ~= "app.lua" then
            register_lang(ext_map[ext])
        end
    end

    -- Безопасная загрузка таблицы манифеста app.lua (если есть)
    local app_lua = root .. "/app.lua"
    local special_dependencies = {}
    if utils.file_exists(app_lua) then
        local chunk = loadfile(app_lua, "t", {})
        if chunk then
            local ok, m = pcall(chunk)
            if ok and type(m) == "table" then
                if type(m.languages) == "table" then
                    for _, l in ipairs(m.languages) do
                        register_lang(l)
                    end
                elseif type(m.languages) == "string" then
                    register_lang(m.languages)
                end
                register_lang(m.lang)
                register_lang(m.type)

                if type(m.special_dependencies) == "table" then
                    for _, dep in ipairs(m.special_dependencies) do
                        if type(dep) == "string" and #dep > 0 then
                            table.insert(special_dependencies, dep)
                        end
                    end
                elseif type(m.special_dependencies) == "string" then
                    for dep in m.special_dependencies:gmatch("%S+") do
                        table.insert(special_dependencies, dep)
                    end
                end
            end
        end
    end

    -- Дополнительная проверка адаптеров через :detect()
    for lang, adp in pairs(ADAPTERS) do
        if not detected_langs_set[lang] and adp.detect and adp:detect(root) then
            register_lang(lang)
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
            if adp.get_nix_packages then
                local pkgs = adp:get_nix_packages(root) or {}
                for _, p in ipairs(pkgs) do
                    add_toolchain_pkg(p)
                end
            elseif LANG_PACKAGES[lang] then
                for _, p in ipairs(LANG_PACKAGES[lang]) do
                    add_toolchain_pkg(p)
                end
            end
            if adp.required_binaries then
                for _, b in ipairs(adp.required_binaries) do
                    add_required_binary(b)
                end
            end
        elseif LANG_PACKAGES[lang] then
            for _, p in ipairs(LANG_PACKAGES[lang]) do
                add_toolchain_pkg(p)
            end
            if lang == "go" then
                add_required_binary("go")
            elseif lang == "nodejs" then
                add_required_binary("node")
            end
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
        special_dependencies = special_dependencies,
        required_binaries = required_binaries,
        files = files,
        has_language = function(_self, lang)
            return detected_langs_set[lang] == true
        end,
        check_host_dependencies = function(self, ctx_in)
            local check_ctx = ctx_in or c or (grime and grime.ctx)
            local missing = {}
            for _, bin in ipairs(self.required_binaries) do
                if not utils.has_binary(bin, check_ctx) then
                    table.insert(missing, bin)
                end
            end
            return (#missing == 0), missing
        end,
    }
end

return Scanner
