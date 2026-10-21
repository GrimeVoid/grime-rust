local BaseAdapter = require("languages.base")
local utils = require("languages.utils")

local LuaAdapter = setmetatable({}, { __index = BaseAdapter })
LuaAdapter.__index = LuaAdapter

function LuaAdapter.new()
    local self = setmetatable(BaseAdapter.new({
        name = "lua",
        aliases = { "lua", "luajit" },
        src_dir = "src",
        required_binaries = { "luajit" },
        extensions = { ".lua" },
        build_files = {},
        entry_files = { "main.lua" },
    }), LuaAdapter)
    return self
end

function LuaAdapter:get_nix_packages(_root)
    return { "luajit" }
end

function LuaAdapter:check_dependencies(ctx, _root)
    if utils.has_binary("luajit", ctx) or utils.has_binary("lua", ctx) then
        return true, {}
    end
    return false, { "luajit" }
end

function LuaAdapter:get_target(root)
    if utils.file_exists(root .. "/src/main.lua") then
        return root .. "/src/main.lua"
    end
    if utils.file_exists(root .. "/main.lua") then
        return root .. "/main.lua"
    end
    return BaseAdapter.get_target(self, root)
end

function LuaAdapter:create_default_files(root, ctx)
    local main_file = root .. "/src/main.lua"
    if not ctx.exists(main_file) then
        local content = [[local function main()
    print("Hello from LuaJIT project!")
end

main()
]]
        local f = io.open(main_file, "w")
        if f then
            f:write(content)
            f:close()
            ctx.log("Файл src/main.lua создан")
        end
    end
end

function LuaAdapter:build(root, ctx)
    local target = self:get_target(root)
    if not target then
        ctx.log("Ошибка: точка входа main.lua не найдена в " .. root .. "!")
        return false
    end

    if utils.has_binary("luajit", ctx) then
        local res = ctx.capture({ "luajit", "-bl", target }, root)
        if res.code ~= 0 then
            ctx.log("Ошибка синтаксиса LuaJIT: " .. (res.stderr or ""))
            return false
        end
        return true
    elseif utils.has_binary("luac", ctx) then
        local res = ctx.capture({ "luac", "-p", target }, root)
        return res.code == 0
    end
    return true
end

function LuaAdapter:get_run_command(root, extra_args)
    local target = self:get_target(root)
    if not target then
        return nil
    end

    local bin = utils.has_binary("luajit") and "luajit" or "lua"
    local cmd = { bin, target }
    if extra_args then
        for _, a in ipairs(extra_args) do
            table.insert(cmd, a)
        end
    end
    return cmd
end

local adapter = LuaAdapter.new()
return adapter
