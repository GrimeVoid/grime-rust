//! Нативный API разбора аргументов для Lua (grime.args).
//!
//! Предоставляет быстрый движок классификации токенов, разделителей, флагов,
//! действий, категорий и нечёткого сопоставления.

use mlua::{Lua, MultiValue, Table, Value};
use std::collections::HashMap;

use crate::args_engine::{
    is_dash_token, is_passthrough_separator, parse_tokens, split_passthrough, strip_dashes,
    ArgSpec, FlagValue, ParsedArgs,
};

/// Преобразует таблицу спецификации Lua в нативную структуру `ArgSpec`.
pub fn lua_table_to_spec(spec_tbl: &Table) -> Result<ArgSpec, mlua::Error> {
    let mut spec = ArgSpec::default();

    // 1. actions
    if let Ok(acts) = spec_tbl.get::<Table>("actions") {
        for (k, v) in acts.pairs::<Value, Value>().flatten() {
            match (k, v) {
                (Value::String(k_str), Value::String(v_str)) => {
                    spec.actions.insert(
                        k_str.to_str()?.to_lowercase(),
                        v_str.to_str()?.to_string(),
                    );
                }
                (Value::Integer(_), Value::String(v_str)) => {
                    let s = v_str.to_str()?.to_string();
                    spec.actions.insert(s.to_lowercase(), s);
                }
                _ => {}
            }
        }
    }

    // 2. default_action
    if let Ok(Some(def_act)) = spec_tbl.get::<Option<String>>("default_action") {
        spec.default_action = Some(def_act);
    }

    // 3. flags
    if let Ok(flags_tbl) = spec_tbl.get::<Table>("flags") {
        for (flag_name, val) in flags_tbl.pairs::<String, Value>().flatten() {
            let patterns = match val {
                Value::Table(tbl) => {
                    let mut pats = Vec::new();
                    for s in tbl.sequence_values::<String>().flatten() {
                        pats.push(s);
                    }
                    pats
                }
                Value::String(s) => vec![s.to_str()?.to_string()],
                _ => Vec::new(),
            };
            spec.flags.insert(flag_name, patterns);
        }
    }

    // 4. value_flags
    if let Ok(val_flags_tbl) = spec_tbl.get::<Table>("value_flags") {
        for (vname, val) in val_flags_tbl.pairs::<String, Value>().flatten() {
            let patterns = match val {
                Value::Table(tbl) => {
                    let mut pats = Vec::new();
                    for s in tbl.sequence_values::<String>().flatten() {
                        pats.push(s);
                    }
                    pats
                }
                Value::String(s) => vec![s.to_str()?.to_string()],
                _ => Vec::new(),
            };
            spec.value_flags.insert(vname, patterns);
        }
    }

    // 5. categories
    if let Ok(cats_tbl) = spec_tbl.get::<Table>("categories") {
        for (cat_name, dict_tbl) in cats_tbl.pairs::<String, Table>().flatten() {
            let mut dict = HashMap::new();
            for (ik, iv) in dict_tbl.pairs::<Value, Value>().flatten() {
                match (ik, iv) {
                    (Value::String(k_str), Value::String(v_str)) => {
                        dict.insert(
                            k_str.to_str()?.to_lowercase(),
                            v_str.to_str()?.to_string(),
                        );
                    }
                    (Value::Integer(_), Value::String(v_str)) => {
                        let s = v_str.to_str()?.to_string();
                        dict.insert(s.to_lowercase(), s);
                    }
                    _ => {}
                }
            }
            spec.categories.insert(cat_name, dict);
        }
    }

    // 6. detect_dir
    if let Ok(detect_dir) = spec_tbl.get::<bool>("detect_dir") {
        spec.detect_dir = detect_dir;
    }

    // 7. fuzzy_threshold
    if let Ok(thresh) = spec_tbl.get::<f64>("fuzzy_threshold") {
        spec.fuzzy_threshold = thresh;
    }

    // 8. allow_unknown_flags
    if let Ok(allow_unk) = spec_tbl.get::<bool>("allow_unknown_flags") {
        spec.allow_unknown_flags = allow_unk;
    }

    // 9. passthrough_actions
    if let Ok(pt_tbl) = spec_tbl.get::<Table>("passthrough_actions") {
        let mut acts = Vec::new();
        for s in pt_tbl.sequence_values::<String>().flatten() {
            acts.push(s);
        }
        if !acts.is_empty() {
            spec.passthrough_actions = acts;
        }
    }

    Ok(spec)
}

/// Извлекает массив строковых токенов из переданного значения Lua или из `grime.ctx.args`.
pub fn extract_raw_args(lua: &Lua, raw_args: Option<Value>) -> Result<Vec<String>, mlua::Error> {
    if let Some(val) = raw_args {
        match val {
            Value::Table(tbl) => {
                let mut vec = Vec::new();
                for v in tbl.sequence_values::<Value>().flatten() {
                    match v {
                        Value::String(s) => vec.push(s.to_str()?.to_string()),
                        Value::Integer(i) => vec.push(i.to_string()),
                        Value::Number(n) => vec.push(n.to_string()),
                        Value::Boolean(b) => vec.push(b.to_string()),
                        _ => {}
                    }
                }
                return Ok(vec);
            }
            Value::Nil => {}
            _ => {}
        }
    }

    // Fallback на grime.ctx.args
    let mut vec = Vec::new();
    if let Ok(g) = lua.globals().get::<Table>("grime") {
        if let Ok(c) = g.get::<Table>("ctx") {
            if let Ok(args_tbl) = c.get::<Table>("args") {
                for s in args_tbl.sequence_values::<String>().flatten() {
                    vec.push(s);
                }
            }
        }
    }
    Ok(vec)
}

/// Преобразует `ParsedArgs` в структуру таблицы Lua.
pub fn parsed_args_to_lua(lua: &Lua, parsed: ParsedArgs) -> Result<Table, mlua::Error> {
    let parsed_tbl = lua.create_table()?;

    parsed_tbl.set("action", parsed.action)?;

    let flags_tbl = lua.create_table()?;
    for (k, v) in parsed.flags {
        match v {
            FlagValue::Bool(b) => flags_tbl.set(k.as_str(), b)?,
            FlagValue::Str(s) => flags_tbl.set(k.as_str(), s)?,
        }
    }
    parsed_tbl.set("flags", flags_tbl)?;

    let cats_tbl = lua.create_table()?;
    for (k, v) in parsed.categories {
        cats_tbl.set(k.as_str(), v)?;
    }
    parsed_tbl.set("categories", cats_tbl)?;

    parsed_tbl.set("target_dir", parsed.target_dir.clone())?;
    parsed_tbl.set("dir", parsed.target_dir)?;

    let args_tbl = lua.create_table()?;
    for (idx, a) in parsed.args.into_iter().enumerate() {
        args_tbl.raw_set(idx + 1, a)?;
    }
    parsed_tbl.set("args", args_tbl)?;

    let cmd_tbl = lua.create_table()?;
    for (idx, c) in parsed.command_tokens.into_iter().enumerate() {
        cmd_tbl.raw_set(idx + 1, c)?;
    }
    parsed_tbl.set("command_tokens", cmd_tbl)?;

    let unk_tbl = lua.create_table()?;
    for (idx, u) in parsed.unknown_flags.into_iter().enumerate() {
        unk_tbl.raw_set(idx + 1, u)?;
    }
    parsed_tbl.set("unknown_flags", unk_tbl)?;

    parsed_tbl.set("has_separator", parsed.has_passthrough_separator)?;
    parsed_tbl.set("has_passthrough_separator", parsed.has_passthrough_separator)?;

    Ok(parsed_tbl)
}

/// Регистрирует нативный модуль `grime.args` в переданной таблице `grime`.
pub fn register_args_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let args_tbl = lua.create_table()?;

    // 1. grime.args.parse(spec, [raw_args], [default_target_dir]) -> parsed_table
    args_tbl.set(
        "parse",
        lua.create_function(
            |lua_ctx,
             (spec_tbl, raw_args, default_target_dir): (
                Table,
                Option<Value>,
                Option<String>,
            )| {
                let spec = lua_table_to_spec(&spec_tbl)?;
                let tokens = extract_raw_args(lua_ctx, raw_args)?;

                let def_dir = match default_target_dir {
                    Some(d) => Some(d),
                    None => lua_ctx
                        .globals()
                        .get::<Table>("grime")
                        .ok()
                        .and_then(|g| g.get::<Table>("ctx").ok())
                        .and_then(|c| c.get::<String>("target_dir").ok()),
                };

                let parsed = parse_tokens(&spec, &tokens, def_dir.as_deref());
                parsed_args_to_lua(lua_ctx, parsed)
            },
        )?,
    )?;

    // 2. grime.args.split_passthrough([raw_args]) -> (tokens_before, command_tokens, has_separator)
    let split_fn = lua.create_function(|lua_ctx, raw_args: Option<Value>| {
        let tokens = extract_raw_args(lua_ctx, raw_args)?;
        let (before, cmd, has_sep) = split_passthrough(&tokens);

        let before_tbl = lua_ctx.create_table()?;
        for (i, t) in before.into_iter().enumerate() {
            before_tbl.raw_set(i + 1, t)?;
        }

        let cmd_tbl = lua_ctx.create_table()?;
        for (i, t) in cmd.into_iter().enumerate() {
            cmd_tbl.raw_set(i + 1, t)?;
        }

        let mut multi = MultiValue::new();
        multi.push_back(Value::Table(before_tbl));
        multi.push_back(Value::Table(cmd_tbl));
        multi.push_back(Value::Boolean(has_sep));
        Ok(multi)
    })?;

    args_tbl.set("split_passthrough", split_fn.clone())?;
    args_tbl.set("split", split_fn)?;

    // 3. grime.args.strip_dashes(token) -> string
    args_tbl.set(
        "strip_dashes",
        lua.create_function(|_, tok: Value| {
            let s = match tok {
                Value::String(st) => st.to_str()?.to_string(),
                Value::Integer(i) => i.to_string(),
                Value::Number(n) => n.to_string(),
                _ => String::new(),
            };
            let stripped = strip_dashes(&s);
            Ok(stripped.to_lowercase())
        })?,
    )?;

    // 4. grime.args.is_flag(token) -> boolean
    args_tbl.set(
        "is_flag",
        lua.create_function(|_, tok: Value| {
            if let Value::String(st) = tok {
                let s = st.to_str()?;
                Ok(is_dash_token(&s))
            } else {
                Ok(false)
            }
        })?,
    )?;

    // 5. grime.args.is_separator(token) -> boolean
    args_tbl.set(
        "is_separator",
        lua.create_function(|_, tok: Value| {
            if let Value::String(st) = tok {
                let s = st.to_str()?;
                Ok(is_passthrough_separator(&s))
            } else {
                Ok(false)
            }
        })?,
    )?;

    // 6. grime.args.new(spec) -> wrapper table with :parse method (обратная совместимость с argparse.new)
    args_tbl.set(
        "new",
        lua.create_function(|lua_ctx, spec_tbl: Table| {
            let obj = lua_ctx.create_table()?;
            obj.set("_spec", spec_tbl)?;

            obj.set(
                "parse",
                lua_ctx.create_function(
                    |inner_ctx,
                     (this, raw_args, default_target_dir): (
                        Table,
                        Option<Value>,
                        Option<String>,
                    )| {
                        let spec: Table = this.get("_spec")?;
                        let globals = inner_ctx.globals();
                        let g: Table = globals.get("grime")?;
                        let a: Table = g.get("args")?;
                        let parse_fn: mlua::Function = a.get("parse")?;
                        parse_fn.call::<Table>((spec, raw_args, default_target_dir))
                    },
                )?,
            )?;

            Ok(obj)
        })?,
    )?;

    grime_tbl.set("args", args_tbl)?;
    Ok(())
}
