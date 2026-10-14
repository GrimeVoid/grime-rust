return {
    name = "{{PROJECT_NAME}}",
    description = "{{PROJECT_DESCRIPTION}}",
    type = "python",
    artifact = "src/main.py",
    run = "python3 src/main.py",
    nix = { "python3" },
    box = nil,
    detached = false,
}
