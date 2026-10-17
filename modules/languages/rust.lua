local BaseAdapter = require("languages.base")

local RustAdapter = setmetatable({}, { __index = BaseAdapter })
RustAdapter.__index = RustAdapter

function RustAdapter.new()
    local self = setmetatable(BaseAdapter.new({
        name = "rust",
        aliases = { "rust", "rs" },
        src_dir = "src",
        required_binaries = { "cargo", "rustc" },
        extensions = { ".rs" },
        build_files = { "Cargo.toml" },
        entry_files = { "main.rs" },
    }), RustAdapter)
    return self
end

function RustAdapter:get_nix_packages(root)
    return { "cargo", "rustc", "rust-analyzer" }
end

function RustAdapter:create_default_files(root, ctx)
    local proj_name = root:match("([^/\\]+)$") or "rust_app"
    local clean_name = proj_name:lower():gsub("[%s%-]", "_")

    local cargo_file = root .. "/Cargo.toml"
    if not ctx.exists(cargo_file) then
        local content = string.format([[# Cargo configuration
[package]
name = "%s"
version = "0.1.0"
edition = "2021"

[dependencies]
]], clean_name)
        local f = io.open(cargo_file, "w")
        if f then
            f:write(content)
            f:close()
            ctx.log("Файл Cargo.toml создан")
        end
    end

    local main_file = root .. "/src/main.rs"
    if not ctx.exists(main_file) then
        local content = [[fn main() {
    println!("Hello from Rust project!");
}
]]
        local f = io.open(main_file, "w")
        if f then
            f:write(content)
            f:close()
            ctx.log("Файл src/main.rs создан")
        end
    end
end

function RustAdapter:build(root, ctx)
    if ctx.exists(root .. "/Cargo.toml") then
        ctx.log("Сборка Rust проекта через Cargo в " .. root .. "...")
        local code = ctx.run_shell("cargo build", root)
        return code == 0
    elseif ctx.exists(root .. "/src/main.rs") or ctx.exists(root .. "/main.rs") then
        local target_src = ctx.exists(root .. "/src/main.rs") and (root .. "/src/main.rs") or (root .. "/main.rs")
        ctx.log("Компиляция " .. target_src .. " через rustc...")
        local code = ctx.run_shell("rustc " .. target_src .. " -o main", root)
        return code == 0
    else
        ctx.log("Ошибка: в " .. root .. " не найдены файлы для сборки Rust!")
        return false
    end
end

function RustAdapter:get_run_command(root, extra_args)
    local target = self:get_target(root)
    if target and grime.fs.exists(target) and grime.fs.is_file(target) then
        local cmd = { target }
        if extra_args then
            for _, a in ipairs(extra_args) do
                table.insert(cmd, a)
            end
        end
        return cmd
    end

    if utils.has_binary("cargo") and grime.fs.exists(root .. "/Cargo.toml") then
        local cmd = { "cargo", "run" }
        if extra_args and #extra_args > 0 then
            table.insert(cmd, "--")
            for _, a in ipairs(extra_args) do
                table.insert(cmd, a)
            end
        end
        return cmd
    end
    return BaseAdapter.get_run_command(self, root, extra_args)
end

local adapter = RustAdapter.new()
return adapter
