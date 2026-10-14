return {
    name = "{{PROJECT_NAME}}",
    description = "{{PROJECT_DESCRIPTION}}",
    type = "lua",
    artifact = "src/main.lua",
    run = "lua src/main.lua",
    nix = { "lua5_4" },
    box = nil,
    detached = false,
}
