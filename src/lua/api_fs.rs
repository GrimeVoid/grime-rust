//! Модуль файловых операций для Lua (grime.fs).
//!
//! Обеспечивает безопасное взаимодействие с файловой системой без паник,
//! с развертыванием путей пользователя (`~`), проверками и нормализацией.
//! Таблица [`FS_OPS`] — единый источник операций: из неё строятся и `grime.fs.*`,
//! и `ctx.*` (с разрешением относительных путей от `target_dir`, см. `context.rs`).

use mlua::{Lua, MultiValue, Table, Value};
use std::fs;
use std::path::PathBuf;

use crate::fs_ops::{
    copy_recursive, delete_safe, expand_and_normalize, expand_tilde, get_latest_mtime, is_newer,
    mkdir_p, move_safe, normalize_path, write_file,
};

/// Разрешение строкового пути из Lua в реальный путь (для `grime.fs` и `ctx` оно разное).
pub type PathResolveFn = fn(&Lua, &str) -> mlua::Result<PathBuf>;

/// Описание файловой операции: имя, алиасы, число путевых аргументов и реализация.
pub struct FsOp {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    /// Количество первых аргументов, являющихся путями (они проходят через резолвер).
    pub paths: usize,
    /// Реализация: разрешённые пути и остальные (не путевые) аргументы Lua.
    pub run: fn(&Lua, &[PathBuf], &[Value]) -> mlua::Result<Value>,
}

fn rt_err(e: String) -> mlua::Error {
    mlua::Error::runtime(e)
}

fn str_arg(lua: &Lua, rest: &[Value], idx: usize) -> mlua::Result<String> {
    match rest.get(idx) {
        Some(Value::String(s)) => Ok(s.to_str()?.to_string()),
        Some(Value::Nil) | None => Err(mlua::Error::runtime("Ожидался строковый аргумент")),
        Some(other) => Ok(lua
            .coerce_string(other.clone())?
            .map(|s| s.to_string_lossy().to_string())
            .ok_or_else(|| mlua::Error::runtime("Ожидался строковый аргумент"))?),
    }
}

fn path_value(lua: &Lua, p: PathBuf) -> mlua::Result<Value> {
    Ok(Value::String(lua.create_string(p.to_string_lossy().as_bytes())?))
}

/// Все файловые операции с путевыми аргументами.
pub static FS_OPS: &[FsOp] = &[
    FsOp { name: "exists", aliases: &[], paths: 1, run: |_, p, _| Ok(Value::Boolean(p[0].exists())) },
    FsOp { name: "is_dir", aliases: &[], paths: 1, run: |_, p, _| Ok(Value::Boolean(p[0].is_dir())) },
    FsOp { name: "is_file", aliases: &[], paths: 1, run: |_, p, _| Ok(Value::Boolean(p[0].is_file())) },
    FsOp {
        name: "mkdir_p",
        aliases: &[],
        paths: 1,
        run: |_, p, _| mkdir_p(&p[0]).map(|_| Value::Boolean(true)).map_err(rt_err),
    },
    FsOp {
        name: "delete",
        aliases: &["remove"],
        paths: 1,
        run: |_, p, rest| {
            let missing_ok = !matches!(rest.first(), Some(Value::Boolean(false)));
            delete_safe(&p[0], missing_ok).map(Value::Boolean).map_err(rt_err)
        },
    },
    FsOp {
        name: "copy",
        aliases: &[],
        paths: 2,
        run: |lua, p, _| path_value(lua, copy_recursive(&p[0], &p[1]).map_err(rt_err)?),
    },
    FsOp {
        name: "move",
        aliases: &["rename"],
        paths: 2,
        run: |lua, p, _| path_value(lua, move_safe(&p[0], &p[1]).map_err(rt_err)?),
    },
    FsOp {
        name: "read",
        aliases: &[],
        paths: 1,
        run: |lua, p, _| match fs::read_to_string(&p[0]) {
            Ok(s) => Ok(Value::String(lua.create_string(s)?)),
            Err(_) => Ok(Value::Nil),
        },
    },
    FsOp {
        name: "write",
        aliases: &[],
        paths: 1,
        run: |lua, p, rest| {
            let content = str_arg(lua, rest, 0)?;
            write_file(&p[0], &content).map(|_| Value::Boolean(true)).map_err(rt_err)
        },
    },
    FsOp {
        name: "mtime",
        aliases: &[],
        paths: 1,
        run: |_, p, _| Ok(Value::Number(get_latest_mtime(&p[0]))),
    },
    FsOp {
        name: "is_newer",
        aliases: &["needs_rebuild"],
        paths: 2,
        run: |_, p, _| Ok(Value::Boolean(is_newer(&p[0], &p[1]))),
    },
];

/// Устанавливает все операции [`FS_OPS`] (с алиасами) в таблицу `target`.
/// Пути каждой операции предварительно проходят через `resolve`.
pub fn install_fs_ops(lua: &Lua, target: &Table, resolve: PathResolveFn) -> Result<(), mlua::Error> {
    for op in FS_OPS {
        let func = lua.create_function(move |lua, args: MultiValue| {
            let mut iter = args.into_iter();
            let mut paths = Vec::with_capacity(op.paths);
            for _ in 0..op.paths {
                let raw = match iter.next() {
                    Some(Value::String(s)) => s.to_str()?.to_string(),
                    _ => return Err(mlua::Error::runtime(format!("{}: ожидался путь (строка)", op.name))),
                };
                paths.push(resolve(lua, &raw)?);
            }
            let rest: Vec<Value> = iter.collect();
            (op.run)(lua, &paths, &rest)
        })?;
        target.set(op.name, func.clone())?;
        for alias in op.aliases {
            target.set(*alias, func.clone())?;
        }
    }
    Ok(())
}

/// Регистрирует подтаблицу `grime.fs` со всеми файловыми функциями.
pub fn register_fs_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let fs_tbl = lua.create_table()?;

    install_fs_ops(lua, &fs_tbl, |_, raw| Ok(expand_tilde(raw).into_owned()))?;

    // grime.fs.normalize(path) -> string
    fs_tbl.set(
        "normalize",
        lua.create_function(|_, path: String| {
            let normalized = expand_and_normalize(&path);
            Ok(normalized.to_string_lossy().to_string())
        })?,
    )?;

    // grime.fs.join(...) -> string
    fs_tbl.set(
        "join",
        lua.create_function(|_, parts: MultiValue| {
            let mut res = PathBuf::new();
            for val in parts {
                if let Value::String(s) = val {
                    let part = s.to_str()?;
                    if !part.is_empty() {
                        let expanded = expand_tilde(part.as_ref());
                        res.push(expanded.as_ref());
                    }
                }
            }
            let normalized = normalize_path(&res);
            Ok(normalized.to_string_lossy().to_string())
        })?,
    )?;
    fs_tbl.set("path_join", fs_tbl.get::<Value>("join")?)?;

    // grime.fs.list(path) -> table
    fs_tbl.set(
        "list",
        lua.create_function(|lua, path: Option<String>| {
            let p_str = path.unwrap_or_else(|| ".".to_string());
            let p = expand_tilde(&p_str);
            let tbl = lua.create_table()?;
            if let Ok(entries) = fs::read_dir(p.as_ref()) {
                for (idx, entry) in entries.flatten().enumerate() {
                    let name = entry.file_name().to_string_lossy().to_string();
                    tbl.set(idx + 1, name)?;
                }
            }
            Ok(tbl)
        })?,
    )?;

    grime_tbl.set("fs", fs_tbl)?;
    Ok(())
}
