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

const PATH_FLAGS: &[&str] = &["-p", "-path", "--path"];
const ARG_FLAGS: &[&str] = &["--args", "-arg"];
const MOD_FLAGS: &[&str] = &["-mod", "--mod"];
const SEPARATORS: &[&str] = &[":", "|"];
use crate::args_engine::is_passthrough_separator;
use crate::modules::ModuleRegistry;

/// Сканирует преамбулу команды (глобальные флаги ядра и начальный путь до первого имени модуля).
/// Возвращает `(найден ли один из `targets`, индекс первого токена после преамбулы)`.
/// Реестр модулей не нужен: преамбула распознаётся только по флагам и пути.
fn scan_preamble(raw_args: &[String], targets: &[&str]) -> (bool, usize) {
    let mut idx = 0;
    let mut seen_work_path = false;
    let mut found = false;

    while idx < raw_args.len() {
        let tok = &raw_args[idx];
        if is_passthrough_separator(tok) {
            break;
        }
        if tok.starts_with('-') {
            let norm = crate::args::normalize_flag(tok, crate::args::GLOBAL_GRIME_FLAGS);
            if targets.contains(&norm) {
                found = true;
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
    (found, idx)
}

/// Проверяет наличие глобального флага (например `--help`/`-h` или `--version`/`-v`)
/// исключительно в преамбуле команды (до первого имени модуля).
pub fn has_preamble_flag(raw_args: &[String], targets: &[&str]) -> bool {
    scan_preamble(raw_args, targets).0
}

/// Вся команда состоит только из преамбулы (шагов конвейера нет), то есть реестр модулей
/// для разбора не нужен. Быстрый путь для `--version` / `--help` без аргументов-модулей.
pub fn is_preamble_only(raw_args: &[String]) -> bool {
    scan_preamble(raw_args, &[]).1 >= raw_args.len()
}

pub fn parse_pipeline_args(raw_args: &[String], registry: &ModuleRegistry) -> ParsedPipeline {
    let mut force = false;
    let mut detach = false;
    let mut work_path: Option<PathBuf> = None;

    // 1. Извлечение и нормализация глобальных флагов ядра ТОЛЬКО в преамбуле (до первого имени модуля)
    let mut idx = 0;
    while idx < raw_args.len() {
        let tok = &raw_args[idx];
        if is_passthrough_separator(tok) {
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
        && !is_passthrough_separator(&tokens[0])
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
                .map(|t| registry.canonical_name(t))
                .collect();
            let args_part: Vec<String> = filtered[arg_idx + 1..].to_vec();
            // Модуль по умолчанию задаётся аннотацией `--@grime default: true`;
            // если ни один не помечен, шагов нет (вызывающий код сообщит об ошибке).
            let target_modules = if modules.is_empty() {
                registry.default_module().into_iter().collect()
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

        let mod_name = registry.canonical_name(&tokens[pos]);
        pos += 1;

        let chain_passthrough = registry.get(&mod_name).is_some_and(|m| m.chain_passthrough());
        let mut mod_args: Vec<String> = Vec::new();
        let mut after_flag_sep = false;

        while pos < tokens.len() {
            let tok = &tokens[pos];

            if !after_flag_sep && is_passthrough_separator(tok) {
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
                // Для модулей с аннотацией `chain: passthrough` (например `grime app App1 : App2`)
                // токен после `:`, не являющийся существующим модулем Grime, остаётся аргументом шага.
                if tok == ":" && pos + 1 < tokens.len() && chain_passthrough {
                    let next_tok = &tokens[pos + 1];
                    let next_norm = crate::args::normalize_flag(next_tok, MOD_FLAGS);
                    if !MOD_FLAGS.contains(&next_norm) && !registry.is_known(next_tok) {
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
    fn test_is_preamble_only() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(is_preamble_only(&a(&[])));
        assert!(is_preamble_only(&a(&["--version"])));
        assert!(is_preamble_only(&a(&["-f", "-h"])));
        assert!(is_preamble_only(&a(&["-p", "/tmp"])));
        assert!(!is_preamble_only(&a(&["-v", "list"])));
        assert!(!is_preamble_only(&a(&["list", "--help"])));
        assert!(!is_preamble_only(&a(&["--args", "x"])));
    }
    use std::sync::OnceLock;

    /// Реестр на временных модулях с аннотациями (ядро не знает имён модулей).
    fn reg() -> &'static ModuleRegistry {
        static REG: OnceLock<ModuleRegistry> = OnceLock::new();
        REG.get_or_init(|| {
            let td = crate::test_support::TempDir::new("pipeline_reg");
            let dir = td.to_path_buf();
            let defs: &[(&str, &str)] = &[
                ("project", "--@grime alias: proj\n"),
                ("cmd", "--@grime alias: exec\n"),
                ("list", "--@grime alias: ls, modules\n"),
                ("host", "--@grime alias: exit-env, unhost, host-env\n--@grime boundary: true\n"),
                ("app", "--@grime chain: passthrough\n"),
                ("pkg", ""),
                ("ai", ""),
            ];
            for (n, body) in defs {
                std::fs::write(dir.join(format!("{}.lua", n)), body).unwrap();
            }
            // td удаляется после скана: реестру файлы далее не нужны
            ModuleRegistry::scan(vec![dir])
        })
    }

    #[test]
    fn test_legacy_form_uses_default_annotation() {
        let td = crate::test_support::TempDir::new("pipeline_def");
        let dir = td.to_path_buf();
        std::fs::write(dir.join("main.lua"), "--@grime default: true\n").unwrap();
        std::fs::write(dir.join("other.lua"), "").unwrap();
        let with_default = ModuleRegistry::scan(vec![dir]);
        let args = vec!["--args".to_string(), "build".to_string()];
        let res = parse_pipeline_args(&args, &with_default);
        assert_eq!(res.steps, vec![PipelineStep { module: "main".into(), args: vec!["build".into()] }]);

        // Без помеченного модуля legacy-форма даёт пустой список шагов
        let td = crate::test_support::TempDir::new("pipeline_nodef");
        let dir = td.to_path_buf();
        std::fs::write(dir.join("other.lua"), "").unwrap();
        let res = parse_pipeline_args(&args, &ModuleRegistry::scan(vec![dir]));
        assert!(res.steps.is_empty());
    }

    #[test]
    fn test_simple_module() {
        let args = vec!["cpp".to_string(), "create".to_string()];
        let res = parse_pipeline_args(&args, reg());
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
        let res = parse_pipeline_args(&args, reg());
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
        let res = parse_pipeline_args(&args, reg());
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
            "ai".to_string(),
            "--message".to_string(),
            "test".to_string(),
        ];
        let res = parse_pipeline_args(&args, reg());
        assert!(res.detach);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "ai");
        assert_eq!(res.steps[0].args, vec!["--message", "test"]);

        let args_long = vec![
            "--detach".to_string(),
            "cmd".to_string(),
            "make".to_string(),
        ];
        let res_long = parse_pipeline_args(&args_long, reg());
        assert!(res_long.detach);
        assert_eq!(res_long.steps.len(), 1);
        assert_eq!(res_long.steps[0].module, "cmd");
    }

    #[test]
    fn test_ai_unquoted_args_parsing() {
        let args = vec![
            "ai".to_string(),
            "~/dotfiles".to_string(),
            "-m".to_string(),
            "что".to_string(),
            "ты".to_string(),
            "скажешь".to_string(),
            "про".to_string(),
            "конфиг".to_string(),
            "niri?".to_string(),
        ];
        let res = parse_pipeline_args(&args, reg());
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "ai");
        assert_eq!(
            res.steps[0].args,
            vec!["~/dotfiles", "-m", "что", "ты", "скажешь", "про", "конфиг", "niri?"]
        );
    }

    #[test]
    fn test_ai_unquoted_pipeline() {
        let args = vec![
            "ai".to_string(),
            "~/dotfiles".to_string(),
            "что".to_string(),
            "ты".to_string(),
            "скажешь".to_string(),
            ":".to_string(),
            "cmd".to_string(),
            "git".to_string(),
            "status".to_string(),
        ];
        let res = parse_pipeline_args(&args, reg());
        assert_eq!(res.steps.len(), 2);
        assert_eq!(res.steps[0].module, "ai");
        assert_eq!(
            res.steps[0].args,
            vec!["~/dotfiles", "что", "ты", "скажешь"]
        );
        assert_eq!(res.steps[1].module, "cmd");
        assert_eq!(res.steps[1].args, vec!["git", "status"]);
    }

    #[test]
    fn test_ai_with_leading_path() {
        let args = vec![
            "/tmp".to_string(),
            "ai".to_string(),
            "-m".to_string(),
            "привет".to_string(),
        ];
        let res = parse_pipeline_args(&args, reg());
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "ai");
        assert_eq!(res.steps[0].args, vec!["-m", "привет"]);
        assert_eq!(res.work_path, Some(PathBuf::from("/tmp")));

        // Путь с явным разделителем ':' даже если директория не существует
        let args_colon = vec![
            "~/nonexistent_dir_xyz".to_string(),
            ":".to_string(),
            "ai".to_string(),
            "-m".to_string(),
            "привет".to_string(),
        ];
        let res_colon = parse_pipeline_args(&args_colon, reg());
        assert_eq!(res_colon.steps.len(), 1);
        assert_eq!(res_colon.steps[0].module, "ai");
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
        let res = parse_pipeline_args(&args, reg());
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
            "ai".to_string(), "-m".to_string(), "review".to_string(),
        ];
        let res = parse_pipeline_args(&args, reg());
        assert_eq!(res.steps.len(), 4);
        assert_eq!(res.steps[0].module, "pkg");
        assert_eq!(res.steps[0].args, vec!["list"]);
        assert_eq!(res.steps[1].module, "cmd");
        assert_eq!(res.steps[1].args, vec!["grep", "git"]);
        assert_eq!(res.steps[2].module, "host");
        assert_eq!(res.steps[3].module, "ai");
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
        let res_arrow = parse_pipeline_args(&args_arrow, reg());
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
        let res_colon_app = parse_pipeline_args(&args_colon_app, reg());
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
        let res_colon_mod = parse_pipeline_args(&args_colon_mod, reg());
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
        let res = parse_pipeline_args(&args, reg());
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
        let res_dash = parse_pipeline_args(&args_dash, reg());
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
        let res_slash = parse_pipeline_args(&args_slash, reg());
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
        let res_rm = parse_pipeline_args(&rm_args, reg());
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
        let res_ls = parse_pipeline_args(&ls_args, reg());
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
        let res_nmap = parse_pipeline_args(&nmap_args, reg());
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
        let res_app = parse_pipeline_args(&app_args, reg());
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
        let res_app_slash = parse_pipeline_args(&app_slash, reg());
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

    #[test]
    fn test_aliases_and_host_resolved_from_annotations() {
        for (alias, canon) in [("ls", "list"), ("modules", "list"), ("exec", "cmd"), ("proj", "project"), ("unhost", "host")] {
            let res = parse_pipeline_args(&[alias.to_string()], reg());
            assert_eq!(res.steps[0].module, canon, "{}", alias);
        }
        assert!(reg().is_boundary("exit-env"));
    }
}
