//! Модуль манипуляций со строками и таблицами для Lua (grime.str и grime.table).
//!
//! Предоставляет богатый набор чистых функций трансформации коллекций и текста.

use mlua::{Lua, Table, Value};

fn convert_separated_case(s: &str, sep: char) -> String {
    let alt_sep = if sep == '_' { '-' } else { '_' };
    let mut result = String::new();
    let chars: Vec<char> = s.chars().collect();
    for i in 0..chars.len() {
        let c = chars[i];
        if c.is_whitespace() || c == alt_sep || c == sep {
            if !result.ends_with(sep) && !result.is_empty() {
                result.push(sep);
            }
        } else if c.is_uppercase() {
            if i > 0 && !result.ends_with(sep) {
                let prev = chars[i - 1];
                if prev.is_lowercase() || prev.is_numeric() {
                    result.push(sep);
                }
            }
            for lc in c.to_lowercase() {
                result.push(lc);
            }
        } else {
            result.push(c);
        }
    }
    result.trim_matches(sep).to_string()
}

/// Регистрирует подтаблицы `grime.str` и `grime.table`.
pub fn register_str_table_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    // -------------------------------------------------------------
    // grime.str
    // -------------------------------------------------------------
    let str_tbl = lua.create_table()?;

    // grime.str.to_snake_case(s) -> string
    str_tbl.set(
        "to_snake_case",
        lua.create_function(|_, s: String| Ok(convert_separated_case(&s, '_')))?,
    )?;

    // grime.str.to_kebab_case(s) -> string
    str_tbl.set(
        "to_kebab_case",
        lua.create_function(|_, s: String| Ok(convert_separated_case(&s, '-')))?,
    )?;

    // grime.str.trim(s) -> string
    str_tbl.set(
        "trim",
        lua.create_function(|_, s: String| {
            Ok(s.trim().to_string())
        })?,
    )?;

    // grime.str.split(s, sep) -> table
    str_tbl.set(
        "split",
        lua.create_function(|lua, (s, sep): (String, Option<String>)| {
            let tbl = lua.create_table()?;
            let separator = sep.unwrap_or_else(|| " ".to_string());
            if separator.is_empty() {
                for (idx, ch) in s.chars().enumerate() {
                    tbl.set(idx + 1, ch.to_string())?;
                }
            } else {
                for (idx, part) in s.split(&separator).enumerate() {
                    tbl.set(idx + 1, part.to_string())?;
                }
            }
            Ok(tbl)
        })?,
    )?;

    // grime.str.starts_with(s, prefix) -> bool
    str_tbl.set(
        "starts_with",
        lua.create_function(|_, (s, prefix): (String, String)| {
            Ok(s.starts_with(&prefix))
        })?,
    )?;

    // grime.str.ends_with(s, suffix) -> bool
    str_tbl.set(
        "ends_with",
        lua.create_function(|_, (s, suffix): (String, String)| {
            Ok(s.ends_with(&suffix))
        })?,
    )?;

    // grime.str.pad_left(s, len, ch) -> string
    str_tbl.set(
        "pad_left",
        lua.create_function(|_, (s, len, ch): (String, usize, Option<String>)| {
            let pad_char = ch.and_then(|c| c.chars().next()).unwrap_or(' ');
            let cur_len = s.chars().count();
            if cur_len >= len {
                Ok(s)
            } else {
                let pad: String = std::iter::repeat_n(pad_char, len - cur_len).collect();
                Ok(format!("{}{}", pad, s))
            }
        })?,
    )?;

    // grime.str.pad_right(s, len, ch) -> string
    str_tbl.set(
        "pad_right",
        lua.create_function(|_, (s, len, ch): (String, usize, Option<String>)| {
            let pad_char = ch.and_then(|c| c.chars().next()).unwrap_or(' ');
            let cur_len = s.chars().count();
            if cur_len >= len {
                Ok(s)
            } else {
                let pad: String = std::iter::repeat_n(pad_char, len - cur_len).collect();
                Ok(format!("{}{}", s, pad))
            }
        })?,
    )?;

    grime_tbl.set("str", &str_tbl)?;

    // -------------------------------------------------------------
    // grime.table
    // -------------------------------------------------------------
    let tbl_tbl = lua.create_table()?;

    // grime.table.keys(tbl) -> table
    tbl_tbl.set(
        "keys",
        lua.create_function(|lua, tbl: Table| {
            let res = lua.create_table()?;
            for (idx, pair) in tbl.pairs::<Value, Value>().enumerate() {
                let (k, _) = pair?;
                res.set(idx + 1, k)?;
            }
            Ok(res)
        })?,
    )?;

    // grime.table.values(tbl) -> table
    tbl_tbl.set(
        "values",
        lua.create_function(|lua, tbl: Table| {
            let res = lua.create_table()?;
            for (idx, pair) in tbl.pairs::<Value, Value>().enumerate() {
                let (_, v) = pair?;
                res.set(idx + 1, v)?;
            }
            Ok(res)
        })?,
    )?;

    // grime.table.contains(tbl, target) -> bool
    tbl_tbl.set(
        "contains",
        lua.create_function(|_, (tbl, target): (Table, Value)| {
            for pair in tbl.pairs::<Value, Value>() {
                let (_, v) = pair?;
                if v == target {
                    return Ok(true);
                }
            }
            Ok(false)
        })?,
    )?;

    // grime.table.merge(t1, t2) -> table
    tbl_tbl.set(
        "merge",
        lua.create_function(|lua, (t1, t2): (Table, Table)| {
            let res = lua.create_table()?;
            for pair in t1.pairs::<Value, Value>() {
                let (k, v) = pair?;
                res.set(k, v)?;
            }
            for pair in t2.pairs::<Value, Value>() {
                let (k, v) = pair?;
                res.set(k, v)?;
            }
            Ok(res)
        })?,
    )?;

    // grime.table.filter(tbl, pred) -> table
    tbl_tbl.set(
        "filter",
        lua.create_function(|lua, (tbl, pred): (Table, mlua::Function)| {
            let res = lua.create_table()?;
            let mut out_idx = 1;
            let len = tbl.raw_len();
            if len > 0 {
                for i in 1..=len {
                    let val: Value = tbl.get(i)?;
                    if pred.call::<bool>(val.clone())? {
                        res.set(out_idx, val)?;
                        out_idx += 1;
                    }
                }
            } else {
                for pair in tbl.pairs::<Value, Value>() {
                    let (k, v) = pair?;
                    if pred.call::<bool>((v.clone(), k.clone()))? {
                        res.set(k, v)?;
                    }
                }
            }
            Ok(res)
        })?,
    )?;

    // grime.table.map(tbl, mapper) -> table
    tbl_tbl.set(
        "map",
        lua.create_function(|lua, (tbl, mapper): (Table, mlua::Function)| {
            let res = lua.create_table()?;
            let len = tbl.raw_len();
            if len > 0 {
                for i in 1..=len {
                    let val: Value = tbl.get(i)?;
                    let mapped: Value = mapper.call(val)?;
                    res.set(i, mapped)?;
                }
            } else {
                for pair in tbl.pairs::<Value, Value>() {
                    let (k, v) = pair?;
                    let mapped: Value = mapper.call((v, k.clone()))?;
                    res.set(k, mapped)?;
                }
            }
            Ok(res)
        })?,
    )?;

    // grime.table.slice(tbl, start, finish) -> table
    tbl_tbl.set(
        "slice",
        lua.create_function(|lua, (tbl, s, end_idx): (Table, Option<usize>, Option<usize>)| {
            let res = lua.create_table()?;
            let len = tbl.raw_len();
            let start = s.unwrap_or(1).max(1);
            let finish = end_idx.unwrap_or(len).min(len);
            if start <= finish {
                for (out_idx, i) in (start..=finish).enumerate() {
                    let val: Value = tbl.get(i)?;
                    res.set(out_idx + 1, val)?;
                }
            }
            Ok(res)
        })?,
    )?;

    grime_tbl.set("table", tbl_tbl)?;
    Ok(())
}
