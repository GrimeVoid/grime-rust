**[ 🇬🇧 English ](README.en.md) • [ 🇷🇺 Русский ](README.md)**

# GRIME (Next Generation / Grime-RS) 🦀🌙

[![Release: v1.1.0](https://img.shields.io/badge/Release-v1.1.0-blue.svg)](https://github.com/ValetJk010/Grime_Project/releases/tag/v1.1.0)
[![Language: Rust](https://img.shields.io/badge/Language-Rust%202021-orange.svg?logo=rust)](https://www.rust-lang.org/)
[![Runtime: LuaJIT](https://img.shields.io/badge/Runtime-LuaJIT%20%2F%20mlua-blue.svg?logo=lua)](https://luajit.org/)
[![Ecosystem: Nix Flakes](https://img.shields.io/badge/Ecosystem-Nix%20Flakes-5277C3.svg?logo=nixos)](https://nixos.org/)
[![Containers: Distrobox](https://img.shields.io/badge/Containers-Distrobox%20%2F%20Podman-purple.svg)](https://distrobox.it/)
[![Startup: 2.8 ms](https://img.shields.io/badge/Cold%20Start-2.8%20ms-brightgreen.svg)]()
[![Socket Latency: 1.1 ms](https://img.shields.io/badge/Latency-1.1%20ms%20(Socket)-brightgreen.svg)]()
[![License: Dual Non-Commercial / Commercial](https://img.shields.io/badge/License-Dual%20Personal%20%2F%20Commercial-blue.svg)](LICENSE)

> **High-performance system orchestrator for projects, containers, and ephemeral Nix environments bridging native Rust and embedded LuaJIT.**  
> **The Ephemeral-First Manifest: The Host OS is sacred and immaculate. Just run it.**

**GRIME** fundamentally rethinks how developers interact with their operating system, build toolchains, and package dependencies. It eliminates the "works on my machine" syndrome, compiler fragmentation, and container bloat. GRIME unifies the mathematical reproducibility of **Nix Flakes**, the flexibility of isolated **Distrobox** containers, and the raw speed of a native **Rust** core into a single declarative data pipeline with sub-millisecond response latency.

Starting with **v1.1.0**, the GRIME core has evolved into a **Production-Grade Resilient Microkernel**. All domain business logic, language adapters, and build cascades reside purely in declarative LuaJIT dynamic modules, leaving the native Rust core focused strictly on lifecycle management, asynchronous pipelining, task supervision, IPC, and uncompromising execution safety.

---

## 🌟 The Ephemeral-First Philosophy

Traditional Linux system administration and software development practices are obsolete:
- Constant `sudo pacman -S`, `apt install`, or global `pip install` commands inevitably turn the host operating system into a dumping ground of incompatible libraries, conflicting Python/GCC/LLVM toolchains, and orphaned packages.
- Package removals leave leftover debris in `/usr/lib`, `/var`, and system configuration directories.
- Host state deteriorates over time into an irreproducible snowflake.

### 🛡️ The GRIME Paradigm: The Immaculate Host
In the GRIME ecosystem, the host operating system remains **crystal-clean and minimal**:
1. **Zero Global Compilers**: You no longer need GCC 14, Clang 19, Rust, OpenJDK 21, Python 3.12, CMake, or Ninja permanently installed on the host.
2. **On-the-Fly Ephemeral Toolchains**: The intelligent scanner automatically determines project requirements and builds code inside an isolated Nix environment that vanishes immediately after compilation.
3. **Hermetic Sandboxing**: Any task demanding a distinct software environment is dispatched into an ephemeral Nix sandbox or an isolated Distrobox container.
4. **Host Sovereignty**: Microkernel protection barriers guarantee that no pipeline step can ever compromise or contaminate critical host partitions (`/`, `/usr`, `/etc`, `/nix`).

---

## ⚡ The "Just Run" Principle (Zero-Friction Execution)

The premier practical manifestation of GRIME's Ephemeral-First philosophy is **Zero-Friction Execution**:

### 1. Interactive Fish Shell Hook (`command-not-found`)
Need a utility for a one-off task (`cmatrix`, `cbonsai`, `figlet`, `cava`, `ffmpeg`, `htop`, `ripgrep`, `jq`, `graphviz`)?  
Simply type its name directly in your terminal:

```text
> cmatrix
[Grime] Command 'cmatrix' not found on host.
Available in Nixpkgs. Run inside isolated environment? [Y/n]: y
```
- Press **Enter** (or `Y`), and the utility launches instantly inside an isolated ephemeral Nix sandbox.
- **Zero Host Installation!** Once you exit, the host system remains spotless.
- Want to run directly without interactive prompts? Use `grime pkg run cmatrix` or pass `--yes`.

### 2. Full Interactive TUI & Native PTY Inheritance (`Stdio::inherit`)
Powered by the Grime-RS v1.1.0 native microkernel with canonical standard stream descriptor inheritance:
- Interactive pseudo-terminal and TUI applications (`cava`, `btop`, `nvim`, `less`, `cmatrix`) render flawlessly with full 24-bit TrueColor, mouse event support, and zero I/O latency.

### 3. Intelligent Command Mappings & Fuzzy Matching
- **Smart Package Resolution**: When a command binary name differs from its Nixpkgs package attribute (e.g., `uname` is packaged inside `coreutils`, `xargs` inside `findutils`), GRIME's built-in mapping database transparently resolves the correct package.
- **Damerau-Levenshtein Typo Detection (`grime.fuzzy`)**: If you misspell a command (`carg` instead of `cargo`), GRIME instantly suggests the closest match among installed utilities:
  ```text
  [Grime] Command 'carg' not found.
  💡 Did you mean: cargo?
  ```

---

## 🎯 Technology Stack

| Component | Technology | Rationale |
| :--- | :--- | :--- |
| **System Microkernel** | **Rust (Edition 2021)**, Tokio, mlua | Complete type safety, zero-cost abstractions, zero garbage collection pauses, and minimal memory footprint (~4–6 MB RAM at idle). Cold start ~2.8 ms. |
| **Scripting Engine** | **LuaJIT FFI / mlua** | Instant module logic execution, sandbox security, and hot-reload support without restarting daemon processes. |
| **Hermetic Environments** | **Nixpkgs / Nix Flakes** | Mathematically reproducible dependencies, hard-link level deduplication, and zero host contamination. |
| **Containerization** | **Distrobox / Podman / Docker** | Seamless integration with any Linux distribution (Fedora, Ubuntu, Arch, Alpine) with shared X11/Wayland, PipeWire, and sockets. |
| **Inter-Process Communication** | **Unix Domain Sockets (UDS)** + StateBus | 1.1 ms roundtrip latency between CLI client and background daemon, DoS/OOM protection (strict 32 MB message limit), and zero-copy binary buffer passing (`bytes::Bytes`). |

---

## ⚡ Key Architectural Capabilities

### 1. Ephemeral Development Toolchains (Auto-Toolchain)
GRIME liberates developers from configuring build environments manually. The built-in scanner [`languages/scanner.lua`](modules/languages/scanner.lua) and shared toolchain utilities [`languages/utils.lua`](modules/languages/utils.lua) analyze project source trees (C++, Rust, Python, Java, Lua, Go) and build configurations (`CMakeLists.txt`, `Cargo.toml`, `Makefile`, `pom.xml`):
- Automatically synthesizes an exact compilation graph and populates `nativeBuildInputs`.
- Seamlessly fuses the auto-discovered toolchain with custom system libraries declared in `app.lua` via `special_dependencies = { "openssl", "raylib", "boost" }`.
- Projects build and run with `grime project build` and `grime project run` without needing compilers installed on the host!

### 2. Zero Dirty Tree Guarantee
Project builds execute in isolated Nix environments without polluting the repository root:
- Synthesizes ephemeral Flake definitions inside user cache (`~/.cache/grime/flakes/<hash>/`).
- Leaves zero stray `flake.nix`, `flake.lock`, or `.direnv` files in your working directory.
- Guarantees build reproducibility on any machine equipped with Nix.

### 3. Microservice & Polyglot Application Orchestration (`grime app`)
GRIME provides complete lifecycle management for microservices and polyglot bundles:
- Declarative definitions in compact `app.lua` manifests.
- Daemon supervision: background execution (`--detach`), PID tracking, lifecycle monitoring, and structured log capture.
- Polyglot workflows: e.g., high-performance C++ compute engine wrapped by Python analysis scripts communicating over streams or IPC.

### 4. Self-Contained Standalone Executables (`grime app bundle`)
The `grime app bundle <app>` command generates self-sufficient portable binaries in `dist/`:
- Bundles all runtime dependencies (including glibc, Python runtime, dynamic libraries, and assets) into a unified portable executable.
- The resulting binary runs on any standard Linux distribution without requiring Nix, compilers, or system libraries.

### 5. Seamless Multi-Environment Pipelines (Host ↔ Distrobox ↔ Nix)
GRIME allows constructing cross-environment pipelines executed in a single command:
```bash
grime project cpp init MyGame : box fedora-box : project build : host : project run
```
- Pipeline stages are delimited by colons `:`.
- Seamlessly forwards execution context, environment variables, and file descriptors across environment boundaries.
- The boundary module `host` cleanly returns execution context back to the host system.

### 6. StateBus Shared State (`grime bus`) and Dual Audit (Git + Nix)
- **StateBus**: Thread-safe in-memory key-value bus in daemon RAM for passing metadata between pipeline stages without brittle stdout parsing. Features RAII automatic cleanup of `pipeline.*` namespaces upon completion and persistent state storage.
- **Dual Audit**: The `grime app diff <app>` command simultaneously audits source code diffs via `git diff` and closure structural deviations via `nix store diff-closures`.
- **Snapshots & Rollbacks**: Instant versioning with `grime app snapshot <app> "revision"` and atomic `grime app rollback <app>`.

### 7. Hardened Resilient Microkernel (v1.1.0)
The native Grime-RS core introduces critical operational-level protections:
- **IPC DoS & OOM Guard**: Strict 32 MB payload limit on socket framing, instantly preventing corrupted or malicious stream payloads from exhausting host RAM.
- **Intelligent Task Supervisor (`TaskSupervisor`)**:
  - Long build protection (`is_step_active`): ensures that active compilation steps or multi-minute pipeline phases do not trigger false watchdog timeouts.
  - Automatic task cleanup (1-hour Retention Policy) preventing memory and file descriptor exhaustion over long daemon uptimes.
  - Mutex Poison Recovery: thread panics automatically recover shared state without bringing down the resident daemon `grimed`.
- **Filesystem Sovereignty & Path Protection**: Strict blocking of destructive operations on critical system hierarchies (`/`, `/etc`, `/usr`, `/nix`, `/var`, `/boot`, `/root`). Enforced symlink safety on permission changes (`chmod`) prevents symlink dereference attacks and privilege escalation.
- **Stack Overflow Guard**: Enforced traversal depth limit (`max_depth = 64`) when serializing complex Lua tables to JSON, preventing stack overflows on cyclic structures.

---

## 🏗️ System Architecture

```mermaid
flowchart TD
    subgraph ClientLayer ["CLI & Shell Interface"]
        CLI["grime (CLI Client / Rust)"]
        Fish["Fish Shell (Pipelines ':' & CNF Hook)"]
    end

    subgraph CoreLayer ["Native Rust Microkernel (grimed / in-process)"]
        UDS["Unix Domain Socket (/run/user/UID/grime.sock)"]
        IPCGuard["IPC DoS & OOM Guard (32 MB Limit)"]
        Router["Pipeline Dispatcher & Async Engine (Tokio)"]
        Supervisor["TaskSupervisor (is_step_active & Retention)"]
        FSGuard["FS Sovereign Guard (System Path Protect)"]
        StateBus["Shared StateBus (RAM Zero-Copy)"]
    end

    subgraph LuaLayer ["LuaJIT Dynamic Modules (~/.config/grime/modules/)"]
        M_App["app.lua (Lifecycle & Bundling)"]
        M_Proj["project.lua (Build Cascades)"]
        M_Nix["nix.lua (Ephemeral Flakes)"]
        M_Box["box.lua (Distrobox Warmup)"]
        M_Pkg["pkg.lua (Meta Pkg, Fuzzy & CNF)"]
        M_Aider["aider.lua (AI Coding Agent)"]
        M_Scan["languages/scanner.lua & utils.lua"]
    end

    subgraph Targets ["Execution Environments"]
        HostOS["Host OS (Arch / Linux)"]
        NixEnv["Nix Ephemeral DevShell / Flake"]
        DBox["Distrobox Containers (Fedora / Ubuntu)"]
    end

    Fish --> CLI
    CLI -->|UDS IPC| UDS
    UDS --> IPCGuard
    IPCGuard --> Router
    Router --> Supervisor
    Router --> FSGuard
    Router --> StateBus
    Router --> LuaLayer
    LuaLayer --> Targets
```

---

## 📊 Performance & System Metrics

Measured latency benchmarks and system overhead:

| Metric | Value | Description & Benchmark Conditions |
| :--- | :--- | :--- |
| **CLI Cold Start (`grime`)** | **`~2.8 ms`** | From binary execution to LuaJIT VM initialization and pipeline parsing |
| **Daemon Socket Roundtrip** | **`1.1 ms`** | Full request-response cycle over Unix Domain Socket |
| **Idle Memory Footprint** | **`4–6 MB`** | Resident Set Size (RSS) of the background `grimed` microkernel |
| **Ephemeral Flake Synthesis** | **`< 15 ms`** | Project hashing, toolchain synthesis, and devShell caching |
| **IPC Message Limit** | **`32 MB`** | Hardware and memory guard against OOM and socket stream attacks |

---

## 🚀 Quick Start

### 1. Build and Installation

#### Via Nix Flake (Recommended Hermetic Method):
```bash
# Build static binary with zero external runtime dependencies:
nix build .#static

# Or enter ready-to-use development shell:
nix develop
```

#### Standard Cargo Build:
```bash
cargo build --release
```
Compiled binaries will be available at:
- `target/release/grime` — Ultra-fast CLI client.
- `target/release/grimed` — Resident background daemon.

Install into user `PATH`:
```bash
cp target/release/grime target/release/grimed ~/.local/bin/
```

### 2. Launch Background Daemon (Optional)
```bash
# Start service in the background:
grimed --daemon

# Verify core health and module availability:
grime doctor
```
*(If the daemon is not running, `grime` automatically executes pipelines locally in-process without loss of features).*

---

## 💡 Real-World Scenarios

### 1. Ephemeral Utility Execution Without Installation:
```bash
# One-time execution of an interactive TUI in Nix isolation:
grime pkg run cmatrix

# Run with auto-confirmation flag:
grime pkg run --yes ffmpeg -version
```

### 2. Build C++ Project via Auto-Toolchain in Ephemeral Nix Flake:
```bash
# Intelligent cascade: CMakeLists.txt -> Makefile -> direct g++/clang++
grime project cpp init FastService
grime nix build FastService
grime project run FastService
```

### 3. Seamless Pipeline Across Environments and Containers:
```bash
# Create project -> Build in Fedora container -> Return to host -> Run
grime project rust MicroCli : box fedora-box : project build : host : project run
```

### 4. Creating and Supervising a Microservice:
```bash
# Initialize service from template
grime app new telemetry-agent --lang rust

# Launch in background with PID supervision
grime app run telemetry-agent --detach

# Inspect all active running services
grime app list

# Stop service
grime app stop telemetry-agent
```

### 5. Packaging Polyglot App into Standalone Portable Binary:
```bash
# Compile C++ core, bundle Python runtime and all dependencies into dist/polyapp
grime app bundle polyapp

# Execute self-contained portable bundle on any Linux machine:
./apps/polyapp/dist/polyapp
```

### 6. Pipeline Coordination via StateBus:
```bash
grime bus set build.target "release-v2" : log INFO "Flag set" : bus get build.target
```

---

## 📝 Application Manifest Specification (`app.lua`)

Each isolated application or microservice is declared via an `app.lua` manifest:

```lua
return {
    -- Application identification
    name = "compute-worker",
    version = "1.0.0",
    description = "High-performance analytics worker",
    type = "polyglot", -- cpp, rust, python, java, polyglot, generic

    -- Build instructions and output artifact
    build = "g++ -O3 src/engine.cpp -o engine",
    artifact = "engine",
    run = "./engine",
    sources = { "src/engine.cpp", "scripts/analyzer.py" },

    -- Auto-toolchain and specific Nixpkgs dependencies
    special_dependencies = {
        "openssl",
        "boost",
        "python3"
    },

    -- Background daemon settings
    detached = false,
    env = {
        LOG_LEVEL = "info",
        WORKER_THREADS = "4"
    }
}
```

---

## 🛠️ Extension Modules Overview

The repository contains declarative LuaJIT modules (`modules/`), each implementing a specialized domain:

- [`modules/pkg.lua`](modules/pkg.lua) — Unified multi-package manager (Pacman, Flatpak, Nix, Distrobox, Cargo), smart command mappings, fuzzy typo detection, and interactive Command-Not-Found.
- [`modules/app.lua`](modules/app.lua) — Full application lifecycle, background supervision, Git snapshots, Nix closure auditing, and standalone bundling.
- [`modules/project.lua`](modules/project.lua) — Developer source project orchestration, fuzzy directory lookup, and mtime-based rebuild checks.
- [`modules/languages/`](modules/languages/) — Compiler and build adapters for C++, Rust, Python, Java with smart structural scanner [`scanner.lua`](modules/languages/scanner.lua) and shared build helpers [`utils.lua`](modules/languages/utils.lua).
- [`modules/nix.lua`](modules/nix.lua) — Declarative and ephemeral Nix Flake/DevShell environments, garbage collection (`gc`), deduplication (`optimise`), generation history, and rollback.
- [`modules/box.lua`](modules/box.lua) — Orchestration and command execution inside isolated Distrobox containers, container app/binary exports.
- [`modules/daemon.lua`](modules/daemon.lua) — Control and inspection of the background `grimed` service: memory usage, socket health, graceful restarts, and diagnostic logging.
- [`modules/aider.lua`](modules/aider.lua) — Direct integration of the Aider autonomous AI coding assistant into Grime pipelines.
- [`modules/bus.lua`](modules/bus.lua) — Inter-stage StateBus shared memory.
- [`modules/git.lua`](modules/git.lua) — High-level Git repository operations, change audits, and atomic snapshots.
- [`modules/doctor.lua`](modules/doctor.lua) — Deep diagnostic inspection of available host and container utilities.
- [`modules/log.lua`](modules/log.lua) — Structured system logging.
- [`modules/host.lua`](modules/host.lua) — Pipeline boundary module cleanly returning execution back to host OS.
- [`modules/cmd.lua`](modules/cmd.lua) — Fallback module for executing isolated ad-hoc shell commands.

---

## 🐚 Shell Compatibility & Fish Shell Integration

### 1. Pipeline Syntax
GRIME pipelines utilize colons `:` as the universal stage delimiter:
```fish
grime host : bus set system.mode production : git status : log INFO "Audit complete"
```
> **Fish Shell Note:** Using `:` prevents token interception by Fish Shell (as `->` is treated as a file redirection operator in Fish).

### 2. Enabling Command-Not-Found in Fish Shell
Connecting the shell hook transforms Fish into a self-resolving development environment powered by the "Just Run" philosophy:

```fish
# Create hook function in Fish Shell (~/.config/fish/functions/fish_command_not_found.fish):
function fish_command_not_found
    grime pkg not-found $argv
end
```
Any command not found on the host will now be handled by GRIME:
1. Instant lookup in Flatpak, Grime Apps, Cargo, and Nix profile.
2. If indexed in Nixpkgs — prompt for isolated execution `[Y/n]` with full interactive TUI support.
3. If misspelled — instant Did-You-Mean suggestion using Levenshtein distance.

---

## 📄 License

Distributed under the **[GRIME Dual License](LICENSE)**:
- **Personal, Educational, and Research Use:** 100% Free, Perpetual, and Unrestricted ([PolyForm Noncommercial 1.0](LICENSE)).
- **Commercial Use:** 1% Royalty on gross revenue, with a generous $50,000/year exemption threshold for indie developers and early startups.

Full terms and legal text are available in [LICENSE](LICENSE).  
Author: **ValetJk010**
