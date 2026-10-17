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

    local target_dir = ctx.input or ctx.pipeline_input or ctx.target_dir or "."

    local os_str = "Linux"
    if ctx.exists("/etc/os-release") then
        local content = grime.fs.read("/etc/os-release") or ""
        local pretty = content:match('PRETTY_NAME="([^"]+)"') or content:match("PRETTY_NAME=([^\r\n]+)")
        if pretty then os_str = pretty end
    end

    local hostname_str = "localhost"
    local res_h = ctx.capture("hostname")
    if res_h and res_h.code == 0 and res_h.stdout and #res_h.stdout > 0 then
        hostname_str = grime.str.trim(res_h.stdout)
    end

    local host_info = string.format("OS: %s\nHost: %s\nTarget: %s", os_str, hostname_str, target_dir)

    if ctx.has_next_step then
        ctx.module_return(host_info)
    else
        print(host_info)
        ctx.module_return(target_dir)
    end
end
