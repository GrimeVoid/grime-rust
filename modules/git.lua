-- Summary: Полноценное управление Git-репозиториями и версионированием
-- Описание: Управление Git (status, commit, log, diff, branch, checkout, init) и программный API

local ctx = grime.ctx

local ANSI = {
    BOLD = "\27[1m",
    RESET = "\27[0m",
    GREEN = "\27[32m",
    YELLOW = "\27[33m",
    RED = "\27[31m",
    CYAN = "\27[36m",
    PURPLE = "\27[35m",
    BLUE = "\27[34m",
    DIM = "\27[90m",
}

local M = {}

local function print_help()
    print(string.format([[
%s%sGrime Git%s — Полноценное управление Git-репозиториями и версионированием

%sИСПОЛЬЗОВАНИЕ:%s
    grime git <команда> [аргументы...]
    grime <директория/модуль> -> git <команда> [аргументы...]

%sКОМАНДЫ:%s
    %sstatus%s                   Форматированный статус рабочего дерева и ветки
    %scommit [сообщение]%s        Фиксация изменений (поддерживает ввод из конвейера)
    %slog [n]%s                  История коммитов в виде таблицы (по умолчанию 10)
    %sdiff [файл]%s              Просмотр незафиксированных изменений
    %sbranch [имя]%s             Список веток или создание новой ветки
    %scheckout <ветка>%s         Переключение на указанную ветку
    %sinit [путь]%s              Инициализация нового Git-репозитория
    %shelp, -h, --help%s         Показать эту справку

%sПРИМЕРЫ В КОНВЕЙЕРАХ:%s
    grime git status
    echo "feat: добавить логирование" -> grime git commit
    grime git log 5
    grime app MyTool -> git status
]],
    ANSI.BOLD, ANSI.GREEN, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.CYAN, ANSI.RESET,
    ANSI.DIM, ANSI.RESET,
    ANSI.BOLD, ANSI.RESET
    ))
end

--- Проверка, является ли директория git-репозиторием
function M.is_git_repo(dir)
    local target = dir or ctx.target_dir or "."
    local res = ctx.capture({ "git", "rev-parse", "--is-inside-work-tree" }, target)
    return res.code == 0
end

--- Инициализация Git-репозитория
function M.init(dir)
    local target = dir or ctx.target_dir or "."
    if not ctx.exists(target) then
        ctx.mkdir_p(target)
    end
    local res = ctx.capture({ "git", "init" }, target)
    if res.code == 0 then
        return { success = true, message = grime.str.trim(res.stdout or "Репозиторий инициализирован") }
    else
        return { success = false, message = grime.str.trim(res.stderr or "Ошибка git init") }
    end
end

--- Получение детального статуса Git-репозитория
function M.status(dir)
    local target = dir or ctx.target_dir or "."
    if not M.is_git_repo(target) then
        return nil, "Директория '" .. target .. "' не является Git-репозиторием"
    end

    local res = ctx.capture({ "git", "status", "--porcelain=v1", "-b" }, target)
    if res.code ~= 0 then
        return nil, grime.str.trim(res.stderr or "Ошибка выполнения git status")
    end

    local lines = grime.str.split(res.stdout or "", "\n")
    local branch_header = "unknown"
    local staged = {}
    local modified = {}
    local untracked = {}

    for _, line in ipairs(lines) do
        local l = grime.str.trim(line)
        if #l > 0 then
            if l:sub(1, 2) == "##" then
                branch_header = l:sub(4)
            elseif l:sub(1, 2) == "??" then
                table.insert(untracked, grime.str.trim(l:sub(4)))
            else
                local x = l:sub(1, 1)
                local y = l:sub(2, 2)
                local file = grime.str.trim(l:sub(3))
                if x ~= " " and x ~= "?" then
                    table.insert(staged, { flag = x, file = file })
                end
                if y ~= " " and y ~= "?" then
                    table.insert(modified, { flag = y, file = file })
                end
            end
        end
    end

    local is_clean = (#staged == 0 and #modified == 0 and #untracked == 0)
    return {
        target = target,
        branch = branch_header,
        staged = staged,
        modified = modified,
        untracked = untracked,
        is_clean = is_clean,
    }
end

--- Фиксация изменений (git add + git commit)
function M.commit(dir, msg, auto_add)
    local target = dir or ctx.target_dir or "."
    if not M.is_git_repo(target) then
        return nil, "Директория '" .. target .. "' не является Git-репозиторием"
    end

    if not msg or #grime.str.trim(msg) == 0 then
        return nil, "Сообщение коммита не может быть пустым"
    end

    local commit_msg = grime.str.trim(msg)

    if auto_add ~= false then
        local add_res = ctx.capture({ "git", "add", "-A" }, target)
        if add_res.code ~= 0 then
            return nil, "Ошибка индексации файлов: " .. (add_res.stderr or "")
        end
    end

    local commit_res = ctx.capture({ "git", "commit", "-m", commit_msg }, target)
    if commit_res.code ~= 0 then
        local out = (commit_res.stdout or "") .. " " .. (commit_res.stderr or "")
        if out:find("nothing to commit") or out:find("нечего коммитить") then
            return { success = true, no_changes = true, message = "Нет изменений для коммита" }
        end
        return nil, "Ошибка git commit: " .. grime.str.trim(out)
    end

    local hash_res = ctx.capture({ "git", "rev-parse", "--short", "HEAD" }, target)
    local hash = hash_res.code == 0 and grime.str.trim(hash_res.stdout) or "HEAD"

    return {
        success = true,
        hash = hash,
        message = commit_msg,
        output = grime.str.trim(commit_res.stdout or "")
    }
end

--- Получение структурированной истории коммитов
function M.log(dir, limit)
    local target = dir or ctx.target_dir or "."
    if not M.is_git_repo(target) then
        return nil, "Директория '" .. target .. "' не является Git-репозиторием"
    end

    local n = tonumber(limit) or 10
    local res = ctx.capture({ "git", "log", "-n", tostring(n), "--pretty=format:%h%x09%an%x09%ar%x09%s" }, target)
    if res.code ~= 0 then
        local out = (res.stderr or "") .. " " .. (res.stdout or "")
        if out:find("does not have any commits yet") or out:find("еще нет коммитов") then
            return {}
        end
        return nil, "Ошибка git log: " .. grime.str.trim(out)
    end

    local commits = {}
    local lines = grime.str.split(res.stdout or "", "\n")
    for _, l in ipairs(lines) do
        local line = grime.str.trim(l)
        if #line > 0 then
            local parts = grime.str.split(line, "\t")
            if #parts >= 4 then
                table.insert(commits, {
                    hash = parts[1],
                    author = parts[2],
                    date = parts[3],
                    message = parts[4],
                })
            end
        end
    end

    return commits
end

--- Получение diff
function M.diff(dir, file)
    local target = dir or ctx.target_dir or "."
    if not M.is_git_repo(target) then
        return nil, "Директория '" .. target .. "' не является Git-репозиторием"
    end

    local cmd = { "git", "diff" }
    if file and #file > 0 then
        table.insert(cmd, file)
    end

    local res = ctx.capture(cmd, target)
    if res.code ~= 0 then
        return nil, grime.str.trim(res.stderr or "Ошибка git diff")
    end
    return res.stdout or ""
end

--- Список или создание веток
function M.branch(dir, name)
    local target = dir or ctx.target_dir or "."
    if not M.is_git_repo(target) then
        return nil, "Директория '" .. target .. "' не является Git-репозиторием"
    end

    if name and #name > 0 then
        local res = ctx.capture({ "git", "branch", name }, target)
        if res.code == 0 then
            return { success = true, message = "Ветка '" .. name .. "' создана" }
        else
            return nil, grime.str.trim(res.stderr or "Ошибка создания ветки")
        end
    else
        local res = ctx.capture({ "git", "branch", "--list" }, target)
        if res.code ~= 0 then
            return nil, grime.str.trim(res.stderr or "Ошибка получения веток")
        end
        local branches = {}
        for _, l in ipairs(grime.str.split(res.stdout or "", "\n")) do
            local line = grime.str.trim(l)
            if #line > 0 then table.insert(branches, line) end
        end
        return branches
    end
end

--- Переключение ветки
function M.checkout(dir, branch)
    local target = dir or ctx.target_dir or "."
    if not M.is_git_repo(target) then
        return nil, "Директория '" .. target .. "' не является Git-репозиторием"
    end

    if not branch or #branch == 0 then
        return nil, "Укажите имя ветки для переключения: checkout <branch>"
    end

    local res = ctx.capture({ "git", "checkout", branch }, target)
    if res.code == 0 then
        return { success = true, message = grime.str.trim((res.stdout or "") .. " " .. (res.stderr or "")) }
    else
        return nil, grime.str.trim(res.stderr or "Ошибка переключения ветки")
    end
end

--- Главная точка входа CLI
function M.main()
    local args = ctx.args or {}
    local subcmd = args[1]

    if not subcmd or subcmd == "help" or subcmd == "-h" or subcmd == "--help" then
        print_help()
        return
    end

    local target_dir = ctx.target_dir or "."

    if subcmd == "init" then
        local path = args[2] or target_dir
        local res = M.init(path)
        if res.success then
            grime.ui.success(string.format("Git-репозиторий успешно инициализирован в: %s", path))
            ctx.success(path)
        else
            ctx.fail(res.message)
        end
        return
    end

    if subcmd == "status" then
        local st, err = M.status(target_dir)
        if not st then
            ctx.fail(err)
            return
        end

        print(string.format("\n%sРепозиторий:%s %s", ANSI.BOLD, ANSI.RESET, target_dir))
        print(string.format("%sТекущая ветка:%s %s%s%s", ANSI.BOLD, ANSI.RESET, ANSI.GREEN, st.branch, ANSI.RESET))

        if st.is_clean then
            grime.ui.success("Рабочее дерево чисто (нет изменений для фиксации)")
        else
            if #st.staged > 0 then
                print(string.format("\n%sИзменения для фиксации (индексированные):%s", ANSI.GREEN, ANSI.RESET))
                for _, f in ipairs(st.staged) do
                    print(string.format("  %s[%s] %s%s", ANSI.GREEN, f.flag, f.file, ANSI.RESET))
                end
            end

            if #st.modified > 0 then
                print(string.format("\n%sИзменения не для фиксации (измененные):%s", ANSI.YELLOW, ANSI.RESET))
                for _, f in ipairs(st.modified) do
                    print(string.format("  %s[%s] %s%s", ANSI.YELLOW, f.flag, f.file, ANSI.RESET))
                end
            end

            if #st.untracked > 0 then
                print(string.format("\n%sНеотслеживаемые файлы:%s", ANSI.RED, ANSI.RESET))
                for _, f in ipairs(st.untracked) do
                    print(string.format("  %s[?] %s%s", ANSI.RED, f, ANSI.RESET))
                end
            end
            print()
        end

        if ctx.has_next_step then
            local summary = string.format("branch:%s, staged:%d, modified:%d, untracked:%d",
                st.branch, #st.staged, #st.modified, #st.untracked)
            ctx.success(summary)
        else
            ctx.success(st.branch)
        end
        return
    end

    if subcmd == "commit" then
        local msg_tokens = {}
        for i = 2, #args do
            table.insert(msg_tokens, args[i])
        end
        local msg = table.concat(msg_tokens, " ")
        if #msg == 0 then
            msg = ctx.input or ctx.pipeline_input or ""
        end
        msg = grime.str.trim(msg)

        if #msg == 0 then
            ctx.fail("Укажите сообщение коммита: grime git commit <сообщение> или передайте через пайплайн")
            return
        end

        local res, err = M.commit(target_dir, msg, true)
        if not res then
            ctx.fail(err or "Не удалось закоммитить изменения")
            return
        end

        if res.no_changes then
            grime.ui.warn("Нет изменений для фиксации коммита.")
            ctx.success(res.message)
        else
            grime.ui.success(string.format("Коммит успешно зафиксирован [%s]: %s", res.hash, res.message))
            ctx.success(res.hash)
        end
        return
    end

    if subcmd == "log" then
        local limit = tonumber(args[2]) or 10
        local commits, err = M.log(target_dir, limit)
        if not commits then
            ctx.fail(err)
            return
        end

        if #commits == 0 then
            grime.ui.log("История коммитов пуста (нет коммитов в репозитории).")
            ctx.success("0 commits")
            return
        end

        local rows = {}
        for _, c in ipairs(commits) do
            table.insert(rows, { c.hash, c.author, c.date, c.message })
        end

        local headers = { "Хеш", "Автор", "Дата", "Сообщение" }
        print()
        grime.ui.print_table(rows, headers)
        print()

        if ctx.has_next_step then
            local lines = {}
            for _, c in ipairs(commits) do
                table.insert(lines, string.format("%s %s (%s)", c.hash, c.message, c.author))
            end
            ctx.success(table.concat(lines, "\n"))
        else
            ctx.success(tostring(#commits))
        end
        return
    end

    if subcmd == "diff" then
        local file = args[2]
        local out, err = M.diff(target_dir, file)
        if not out then
            ctx.fail(err)
            return
        end

        if #grime.str.trim(out) == 0 then
            grime.ui.log("Изменений нет (diff пуст).")
            ctx.success("")
        else
            print(out)
            ctx.success(out)
        end
        return
    end

    if subcmd == "branch" then
        local bname = args[2]
        local res, err = M.branch(target_dir, bname)
        if not res then
            ctx.fail(err)
            return
        end
        if type(res) == "table" and res.message then
            grime.ui.success(res.message)
            ctx.success(bname)
        elseif type(res) == "table" then
            print(string.format("\n%sВетки репозитория:%s", ANSI.BOLD, ANSI.RESET))
            for _, b in ipairs(res) do
                print("  " .. b)
            end
            print()
            ctx.success(table.concat(res, "\n"))
        end
        return
    end

    if subcmd == "checkout" then
        local bname = args[2]
        local res, err = M.checkout(target_dir, bname)
        if not res then
            ctx.fail(err)
            return
        end
        grime.ui.success(res.message)
        ctx.success(bname)
        return
    end

    ctx.fail("Неизвестная команда git: '" .. subcmd .. "'. Используйте 'grime git --help' для справки.")
end

-- Если модуль запускается как оркестрируемый скрипт
function main()
    M.main()
end

return M
