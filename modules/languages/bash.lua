local BaseAdapter = require("languages.base")
local utils = require("languages.utils")

local BashAdapter = setmetatable({}, { __index = BaseAdapter })
BashAdapter.__index = BashAdapter

function BashAdapter.new()
    local self = setmetatable(BaseAdapter.new({
        name = "bash",
        aliases = { "bash", "sh", "shell" },
        src_dir = "src",
        required_binaries = { "bash" },
        extensions = { ".sh", ".bash" },
        build_files = {},
        entry_files = { "main.sh" },
    }), BashAdapter)
    return self
end

function BashAdapter:get_nix_packages(_root)
    return { "bashInteractive" }
end

function BashAdapter:check_dependencies(ctx, _root)
    if utils.has_binary("bash", ctx) or utils.has_binary("sh", ctx) then
        return true, {}
    end
    return false, { "bash" }
end

function BashAdapter:get_target(root)
    local root_name = root:match("([^/\\]+)$") or "app"
    local candidates = {
        root .. "/main.sh",
        root .. "/src/main.sh",
        root .. "/" .. root_name .. ".sh",
        root .. "/main.bash",
        root .. "/src/main.bash",
        root .. "/" .. root_name .. ".bash",
    }
    for _, c in ipairs(candidates) do
        if utils.file_exists(c) then
            return c
        end
    end
    if grime and grime.fs and grime.fs.list then
        for _, dir in ipairs({ root, root .. "/src" }) do
            if grime.fs.exists(dir) then
                local items = grime.fs.list(dir) or {}
                table.sort(items)
                for _, item in ipairs(items) do
                    if item:match("%.sh$") or item:match("%.bash$") then
                        local full = dir .. "/" .. item
                        if grime.fs.is_file(full) then
                            return full
                        end
                    end
                end
            end
        end
    end
    return BaseAdapter.get_target(self, root)
end

function BashAdapter:create_default_files(root, ctx, description)
    local main_file = root .. "/main.sh"
    if not ctx.exists(main_file) and not ctx.exists(root .. "/src/main.sh") then
        local desc = (description and description ~= "") and description:gsub("\n", " ") or "Bash-скрипт GRIME"
        local content = string.format([[#!/usr/bin/env bash
# description: %s
set -euo pipefail

main() {
    echo "Hello from Bash!"
}

main "$@"
]], desc)
        local f = io.open(main_file, "w")
        if f then
            f:write(content)
            f:close()
            if ctx.capture then
                ctx.capture({ "chmod", "+x", main_file })
            end
            ctx.log("Файл main.sh создан")
        end
    end
end

function BashAdapter:build(root, ctx)
    local target = self:get_target(root)
    if not target then
        ctx.log("Ошибка: точка входа .sh не найдена в " .. root .. "!")
        return false
    end
    local checker = utils.has_binary("bash", ctx) and "bash" or "sh"
    local res = ctx.capture({ checker, "-n", target }, root)
    if res.code ~= 0 then
        ctx.log("Ошибка синтаксиса Bash: " .. (res.stderr or ""))
        return false
    end
    return true
end

function BashAdapter:get_run_command(root, extra_args)
    local target = self:get_target(root)
    if not target then
        return nil
    end
    local bin = utils.has_binary("bash") and "bash" or "sh"
    local cmd = { bin, target }
    if extra_args then
        for _, a in ipairs(extra_args) do
            table.insert(cmd, a)
        end
    end
    return cmd
end

local adapter = BashAdapter.new()
return adapter
