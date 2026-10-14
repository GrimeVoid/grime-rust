local helper = {}

local function get_ctx()
    if grime and grime.ctx then
        return grime.ctx
    end
    return {}
end

helper.ctx = setmetatable({}, {
    __index = function(_, k)
        local c = get_ctx()
        if k == "args" then
            return c.args or {}
        elseif k == "target_dir" then
            return c.target_dir or "."
        elseif k == "pipeline_input" then
            return c.pipeline_input
        elseif k == "step_index" then
            return c.step_index or 0
        elseif k == "total_steps" then
            return c.total_steps or 1
        elseif k == "has_next_step" then
            return c.has_next_step or false
        elseif k == "is_last_step" then
            return c.is_last_step or true
        elseif k == "success" then
            return function(val) if c.success then c.success(val) end end
        elseif k == "fail" then
            return function(msg) if c.fail then c.fail(msg) end end
        elseif k == "module_return" then
            return function(val) if c.module_return then c.module_return(val) end end
        elseif k == "log" then
            return function(msg) if grime and grime.ui then grime.ui.log(msg) else io.stderr:write(msg .. "\n") end end
        elseif k == "error" then
            return function(msg) if grime and grime.ui then grime.ui.error(msg) else io.stderr:write(msg .. "\n") end end
        elseif k == "warn" then
            return function(msg) if grime and grime.ui then grime.ui.warn(msg) else io.stderr:write(msg .. "\n") end end
        elseif k == "run_process" or k == "run_interactive" then
            return function(cmd, cwd, env)
                cwd = cwd or c.target_dir or "."
                if grime and grime.process then
                    return grime.process.run_interactive(cmd, cwd, env)
                end
                return 1
            end
        elseif k == "run_shell" then
            return function(cmd, cwd, env)
                cwd = cwd or c.target_dir or "."
                if grime and grime.process then
                    return grime.process.run(cmd, cwd, env)
                end
                return 1
            end
        elseif k == "capture" then
            return function(cmd, cwd, env)
                cwd = cwd or c.target_dir or "."
                if grime and grime.process then
                    return grime.process.capture(cmd, cwd, env)
                end
                return { code = 1, stdout = "", stderr = "grime.process unavailable" }
            end
        elseif k == "exists" then
            return function(path)
                return grime and grime.fs and grime.fs.exists(path) or false
            end
        elseif k == "is_dir" then
            return function(path)
                return grime and grime.fs and grime.fs.is_dir and grime.fs.is_dir(path) or false
            end
        elseif k == "is_file" then
            return function(path)
                return grime and grime.fs and grime.fs.is_file and grime.fs.is_file(path) or false
            end
        elseif k == "mkdir_p" then
            return function(path)
                return grime and grime.fs and grime.fs.mkdir_p(path) or false
            end
        elseif k == "delete" or k == "remove" then
            return function(path, missing_ok)
                return grime and grime.fs and grime.fs.delete(path, missing_ok) or false
            end
        elseif k == "copy" then
            return function(src, dst)
                return grime and grime.fs and grime.fs.copy(src, dst) or dst
            end
        elseif k == "move" or k == "rename" then
            return function(src, dst)
                return grime and grime.fs and grime.fs.move(src, dst) or dst
            end
        elseif k == "mtime" then
            return function(path)
                return grime and grime.fs and grime.fs.mtime(path) or 0.0
            end
        elseif k == "is_newer" or k == "needs_rebuild" then
            return function(src, target)
                if grime and grime.fs and grime.fs.is_newer then
                    return grime.fs.is_newer(src, target)
                end
                return true
            end
        elseif k == "paths" then
            if c.paths then
                return c.paths
            elseif grime and grime.paths then
                return grime.paths
            end
            return {}
        elseif k == "get_path" then
            return function(name, fallback)
                if not name then return fallback end
                local p = nil
                if c.paths and c.paths[name] and c.paths[name] ~= "" then
                    p = c.paths[name]
                elseif grime and grime.paths and grime.paths[name] and grime.paths[name] ~= "" then
                    p = grime.paths[name]
                elseif grime and grime.config and grime.config.get then
                    p = grime.config.get(name)
                end
                if not p or p == "" or p == "auto" then
                    return fallback
                end
                return p
            end
        elseif k == "projects_root" then
            return function()
                local p = (c.paths and c.paths.projects)
                    or (grime and grime.paths and grime.paths.projects)
                    or (grime and grime.config and grime.config.projects_root and grime.config.projects_root())
                if not p or p == "" then
                    local home = os.getenv("HOME") or ""
                    p = (home ~= "" and (home .. "/Projects")) or "./projects"
                end
                return helper.normalize_path(p)
            end
        elseif k == "templates_root" then
            return function()
                local p = (c.paths and c.paths.templates)
                    or (grime and grime.paths and grime.paths.templates)
                    or (grime and grime.config and grime.config.templates_root and grime.config.templates_root())
                if not p or p == "" then
                    local home = os.getenv("HOME") or ""
                    p = (home ~= "" and (home .. "/.config/grime/templates")) or "./templates"
                end
                return helper.normalize_path(p)
            end
        elseif k == "apps_root" then
            return function()
                local p = (c.paths and c.paths.apps)
                    or (grime and grime.paths and grime.paths.apps)
                    or (grime and grime.config and grime.config.apps_root and grime.config.apps_root())
                if not p or p == "" then
                    local home = os.getenv("HOME") or ""
                    p = (home ~= "" and (home .. "/.config/grime/apps")) or "./apps"
                end
                return helper.normalize_path(p)
            end
        elseif k == "config_dir" then
            return function()
                local p = (c.paths and c.paths.config)
                    or (grime and grime.paths and grime.paths.config)
                    or (grime and grime.config and grime.config.config_dir and grime.config.config_dir())
                if not p or p == "" then
                    local home = os.getenv("HOME") or ""
                    p = (home ~= "" and (home .. "/.config/grime")) or "."
                end
                return helper.normalize_path(p)
            end
        elseif k == "get_config" then
            return function(key, default)
                return grime and grime.config and grime.config.get(key, default) or (default or "")
            end
        elseif k == "normalize_path" or k == "normalize" then
            return function(path)
                return helper.normalize_path(path)
            end
        elseif k == "path_join" or k == "join" then
            return function(...)
                return helper.join(...)
            end
        end
        return c[k]
    end
})

function helper.normalize_path(p)
    if not p then return "" end
    if grime and grime.fs and grime.fs.normalize then
        return grime.fs.normalize(p)
    end
    -- Чистая Lua-нормализация (удаление повторяющихся / и завершающего /, кроме корня)
    local is_abs = p:sub(1, 1) == "/"
    local clean = p:gsub("/+", "/")
    if #clean > 1 and clean:sub(-1) == "/" then
        clean = clean:sub(1, -2)
    end
    return clean
end

function helper.join(...)
    local parts = { ... }
    local res = ""
    for _, part in ipairs(parts) do
        if part and #part > 0 then
            if #res == 0 then
                res = part
            else
                res = res:gsub("/+$", "") .. "/" .. part:gsub("^/+", "")
            end
        end
    end
    return helper.normalize_path(res)
end

return helper
