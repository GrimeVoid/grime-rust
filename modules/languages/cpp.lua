local BaseAdapter = require("languages.base")

local CppAdapter = setmetatable({}, { __index = BaseAdapter })
CppAdapter.__index = CppAdapter

function CppAdapter.new()
    local self = setmetatable(BaseAdapter.new({
        name = "cpp",
        aliases = { "cpp", "c++", "c" },
        src_dir = "src",
        required_binaries = { "cmake", "ninja" },
        extensions = { ".cpp", ".hpp", ".cc", ".cxx", ".h" },
        build_files = { "CMakeLists.txt", "Makefile" },
        entry_files = { "main.cpp" },
    }), CppAdapter)
    return self
end

local function file_exists(p)
    if grime and grime.fs and grime.fs.exists then return grime.fs.exists(p) end
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

function CppAdapter:get_nix_packages(root)
    if file_exists(root .. "/CMakeLists.txt") then
        return { "cmake", "gcc", "ninja", "pkg-config" }
    end
    if file_exists(root .. "/Makefile") then
        return { "gnumake", "gcc" }
    end
    return { "gcc" }
end

function CppAdapter:create_default_files(root, ctx)
    local proj_name = root:match("([^/\\]+)$") or "MyGame"
    local tpl_root = (ctx.paths and ctx.paths.templates)
        or (ctx.get_path and ctx.get_path("templates"))
        or (ctx.templates_root and ctx.templates_root())
        or "./templates"
    tpl_root = ctx.normalize_path(tpl_root)

    local cmake_file = root .. "/CMakeLists.txt"
    if not ctx.exists(cmake_file) then
        local tpl = tpl_root .. "/cpp/CMakeLists.txt"
        if ctx.exists(tpl) then
            ctx.copy(tpl, cmake_file)
            ctx.log("Шаблон CMakeLists.txt скопирован")
        else
            local content = string.format([[cmake_minimum_required(VERSION 3.15)
project(%s)

set(CMAKE_CXX_STANDARD 20)

add_executable(%s src/main.cpp)
]], proj_name, proj_name)
            local f = io.open(cmake_file, "w")
            if f then
                f:write(content)
                f:close()
                ctx.log("Создан CMakeLists.txt по умолчанию")
            end
        end
    end

    local main_file = root .. "/src/main.cpp"
    if not ctx.exists(main_file) then
        local tpl = tpl_root .. "/cpp/main.cpp"
        if ctx.exists(tpl) then
            ctx.copy(tpl, main_file)
            ctx.log("Шаблон src/main.cpp скопирован")
        else
            local content = [[#include <iostream>

int main() {
    std::cout << "Hello from C++ project!" << std::endl;
    return 0;
}
]]
            local f = io.open(main_file, "w")
            if f then
                f:write(content)
                f:close()
                ctx.log("Создан src/main.cpp по умолчанию")
            end
        end
    end
end

function CppAdapter:check_dependencies(ctx, root)
    root = root or ctx.target_dir
    local needed = {}
    if root and file_exists(root .. "/CMakeLists.txt") then
        needed = { "cmake", "ninja" }
    elseif root and file_exists(root .. "/Makefile") then
        needed = { "make" }
    else
        needed = { "g++" }
    end

    local missing = {}
    for _, bin in ipairs(needed) do
        local found = false
        if grime and grime.process and grime.process.which then
            local p = grime.process.which(bin)
            if p and #p > 0 then found = true end
        end
        if not found and ctx and ctx.capture then
            local res = ctx.capture("which " .. bin .. " 2>/dev/null")
            if res and res.code == 0 and res.stdout and #res.stdout > 0 then
                found = true
            end
        end
        if not found then
            table.insert(missing, bin)
        end
    end
    return (#missing == 0), missing
end

function CppAdapter:get_target(root, ctx)
    local proj_name = root:match("([^/\\]+)$") or "main"
    if file_exists(root .. "/CMakeLists.txt") then
        local build_target = root .. "/build/" .. proj_name
        if file_exists(build_target) then
            return build_target
        end
        if file_exists(root .. "/build/main") then
            return root .. "/build/main"
        end
        return BaseAdapter.get_target(self, root) or build_target
    end

    -- Если CMakeLists.txt отсутствует: возвращать прямой бинарник (<root>/<target>)
    if file_exists(root .. "/" .. proj_name) then
        return root .. "/" .. proj_name
    end
    if file_exists(root .. "/main") then
        return root .. "/main"
    end
    return root .. "/" .. proj_name
end

function CppAdapter:build(root, ctx)
    -- 1. Если есть CMakeLists.txt -> собирать через cmake + ninja
    if ctx.exists(root .. "/CMakeLists.txt") then
        ctx.log("Компиляция C++ проекта (CMake + Ninja) в " .. root .. "...")
        local code = ctx.run_shell("cmake -B build -G Ninja && ninja -C build", root)
        return code == 0
    end

    -- 2. Иначе если есть Makefile -> собирать через make
    if ctx.exists(root .. "/Makefile") then
        ctx.log("Компиляция C++ проекта (Make) в " .. root .. "...")
        local code = ctx.run_shell("make", root)
        return code == 0
    end

    -- 3. Иначе если в корне или в src/ найдены .cpp / .c файлы -> собирать напрямую компилятором хоста/devShell
    local source_files = {}
    local function collect_sources(dir)
        local p = io.popen("find \"" .. dir .. "\" -maxdepth 1 -type f \\( -name \"*.cpp\" -o -name \"*.cc\" -o -name \"*.cxx\" -o -name \"*.c\" \\) 2>/dev/null")
        if p then
            for line in p:lines() do
                local trimmed = line:match("^%s*(.-)%s*$")
                if #trimmed > 0 then
                    table.insert(source_files, string.format("%q", trimmed))
                end
            end
            p:close()
        end
    end

    collect_sources(root)
    if ctx.exists(root .. "/src") then
        collect_sources(root .. "/src")
    end

    if #source_files == 0 then
        ctx.log("Ошибка: в " .. root .. " не найден CMakeLists.txt, Makefile или исходные файлы C/C++ (.cpp, .c, .cc, .cxx)!")
        return false
    end

    local proj_name = root:match("([^/\\]+)$") or "main"
    local compiler = "g++"
    if ctx.capture and ctx.capture("which g++ 2>/dev/null").code ~= 0 then
        if ctx.capture("which clang++ 2>/dev/null").code == 0 then
            compiler = "clang++"
        end
    end

    ctx.log(string.format("Компиляция C++ проекта напрямую (%s) в %s...", compiler, root))
    local cmd = string.format("%s -O2 -std=c++20 %s -o %q", compiler, table.concat(source_files, " "), proj_name)
    local code = ctx.run_shell(cmd, root)
    return code == 0
end

local adapter = CppAdapter.new()
return adapter
