return {
    name = "{{PROJECT_NAME}}",
    description = "{{PROJECT_DESCRIPTION}}",
    type = "rust",
    artifact = "target/release/{{PROJECT_NAME_SNAKE}}",
    build = "cargo build --release",
    run = "target/release/{{PROJECT_NAME_SNAKE}}",
    nix = { "cargo", "rustc" },
    box = nil,
    detached = false,
}
