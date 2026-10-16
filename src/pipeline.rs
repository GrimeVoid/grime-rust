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
const ARG_FLAGS: &[&str] = &["-arg", "--args", "-c", "-com", "--com"];
const MOD_FLAGS: &[&str] = &["-mod", "--mod"];
const SEPARATORS: &[&str] = &["--", ":", "->", "|"];

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

pub fn parse_pipeline_args(raw_args: &[String]) -> ParsedPipeline {
    let mut args: Vec<String> = crate::args::normalize_cli_flags(raw_args, crate::args::GLOBAL_GRIME_FLAGS);

    // 1. Извлечение флагов --force / -f и --detach / -d
    let mut force = false;
    if let Some(pos) = args.iter().position(|a| a == "--force" || a == "-f") {
        force = true;
        args.remove(pos);
    }

    let mut detach = false;
    if let Some(pos) = args.iter().position(|a| a == "--detach" || a == "-d") {
        detach = true;
        args.remove(pos);
    }

    // 2. Извлечение рабочего пути (-p / --path)
    let mut work_path: Option<PathBuf> = None;
    let mut tokens: Vec<String> = Vec::with_capacity(args.len());
    let mut i = 0;
    while i < args.len() {
        let token = &args[i];
        if PATH_FLAGS.contains(&token.as_str()) && i + 1 < args.len() {
            let expanded = crate::fs_ops::expand_tilde(&args[i + 1]);
            work_path = Some(expanded.into_owned());
            i += 2;
            continue;
        }
        tokens.push(token.clone());
        i += 1;
    }

    if tokens.is_empty() {
        return ParsedPipeline {
            steps: Vec::new(),
            work_path,
            force,
            detach,
        };
    }

    // Проверка начального пути (./, ../, /, ~)
    if work_path.is_none() {
        let first = &tokens[0];
        if first.starts_with("./")
            || first.starts_with("../")
            || first.starts_with('/')
            || first.starts_with('~')
        {
            let expanded = crate::fs_ops::expand_tilde(first);
            work_path = Some(expanded.into_owned());
            tokens.remove(0);
            if tokens.is_empty() {
                return ParsedPipeline {
                    steps: Vec::new(),
                    work_path,
                    force,
                    detach,
                };
            }
        }
    }

    // 3. Проверка разделителей конвейера (-- или :)
    let has_pipeline_separators = tokens.iter().any(|t| SEPARATORS.contains(&t.as_str()));
    let mut steps: Vec<PipelineStep> = Vec::new();

    if has_pipeline_separators {
        let mut sections: Vec<Vec<String>> = Vec::new();
        let mut current_section: Vec<String> = Vec::new();

        for t in tokens {
            if SEPARATORS.contains(&t.as_str()) {
                if !current_section.is_empty() {
                    sections.push(current_section);
                    current_section = Vec::new();
                }
            } else {
                current_section.push(t);
            }
        }
        if !current_section.is_empty() {
            sections.push(current_section);
        }

        for mut sec in sections {
            if sec.is_empty() {
                continue;
            }
            if MOD_FLAGS.contains(&sec[0].as_str()) && sec.len() > 1 {
                sec.remove(0);
            }

            let mod_name = canonical_module_name(&sec[0]);
            let mut mod_args: Vec<String> = Vec::new();

            for arg_tok in sec.into_iter().skip(1) {
                if ARG_FLAGS.contains(&arg_tok.as_str()) {
                    continue;
                }
                mod_args.push(arg_tok);
            }

            steps.push(PipelineStep {
                module: mod_name,
                args: mod_args,
            });
        }
    } else {
        // Режим без разделителей (одиночный модуль или legacy -a)
        let mut arg_flag_idx: Option<usize> = None;
        for (idx, t) in tokens.iter().enumerate() {
            if ARG_FLAGS.contains(&t.as_str()) {
                arg_flag_idx = Some(idx);
                break;
            }
        }

        if let Some(idx) = arg_flag_idx {
            let modules: Vec<String> = tokens[..idx]
                .iter()
                .filter(|t| !MOD_FLAGS.contains(&t.as_str()))
                .map(|t| canonical_module_name(t))
                .collect();
            let args_part: Vec<String> = tokens[idx + 1..].to_vec();

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
        } else {
            let filtered: Vec<String> = tokens
                .into_iter()
                .filter(|t| !MOD_FLAGS.contains(&t.as_str()))
                .collect();
            if !filtered.is_empty() {
                if !filtered[0].starts_with('-') {
                    let mod_name = canonical_module_name(&filtered[0]);
                    let mod_args = filtered[1..].to_vec();
                    steps.push(PipelineStep {
                        module: mod_name,
                        args: mod_args,
                    });
                }
            }
        }
    }

    ParsedPipeline {
        steps,
        work_path,
        force,
        detach,
    }
}

pub fn format_subpipeline_cli(steps: &[PipelineStep]) -> String {
    let parts: Vec<String> = steps
        .iter()
        .map(|s| {
            let mut items = vec![s.module.clone()];
            items.extend(s.args.clone());
            items
                .iter()
                .map(|arg| {
                    if arg.contains(' ') || arg.contains('\t') || arg.is_empty() {
                        format!("\"{}\"", arg.replace('\"', "\\\""))
                    } else {
                        arg.clone()
                    }
                })
                .collect::<Vec<_>>()
                .join(" ")
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
        assert_eq!(res.force, false);
        assert_eq!(res.detach, false);
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
        assert_eq!(res.detach, false);
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
        assert_eq!(res.force, true);
        assert_eq!(res.detach, false);
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
        assert_eq!(res.detach, true);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "aider");
        assert_eq!(res.steps[0].args, vec!["--message", "test"]);

        let args_long = vec![
            "--detach".to_string(),
            "cmd".to_string(),
            "make".to_string(),
        ];
        let res_long = parse_pipeline_args(&args_long);
        assert_eq!(res_long.detach, true);
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
            "~/dotfiles".to_string(),
            "aider".to_string(),
            "-m".to_string(),
            "привет".to_string(),
        ];
        let res = parse_pipeline_args(&args);
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "aider");
        assert_eq!(res.steps[0].args, vec!["-m", "привет"]);
        assert!(res.work_path.is_some());
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
        assert_eq!(res.force, true);
        assert_eq!(res.detach, true);
        assert_eq!(res.work_path, Some(PathBuf::from("/home/user/project")));
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "project");
        assert_eq!(res.steps[0].args, vec!["build"]);
    }

    #[test]
    fn test_long_pipeline_arrow_chain() {
        let args = vec![
            "pkg".to_string(), "list".to_string(),
            "->".to_string(),
            "cmd".to_string(), "grep".to_string(), "git".to_string(),
            "->".to_string(),
            "host".to_string(),
            "->".to_string(),
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
}
