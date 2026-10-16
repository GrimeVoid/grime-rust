return {
    name = "gluebench",
    description = "Полиглотный IPC бенчмарк клей",
    type = "generic",
    artifact = "consumer",
    build = "gcc -O3 -march=native consumer.c -o consumer",
    run = "./consumer",
    nix = {
        packages = { "gcc", "python3" },
    },
    detached = false,
}
