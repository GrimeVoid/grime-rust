return {
    name = "{{PROJECT_NAME}}",
    description = "{{PROJECT_DESCRIPTION}}",
    type = "java",
    artifact = "target/{{PROJECT_NAME}}-1.0-SNAPSHOT.jar",
    build = "mvn package",
    run = "java -jar target/{{PROJECT_NAME}}-1.0-SNAPSHOT.jar",
    nix = { "jdk17", "maven" },
    box = nil,
    detached = false,
}
