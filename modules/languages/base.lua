local BaseAdapter = {}
BaseAdapter.__index = BaseAdapter

function BaseAdapter.new(opts)
    opts = opts or {}
    local self = setmetatable({}, BaseAdapter)
    self.name = opts.name or ""
    self.aliases = opts.aliases or {}
    self.src_dir = opts.src_dir or "src"
    self.required_binaries = opts.required_binaries or {}
    self.extensions = opts.extensions or {}
    self.build_files = opts.build_files or {}
    self.entry_files = opts.entry_files or {}
    return self
end

function BaseAdapter:detect(root)
    if not (grime and grime.fs and grime.fs.exists(root)) then
        return false
    end

    -- 1. Проверка файлов сборки
    for _, bf in ipairs(self.build_files) do
        local p = root .. "/" .. bf
        if grime.fs.exists(p) then
            return true
        end
    end

    -- 2. Проверка точек входа
    for _, ef in ipairs(self.entry_files) do
        if grime.fs.exists(root .. "/" .. ef) or grime.fs.exists(root .. "/" .. self.src_dir .. "/" .. ef) then
            return true
        end
    end

    return false
end

function BaseAdapter:get_nix_packages(root)
    return self.required_binaries
end

function BaseAdapter:get_target(root)
    -- 1. build/<root_name>
    local root_name = root:match("([^/\\]+)$") or "app"
    local build_target = root .. "/build/" .. root_name
    if grime.fs.exists(build_target) then
        return build_target
    end

    -- 2. target/debug/<root_name>
    local cargo_target = root .. "/target/debug/" .. root_name
    if grime.fs.exists(cargo_target) then
        return cargo_target
    end

    -- 3. root/<root_name> или root/main
    if grime.fs.exists(root .. "/" .. root_name) then
        return root .. "/" .. root_name
    end
    if grime.fs.exists(root .. "/main") then
        return root .. "/main"
    end

    -- 4. Точки входа
    for _, ef in ipairs(self.entry_files) do
        local p_src = root .. "/" .. self.src_dir .. "/" .. ef
        if grime.fs.exists(p_src) then return p_src end
        local p_root = root .. "/" .. ef
        if grime.fs.exists(p_root) then return p_root end
    end

    return nil
end

function BaseAdapter:apply_template(root, ctx)
    local tpl_root = (ctx.paths and ctx.paths.templates)
        or (ctx.get_path and ctx.get_path("templates"))
        or (ctx.templates_root and ctx.templates_root())
        or "./templates"
    local tpl_dir = ctx.normalize_path(tpl_root) .. "/" .. self.name
    if not ctx.exists(tpl_dir) then
        return false
    end

    local proj_name = root:match("([^/\\]+)$") or "app"
    local snake_name = proj_name:lower():gsub("[%s%-]", "_")
    local kebab_name = proj_name:lower():gsub("[%s_]", "-")
    local lower_name = proj_name:lower()
    local upper_name = proj_name:upper()

    -- Рекурсивно копируем файлы из директории шаблона в root
    ctx.copy(tpl_dir, root)
    ctx.log(string.format("Шаблон %s развернут из %s", self.name, tpl_dir))

    -- Подстановка переменных во всех текстовых файлах
    local function substitute_file(filepath)
        local f = io.open(filepath, "r")
        if not f then return end
        local content = f:read("*all")
        f:close()
        if not content then return end

        local new_content = content
        new_content = new_content:gsub("{{PROJECT_NAME}}", proj_name)
        new_content = new_content:gsub("{{PROJECT_NAME_LOWER}}", lower_name)
        new_content = new_content:gsub("{{PROJECT_NAME_UPPER}}", upper_name)
        new_content = new_content:gsub("{{PROJECT_NAME_SNAKE}}", snake_name)
        new_content = new_content:gsub("{{PROJECT_NAME_KEBAB}}", kebab_name)

        if new_content ~= content then
            local wf = io.open(filepath, "w")
            if wf then
                wf:write(new_content)
                wf:close()
            end
        end
    end

    local p = io.popen("find \"" .. root .. "\" -type f 2>/dev/null")
    if p then
        for file in p:lines() do
            if not file:find("/%.git/") and not file:find("/build/") and not file:find("/target/") then
                substitute_file(file)
            end
        end
        p:close()
    end

    return true
end

function BaseAdapter:init_project(root, ctx)
    ctx.mkdir_p(root .. "/" .. self.src_dir)
    local template_applied = self:apply_template(root, ctx)
    if not template_applied then
        self:create_default_files(root, ctx)
    end
end

function BaseAdapter:create_default_files(root, ctx)
    -- Переопределяется в конкретном адаптере
end

function BaseAdapter:build(root, ctx)
    ctx.log("Сборка для языка " .. self.name .. " не требует действий или не переопределена.")
    return true
end

function BaseAdapter:get_run_command(root, extra_args)
    local target = self:get_target(root)
    if not target then
        return nil
    end

    local cmd = { target }
    if extra_args then
        for _, a in ipairs(extra_args) do
            table.insert(cmd, a)
        end
    end
    return cmd
end

function BaseAdapter:run(root, extra_args, ctx)
    local cmd = self:get_run_command(root, extra_args)
    if not cmd then
        ctx.log("Ошибка: исполняемый файл или точка входа для " .. self.name .. " не найдена в " .. root .. "!")
        return 1
    end

    ctx.log("Запуск: " .. table.concat(cmd, " "))
    return ctx.run_process(cmd, root)
end

function BaseAdapter:needs_rebuild(root, ctx)
    local target = self:get_target(root)
    if not target then
        return true
    end
    local src_path = root .. "/" .. self.src_dir
    return ctx.needs_rebuild(src_path, target)
end

return BaseAdapter
