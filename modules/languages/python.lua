local BaseAdapter = require("languages.base")

local PythonAdapter = setmetatable({}, { __index = BaseAdapter })
PythonAdapter.__index = PythonAdapter

function PythonAdapter.new()
    local self = setmetatable(BaseAdapter.new({
        name = "python",
        aliases = { "python", "py" },
        src_dir = "src",
        required_binaries = { "python3" },
        extensions = { ".py" },
        build_files = { "pyproject.toml", "requirements.txt" },
        entry_files = { "main.py" },
    }), PythonAdapter)
    return self
end

function PythonAdapter:get_nix_packages(root)
    if grime.fs.exists(root .. "/pyproject.toml") then
        return { "python3", "uv" }
    end
    if grime.fs.exists(root .. "/requirements.txt") then
        return { "python3", "pip" }
    end
    return { "python3" }
end

function PythonAdapter:create_default_files(root, ctx)
    local main_file = root .. "/src/main.py"
    if not ctx.exists(main_file) then
        local content = [[def main():
    print("Hello from Python project!")

if __name__ == "__main__":
    main()
]]
        local f = io.open(main_file, "w")
        if f then
            f:write(content)
            f:close()
            ctx.log("Файл src/main.py создан")
        end
    end
end

function PythonAdapter:build(root, ctx)
    local target = self:get_target(root)
    if not target then
        ctx.log("Ошибка: точка входа main.py не найдена в " .. root .. "!")
        return false
    end

    local code = ctx.run_shell("python3 -m py_compile " .. target, root)
    return code == 0
end

function PythonAdapter:get_run_command(root, extra_args)
    local target = self:get_target(root)
    if not target then
        return nil
    end

    local cmd = { "python3", target }
    if extra_args then
        for _, a in ipairs(extra_args) do
            table.insert(cmd, a)
        end
    end
    return cmd
end

local adapter = PythonAdapter.new()
return adapter
