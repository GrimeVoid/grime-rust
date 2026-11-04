-- Модуль парсинга аргументов командной строки и сопоставления флагов (Единый стандарт '-' и '--')
local argparse = {}
argparse.__index = argparse

function argparse.new(opts)
    opts = opts or {}
    local self = setmetatable({}, argparse)
    self.actions = opts.actions or {}
    self.default_action = opts.default_action
    self.flags = opts.flags or {}
    self.value_flags = opts.value_flags or {}
    self.categories = opts.categories or {}
    self.detect_dir = opts.detect_dir or false
    self.fuzzy_threshold = opts.fuzzy_threshold or 0.75
    self.allow_unknown_flags = opts.allow_unknown_flags or false
    return self
end

local function match_category_dict(cat_dict, key)
    if not cat_dict or not key then return nil end
    if cat_dict[key] ~= nil and type(key) == "string" then
        return cat_dict[key]
    end
    for k, v in pairs(cat_dict) do
        if type(k) == "number" and type(v) == "string" and v:lower() == key then
            return v:lower()
        end
    end
    return nil
end

function argparse:parse(args, default_target_dir)
    args = args or {}
    local tokens_before = {}
    local command_tokens = {}
    local found_dash = false

    for _, tok in ipairs(args) do
        if not found_dash and (tok == "--" or tok == "//") then
            found_dash = true
        elseif found_dash then
            table.insert(command_tokens, tok)
        else
            table.insert(tokens_before, tok)
        end
    end

    local res_flags = {}
    for flag_name, _ in pairs(self.flags) do
        res_flags[flag_name] = false
    end

    local res_categories = {}
    for cat_name, _ in pairs(self.categories) do
        res_categories[cat_name] = nil
    end

    local res_action = self.default_action
    local res_target_dir = nil
    local rest_args = {}
    local unknown_flags = {}
    local action_found = false

    local i = 1
    while i <= #tokens_before do
        local tok = tostring(tokens_before[i])
        local tok_lower = string.lower(tok)
        local is_dash_token = (tok:sub(1, 1) == "-" and #tok > 1)
        local stripped = is_dash_token and tok_lower:gsub("^%-+", "") or nil
        local flag_matched = false

        -- 0. Проверка флагов со значением (value_flags): --flag=val или --flag val
        for vname, patterns in pairs(self.value_flags) do
            for _, pat in ipairs(patterns) do
                local pat_low = string.lower(pat)
                local eq_prefix = pat_low .. "="
                if tok_lower:sub(1, #eq_prefix) == eq_prefix then
                    res_flags[vname] = tok:sub(#eq_prefix + 1)
                    flag_matched = true
                    break
                elseif tok_lower == pat_low or (stripped and #stripped > 0 and stripped == pat_low:gsub("^%-+", "")) then
                    if i + 1 <= #tokens_before then
                        i = i + 1
                        res_flags[vname] = tostring(tokens_before[i])
                    else
                        res_flags[vname] = true
                    end
                    flag_matched = true
                    break
                end
            end
            if flag_matched then break end
        end

        -- 1. Проверка точного совпадения булевых флагов (включая эквиваленты с '-' и '--')
        if not flag_matched then
            for flag_name, patterns in pairs(self.flags) do
                for _, pat in ipairs(patterns) do
                    local pat_low = string.lower(pat)
                    local pat_stripped = pat_low:gsub("^%-+", "")
                    if tok == pat or tok_lower == pat_low or (stripped and #stripped > 0 and stripped == pat_stripped) then
                        res_flags[flag_name] = true
                        flag_matched = true
                        -- Если этот же токен является действием и действие еще не выбрано, фиксируем и действие
                        local act_cand = self.actions[tok_lower] or (stripped and self.actions[stripped])
                        if act_cand and not action_found then
                            res_action = act_cand
                            action_found = true
                        end
                        break
                    end
                end
                if flag_matched then break end
            end
        end

        local in_passthrough_cmd = (res_action == "run" or res_action == "exec") and #rest_args > 0

        -- 1.1. Если токен начинается с '-': проверка действий и категорий со знаком минус (-action, --action, -cat, --cat)
        if not flag_matched and not in_passthrough_cmd and is_dash_token and stripped and #stripped > 0 then
            -- Сначала проверяем категории со знаком минус (например, -cpp, --rust, -pacman)
            for cat_name, cat_dict in pairs(self.categories) do
                if res_categories[cat_name] == nil then
                    local cval = match_category_dict(cat_dict, tok_lower) or match_category_dict(cat_dict, stripped)
                    if cval then
                        res_categories[cat_name] = cval
                        flag_matched = true
                        break
                    end
                end
            end

            -- Проверяем действия со знаком минус (например, -list, --list, -build, --build, -update, --update)
            if not flag_matched then
                local act_target = self.actions[tok_lower] or self.actions[stripped]
                if act_target then
                    if not action_found then
                        res_action = act_target
                        action_found = true
                    else
                        res_flags[act_target] = true
                    end
                    flag_matched = true
                end
            end
        end

        -- 1.2. Нечёткое сопоставление флагов (fuzzy match)
        if not flag_matched and not in_passthrough_cmd and is_dash_token and grime and grime.fuzzy and grime.fuzzy.match_flag then
            local best_flag_name = nil
            local best_score = 0.0
            local second_best_score = 0.0

            for flag_name, patterns in pairs(self.flags) do
                for _, pat in ipairs(patterns) do
                    local matched = grime.fuzzy.match_flag(tok, { pat }, self.fuzzy_threshold)
                    if matched then
                        local sim = grime.fuzzy.similarity(tok:gsub("^%-%-?", ""), pat:gsub("^%-%-?", ""))
                        if sim > best_score then
                            if best_flag_name and best_flag_name ~= flag_name then
                                second_best_score = best_score
                            end
                            best_score = sim
                            best_flag_name = flag_name
                        elseif math.abs(sim - best_score) < 1e-4 and best_flag_name ~= flag_name then
                            second_best_score = sim
                        end
                    end
                end
            end

            if best_flag_name and (best_score - second_best_score >= 0.08 or second_best_score < self.fuzzy_threshold) then
                res_flags[best_flag_name] = true
                flag_matched = true
            end
        end

        -- 1.3. Нечёткое сопоставление действий со знаком минус (для длинных флагов >= 3 символов)
        if not flag_matched and not in_passthrough_cmd and is_dash_token and not action_found and stripped and #stripped >= 3 and grime and grime.fuzzy and grime.fuzzy.find_best_match then
            local act_keys = {}
            for k, _ in pairs(self.actions) do
                local clean_k = tostring(k):gsub("^%-+", "")
                if #clean_k >= 3 then
                    table.insert(act_keys, clean_k)
                end
            end
            local best_act = grime.fuzzy.find_best_match(stripped, act_keys, 0.82)
            if best_act and self.actions[best_act] then
                res_action = self.actions[best_act]
                action_found = true
                flag_matched = true
            end
        end

        -- 1.4. Если токен начинается с '-', но не распознан:
        -- для команд-ранеров (run, exec, export, create) сохраняем его для дочерней команды,
        -- а для обычных модулей не засоряем позиционные аргументы args.
        if not flag_matched and is_dash_token then
            table.insert(unknown_flags, tok)
            if self.allow_unknown_flags or in_passthrough_cmd or res_action == "run" or res_action == "exec" or res_action == "export" or res_action == "create" then
                table.insert(rest_args, tok)
            end
            flag_matched = true
        end

        if not flag_matched then
            -- 2. Проверка действий без минуса
            if not action_found and self.actions[tok_lower] then
                res_action = self.actions[tok_lower]
                action_found = true
            else
                -- 3. Проверка категорий без минуса
                local cat_matched = false
                for cat_name, cat_dict in pairs(self.categories) do
                    if res_categories[cat_name] == nil then
                        local cval = match_category_dict(cat_dict, tok_lower)
                        if cval then
                            res_categories[cat_name] = cval
                            cat_matched = true
                            break
                        end
                    end
                end

                if not cat_matched then
                    -- 4. Автоопределение директории
                    local is_dir_candidate = false
                    if self.detect_dir and not res_target_dir then
                        if (tok:find("^[./~]") or tok:find("/")) and grime and grime.fs and grime.fs.exists(tok) and grime.fs.is_dir(tok) then
                            res_target_dir = tok
                            is_dir_candidate = true
                        end
                    end

                    if not is_dir_candidate then
                        -- 5. Позиционный токен
                        table.insert(rest_args, tok)
                    end
                end
            end
        end

        i = i + 1
    end

    return {
        action = res_action,
        flags = res_flags,
        categories = res_categories,
        target_dir = res_target_dir,
        dir = res_target_dir,
        args = rest_args,
        command_tokens = command_tokens,
        unknown_flags = unknown_flags,
    }
end

return argparse
