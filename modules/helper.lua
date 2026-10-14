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
        elseif k == "json" then
            return {
                decode = helper.json_decode,
                encode = helper.json_encode,
            }
        elseif k == "to_snake_case" then
            return helper.to_snake_case
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

function helper.to_snake_case(str)
    if not str then return "" end
    local s = str:gsub("([a-z0-9])([A-Z])", "%1_%2")
    s = s:gsub("[%s%-]+", "_")
    return s:lower()
end

function helper.json_decode(str)
    if not str or str == "" then return nil end
    if grime and grime.json and grime.json.decode then
        local ok, res = pcall(grime.json.decode, str)
        if ok then return res end
    end
    -- Базовый fallback для чисел, boolean, строк и null
    local trimmed = str:match("^%s*(.-)%s*$")
    if trimmed == "true" then return true end
    if trimmed == "false" then return false end
    if trimmed == "null" then return nil end
    local num = tonumber(trimmed)
    if num ~= nil then return num end
    if (trimmed:sub(1, 1) == '"' and trimmed:sub(-1) == '"') or (trimmed:sub(1, 1) == "'" and trimmed:sub(-1) == "'") then
        return trimmed:sub(2, -2)
    end
    return trimmed
end

function helper.json_encode(val)
    if grime and grime.json and grime.json.encode then
        local ok, res = pcall(grime.json.encode, val)
        if ok then return res end
    end
    if type(val) == "string" then
        return string.format("%q", val)
    elseif type(val) == "number" or type(val) == "boolean" then
        return tostring(val)
    elseif val == nil then
        return "null"
    end
    return tostring(val)
end

-- Расстояние Дамерау-Левенштейна (с транспозициями соседних символов)
function helper.damerau_levenshtein(s1, s2)
    if grime and grime.fuzzy and grime.fuzzy.damerau_levenshtein then
        local ok, res = pcall(grime.fuzzy.damerau_levenshtein, s1, s2)
        if ok and res ~= nil then return res end
    end

    local len1 = #(s1 or "")
    local len2 = #(s2 or "")
    if len1 == 0 then return len2 end
    if len2 == 0 then return len1 end

    local d = {}
    for i = 0, len1 do
        d[i] = { [0] = i }
    end
    for j = 0, len2 do
        d[0][j] = j
    end

    for i = 1, len1 do
        local c1 = s1:sub(i, i)
        for j = 1, len2 do
            local c2 = s2:sub(j, j)
            local cost = (c1 == c2) and 0 or 1

            local del = d[i - 1][j] + 1
            local ins = d[i][j - 1] + 1
            local sub = d[i - 1][j - 1] + cost

            local min_val = del
            if ins < min_val then min_val = ins end
            if sub < min_val then min_val = sub end

            if i > 1 and j > 1 and c1 == s2:sub(j - 1, j - 1) and s1:sub(i - 1, i - 1) == c2 then
                local trans = d[i - 2][j - 2] + 1
                if trans < min_val then min_val = trans end
            end

            d[i][j] = min_val
        end
    end

    return d[len1][len2]
end

-- Мера сходства флагов (от 0.0 до 1.0)
function helper.similarity(s1, s2)
    if grime and grime.fuzzy and grime.fuzzy.similarity then
        local ok, res = pcall(grime.fuzzy.similarity, s1, s2)
        if ok and res ~= nil then return res end
    end

    local inp = (s1 or ""):lower()
    local cand = (s2 or ""):lower()
    if inp == cand then return 1.0 end

    local len_inp = #inp
    local len_cand = #cand
    if len_inp == 0 or len_cand == 0 then return 0.0 end

    local max_len = (len_inp > len_cand) and len_inp or len_cand
    local dist = helper.damerau_levenshtein(inp, cand)
    local base_sim = 1.0 - (dist / max_len)

    -- Префиксный бонус
    if cand:find(inp, 1, true) == 1 and len_inp >= 2 then
        local diff = len_cand - len_inp
        if diff <= 3 then
            local prefix_sim = 1.0 - (diff / (len_cand * 2.0))
            if prefix_sim > base_sim then
                base_sim = prefix_sim
            end
        end
    end

    -- Граничный бонус (совпадение первой и последней буквы)
    if dist == 1 and len_inp >= 3 and len_cand >= 3 then
        if inp:sub(1, 1) == cand:sub(1, 1) and inp:sub(-1) == cand:sub(-1) then
            base_sim = math.min(1.0, base_sim + 0.05)
        end
    end

    return base_sim
end

-- Нечёткий поиск флага с высоким порогом (threshold по умолчанию 0.75)
-- ПРАВИЛО: произвольные строковые значения (не начинающиеся с '-') не затрагиваются!
function helper.fuzzy_match_flag(token, known_flags, threshold)
    threshold = threshold or 0.75
    if not token or type(token) ~= "string" then return nil end

    -- Строгое ограничение: только аргументы, начинающиеся с '-' и не являющиеся '--'
    if not token:match("^%-") or token == "--" then
        return nil
    end

    -- Если токен совпадает в точности с одним из флагов
    for _, cand in ipairs(known_flags or {}) do
        if token == cand then
            return cand
        end
    end

    -- Вызов нативного Rust-матчера при наличии
    if grime and grime.fuzzy and grime.fuzzy.match_flag then
        local ok, res = pcall(grime.fuzzy.match_flag, token, known_flags, threshold)
        if ok and res ~= nil then return res end
    end

    local is_double = (token:sub(1, 2) == "--")
    local input_raw = token:gsub("^%-%-?", ""):lower()
    local len_raw = #input_raw

    -- Однобуквенные флаги (-x, -h, -a) не подвергаются нечеткому поиску
    if len_raw <= 1 then
        return nil
    end

    local best_candidate = nil
    local best_cand_raw = nil
    local best_score = 0.0
    local second_best_score = 0.0

    for _, cand in ipairs(known_flags or {}) do
        local cand_is_double = (cand:sub(1, 2) == "--")
        local cand_raw = cand:gsub("^%-%-?", ""):lower()
        local len_cand = #cand_raw

        if len_cand > 1 then
            local sim = helper.similarity(input_raw, cand_raw)
            local dist = helper.damerau_levenshtein(input_raw, cand_raw)

            local valid_dist = false
            if len_cand <= 4 then
                valid_dist = (dist <= 1) or (cand_raw:find(input_raw, 1, true) == 1)
            elseif len_cand <= 7 then
                valid_dist = (dist <= 2)
            else
                valid_dist = (dist <= 3)
            end

            if valid_dist and sim >= threshold then
                if best_cand_raw and best_cand_raw == cand_raw then
                    if cand_is_double == is_double then
                        best_candidate = cand
                    end
                elseif sim > best_score then
                    second_best_score = best_score
                    best_score = sim
                    best_candidate = cand
                    best_cand_raw = cand_raw
                elseif math.abs(sim - best_score) < 1e-4 then
                    second_best_score = sim
                elseif sim > second_best_score then
                    second_best_score = sim
                end
            end
        end
    end

    if best_candidate then
        if (best_score - second_best_score >= 0.08) or (second_best_score < threshold) then
            return best_candidate
        end
    end

    return nil
end

-- Нормализация списка аргументов для флагов (позиционные строковые аргументы остаются неизменными)
function helper.normalize_flags(args, known_flags, threshold)
    threshold = threshold or 0.75
    local res = {}
    for _, arg in ipairs(args or {}) do
        if type(arg) == "string" and arg:match("^%-") and arg ~= "--" then
            local matched = helper.fuzzy_match_flag(arg, known_flags, threshold)
            table.insert(res, matched or arg)
        else
            table.insert(res, arg)
        end
    end
    return res
end

-- Универсальный нечёткий поиск лучшего совпадения для ключевых сущностей
-- (имена модулей, приложений, проектов, пакетов и пакетных менеджеров).
-- threshold по умолчанию 0.75. Принимает список строк или таблицу с ключами.
function helper.find_best_match(query, candidates, threshold)
    threshold = threshold or 0.75
    if not query or type(query) ~= "string" or query == "" then
        return nil, 0.0
    end

    local q = query:lower():match("^%s*(.-)%s*$")
    if not q or q == "" then
        return nil, 0.0
    end

    -- Приведение candidates к списку строк
    local cand_list = {}
    if type(candidates) == "table" then
        if #candidates > 0 then
            for _, c in ipairs(candidates) do
                if type(c) == "string" and c ~= "" then
                    table.insert(cand_list, c)
                end
            end
        else
            for k, _ in pairs(candidates) do
                if type(k) == "string" and k ~= "" then
                    table.insert(cand_list, k)
                end
            end
        end
    end

    if #cand_list == 0 then
        return nil, 0.0
    end

    -- 1. Точное совпадение
    for _, cand in ipairs(cand_list) do
        if q == cand:lower() then
            return cand, 1.0
        end
    end

    -- 2. Вызов нативного Rust-матчера при наличии
    if grime and grime.fuzzy and grime.fuzzy.find_best_match then
        local ok, res = pcall(grime.fuzzy.find_best_match, q, cand_list, threshold)
        if ok and res ~= nil and res ~= "" then
            local sim = helper.similarity(q, res)
            return res, sim
        end
    end

    -- 3. Чистый fallback на Lua
    local len_q = #q
    local best_cand = nil
    local best_score = 0.0
    local second_best_score = 0.0

    for _, cand in ipairs(cand_list) do
        local c = cand:lower()
        local len_c = #c

        local sim = helper.similarity(q, c)
        local dist = helper.damerau_levenshtein(q, c)

        local is_prefix = (c:find(q, 1, true) == 1) and (len_q >= 2) and (len_c >= len_q) and (len_c - len_q <= 3)
        local valid_dist = is_prefix or (len_c <= 3 and dist <= 1) or (len_c <= 6 and dist <= 1) or (len_c <= 9 and dist <= 2) or (dist <= 3)

        if valid_dist and sim >= threshold then
            if sim > best_score then
                second_best_score = best_score
                best_score = sim
                best_cand = cand
            elseif math.abs(sim - best_score) < 1e-4 then
                second_best_score = sim
            elseif sim > second_best_score then
                second_best_score = sim
            end
        end
    end

    if best_cand then
        if (best_score - second_best_score >= 0.08) or (second_best_score < threshold) then
            return best_cand, best_score
        end
    end

    return nil, 0.0
end

helper.fuzzy_match = helper.find_best_match

return helper

