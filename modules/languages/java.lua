local BaseAdapter = require("languages.base")
local utils = require("languages.utils")

local JavaAdapter = setmetatable({}, { __index = BaseAdapter })
JavaAdapter.__index = JavaAdapter

function JavaAdapter.new()
    local self = setmetatable(BaseAdapter.new({
        name = "java",
        aliases = { "java", "jav" },
        src_dir = "src",
        required_binaries = { "java", "javac" },
        extensions = { ".java" },
        build_files = { "build.gradle", "pom.xml" },
        entry_files = { "Main.java" },
    }), JavaAdapter)
    return self
end

function JavaAdapter:get_nix_packages(root)
    if utils.file_exists(root .. "/pom.xml") then
        return { "jdk", "maven" }
    end
    if utils.file_exists(root .. "/build.gradle") then
        return { "jdk", "gradle" }
    end
    return { "jdk" }
end

function JavaAdapter:get_target(root)
    local bin_main = root .. "/bin/Main.class"
    if grime.fs.exists(bin_main) then
        return bin_main
    end
    return BaseAdapter.get_target(self, root)
end

function JavaAdapter:create_default_files(root, ctx)
    local main_file = root .. "/src/Main.java"
    if not ctx.exists(main_file) then
        local content = [[public class Main {
    public static void main(String[] args) {
        System.out.println("Hello from Java project!");
    }
}
]]
        local f = io.open(main_file, "w")
        if f then
            f:write(content)
            f:close()
            ctx.log("Файл src/Main.java создан")
        end
    end
end

function JavaAdapter:build(root, ctx)
    ctx.mkdir_p(root .. "/bin")
    local main_file = root .. "/src/Main.java"
    if not ctx.exists(main_file) then
        main_file = root .. "/Main.java"
    end

    if not ctx.exists(main_file) then
        ctx.log("Ошибка: Main.java не найден в " .. root .. "!")
        return false
    end

    local code = ctx.run_shell("javac -d bin " .. main_file, root)
    return code == 0
end

function JavaAdapter:get_run_command(root, extra_args)
    local target = self:get_target(root)
    if not target then
        return nil
    end

    local cmd = { "java", "-cp", root .. "/bin", "Main" }
    if extra_args then
        for _, a in ipairs(extra_args) do
            table.insert(cmd, a)
        end
    end
    return cmd
end

local adapter = JavaAdapter.new()
return adapter
