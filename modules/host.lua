local ctx = grime.ctx

local function print_help()
    print(string.format([[
%s%sGrime Host%s — Сброс и возврат контекста исполнения на хост-систему

%sИСПОЛЬЗОВАНИЕ:%s
    grime <шаг_в_контейнере> : host : <шаг_на_хосте>
    grime host [help|-h|--help]

%sОПИСАНИЕ:%s
    Используется в конвейерах Grime для возврата контекста на хост после
    выполнения шагов внутри контейнера Distrobox или изолированного devShell.
    Передает полученный путь директории или текущий target_dir дальше по конвейеру.

%sПРИМЕР В КОНВЕЙЕРЕ:%s
    grime box run fedora-box ninja : host : cmd git status
]],
    "\27[1m", "\27[32m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m",
    "\27[1m", "\27[0m"
    ))
end

function main()
    for _, a in ipairs(ctx.args or {}) do
        if a == "--help" or a == "-h" or a == "help" then
            print_help()
            return
        end
    end

    local target_dir = ctx.pipeline_input or ctx.target_dir
    if ctx.has_next_step then
        ctx.module_return(target_dir)
    end
end
