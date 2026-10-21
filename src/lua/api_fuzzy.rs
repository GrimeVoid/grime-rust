//! Модуль нечёткого поиска и сравнения строк для Lua (grime.fuzzy).
//!
//! Интегрирован с алгоритмами Дамерау-Левенштейна и SkimMatcher из `crate::args`.

use fuzzy_matcher::skim::SkimMatcherV2;
use fuzzy_matcher::FuzzyMatcher;
use mlua::{Lua, MultiValue, Table, Value};

/// Регистрирует подтаблицу `grime.fuzzy`.
pub fn register_fuzzy_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let fuzzy_tbl = lua.create_table()?;

    // grime.fuzzy.match_best(query, candidates) -> best_candidate | nil
    fuzzy_tbl.set(
        "match_best",
        lua.create_function(|_, (query, candidates): (String, Vec<String>)| {
            let matcher = SkimMatcherV2::default();
            let mut best_score = None;
            let mut best_candidate = None;

            for c in &candidates {
                if let Some(score) = matcher.fuzzy_match(c, &query) {
                    if best_score.is_none_or(|best| score > best) {
                        best_score = Some(score);
                        best_candidate = Some(c.clone());
                    }
                }
            }
            Ok(best_candidate)
        })?,
    )?;

    // grime.fuzzy.similarity(s1, s2) -> f64
    fuzzy_tbl.set(
        "similarity",
        lua.create_function(|_, (s1, s2): (String, String)| {
            Ok(crate::args::flag_similarity(&s1, &s2))
        })?,
    )?;

    // grime.fuzzy.damerau_levenshtein(s1, s2) -> usize
    fuzzy_tbl.set(
        "damerau_levenshtein",
        lua.create_function(|_, (s1, s2): (String, String)| {
            Ok(crate::args::damerau_levenshtein(&s1, &s2))
        })?,
    )?;

    // grime.fuzzy.match_flag(token, candidates, threshold) -> string | nil
    fuzzy_tbl.set(
        "match_flag",
        lua.create_function(|_, (token, candidates, threshold): (String, Vec<String>, Option<f64>)| {
            let thresh = threshold.unwrap_or(0.75);
            let cand_refs: Vec<&str> = candidates.iter().map(|s| s.as_str()).collect();
            Ok(crate::args::fuzzy_match_flag(&token, &cand_refs, thresh).map(|s| s.to_string()))
        })?,
    )?;
    fuzzy_tbl.set("fuzzy_match_flag", fuzzy_tbl.get::<Value>("match_flag")?)?;

    // grime.fuzzy.find_best_match(query, candidates, threshold) -> (matched, score)
    fuzzy_tbl.set(
        "find_best_match",
        lua.create_function(|lua, (query, candidates, threshold): (String, Value, Option<f64>)| {
            let thresh = threshold.unwrap_or(0.75);
            let mut cand_list = Vec::new();
            if let Value::Table(tbl) = candidates {
                let len = tbl.raw_len();
                if len > 0 {
                    for i in 1..=len {
                        if let Ok(s) = tbl.get::<String>(i) {
                            if !s.is_empty() {
                                cand_list.push(s);
                            }
                        }
                    }
                } else {
                    for (k, _) in tbl.pairs::<Value, Value>().flatten() {
                        if let Value::String(s) = k {
                            if let Ok(utf8) = s.to_str() {
                                if !utf8.is_empty() {
                                    cand_list.push(utf8.to_string());
                                }
                            }
                        }
                    }
                }
            }

            let cand_refs: Vec<&str> = cand_list.iter().map(|s| s.as_str()).collect();
            if let Some(matched) = crate::args::fuzzy_match_entity(&query, &cand_refs, thresh) {
                let sim = crate::args::flag_similarity(&query, matched);
                let m_str = lua.create_string(matched)?;
                let mut multi = MultiValue::new();
                multi.push_back(Value::String(m_str));
                multi.push_back(Value::Number(sim));
                Ok(multi)
            } else {
                let mut multi = MultiValue::new();
                multi.push_back(Value::Nil);
                multi.push_back(Value::Number(0.0));
                Ok(multi)
            }
        })?,
    )?;
    fuzzy_tbl.set("fuzzy_match", fuzzy_tbl.get::<Value>("find_best_match")?)?;

    // grime.fuzzy.normalize_flags(args, known_flags, threshold) -> table
    fuzzy_tbl.set(
        "normalize_flags",
        lua.create_function(|lua, (args, known_flags, threshold): (Vec<String>, Vec<String>, Option<f64>)| {
            let thresh = threshold.unwrap_or(0.75);
            let cand_refs: Vec<&str> = known_flags.iter().map(|s| s.as_str()).collect();
            let res_tbl = lua.create_table()?;
            let mut passthrough = false;
            for (idx, arg) in args.iter().enumerate() {
                if passthrough {
                    res_tbl.set(idx + 1, arg.clone())?;
                    continue;
                }
                if arg == "--" || arg == "//" {
                    passthrough = true;
                    res_tbl.set(idx + 1, arg.clone())?;
                    continue;
                }
                let replaced = if arg.starts_with('-') {
                    crate::args::fuzzy_match_flag(arg, &cand_refs, thresh)
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| arg.clone())
                } else {
                    arg.clone()
                };
                res_tbl.set(idx + 1, replaced)?;
            }
            Ok(res_tbl)
        })?,
    )?;

    grime_tbl.set("fuzzy", fuzzy_tbl)?;
    Ok(())
}
