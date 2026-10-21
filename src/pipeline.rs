use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct PipelineStep {
    pub module: String,
    pub args: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct ParsedPipeline {
    pub steps: Vec<PipelineStep>,
    pub work_path: Option<PathBuf>,
    pub force: bool,
    pub detach: bool,
}

pub const HOST_ALIASES: &[&str] = &["host", "exit-env", "unhost", "host-env"];

const PATH_FLAGS: &[&str] = &["-p", "-path", "--path"];
const ARG_FLAGS: &[&str] = &["--args", "-arg"];
const MOD_FLAGS: &[&str] = &["-mod", "--mod"];
const SEPARATORS: &[&str] = &[":", "|"];
const FLAG_SEPARATORS: &[&str] = &["--", "//"];

const BUILTIN_MODULE_NAMES: &[&str] = &[
    "exec", "proj", "ls", "modules", "project", "pkg", "app", "box", "nix", "aider", "cmd",
    "host", "list", "doctor", "bus", "daemon", "git", "log",
];

/// Динамическое сканирование директорий модулей Grime на диске
pub fn discover_available_modules(config: &crate::config::GrimeConfig) -> Vec<String> {
    let mut modules = Vec::new();
    let mut search_dirs = Vec::new();
    search_dirs.push(PathBuf::from("modules"));
    search_dirs.push(config.modules_dir());
    if let Some(home) = crate::fs_ops::get_cached_home_dir() {
        search_dirs.push(home.join(".config").join("grime").join("modules"));
        search_dirs.push(home.join("dotfiles").join("grime").join("modules"));
    }
    if let Ok(exe_p) = std::env::current_exe() {
        if let Some(parent) = exe_p.parent() {
            search_dirs.push(parent.join("../share/grime/modules"));
            search_dirs.push(parent.join("modules"));
        }
    }

    for dir in search_dirs {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) == Some("lua") {
                    if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                        let name = stem.to_string();
                        if !modules.contains(&name) {
                            modules.push(name);
                        }
                    }
                }
            }
        }
    }
    modules.sort();
    modules
}

static MODULES_CACHE: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();

pub fn cached_available_modules() -> &'static [String] {
    MODULES_CACHE.get_or_init(|| {
        let config = crate::config::GrimeConfig::load_or_default(None);
        discover_available_modules(&config)
    })
}

/// Проверяет, является ли токен известным именем (или алиасом) модуля Grime
pub fn is_known_module(name: &str) -> bool {
    if name.is_empty() || name.starts_with('-') {
        return false;
    }
    let lower = name.to_lowercase();
    if BUILTIN_MODULE_NAMES.contains(&lower.as_str()) || HOST_ALIASES.contains(&lower.as_str()) {
        return true;
    }
    let available = cached_available_modules();
    available.iter().any(|s| s == &lower)
}

pub fn canonical_module_name(name: &str) -> String {
    let lower = name.to_lowercase();
    let alias_resolved = match lower.as_str() {
        "exec" => "cmd".to_string(),
        "proj" => "project".to_string(),
        "ls" | "modules" => "list".to_string(),
        h if HOST_ALIASES.contains(&h) => "host".to_string(),
        _ => lower,
    };

    let available = cached_available_modules();
    if available.iter().any(|s| s == &alias_resolved) {
        return alias_resolved;
    }

    let available_refs: Vec<&str> = available.iter().map(|s| s.as_str()).collect();
    if let Some(matched) = crate::args::fuzzy_match_entity(&alias_resolved, &available_refs, 0.75) {
        return matched.to_string();
    }

    alias_resolved
}

pub fn is_host_step(name: &str) -> bool {
    let lower = name.to_lowercase();
    HOST_ALIASES.contains(&lower.as_str())
}

/// Проверяет наличие глобального флага (например `--help`/`-h` или `--version`/`-v`)
/// исключительно в преамбуле команды (до первого имени модуля).
pub fn has_preamble_flag(raw_args: &[String], targets: &[&str]) -> bool {
    let mut idx = 0;
    let mut seen_work_path = false;

    while idx < raw_args.len() {
        let tok = &raw_args[idx];
        if FLAG_SEPARATORS.contains(&tok.as_str()) {
            break;
        }
        if tok.starts_with('-') {
            let norm = crate::args::normalize_flag(tok, crate::args::GLOBAL_GRIME_FLAGS);
            if targets.contains(&norm) {
                return true;
            }
            if PATH_FLAGS.contains(&norm) {
                idx += 2;
                seen_work_path = true;
                continue;
            }
            if matches!(
                norm,
                "--force" | "-f" | "--detach" | "-d" | "--help" | "-h" | "--version" | "-v"
            ) {
                idx += 1;
                continue;
            }
            break;
        }
        if !seen_work_path
            && (tok.starts_with("./")
                || tok.starts_with("../")
                || tok.starts_with('/')
                || tok.starts_with('~'))
        {
            let expanded = crate::fs_ops::expand_tilde(tok);
            let followed_by_colon = idx + 1 < raw_args.len() && raw_args[idx + 1] == ":";
            if expanded.is_dir() || followed_by_colon {
                seen_work_path = true;
                idx += if followed_by_colon { 2 } else { 1 };
                continue;
            }
        }
        break;
    }
    false
}

pub fn parse_pipeline_args(raw_args: &[String]) -> ParsedPipeline {
    let mut force = false;
    let mut detach = false;
    let mut work_path: Option<PathBuf> = None;

    // 1. Извлечение и нормализация глобальных флагов ядра ТОЛЬКО в преамбуле (до первого имени модуля)
    let mut idx = 0;
    while idx < raw_args.len() {
        let tok = &raw_args[idx];
        if FLAG_SEPARATORS.contains(&tok.as_str()) {
            break;
        }

        if tok.starts_with('-') {
            let norm = crate::args::normalize_flag(tok, crate::args::GLOBAL_GRIME_FLAGS);
            if norm == "--force" || norm == "-f" {
                force = true;
                idx += 1;
                continue;
            }
            if norm == "--detach" || norm == "-d" {
                detach = true;
                idx += 1;
                continue;
            }
            if PATH_FLAGS.contains(&norm) {
                if idx + 1 < raw_args.len() {
                    let expanded = crate::fs_ops::expand_tilde(&raw_args[idx + 1]);
                    work_path = Some(expanded.into_owned());
                    idx += 2;
                } else {
                    idx += 1;
                }
                continue;
            }
            if norm == "--help" || norm == "-h" || norm == "--version" || norm == "-v" {
                idx += 1;
                continue;
            }
            // Любой другой флаг (например -mod, --args) завершает преамбулу
            break;
        }

        // Проверка начального пути (./, ../, /, ~): только если это существующая директория или за ним следует ':'
        if work_path.is_none()
            && (tok.starts_with("./")
                || tok.starts_with("../")
                || tok.starts_with('/')
                || tok.starts_with('~'))
        {
            let expanded = crate::fs_ops::expand_tilde(tok);
            let followed_by_colon = idx + 1 < raw_args.len() && raw_args[idx + 1] == ":";
            if expanded.is_dir() || followed_by_colon {
                work_path = Some(expanded.into_owned());
                idx += 1;
                if followed_by_colon {
                    idx += 1;
                }
                continue;
            }
        }

        // Достигли первого имени модуля
        break;
    }

    let tokens = &raw_args[idx..];
    if tokens.is_empty() {
        return ParsedPipeline {
            steps: Vec::new(),
            work_path,
            force,
            detach,
        };
    }

    let mut steps: Vec<PipelineStep> = Vec::new();

    // Поддержка legacy-режима, когда команда начинается с флага (например `--args build`) без разделителей
    let first_norm = crate::args::normalize_flag(&tokens[0], crate::args::GLOBAL_GRIME_FLAGS);
    if tokens[0].starts_with('-')
        && !FLAG_SEPARATORS.contains(&tokens[0].as_str())
        && !MOD_FLAGS.contains(&first_norm)
        && !tokens.iter().any(|t| SEPARATORS.contains(&t.as_str()))
    {
        let filtered: Vec<String> = tokens
            .iter()
            .filter(|t| !MOD_FLAGS.contains(&t.as_str()))
            .cloned()
            .collect();

        if let Some(arg_idx) = filtered.iter().position(|t| ARG_FLAGS.contains(&t.as_str())) {
            let modules: Vec<String> = filtered[..arg_idx]
                .iter()
                .map(|t| canonical_module_name(t))
                .collect();
            let args_part: Vec<String> = filtered[arg_idx + 1..].to_vec();
            let target_modules = if modules.is_empty() {
                vec!["project".to_string()]
            } else {
                modules
            };
            for m in target_modules {
                steps.push(PipelineStep {
                    module: m,
                    args: args_part.clone(),
                });
            }
        }
        return ParsedPipeline {
            steps,
            work_path,
            force,
            detach,
        };
    }

    // 2. Пошаговый разбор конвейера
    let mut pos = 0;
    while pos < tokens.len() {
        while pos < tokens.len() && SEPARATORS.contains(&tokens[pos].as_str()) {
            pos += 1;
        }
        if pos >= tokens.len() {
            break;
        }

        // MOD_FLAGS (-mod, --mod) обрабатывается ТОЛЬКО если это первый токен шага
        let first_step_norm = crate::args::normalize_flag(&tokens[pos], MOD_FLAGS);
        if MOD_FLAGS.contains(&first_step_norm) && pos + 1 < tokens.len() {
            pos += 1;
        }

        let mod_name = canonical_module_name(&tokens[pos]);
        pos += 1;

        let mut mod_args: Vec<String> = Vec::new();
        let mut after_flag_sep = false;

        while pos < tokens.len() {
            let tok = &tokens[pos];

            if !after_flag_sep && FLAG_SEPARATORS.contains(&tok.as_str()) {
                after_flag_sep = true;
                mod_args.push(tok.clone());
                pos += 1;
                continue;
            }

            // После `--` или `//` токены не подвергаются normalize_cli_flags и не разбиваются по разделителям
            if after_flag_sep {
                mod_args.push(tok.clone());
                pos += 1;
                continue;
            }

            if SEPARATORS.contains(&tok.as_str()) {
                // Если в `grime app App1 : App2` токен после `:` не является существующим модулем Grime,
                // передаём `:` и `App2` в аргументы текущего шага `app`.
                if mod_name == "app" && tok == ":" && pos + 1 < tokens.len() {
                    let next_tok = &tokens[pos + 1];
                    let next_norm = crate::args::normalize_flag(next_tok, MOD_FLAGS);
                    if !MOD_FLAGS.contains(&next_norm) && !is_known_module(next_tok) {
                        mod_args.push(tok.clone());
                        pos += 1;
                        continue;
                    }
                }
                pos += 1;
                break;
            }

            mod_args.push(tok.clone());
            pos += 1;
        }

        steps.push(PipelineStep {
            module: mod_name,
            args: mod_args,
        });
    }

    ParsedPipeline {
        steps,
        work_path,
        force,
        detach,
    }
}

/// Надёжное экранирование отдельного аргумента для безопасной передачи в POSIX shell
pub fn shell_escape_arg(arg: &str) -> String {
    if !arg.is_empty()
        && arg.bytes().all(|b| {
            b.is_ascii_alphanumeric()
                || matches!(b, b'-' | b'_' | b'.' | b'/' | b'=' | b'+' | b'@')
        })
    {
        arg.to_string()
    } else {
        format!("'{}'", arg.replace('\'', "'\\''"))
    }
}

pub fn format_subpipeline_cli(steps: &[PipelineStep]) -> String {
    let parts: Vec<String> = steps
        .iter()
        .map(|s| {
            let mut items = Vec::with_capacity(1 + s.args.len());
            items.push(shell_escape_arg(&s.module));
            for arg in &s.args {
                items.push(shell_escape_arg(arg));
            }
            items.join(" ")
        })
        .collect();

    parts.join(" : ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_simple_module() {
        let args = vec!["cpp".to_string(), "create".to_string()];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "cpp");
        assert_eq!(res.steps[0].args, vec!["create"]);
        assert!(!res.force);
        assert!(!res.detach);
        assert_eq!(res.work_path, None);
    }

    #[test]
    fn test_pipeline_separators() {
        let args = vec![
            "project".to_string(),
            "MyGame".to_string(),
            ":".to_string(),
            "cmd".to_string(),
            "git".to_string(),
            "status".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 2);
        assert_eq!(res.steps[0].module, "project");
        assert_eq!(res.steps[0].args, vec!["MyGame"]);
        assert_eq!(res.steps[1].module, "cmd");
        assert_eq!(res.steps[1].args, vec!["git", "status"]);
        assert!(!res.detach);
    }

    #[test]
    fn test_path_flag_and_force() {
        let args = vec![
            "-p".to_string(),
            "/home/user/dev".to_string(),
            "-f".to_string(),
            "proj".to_string(),
            "build".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert!(res.force);
        assert!(!res.detach);
        assert_eq!(res.work_path, Some(PathBuf::from("/home/user/dev")));
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "project");
        assert_eq!(res.steps[0].args, vec!["build"]);
    }

    #[test]
    fn test_detach_flag_parsing() {
        let args = vec![
            "-d".to_string(),
            "aider".to_string(),
            "--message".to_string(),
            "test".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert!(res.detach);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "aider");
        assert_eq!(res.steps[0].args, vec!["--message", "test"]);

        let args_long = vec![
            "--detach".to_string(),
            "cmd".to_string(),
            "make".to_string(),
        ];
        let res_long = parse_pipeline_args(&args_long);
        assert!(res_long.detach);
        assert_eq!(res_long.steps.len(), 1);
        assert_eq!(res_long.steps[0].module, "cmd");
    }

    #[test]
    fn test_aider_unquoted_args_parsing() {
        let args = vec![
            "aider".to_string(),
            "~/dotfiles".to_string(),
            "-m".to_string(),
            "что".to_string(),
            "ты".to_string(),
            "скажешь".to_string(),
            "про".to_string(),
            "конфиг".to_string(),
            "niri?".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "aider");
        assert_eq!(
            res.steps[0].args,
            vec!["~/dotfiles", "-m", "что", "ты", "скажешь", "про", "конфиг", "niri?"]
        );
    }

    #[test]
    fn test_aider_unquoted_pipeline() {
        let args = vec![
            "aider".to_string(),
            "~/dotfiles".to_string(),
            "что".to_string(),
            "ты".to_string(),
            "скажешь".to_string(),
            ":".to_string(),
            "cmd".to_string(),
            "git".to_string(),
            "status".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 2);
        assert_eq!(res.steps[0].module, "aider");
        assert_eq!(
            res.steps[0].args,
            vec!["~/dotfiles", "что", "ты", "скажешь"]
        );
        assert_eq!(res.steps[1].module, "cmd");
        assert_eq!(res.steps[1].args, vec!["git", "status"]);
    }

    #[test]
    fn test_aider_with_leading_path() {
        let args = vec![
            "/tmp".to_string(),
            "aider".to_string(),
            "-m".to_string(),
            "привет".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "aider");
        assert_eq!(res.steps[0].args, vec!["-m", "привет"]);
        assert_eq!(res.work_path, Some(PathBuf::from("/tmp")));

        // Путь с явным разделителем ':' даже если директория не существует
        let args_colon = vec![
            "~/nonexistent_dir_xyz".to_string(),
            ":".to_string(),
            "aider".to_string(),
            "-m".to_string(),
            "привет".to_string(),
        ];
        let res_colon = parse_pipeline_args(&args_colon);
        assert_eq!(res_colon.steps.len(), 1);
        assert_eq!(res_colon.steps[0].module, "aider");
        assert!(res_colon.work_path.is_some());
    }

    #[test]
    fn test_fuzzy_global_flags() {
        let args = vec![
            "--forc".to_string(),
            "--detch".to_string(),
            "--pth".to_string(),
            "/home/user/project".to_string(),
            "project".to_string(),
            "build".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert!(res.force);
        assert!(res.detach);
        assert_eq!(res.work_path, Some(PathBuf::from("/home/user/project")));
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "project");
        assert_eq!(res.steps[0].args, vec!["build"]);
    }

    #[test]
    fn test_long_pipeline_colon_and_pipe_chain() {
        let args = vec![
            "pkg".to_string(), "list".to_string(),
            ":".to_string(),
            "cmd".to_string(), "grep".to_string(), "git".to_string(),
            "|".to_string(),
            "host".to_string(),
            ":".to_string(),
            "aider".to_string(), "-m".to_string(), "review".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 4);
        assert_eq!(res.steps[0].module, "pkg");
        assert_eq!(res.steps[0].args, vec!["list"]);
        assert_eq!(res.steps[1].module, "cmd");
        assert_eq!(res.steps[1].args, vec!["grep", "git"]);
        assert_eq!(res.steps[2].module, "host");
        assert_eq!(res.steps[3].module, "aider");
        assert_eq!(res.steps[3].args, vec!["-m", "review"]);
    }

    #[test]
    fn test_app_chaining_arrows_and_colons() {
        // 1. Цепочка микросервисов через '->' передается внутрь модуля app
        let args_arrow = vec![
            "app".to_string(),
            "App1".to_string(),
            "->".to_string(),
            "App2".to_string(),
        ];
        let res_arrow = parse_pipeline_args(&args_arrow);
        assert_eq!(res_arrow.steps.len(), 1);
        assert_eq!(res_arrow.steps[0].module, "app");
        assert_eq!(res_arrow.steps[0].args, vec!["App1", "->", "App2"]);

        // 2. Цепочка через ':', когда App2 не является модулем Grime
        let args_colon_app = vec![
            "app".to_string(),
            "App1".to_string(),
            ":".to_string(),
            "App2".to_string(),
        ];
        let res_colon_app = parse_pipeline_args(&args_colon_app);
        assert_eq!(res_colon_app.steps.len(), 1);
        assert_eq!(res_colon_app.steps[0].module, "app");
        assert_eq!(res_colon_app.steps[0].args, vec!["App1", ":", "App2"]);

        // 3. Конструкция `grime app App1 : cmd ls`, где `cmd` — реальный модуль Grime
        let args_colon_mod = vec![
            "app".to_string(),
            "App1".to_string(),
            ":".to_string(),
            "cmd".to_string(),
            "ls".to_string(),
        ];
        let res_colon_mod = parse_pipeline_args(&args_colon_mod);
        assert_eq!(res_colon_mod.steps.len(), 2);
        assert_eq!(res_colon_mod.steps[0].module, "app");
        assert_eq!(res_colon_mod.steps[0].args, vec!["App1"]);
        assert_eq!(res_colon_mod.steps[1].module, "cmd");
        assert_eq!(res_colon_mod.steps[1].args, vec!["ls"]);
    }

    #[test]
    fn test_pkg_not_found_with_flag_c() {
        let args = vec![
            "pkg".to_string(),
            "not-found".to_string(),
            "--no-confirm".to_string(),
            "tty-clock".to_string(),
            "-C".to_string(),
            "4".to_string(),
            "-c".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "pkg");
        assert_eq!(
            res.steps[0].args,
            vec!["not-found", "--no-confirm", "tty-clock", "-C", "4", "-c"]
        );
    }

    #[test]
    fn test_pkg_not_found_with_double_dash_and_double_slash() {
        let args_dash = vec![
            "pkg".to_string(),
            "not-found".to_string(),
            "--no-confirm".to_string(),
            "--".to_string(),
            "tty-clock".to_string(),
            "-C".to_string(),
            "4".to_string(),
            "-c".to_string(),
        ];
        let res_dash = parse_pipeline_args(&args_dash);
        assert_eq!(res_dash.steps.len(), 1);
        assert_eq!(res_dash.steps[0].module, "pkg");
        assert_eq!(
            res_dash.steps[0].args,
            vec!["not-found", "--no-confirm", "--", "tty-clock", "-C", "4", "-c"]
        );

        let args_slash = vec![
            "pkg".to_string(),
            "not-found".to_string(),
            "--no-confirm".to_string(),
            "//".to_string(),
            "tty-clock".to_string(),
            "-f".to_string(),
            "-d".to_string(),
            ":".to_string(),
            "cmd".to_string(),
        ];
        let res_slash = parse_pipeline_args(&args_slash);
        assert!(!res_slash.force);
        assert!(!res_slash.detach);
        assert_eq!(res_slash.steps.len(), 1);
        assert_eq!(res_slash.steps[0].module, "pkg");
        assert_eq!(
            res_slash.steps[0].args,
            vec!["not-found", "--no-confirm", "//", "tty-clock", "-f", "-d", ":", "cmd"]
        );
    }

    #[test]
    fn test_subcommand_flags_not_stolen_by_kernel() {
        // 1. grime cmd rm -f a
        let rm_args = vec![
            "cmd".to_string(),
            "rm".to_string(),
            "-f".to_string(),
            "a".to_string(),
        ];
        let res_rm = parse_pipeline_args(&rm_args);
        assert!(!res_rm.force, "Ядро не должно красть -f у модуля cmd");
        assert_eq!(res_rm.steps.len(), 1);
        assert_eq!(res_rm.steps[0].module, "cmd");
        assert_eq!(res_rm.steps[0].args, vec!["rm", "-f", "a"]);

        // 2. grime cmd ls -d dir
        let ls_args = vec![
            "cmd".to_string(),
            "ls".to_string(),
            "-d".to_string(),
            "dir".to_string(),
        ];
        let res_ls = parse_pipeline_args(&ls_args);
        assert!(!res_ls.detach, "Ядро не должно красть -d у модуля cmd");
        assert_eq!(res_ls.steps.len(), 1);
        assert_eq!(res_ls.steps[0].module, "cmd");
        assert_eq!(res_ls.steps[0].args, vec!["ls", "-d", "dir"]);

        // 3. grime pkg run nmap -p 80
        let nmap_args = vec![
            "pkg".to_string(),
            "run".to_string(),
            "nmap".to_string(),
            "-p".to_string(),
            "80".to_string(),
        ];
        let res_nmap = parse_pipeline_args(&nmap_args);
        assert_eq!(res_nmap.work_path, None, "Ядро не должно красть -p у модуля pkg");
        assert_eq!(res_nmap.steps.len(), 1);
        assert_eq!(res_nmap.steps[0].module, "pkg");
        assert_eq!(res_nmap.steps[0].args, vec!["run", "nmap", "-p", "80"]);

        // 4. grime app run foo -- -d
        let app_args = vec![
            "app".to_string(),
            "run".to_string(),
            "foo".to_string(),
            "--".to_string(),
            "-d".to_string(),
        ];
        let res_app = parse_pipeline_args(&app_args);
        assert!(!res_app.detach, "Ядро не должно красть -d после --");
        assert_eq!(res_app.steps.len(), 1);
        assert_eq!(res_app.steps[0].module, "app");
        assert_eq!(res_app.steps[0].args, vec!["run", "foo", "--", "-d"]);

        // 5. grime app run foo // -d -f -p /tmp
        let app_slash = vec![
            "app".to_string(),
            "run".to_string(),
            "foo".to_string(),
            "//".to_string(),
            "-d".to_string(),
            "-f".to_string(),
            "-p".to_string(),
            "/tmp".to_string(),
        ];
        let res_app_slash = parse_pipeline_args(&app_slash);
        assert!(!res_app_slash.detach);
        assert!(!res_app_slash.force);
        assert_eq!(res_app_slash.work_path, None);
        assert_eq!(
            res_app_slash.steps[0].args,
            vec!["run", "foo", "//", "-d", "-f", "-p", "/tmp"]
        );
    }

    #[test]
    fn test_format_subpipeline_cli_escaping() {
        let steps = vec![
            PipelineStep {
                module: "project".to_string(),
                args: vec!["build".to_string()],
            },
            PipelineStep {
                module: "cmd".to_string(),
                args: vec![
                    "sh".to_string(),
                    "-c".to_string(),
                    "echo 'hello $USER' && ls \"a b\"".to_string(),
                ],
            },
        ];
        let formatted = format_subpipeline_cli(&steps);
        assert_eq!(
            formatted,
            "project build : cmd sh -c 'echo '\\''hello $USER'\\'' && ls \"a b\"'"
        );
    }
}
