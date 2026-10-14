use std::collections::HashSet;
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
}

pub const HOST_ALIASES: &[&str] = &["host", "exit-env", "unhost", "host-env"];
pub const ENV_MODULES: &[&str] = &["box", "nix"];

pub const BOX_STANDALONE_ACTIONS: &[&str] = &[
    "list", "ls", "status", "ps", "create", "new", "init", "stop", "rm", "delete", "remove",
    "del", "export", "exp",
];

pub const NIX_STANDALONE_ACTIONS: &[&str] = &[
    "list",
    "ls",
    "flake",
    "f",
    "gc",
    "clean",
    "cleanup",
    "garbage-collect",
    "optimise",
    "optimize",
    "opt",
    "dedup",
    "check",
    "test",
    "validate",
    "init",
    "create",
    "new",
    "make",
    "add",
    "append",
    "in",
    "rm",
    "remove",
    "del",
    "delete",
    "install",
    "i",
    "profile-install",
    "get",
    "uninstall",
    "un",
    "remove-profile",
    "rm-profile",
    "erase",
    "help",
];

pub fn canonical_module_name(name: &str) -> String {
    let lower = name.to_lowercase();
    match lower.as_str() {
        "exec" => "cmd".to_string(),
        "proj" => "project".to_string(),
        h if HOST_ALIASES.contains(&h) => "host".to_string(),
        _ => lower,
    }
}

pub fn is_host_step(name: &str) -> bool {
    let lower = name.to_lowercase();
    HOST_ALIASES.contains(&lower.as_str())
}

pub fn is_env_wrapper_step(mod_name: &str, mod_args: &[String], has_subsequent_steps: bool) -> bool {
    let canon = canonical_module_name(mod_name);
    if !ENV_MODULES.contains(&canon.as_str()) || !has_subsequent_steps {
        return false;
    }

    let args_lower: Vec<String> = mod_args.iter().map(|a| a.to_lowercase()).collect();

    if canon == "box" {
        for a in &args_lower {
            if BOX_STANDALONE_ACTIONS.contains(&a.as_str()) {
                return false;
            }
        }
        return true;
    }

    if canon == "nix" {
        for a in &args_lower {
            if NIX_STANDALONE_ACTIONS.contains(&a.as_str()) {
                return false;
            }
        }
        return true;
    }

    false
}

pub fn parse_pipeline_args(raw_args: &[String]) -> ParsedPipeline {
    let mut args: Vec<String> = raw_args.to_vec();

    // 1. Извлечение флага --force / -f
    let mut force = false;
    if let Some(pos) = args.iter().position(|a| a == "--force" || a == "-f") {
        force = true;
        args.remove(pos);
    }

    let path_flags: HashSet<&str> = ["-p", "-path", "--path"].into_iter().collect();
    let arg_flags: HashSet<&str> = [
        "-a", "-arg", "--args", "-c", "-com", "--com",
    ]
    .into_iter()
    .collect();
    let mod_flags: HashSet<&str> = ["-mod", "--mod"].into_iter().collect();
    let separators: HashSet<&str> = ["--", ":"].into_iter().collect();

    // 2. Извлечение рабочего пути (-p / --path)
    let mut work_path: Option<PathBuf> = None;
    let mut tokens: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let token = &args[i];
        if path_flags.contains(token.as_str()) && i + 1 < args.len() {
            let path_str = shellexpand::tilde(&args[i + 1]).to_string();
            work_path = Some(PathBuf::from(path_str));
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
            let path_str = shellexpand::tilde(first).to_string();
            work_path = Some(PathBuf::from(path_str));
            tokens.remove(0);
            if tokens.is_empty() {
                return ParsedPipeline {
                    steps: Vec::new(),
                    work_path,
                    force,
                };
            }
        }
    }

    // 3. Проверка разделителей конвейера (-- или :)
    let has_pipeline_separators = tokens.iter().any(|t| separators.contains(t.as_str()));
    let mut steps: Vec<PipelineStep> = Vec::new();

    if has_pipeline_separators {
        let mut sections: Vec<Vec<String>> = Vec::new();
        let mut current_section: Vec<String> = Vec::new();

        for t in tokens {
            if separators.contains(t.as_str()) {
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
            if mod_flags.contains(sec[0].as_str()) && sec.len() > 1 {
                sec.remove(0);
            }

            let mod_name = canonical_module_name(&sec[0]);
            let mut mod_args: Vec<String> = Vec::new();

            for arg_tok in sec.into_iter().skip(1) {
                if arg_flags.contains(arg_tok.as_str()) {
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
            if arg_flags.contains(t.as_str()) {
                arg_flag_idx = Some(idx);
                break;
            }
        }

        if let Some(idx) = arg_flag_idx {
            let modules: Vec<String> = tokens[..idx]
                .iter()
                .filter(|t| !mod_flags.contains(t.as_str()))
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
                .filter(|t| !mod_flags.contains(t.as_str()))
                .collect();
            if !filtered.is_empty() {
                let mod_name = canonical_module_name(&filtered[0]);
                let mod_args = filtered[1..].to_vec();
                steps.push(PipelineStep {
                    module: mod_name,
                    args: mod_args,
                });
            }
        }
    }

    ParsedPipeline {
        steps,
        work_path,
        force,
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
        assert_eq!(res.work_path, Some(PathBuf::from("/home/user/dev")));
        assert_eq!(res.steps.len(), 1);
        assert_eq!(res.steps[0].module, "project");
        assert_eq!(res.steps[0].args, vec!["build"]);
    }

    #[test]
    fn test_env_wrapper_tail() {
        let step = PipelineStep {
            module: "box".to_string(),
            args: vec!["fedora-box".to_string()],
        };
        assert!(is_env_wrapper_step(&step.module, &step.args, true));

        let standalone_step = PipelineStep {
            module: "box".to_string(),
            args: vec!["list".to_string()],
        };
        assert!(!is_env_wrapper_step(&standalone_step.module, &standalone_step.args, true));
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
}
