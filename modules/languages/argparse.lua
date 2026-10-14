-- Модуль парсинга аргументов командной строки и сопоставления флагов
local argparse = {}
argparse.__index = argparse

function argparse.new(opts)
    opts = opts or {}
    local self = setmetatable({}, argparse)
    self.actions = opts.actions or {}
    self.default_action = opts.default_action
    self.flags = opts.flags or {}
    self.categories = opts.categories or {}
    self.detect_dir = opts.detect_dir or false
    self.fuzzy_threshold = opts.fuzzy_threshold or 0.75
    return self
end

function argparse:parse(args, default_target_dir)
    args = args or {}
    local tokens_before = {}
    local command_tokens = {}
    local found_dash = false

    for _, tok in ipairs(args) do
        if not found_dash and tok == "--" then
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
    local action_found = false

    for _, tok in ipairs(tokens_before) do
        local tok_lower = string.lower(tok)
        local flag_matched = false

        -- 1. Проверка точного совпадения флагов
        for flag_name, patterns in pairs(self.flags) do
            for _, pat in ipairs(patterns) do
                if tok == pat then
                    res_flags[flag_name] = true
                    flag_matched = true
                    break
                end
            end
            if flag_matched then break end
        end

        -- 1.1. Нечёткое сопоставление флагов
        if not flag_matched and tok:sub(1, 1) == "-" and tok ~= "--" then
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

        if not flag_matched then
            -- 2. Проверка действий
            if not action_found and self.actions[tok_lower] then
                res_action = self.actions[tok_lower]
                action_found = true
            else
                -- 3. Проверка категорий
                local cat_matched = false
                for cat_name, cat_dict in pairs(self.categories) do
                    if res_categories[cat_name] == nil and cat_dict[tok_lower] then
                        res_categories[cat_name] = cat_dict[tok_lower]
                        cat_matched = true
                        break
                    end
                end

                if not cat_matched then
                    -- 4. Автоопределение директории
                    local is_dir_candidate = false
                    if self.detect_dir and not res_target_dir then
                        if (tok:find("^[./~]") or tok:find("/")) and grime and grime.fs and grime.fs.exists(tok) then
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
    end

    return {
        action = res_action,
        flags = res_flags,
        categories = res_categories,
        target_dir = res_target_dir,
        args = rest_args,
        command_tokens = command_tokens,
    }
end

return argparse
