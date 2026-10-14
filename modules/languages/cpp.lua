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

function CppAdapter:get_nix_packages(root)
    if grime.fs.exists(root .. "/CMakeLists.txt") then
        return { "cmake", "gcc", "ninja", "pkg-config" }
    end
    if grime.fs.exists(root .. "/Makefile") then
        return { "gnumake", "gcc" }
    end
    return { "gcc" }
end

function CppAdapter:create_default_files(root, ctx)
    local proj_name = root:match("([^/\\]+)$") or "MyGame"

    local cmake_file = root .. "/CMakeLists.txt"
    if not ctx.exists(cmake_file) then
        local tpl = ctx.templates_root() .. "/cpp/CMakeLists.txt"
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
        local tpl = ctx.templates_root() .. "/cpp/main.cpp"
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

function CppAdapter:build(root, ctx)
    if not ctx.exists(root .. "/CMakeLists.txt") then
        ctx.log("Ошибка: в " .. root .. " не найден CMakeLists.txt для сборки!")
        return false
    end

    ctx.log("Компиляция C++ проекта в " .. root .. "...")
    local code = ctx.run_shell("cmake -B build -G Ninja && ninja -C build", root)
    return code == 0
end

local adapter = CppAdapter.new()
return adapter
