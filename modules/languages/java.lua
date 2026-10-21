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
        build_files = { "build.gradle", "build.gradle.kts", "pom.xml" },
        entry_files = { "Main.java" },
    }), JavaAdapter)
    return self
end

function JavaAdapter:get_nix_packages(root)
    if utils.file_exists(root .. "/pom.xml") then
        return { "jdk", "maven" }
    end
    if utils.file_exists(root .. "/build.gradle") or utils.file_exists(root .. "/build.gradle.kts") then
        return { "jdk", "gradle" }
    end
    return { "jdk" }
end

function JavaAdapter:check_dependencies(ctx, root)
    root = root or (ctx and ctx.target_dir)
    local needed = { "java", "javac" }
    if root and utils.file_exists(root .. "/pom.xml") then
        needed = { "java", "mvn" }
    elseif root and (utils.file_exists(root .. "/build.gradle") or utils.file_exists(root .. "/build.gradle.kts")) then
        if utils.file_exists(root .. "/gradlew") then
            needed = { "java" }
        else
            needed = { "java", "gradle" }
        end
    end

    local missing = {}
    for _, bin in ipairs(needed) do
        if not utils.has_binary(bin, ctx) then
            table.insert(missing, bin)
        end
    end
    return (#missing == 0), missing
end

local function find_jar_in_dir(dir)
    if not (grime and grime.fs and grime.fs.exists(dir) and grime.fs.list) then
        return nil
    end
    local items = grime.fs.list(dir) or {}
    table.sort(items)
    for _, item in ipairs(items) do
        if item:match("%.jar$") and not item:match("^original%-") and not item:match("%-sources%.jar$") and not item:match("%-javadoc%.jar$") then
            return dir .. "/" .. item
        end
    end
    return nil
end

function JavaAdapter:get_target(root)
    if utils.file_exists(root .. "/pom.xml") then
        local jar = find_jar_in_dir(root .. "/target")
        if jar then return jar end
        if utils.file_exists(root .. "/target/classes/Main.class") then
            return root .. "/target/classes/Main.class"
        end
    end

    if utils.file_exists(root .. "/build.gradle") or utils.file_exists(root .. "/build.gradle.kts") then
        local jar = find_jar_in_dir(root .. "/build/libs")
        if jar then return jar end
        if utils.file_exists(root .. "/build/classes/java/main/Main.class") then
            return root .. "/build/classes/java/main/Main.class"
        end
    end

    local bin_main = root .. "/bin/Main.class"
    if utils.file_exists(bin_main) then
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
    if ctx.exists(root .. "/pom.xml") then
        ctx.log("Сборка Java проекта (Maven) в " .. root .. "...")
        local code = ctx.run_shell("mvn -q package -DskipTests", root)
        return code == 0
    end

    if ctx.exists(root .. "/build.gradle") or ctx.exists(root .. "/build.gradle.kts") then
        ctx.log("Сборка Java проекта (Gradle) в " .. root .. "...")
        local gradle_cmd = ctx.exists(root .. "/gradlew") and "./gradlew build -x test -q" or "gradle build -x test -q"
        local code = ctx.run_shell(gradle_cmd, root)
        return code == 0
    end

    ctx.mkdir_p(root .. "/bin")
    local main_file = root .. "/src/Main.java"
    if not ctx.exists(main_file) then
        main_file = root .. "/Main.java"
    end

    if not ctx.exists(main_file) then
        ctx.log("Ошибка: Main.java, pom.xml или build.gradle не найдены в " .. root .. "!")
        return false
    end

    local code = ctx.run_process({ "javac", "-d", root .. "/bin", main_file }, root)
    return code == 0
end

function JavaAdapter:get_run_command(root, extra_args)
    local function append_extra(cmd)
        if extra_args then
            for _, a in ipairs(extra_args) do
                table.insert(cmd, a)
            end
        end
        return cmd
    end

    if utils.file_exists(root .. "/pom.xml") then
        local main_class = nil
        local f = io.open(root .. "/pom.xml", "r")
        if f then
            local content = f:read("*all") or ""
            f:close()
            main_class = content:match("<mainClass>%s*([^<%s]+)%s*</mainClass>")
        end
        if not main_class and utils.file_exists(root .. "/target/classes/Main.class") then
            main_class = "Main"
        end
        if main_class and utils.file_exists(root .. "/target/classes") then
            return append_extra({ "java", "-cp", root .. "/target/classes", main_class })
        end
        local jar = find_jar_in_dir(root .. "/target")
        if jar then
            return append_extra({ "java", "-jar", jar })
        end
        local cmd = { "mvn", "-q", "exec:java" }
        if extra_args and #extra_args > 0 then
            table.insert(cmd, "-Dexec.args=" .. table.concat(extra_args, " "))
        end
        return cmd
    end

    if utils.file_exists(root .. "/build.gradle") or utils.file_exists(root .. "/build.gradle.kts") then
        if utils.file_exists(root .. "/build/classes/java/main/Main.class") then
            return append_extra({ "java", "-cp", root .. "/build/classes/java/main", "Main" })
        end
        local jar = find_jar_in_dir(root .. "/build/libs")
        if jar then
            return append_extra({ "java", "-jar", jar })
        end
        local gradle_bin = utils.file_exists(root .. "/gradlew") and (root .. "/gradlew") or "gradle"
        local cmd = { gradle_bin, "-q", "run" }
        if extra_args and #extra_args > 0 then
            table.insert(cmd, "--args=" .. table.concat(extra_args, " "))
        end
        return cmd
    end

    local target = self:get_target(root)
    if not target then
        return nil
    end

    return append_extra({ "java", "-cp", root .. "/bin", "Main" })
end

local adapter = JavaAdapter.new()
return adapter
