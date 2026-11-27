---
name: grime
description: Работа с оркестратором Grime (project, app, pkg, nix, box, git, ai, doctor, конвейеры через ":"). Используй при сборке, запуске, управлении проектами, пакетами и контейнерами вместо голого shell.
---

# Grime Orchestration System: Skill Guide for AI Agents

You are operating inside an execution system orchestrated by **Grime**, a modular command-line pipeline and project lifecycle manager (Rust core + Lua 5.4 modules). Grime handles infrastructure, build systems, tooling environments, and modular pipelines. The up-to-date help for every module is `grime <module> --help`.

---

## 1. Syntax rules

- All actions and flags start with `-` or `--` (`-list`, `-build`, `-run`, `-path`, `-rm`). A token without a dash is a positional argument (project name, path, message), so names like `test` or `run` are never mistaken for commands.
- Pipelines join steps with `:` (never `->`: in Fish it is a file redirection). Each step forwards its working directory, its return value, and bus data to the next one.
- `//` (or `--`) passes the rest of the command to an external program untouched: `grime cmd // echo -n "x"`.
- Global flags before the first module: `-f` (ignore step errors), `-d` (run as a daemon background task), `-p <path>` (base directory).

```bash
grime project MyApp -path : git -status : cmd cargo test
```

### Multi-agent pipeline interaction
1. **Intermediate agent (`ctx.has_next_step`).** If you are a preparatory step (architect/planner), wrap the master-prompt for the next agent in a tag; Grime passes its content on as input:
   ```markdown
   <next_agent_prompt>
   [precise requirements or architecture for the next agent]
   </next_agent_prompt>
   ```
2. **Final agent (`ctx.is_last_step`).** Answer directly, without `<next_agent_prompt>`.
3. **No shell injection.** Do not print fake terminal commands to run things. Grime controls build, test, and module execution. Executable tags (`<grime_spawn>`, `<grime_exec>`) are allowed only where the task explicitly asks for them, and are checked: `<grime_spawn>` is limited to the modules `ai`, `cmd`, `app`, `project`, `nix`, `git`, `doctor`, `list`, `log`, and destructive flags (`-rm`, `-clear`, `-rollback`, `-gc`, `-force`, ...) are rejected.

### Environment switching
`box` (Distrobox) and `nix` (Nix devShell) declare `wraps: pipeline`: the steps after them run inside that environment. The `host` module is the boundary that returns execution to the host:

```bash
grime project MyApp -path : box fedora-box : project -build : cmd pytest : host : project -run
grime project MyApp -path : nix : project -build
```

---

## 2. Modules

Fourteen modules: `project`, `app`, `pkg`, `ai`, `nix`, `box`, `host`, `git`, `list`, `log`, `bus`, `daemon`, `doctor`, `cmd`. The core knows nothing about them: names, aliases, descriptions, boundaries, default paths, and dependencies are declared by each module in `--@grime key: value` annotations in its header (see `documentation.md`).

### `project` (alias `proj`, default module)
Languages: C++, Rust, Python, Java, Lua, Bash, Fish.
```bash
grime project init cpp MyGame        # or: grime project rust Tool -init
grime project -list [lang] [filter]
grime project -build MyGame
grime project -run MyGame [-- args]  # auto-rebuild when sources changed
grime project -path MyGame           # fuzzy: exact, prefix, substring, similarity
grime project --rename Old New
grime project -rm MyGame --yes       # exact name only; confirmation or --yes
grime project --clear MyGame --yes   # reset to the clean template
```

### `app` (local micro-apps)
```bash
grime app -new <name> [-lang <lang>] "description"
grime app -run <name> [args]  [-d]   # -d: background
grime app -ps | -stop <name> [-9]
grime app -build | -flake | -bundle | -path | -rm <name>
grime app -compile <target> [command_name]   # into apps + symlink in ~/.local/bin
grime app -commit | -log | -diff | -snapshot | -status | -rollback <name>
```

### `pkg` (package management)
```bash
grime pkg                              # summary of active managers
grime pkg <manager> [-l] [-a] [filter] # host(pacman), yay, flatpak, nix, distrobox, apps, cargo, pipx
grime pkg <name>                       # fuzzy search across managers
grime pkg -i <manager> <pkg>           # the manager must be named explicitly
grime pkg -rm <manager> <pkg>
grime pkg -u [manager]
grime pkg -run <tool> [args]           # local -> Distrobox -> ephemeral Nix
```

### `nix`
`-build`, `-init` (persistent `flake.nix` with toolchain auto-detection), `-enter`, `-run <cmd>`, `-history`, `-rollback [--to N]`, `-update`, `-bundle`, `-diff`, `-install`, `-uninstall`, `-gc`, `-optimise`, `-check`; flags `--force`, `--pure`.

### `box`
`-list`, `-enter`, `-run <container> <cmd>`, `-create <name> [--image ...]`, `-stop`, `-rm`, `-export [name] --app <app> | --bin <path>`. The default container is the `distrobox_default` config key.

### `host`
Boundary that returns the rest of the pipeline to the host (aliases `exit-env`, `unhost`, `host-env`).

### `git`
`-status`, `-commit [msg]`, `-log [N]`, `-diff`, `-branch`, `-checkout`, `-ls-files`, `-snapshot [msg]`, `-add`, `-init`.

### `cmd` (alias `exec`)
Runs an arbitrary command in the pipeline's working directory: `grime project MyGame -path : cmd git status`.

### `list`, `log`, `bus`, `daemon`, `doctor`
- `grime list [-modules|-apps|-projects]` — overview of the ecosystem.
- `grime log -list [n] | -errors [n] | -git | -clear | -add <level> <msg>`.
- `grime bus -get|-set|-has|-rm|-list|-emit` — shared state; keys need a namespace (`build.ready`).
- `grime daemon -status|-ping|-start|-stop|-restart|-feed|-dump|-clear`.
- `grime doctor` — diagnostics; `grime doctor -fix [-dry] [-yes]` — AI repair (the script is shown in full with SHA-256 and runs only after an interactive "y").

### `ai`
Orchestrates the **Claude Code** and **Aider** agents (adapters in `modules/agents/`).
```bash
grime ai [-claude|-aider|-agent <name>] [project] [files...] ["prompt"]
grime ai -claude -m "headless prompt"
grime ai -app <name> [-lang <lang>] "prompt"      # create an app
grime ai -module <name> "prompt"                  # create/improve a Grime module
grime project MyApp -path : ai -aider "Refactor CMake"
```
Agent choice: flag, then bus key `modules.ai.agent`, then config key `ai_agent`, then the first available (`claude`, `aider`).

---

## 3. Writing or changing a module (for `ai -module`)

- File: `<modules dir>/<name>.lua`. Start with annotations: `--@grime description: ...`, optional `alias`, `requires`, `boundary`, `wraps: pipeline`, `chain: passthrough`, `default`, `path.<name>`.
- Return a table: `return { main = main, cleanup = cleanup }` (`wrap_pipeline(args, rest_argv)` for environment modules).
- Use `ctx.parse_args(spec)` for arguments (every flag starts with `-`), `ctx.capture`/`ctx.run_process` for processes, `ctx.fail(msg)`/`ctx.success()`/`ctx.module_return(data)` to finish. Never call `os.exit` or `io.popen`.
- Temporary files and directories: `grime.ephemeral.dir()` / `grime.ephemeral.file()`, never `/tmp`.
- Core API: `grime.ctx`, `grime.fs`, `grime.process`, `grime.bus`, `grime.events`, `grime.modules`, `grime.ephemeral`, `grime.args`, `grime.fuzzy`, `grime.json`, `grime.msgpack`, `grime.str`, `grime.table`, `grime.ui`, `grime.time`, `grime.config`, `grime.paths`. Details are in `documentation.md`.
- Check it with `GRIME_MODULES=<dir> grime <name> --help`.
