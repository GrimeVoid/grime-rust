use std::cmp::min;

/// Расстояние Дамерау-Левенштейна между двумя строками (учитывает вставки, удаления, замены и транспозиции соседних символов).
pub fn damerau_levenshtein(s1: &str, s2: &str) -> usize {
    let a: Vec<char> = s1.chars().collect();
    let b: Vec<char> = s2.chars().collect();
    let len_a = a.len();
    let len_b = b.len();

    if len_a == 0 {
        return len_b;
    }
    if len_b == 0 {
        return len_a;
    }

    let mut d = vec![vec![0usize; len_b + 1]; len_a + 1];

    for i in 0..=len_a {
        d[i][0] = i;
    }
    for j in 0..=len_b {
        d[0][j] = j;
    }

    for i in 1..=len_a {
        for j in 1..=len_b {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };

            d[i][j] = min(
                min(
                    d[i - 1][j] + 1,     // удаление
                    d[i][j - 1] + 1,     // вставка
                ),
                d[i - 1][j - 1] + cost, // замена
            );

            // Транспозиция двух соседних символов
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1);
            }
        }
    }

    d[len_a][len_b]
}

/// Вычисление меры сходства (от 0.0 до 1.0) между строкой флага (без дефисов) и кандидатом.
pub fn flag_similarity(input_raw: &str, cand_raw: &str) -> f64 {
    let inp = input_raw.to_lowercase();
    let cand = cand_raw.to_lowercase();

    if inp == cand {
        return 1.0;
    }

    let len_inp = inp.chars().count();
    let len_cand = cand.chars().count();

    if len_inp == 0 || len_cand == 0 {
        return 0.0;
    }

    let max_len = std::cmp::max(len_inp, len_cand);
    let dist = damerau_levenshtein(&inp, &cand);
    let mut base_sim = 1.0 - (dist as f64 / max_len as f64);

    // Префиксный бонус: если кандидат начинается с введенного префикса (например, 'al' для 'all', 'dep' для 'deps')
    if cand.starts_with(&inp) && len_inp >= 2 {
        let diff = len_cand - len_inp;
        if diff <= 3 {
            let prefix_sim = 1.0 - (diff as f64 / (len_cand as f64 * 2.0));
            if prefix_sim > base_sim {
                base_sim = prefix_sim;
            }
        }
    }

    // Бонус совпадения граничных символов (первой и последней буквы) при небольшом расстоянии
    if dist == 1 && len_inp >= 2 && len_cand >= 2 {
        let inp_first = inp.chars().next();
        let cand_first = cand.chars().next();
        let inp_last = inp.chars().last();
        let cand_last = cand.chars().last();

        if inp_first == cand_first && inp_last == cand_last {
            base_sim = (base_sim + 0.10).min(1.0);
        }
    }

    base_sim
}

/// Нечёткое сопоставление флага со списком известных флагов.
///
/// ПРАВИЛО БЕЗОПАСНОСТИ:
/// - Если токен не начинается с '-' или равен "--", сопоставление НЕ производится (возвращает None).
/// - Однобуквенные флаги (-f, -h, -p, -a) требуют строгого точного совпадения.
/// - Многобуквенные флаги (--al, --halp, -hlp, --verbos, --dep) сопоставляются с порогом threshold (по умолчанию >= 0.75).
pub fn fuzzy_match_flag<'a>(
    token: &str,
    known_flags: &[&'a str],
    threshold: f64,
) -> Option<&'a str> {
    // 1. Проверка: аргумент обязан быть флагом (начинаться с '-') и не быть разделителем '--'
    if !token.starts_with('-') || token == "--" {
        return None;
    }

    // 2. Если есть точное совпадение — мгновенный возврат
    for &cand in known_flags {
        if token == cand {
            return Some(cand);
        }
    }

    // 3. Выделяем имя флага без ведущих дефисов
    let is_double_dash = token.starts_with("--");
    let input_raw = if is_double_dash {
        &token[2..]
    } else {
        &token[1..]
    };

    let len_raw = input_raw.chars().count();

    // Однобуквенные флаги (-x, -h, -a) не подвергаются нечеткому поиску, чтобы не менять флаг ошибочно
    if len_raw <= 1 {
        return None;
    }

    let mut best_candidate: Option<&'a str> = None;
    let mut best_cand_raw: Option<&str> = None;
    let mut best_score = 0.0;
    let mut second_best_score = 0.0;

    for &cand in known_flags {
        let cand_is_double = cand.starts_with("--");
        let cand_raw = if cand_is_double {
            &cand[2..]
        } else {
            &cand[1..]
        };

        let len_cand = cand_raw.chars().count();
        if len_cand <= 1 {
            continue;
        }

        let sim = flag_similarity(input_raw, cand_raw);
        let dist = damerau_levenshtein(input_raw, cand_raw);

        let is_prefix = cand_raw.starts_with(input_raw) && len_raw >= 3 && (len_cand >= len_raw) && (len_cand - len_raw) <= 3;
        let valid_dist = is_prefix || match len_cand {
            0..=4 => dist <= 1,
            5..=7 => dist <= 2,
            _ => dist <= 3,
        };

        if valid_dist && sim >= threshold {
            if let Some(b_raw) = best_cand_raw {
                if b_raw == cand_raw {
                    // Это тот же флаг в другом написании (например, --path и -path)
                    // Предпочитаем вариант с совпадающим стилем дефисов
                    if cand_is_double == is_double_dash {
                        best_candidate = Some(cand);
                    }
                    continue;
                }
            }

            if sim > best_score {
                second_best_score = best_score;
                best_score = sim;
                best_candidate = Some(cand);
                best_cand_raw = Some(cand_raw);
            } else if (sim - best_score).abs() < 1e-4 {
                // Коллизия разных флагов с одинаковым счетом
                second_best_score = sim;
            } else if sim > second_best_score {
                second_best_score = sim;
            }
        }
    }

    // Если есть два разных кандидата с одинаково высоким счетом, во избежание неоднозначности не заменяем
    if let Some(best) = best_candidate {
        if best_score - second_best_score >= 0.08 || second_best_score < threshold {
            return Some(best);
        }
    }

    None
}

/// Нечёткий поиск лучшего совпадения для имени сущности (название модуля, аппа, проекта, пакета)
/// с высоким порогом схожести (по умолчанию threshold >= 0.75).
pub fn fuzzy_match_entity<'a>(
    query: &str,
    candidates: &[&'a str],
    threshold: f64,
) -> Option<&'a str> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return None;
    }

    // 1. Точное совпадение
    for &cand in candidates {
        if q == cand.to_lowercase() {
            return Some(cand);
        }
    }

    let len_q = q.chars().count();
    let mut best_candidate: Option<&'a str> = None;
    let mut best_score = 0.0;
    let mut second_best_score = 0.0;

    for &cand in candidates {
        let c = cand.to_lowercase();
        let len_c = c.chars().count();

        let sim = flag_similarity(&q, &c);
        let dist = damerau_levenshtein(&q, &c);

        let is_prefix = c.starts_with(&q) && len_q >= 2 && (len_c >= len_q) && (len_c - len_q) <= 3;
        let valid_dist = is_prefix || match len_c {
            0..=3 => dist <= 1,
            4..=6 => dist <= 1,
            7..=9 => dist <= 2,
            _ => dist <= 3,
        };

        if valid_dist && sim >= threshold {
            if sim > best_score {
                second_best_score = best_score;
                best_score = sim;
                best_candidate = Some(cand);
            } else if (sim - best_score).abs() < 1e-4 {
                second_best_score = sim;
            } else if sim > second_best_score {
                second_best_score = sim;
            }
        }
    }

    if let Some(best) = best_candidate {
        if best_score - second_best_score >= 0.08 || second_best_score < threshold {
            return Some(best);
        }
    }

    None
}

/// Список известных глобальных флагов CLI Grime
pub const GLOBAL_GRIME_FLAGS: &[&str] = &[
    "--force", "-f",
    "--detach", "-d",
    "--path", "-path", "-p",
    "--args", "-arg", "-c", "-com", "--com",
    "--mod", "-mod",
    "--help", "-h",
    "--version", "-v",
];

/// Нормализация отдельного токена флага:
/// Если токен распознан как флаг с опечаткой — возвращается канонический флаг,
/// иначе исходный токен без изменений.
pub fn normalize_flag(token: &str, known_flags: &[&str]) -> String {
    if let Some(canonical) = fuzzy_match_flag(token, known_flags, 0.75) {
        canonical.to_string()
    } else {
        token.to_string()
    }
}

/// Нормализация списка аргументов командной строки.
/// Строковые позиционные параметры (не начинающиеся с '-') остаются в первозданном виде.
pub fn normalize_cli_flags(args: &[String], known_flags: &[&str]) -> Vec<String> {
    args.iter()
        .map(|tok| {
            if tok.starts_with('-') && tok != "--" {
                normalize_flag(tok, known_flags)
            } else {
                tok.clone()
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_damerau_levenshtein() {
        assert_eq!(damerau_levenshtein("help", "help"), 0);
        assert_eq!(damerau_levenshtein("hlp", "help"), 1);
        assert_eq!(damerau_levenshtein("halp", "help"), 1);
        assert_eq!(damerau_levenshtein("tehs", "thes"), 1); // транспозиция
        assert_eq!(damerau_levenshtein("all", "al"), 1);
    }

    #[test]
    fn test_flag_similarity() {
        assert_eq!(flag_similarity("help", "help"), 1.0);
        assert!(flag_similarity("al", "all") >= 0.80);
        assert!(flag_similarity("dep", "deps") >= 0.80);
        assert!(flag_similarity("hlp", "help") >= 0.75);
        assert!(flag_similarity("halp", "help") >= 0.75);
        assert!(flag_similarity("verbos", "verbose") >= 0.85);
        assert!(flag_similarity("detch", "detach") >= 0.80);

        // Разные флаги не должны давать высокий балл
        assert!(flag_similarity("all", "app") < 0.50);
        assert!(flag_similarity("pure", "path") < 0.40);
        assert!(flag_similarity("force", "flake") < 0.45);
    }

    #[test]
    fn test_fuzzy_match_flag() {
        let flags = &[
            "--force", "-f", "--detach", "-d", "--help", "-h", "--all", "-a", "--deps",
            "--version", "-v",
        ];

        // Положительные сопоставления
        assert_eq!(fuzzy_match_flag("--forc", flags, 0.75), Some("--force"));
        assert_eq!(fuzzy_match_flag("--detch", flags, 0.75), Some("--detach"));
        assert_eq!(fuzzy_match_flag("--dettach", flags, 0.75), Some("--detach"));
        assert_eq!(fuzzy_match_flag("--al", flags, 0.75), Some("--all"));
        assert_eq!(fuzzy_match_flag("--dep", flags, 0.75), Some("--deps"));
        assert_eq!(fuzzy_match_flag("--halp", flags, 0.75), Some("--help"));
        assert_eq!(fuzzy_match_flag("-hlp", flags, 0.75), Some("--help"));
        assert_eq!(fuzzy_match_flag("--vers", flags, 0.75), Some("--version"));

        // Точные совпадения
        assert_eq!(fuzzy_match_flag("-f", flags, 0.75), Some("-f"));
        assert_eq!(fuzzy_match_flag("-h", flags, 0.75), Some("-h"));
        assert_eq!(fuzzy_match_flag("--force", flags, 0.75), Some("--force"));

        // Однобуквенные опечатки НЕ должны нечетко матчиться
        assert_eq!(fuzzy_match_flag("-x", flags, 0.75), None);
        assert_eq!(fuzzy_match_flag("-z", flags, 0.75), None);

        // Строки НЕ должны трогаться
        assert_eq!(fuzzy_match_flag("git", flags, 0.75), None);
        assert_eq!(fuzzy_match_flag("cowsay", flags, 0.75), None);
        assert_eq!(fuzzy_match_flag("MyProject", flags, 0.75), None);
        assert_eq!(fuzzy_match_flag("--", flags, 0.75), None);
    }

    #[test]
    fn test_normalize_cli_flags() {
        let raw = vec![
            "--forc".to_string(),
            "pkg".to_string(),
            "--al".to_string(),
            "git".to_string(),
        ];
        let known = &["--force", "-f", "--all", "-a"];
        let normalized = normalize_cli_flags(&raw, known);

        assert_eq!(
            normalized,
            vec![
                "--force".to_string(),
                "pkg".to_string(),
                "--all".to_string(),
                "git".to_string(),
            ]
        );
    }

    #[test]
    fn test_fuzzy_match_entity() {
        let modules = &["project", "pkg", "app", "box", "nix", "aider", "cmd", "host"];

        // Успешные совпадения
        assert_eq!(fuzzy_match_entity("proj", modules, 0.75), Some("project"));
        assert_eq!(fuzzy_match_entity("pckg", modules, 0.75), Some("pkg"));
        assert_eq!(fuzzy_match_entity("ap", modules, 0.75), Some("app"));
        assert_eq!(fuzzy_match_entity("bx", modules, 0.75), Some("box"));
        assert_eq!(fuzzy_match_entity("nx", modules, 0.75), Some("nix"));
        assert_eq!(fuzzy_match_entity("aidr", modules, 0.75), Some("aider"));

        // Точные совпадения
        assert_eq!(fuzzy_match_entity("cmd", modules, 0.75), Some("cmd"));
        assert_eq!(fuzzy_match_entity("host", modules, 0.75), Some("host"));

        // Несвязанные строки не должны матчиться
        assert_eq!(fuzzy_match_entity("random_unknown", modules, 0.75), None);
        assert_eq!(fuzzy_match_entity("my_cool_game", modules, 0.75), None);
    }
}
