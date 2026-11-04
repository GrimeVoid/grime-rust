//! Единый нативный движок парсинга аргументов командной строки ядра Grime-RS.
//!
//! Предоставляет общие функции классификации токенов, разделителей конвейера (`//` и `--`),
//! булевых флагов, флагов со значением (`--key=value` и `--key value`), действий (`actions`),
//! категорий (`categories`), автоопределения директорий и нечёткого сопоставления (`fuzzy`).

use std::collections::HashMap;

/// Спецификация правил парсинга, передаваемая модулем или преамбулой ядра.
#[derive(Debug, Clone)]
pub struct ArgSpec {
    /// Словарь канонических действий и их синонимов: {"list": "list", "ls": "list", "l": "list"}
    pub actions: HashMap<String, String>,
    /// Действие по умолчанию, если ни одно действие не было явно распознано
    pub default_action: Option<String>,
    /// Булевы флаги: {"force": ["-f", "--force"], "all": ["-a", "--all"]}
    pub flags: HashMap<String, Vec<String>>,
    /// Флаги со значением: {"lang": ["-l", "--lang"], "limit": ["-n", "--limit"]}
    pub value_flags: HashMap<String, Vec<String>>,
    /// Категории: {"language": {"rust": "rust", "rs": "rust", "py": "python"}}
    pub categories: HashMap<String, HashMap<String, String>>,
    /// Автоматически определять существующую директорию среди позиционных аргументов
    pub detect_dir: bool,
    /// Порог нечёткого сопоставления (Jaro-Winkler) для флагов (по умолчанию 0.75)
    pub fuzzy_threshold: f64,
    /// Разрешать ли нераспознанным флагам с '-' попадать в позиционные args
    pub allow_unknown_flags: bool,
    /// Список действий, для которых все последующие токены и флаги пробрасываются дочерней команде
    pub passthrough_actions: Vec<String>,
}

impl Default for ArgSpec {
    fn default() -> Self {
        Self {
            actions: HashMap::new(),
            default_action: None,
            flags: HashMap::new(),
            value_flags: HashMap::new(),
            categories: HashMap::new(),
            detect_dir: false,
            fuzzy_threshold: 0.75,
            allow_unknown_flags: false,
            passthrough_actions: vec![
                "run".to_string(),
                "exec".to_string(),
                "export".to_string(),
                "create".to_string(),
            ],
        }
    }
}

/// Значение флага в результате парсинга
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlagValue {
    Bool(bool),
    Str(String),
}

/// Результат работы нативного парсера аргументов
#[derive(Debug, Clone, Default)]
pub struct ParsedArgs {
    /// Распознанное каноническое действие (или default_action)
    pub action: Option<String>,
    /// Карта значений всех флагов (булевых и строковых)
    pub flags: HashMap<String, FlagValue>,
    /// Распознанные значения по каждой категории
    pub categories: HashMap<String, String>,
    /// Обнаруженная целевая директория (если detect_dir = true)
    pub target_dir: Option<String>,
    /// Очищенные позиционные аргументы (до разделителя '//' или '--')
    pub args: Vec<String>,
    /// Аргументы после разделителя '//' или '--' (для прямой передачи внешней утилите)
    pub command_tokens: Vec<String>,
    /// Список нераспознанных флагов, начинающихся с '-'
    pub unknown_flags: Vec<String>,
    /// Был ли явно встречен разделитель '//' или '--'
    pub has_passthrough_separator: bool,
}

/// Проверяет, является ли токен разделителем сквозного проброса аргументов (`"--"` или `"//"`).
#[inline]
pub fn is_passthrough_separator(token: &str) -> bool {
    token == "--" || token == "//"
}

/// Разделяет срез токенов по первому разделителю `"//"` или `"--"` на:
/// `(tokens_before, command_tokens, has_separator)`.
pub fn split_passthrough(tokens: &[String]) -> (Vec<String>, Vec<String>, bool) {
    let mut tokens_before = Vec::new();
    let mut command_tokens = Vec::new();
    let mut found_sep = false;

    for tok in tokens {
        if !found_sep && is_passthrough_separator(tok) {
            found_sep = true;
        } else if found_sep {
            command_tokens.push(tok.clone());
        } else {
            tokens_before.push(tok.clone());
        }
    }

    (tokens_before, command_tokens, found_sep)
}

/// Проверяет, начинается ли токен с `'-'`, имеет длину `> 1` и не является `"--"`.
#[inline]
pub fn is_dash_token(token: &str) -> bool {
    token.starts_with('-') && token.len() > 1 && token != "--"
}

/// Срезает ведущие символы `'-'` из токена.
#[inline]
pub fn strip_dashes(token: &str) -> &str {
    token.trim_start_matches('-')
}

/// Основной конвейер разбора и классификации токенов по спецификации `ArgSpec`.
pub fn parse_tokens(
    spec: &ArgSpec,
    raw_args: &[String],
    _default_target_dir: Option<&str>,
) -> ParsedArgs {
    let (tokens_before, command_tokens, has_separator) = split_passthrough(raw_args);

    let mut res_flags: HashMap<String, FlagValue> = HashMap::new();
    for flag_name in spec.flags.keys() {
        res_flags.insert(flag_name.clone(), FlagValue::Bool(false));
    }

    let mut res_categories: HashMap<String, String> = HashMap::new();
    let mut res_action: Option<String> = spec.default_action.clone();
    let mut action_found = false;
    let mut res_target_dir: Option<String> = None;
    let mut rest_args: Vec<String> = Vec::new();
    let mut unknown_flags: Vec<String> = Vec::new();

    let mut i = 0;
    while i < tokens_before.len() {
        let tok = &tokens_before[i];
        let tok_lower = tok.to_lowercase();
        let is_dash = is_dash_token(tok);
        let stripped = if is_dash {
            strip_dashes(&tok_lower)
        } else {
            ""
        };

        // 1. Проверка режима сквозного проброса:
        // Если action входит в passthrough_actions (напр. "run" или "exec") и уже встречен хотя бы 1 позиционный аргумент
        let in_passthrough_cmd = res_action.as_ref().is_some_and(|act| {
            spec.passthrough_actions.iter().any(|p| p == act)
        }) && !rest_args.is_empty();

        if in_passthrough_cmd {
            rest_args.push(tok.clone());
            i += 1;
            continue;
        }

        let mut flag_matched = false;

        // 2. Проверка флагов со значением (value_flags): --flag=val или --flag val
        for (vname, patterns) in &spec.value_flags {
            for pat in patterns {
                let pat_low = pat.to_lowercase();
                let pat_stripped = strip_dashes(&pat_low);

                // Формат --flag=val
                if let Some((prefix, val)) = tok.split_once('=') {
                    let prefix_low = prefix.to_lowercase();
                    let prefix_stripped = strip_dashes(&prefix_low);
                    if prefix_low == pat_low
                        || (!prefix_stripped.is_empty() && prefix_stripped == pat_stripped)
                    {
                        res_flags.insert(vname.clone(), FlagValue::Str(val.to_string()));
                        flag_matched = true;
                        break;
                    }
                } else if tok_lower == pat_low
                    || (!stripped.is_empty() && stripped == pat_stripped)
                {
                    // Формат --flag val
                    if i + 1 < tokens_before.len() {
                        i += 1;
                        res_flags.insert(vname.clone(), FlagValue::Str(tokens_before[i].clone()));
                    } else {
                        res_flags.insert(vname.clone(), FlagValue::Bool(true));
                    }
                    flag_matched = true;
                    break;
                }
            }
            if flag_matched {
                break;
            }
        }

        // 3. Проверка точного совпадения булевых флагов (flags)
        if !flag_matched {
            for (flag_name, patterns) in &spec.flags {
                for pat in patterns {
                    let pat_low = pat.to_lowercase();
                    let pat_stripped = strip_dashes(&pat_low);
                    if tok == pat
                        || tok_lower == pat_low
                        || (!stripped.is_empty() && stripped == pat_stripped)
                    {
                        res_flags.insert(flag_name.clone(), FlagValue::Bool(true));
                        flag_matched = true;

                        // Если этот же токен одновременно является действием и действие еще не выбрано
                        let act_cand = spec
                            .actions
                            .get(&tok_lower)
                            .or_else(|| {
                                if !stripped.is_empty() {
                                    spec.actions.get(stripped)
                                } else {
                                    None
                                }
                            });
                        if let Some(act) = act_cand {
                            if !action_found {
                                res_action = Some(act.clone());
                                action_found = true;
                            }
                        }
                        break;
                    }
                }
                if flag_matched {
                    break;
                }
            }
        }

        // 4. Если токен начинается с '-': проверка действий и категорий со знаком минус (-action, --action, -cat)
        if !flag_matched && is_dash && !stripped.is_empty() {
            // Сначала проверяем категории со знаком минус (-cpp, --rust, -pacman)
            for (cat_name, cat_dict) in &spec.categories {
                if !res_categories.contains_key(cat_name) {
                    if let Some(canonical) = cat_dict
                        .get(&tok_lower)
                        .or_else(|| cat_dict.get(stripped))
                    {
                        res_categories.insert(cat_name.clone(), canonical.clone());
                        flag_matched = true;
                        break;
                    }
                }
            }

            // Затем проверяем действия со знаком минус (-list, --build, -update)
            if !flag_matched {
                if let Some(act_target) = spec
                    .actions
                    .get(&tok_lower)
                    .or_else(|| spec.actions.get(stripped))
                {
                    if !action_found {
                        res_action = Some(act_target.clone());
                        action_found = true;
                    } else {
                        res_flags.insert(act_target.clone(), FlagValue::Bool(true));
                    }
                    flag_matched = true;
                }
            }
        }

        // 5. Нечёткое сопоставление (fuzzy match) для токенов с '-'
        if !flag_matched && is_dash {
            // 5.1. Поиск среди булевых флагов
            let mut pattern_to_flag: Vec<(&str, &str)> = Vec::new();
            for (flag_name, patterns) in &spec.flags {
                for pat in patterns {
                    pattern_to_flag.push((pat.as_str(), flag_name.as_str()));
                }
            }
            let candidates: Vec<&str> = pattern_to_flag.iter().map(|(p, _)| *p).collect();
            if let Some(matched_pat) =
                crate::args::fuzzy_match_flag(tok, &candidates, spec.fuzzy_threshold)
            {
                if let Some((_, flag_name)) =
                    pattern_to_flag.iter().find(|(p, _)| *p == matched_pat)
                {
                    res_flags.insert(flag_name.to_string(), FlagValue::Bool(true));
                    flag_matched = true;
                }
            }

            // 5.2. Нечёткое сопоставление действий со знаком минус (для флагов >= 3 символов)
            if !flag_matched && !action_found && stripped.chars().count() >= 3 {
                let mut act_keys: Vec<&str> = Vec::new();
                for k in spec.actions.keys() {
                    let clean_k = strip_dashes(k);
                    if clean_k.chars().count() >= 3 && !act_keys.contains(&clean_k) {
                        act_keys.push(clean_k);
                    }
                }
                if let Some(best_act) = crate::args::fuzzy_match_entity(stripped, &act_keys, 0.82) {
                    if let Some(act_target) = spec
                        .actions
                        .get(best_act)
                        .or_else(|| spec.actions.get(&format!("-{}", best_act)))
                    {
                        res_action = Some(act_target.clone());
                        action_found = true;
                        flag_matched = true;
                    }
                }
            }
        }

        // 6. Изоляция нераспознанных флагов с '-'
        if !flag_matched && is_dash {
            unknown_flags.push(tok.clone());
            let is_passthrough_action = res_action.as_ref().is_some_and(|act| {
                spec.passthrough_actions.iter().any(|p| p == act)
            });
            if spec.allow_unknown_flags || is_passthrough_action {
                rest_args.push(tok.clone());
            }
            flag_matched = true;
        }

        // 7. Токены без знака минус
        if !flag_matched {
            // 7.1. Проверка действий без минуса
            if !action_found && spec.actions.contains_key(&tok_lower) {
                res_action = Some(spec.actions[&tok_lower].clone());
                action_found = true;
            } else {
                // 7.2. Проверка категорий без минуса
                let mut cat_matched = false;
                for (cat_name, cat_dict) in &spec.categories {
                    if !res_categories.contains_key(cat_name) {
                        if let Some(canonical) = cat_dict.get(&tok_lower) {
                            res_categories.insert(cat_name.clone(), canonical.clone());
                            cat_matched = true;
                            break;
                        }
                    }
                }

                if !cat_matched {
                    // 7.3. Автоопределение существующей директории
                    let mut is_dir_candidate = false;
                    if spec.detect_dir && res_target_dir.is_none() {
                        let is_path_like = tok.starts_with("./")
                            || tok.starts_with('/')
                            || tok.starts_with('~')
                            || tok.contains('/');
                        if is_path_like {
                            let expanded = crate::fs_ops::expand_tilde(tok);
                            if expanded.is_dir() {
                                res_target_dir = Some(tok.clone());
                                is_dir_candidate = true;
                            }
                        }
                    }

                    if !is_dir_candidate {
                        // 7.4. Обычный позиционный аргумент
                        rest_args.push(tok.clone());
                    }
                }
            }
        }

        i += 1;
    }

    // res_target_dir заполняется ТОЛЬКО если в аргументах был обнаружен явный путь.
    // Если пути в аргументах не было, target_dir остается None, чтобы модуль мог отличить явный ввод от контекста.

    ParsedArgs {
        action: res_action,
        flags: res_flags,
        categories: res_categories,
        target_dir: res_target_dir,
        args: rest_args,
        command_tokens,
        unknown_flags,
        has_passthrough_separator: has_separator,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_split_passthrough() {
        let tokens = vec![
            "project".to_string(),
            "build".to_string(),
            "--".to_string(),
            "--release".to_string(),
            "-j4".to_string(),
        ];
        let (before, cmd, has_sep) = split_passthrough(&tokens);
        assert_eq!(before, vec!["project", "build"]);
        assert_eq!(cmd, vec!["--release", "-j4"]);
        assert!(has_sep);

        let slash_tokens = vec![
            "cmd".to_string(),
            "//".to_string(),
            "echo".to_string(),
            "hello".to_string(),
        ];
        let (before2, cmd2, has_sep2) = split_passthrough(&slash_tokens);
        assert_eq!(before2, vec!["cmd"]);
        assert_eq!(cmd2, vec!["echo", "hello"]);
        assert!(has_sep2);

        let no_sep = vec!["app".to_string(), "list".to_string()];
        let (before3, cmd3, has_sep3) = split_passthrough(&no_sep);
        assert_eq!(before3, vec!["app", "list"]);
        assert!(cmd3.is_empty());
        assert!(!has_sep3);
    }

    #[test]
    fn test_is_dash_and_strip() {
        assert!(is_dash_token("-f"));
        assert!(is_dash_token("--force"));
        assert!(!is_dash_token("-"));
        assert!(!is_dash_token("--"));
        assert!(!is_dash_token("init"));

        assert_eq!(strip_dashes("--build"), "build");
        assert_eq!(strip_dashes("-b"), "b");
        assert_eq!(strip_dashes("run"), "run");
    }

    #[test]
    fn test_parse_flags_and_values() {
        let mut spec = ArgSpec::default();
        spec.flags.insert(
            "force".to_string(),
            vec!["-f".to_string(), "--force".to_string()],
        );
        spec.value_flags.insert(
            "lang".to_string(),
            vec!["-l".to_string(), "--lang".to_string()],
        );

        let args = vec![
            "-f".to_string(),
            "--lang=rust".to_string(),
            "pos1".to_string(),
        ];
        let res = parse_tokens(&spec, &args, None);
        assert_eq!(res.flags.get("force"), Some(&FlagValue::Bool(true)));
        assert_eq!(
            res.flags.get("lang"),
            Some(&FlagValue::Str("rust".to_string()))
        );
        assert_eq!(res.args, vec!["pos1"]);

        // Проверка формата --lang rust
        let args2 = vec![
            "--lang".to_string(),
            "python".to_string(),
            "pos2".to_string(),
        ];
        let res2 = parse_tokens(&spec, &args2, None);
        assert_eq!(
            res2.flags.get("lang"),
            Some(&FlagValue::Str("python".to_string()))
        );
        assert_eq!(res2.args, vec!["pos2"]);
    }

    #[test]
    fn test_parse_actions_and_categories() {
        let mut spec = ArgSpec::default();
        spec.actions
            .insert("build".to_string(), "build".to_string());
        spec.actions.insert("b".to_string(), "build".to_string());
        spec.default_action = Some("list".to_string());

        let mut langs = HashMap::new();
        langs.insert("cpp".to_string(), "cpp".to_string());
        langs.insert("rust".to_string(), "rust".to_string());
        langs.insert("rs".to_string(), "rust".to_string());
        spec.categories.insert("language".to_string(), langs);

        // Передача действия со знаком минус и категории со знаком минус
        let args = vec!["-b".to_string(), "--rust".to_string(), "my_app".to_string()];
        let res = parse_tokens(&spec, &args, None);
        assert_eq!(res.action, Some("build".to_string()));
        assert_eq!(res.categories.get("language"), Some(&"rust".to_string()));
        assert_eq!(res.args, vec!["my_app"]);

        // Без минуса
        let args2 = vec!["build".to_string(), "cpp".to_string()];
        let res2 = parse_tokens(&spec, &args2, None);
        assert_eq!(res2.action, Some("build".to_string()));
        assert_eq!(res2.categories.get("language"), Some(&"cpp".to_string()));
    }

    #[test]
    fn test_fuzzy_matching() {
        let mut spec = ArgSpec::default();
        spec.flags.insert(
            "force".to_string(),
            vec!["--force".to_string(), "-f".to_string()],
        );
        spec.actions
            .insert("build".to_string(), "build".to_string());

        // Опечатка во флаге: --forc
        let args = vec!["--forc".to_string()];
        let res = parse_tokens(&spec, &args, None);
        assert_eq!(res.flags.get("force"), Some(&FlagValue::Bool(true)));

        // Опечатка в действии: --bild
        let args2 = vec!["--bild".to_string()];
        let res2 = parse_tokens(&spec, &args2, None);
        assert_eq!(res2.action, Some("build".to_string()));
    }

    #[test]
    fn test_unknown_flags_isolation() {
        let spec = ArgSpec {
            allow_unknown_flags: false,
            ..Default::default()
        };
        let args = vec![
            "-unknown".to_string(),
            "pkg_name".to_string(),
            "--another".to_string(),
        ];
        let res = parse_tokens(&spec, &args, None);
        assert_eq!(res.args, vec!["pkg_name"]);
        assert_eq!(res.unknown_flags, vec!["-unknown", "--another"]);
    }

    #[test]
    fn test_passthrough_mode_action() {
        let mut spec = ArgSpec::default();
        spec.actions.insert("run".to_string(), "run".to_string());
        spec.flags.insert(
            "force".to_string(),
            vec!["-f".to_string(), "--force".to_string()],
        );

        // В passthrough-режиме для action "run" после первого аргумента (имя утилиты)
        // все последующие флаги (-f, --help) должны сохраняться в args
        let args = vec![
            "run".to_string(),
            "my_prog".to_string(),
            "-f".to_string(),
            "--custom-flag".to_string(),
        ];
        let res = parse_tokens(&spec, &args, None);
        assert_eq!(res.action, Some("run".to_string()));
        assert_eq!(res.args, vec!["my_prog", "-f", "--custom-flag"]);
        // До первого позиционного аргумента -f не было, поэтому flag.force не взведен
        assert_eq!(res.flags.get("force"), Some(&FlagValue::Bool(false)));
    }

    #[test]
    fn test_detect_dir() {
        let spec = ArgSpec {
            detect_dir: true,
            ..Default::default()
        };
        // Тестируем существующую директорию на диске (текущий каталог ".")
        let args = vec!["./src".to_string(), "file.rs".to_string()];
        let res = parse_tokens(&spec, &args, None);
        assert_eq!(res.target_dir, Some("./src".to_string()));
        assert_eq!(res.args, vec!["file.rs"]);
    }
}
