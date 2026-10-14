return {
    name = "{{PROJECT_NAME}}",
    description = "{{PROJECT_DESCRIPTION}}",
    type = "cpp",
    artifact = "build/{{PROJECT_NAME}}",
    build = "cmake -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build",
    run = "build/{{PROJECT_NAME}}",
    nix = { "cmake", "ninja", "gcc" },
    box = nil,
    detached = false,
}
