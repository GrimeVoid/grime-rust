//! Модуль файловых операций для Lua (grime.fs).
//!
//! Обеспечивает безопасное взаимодействие с файловой системой без паник,
//! с развертыванием путей пользователя (`~`), проверками и нормализацией.

use mlua::{Lua, MultiValue, Table, Value};
use std::fs;
use std::path::PathBuf;

use crate::fs_ops::{
    copy_recursive, delete_safe, expand_and_normalize, expand_tilde, get_latest_mtime, is_newer,
    move_safe, normalize_path,
};

/// Регистрирует подтаблицу `grime.fs` со всеми файловыми функциями.
pub fn register_fs_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let fs_tbl = lua.create_table()?;

    // grime.fs.normalize(path) -> string
    fs_tbl.set(
        "normalize",
        lua.create_function(|_, path: String| {
            let normalized = expand_and_normalize(&path);
            Ok(normalized.to_string_lossy().to_string())
        })?,
    )?;

    // grime.fs.exists(path) -> bool
    fs_tbl.set(
        "exists",
        lua.create_function(|_, path: String| {
            let p = expand_tilde(&path);
            Ok(p.as_ref().exists())
        })?,
    )?;

    // grime.fs.is_dir(path) -> bool
    fs_tbl.set(
        "is_dir",
        lua.create_function(|_, path: String| {
            let p = expand_tilde(&path);
            Ok(p.as_ref().is_dir())
        })?,
    )?;

    // grime.fs.is_file(path) -> bool
    fs_tbl.set(
        "is_file",
        lua.create_function(|_, path: String| {
            let p = expand_tilde(&path);
            Ok(p.as_ref().is_file())
        })?,
    )?;

    // grime.fs.mkdir_p(path) -> bool
    fs_tbl.set(
        "mkdir_p",
        lua.create_function(|_, path: String| {
            let p = expand_tilde(&path);
            match fs::create_dir_all(p.as_ref()) {
                Ok(_) => Ok(true),
                Err(e) => Err(mlua::Error::runtime(format!("Ошибка создания каталога '{}': {}", p.as_ref().display(), e))),
            }
        })?,
    )?;

    // grime.fs.delete(path, missing_ok) -> bool
    fs_tbl.set(
        "delete",
        lua.create_function(|_, (path, missing_ok): (String, Option<bool>)| {
            let p = expand_tilde(&path);
            match delete_safe(p.as_ref(), missing_ok.unwrap_or(true)) {
                Ok(val) => Ok(val),
                Err(e) => Err(mlua::Error::runtime(e)),
            }
        })?,
    )?;
    fs_tbl.set("remove", fs_tbl.get::<Value>("delete")?)?;

    // grime.fs.copy(src, dst) -> string
    fs_tbl.set(
        "copy",
        lua.create_function(|_, (src, dst): (String, String)| {
            let s = expand_tilde(&src);
            let d = expand_tilde(&dst);
            match copy_recursive(s.as_ref(), d.as_ref()) {
                Ok(res) => Ok(res.to_string_lossy().to_string()),
                Err(e) => Err(mlua::Error::runtime(e)),
            }
        })?,
    )?;

    // grime.fs.move(src, dst) -> string
    fs_tbl.set(
        "move",
        lua.create_function(|_, (src, dst): (String, String)| {
            let s = expand_tilde(&src);
            let d = expand_tilde(&dst);
            match move_safe(s.as_ref(), d.as_ref()) {
                Ok(res) => Ok(res.to_string_lossy().to_string()),
                Err(e) => Err(mlua::Error::runtime(e)),
            }
        })?,
    )?;
    fs_tbl.set("rename", fs_tbl.get::<Value>("move")?)?;

    // grime.fs.mtime(path) -> f64
    fs_tbl.set(
        "mtime",
        lua.create_function(|_, path: String| {
            let p = expand_tilde(&path);
            Ok(get_latest_mtime(p.as_ref()))
        })?,
    )?;

    // grime.fs.is_newer(src, target) -> bool
    fs_tbl.set(
        "is_newer",
        lua.create_function(|_, (src, target): (String, String)| {
            let s = expand_tilde(&src);
            let t = expand_tilde(&target);
            Ok(is_newer(s.as_ref(), t.as_ref()))
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

    // grime.fs.read(path) -> string | nil
    fs_tbl.set(
        "read",
        lua.create_function(|_, path: String| {
            let p = expand_tilde(&path);
            match fs::read_to_string(p.as_ref()) {
                Ok(s) => Ok(Some(s)),
                Err(_) => Ok(None),
            }
        })?,
    )?;

    // grime.fs.write(path, content) -> bool
    fs_tbl.set(
        "write",
        lua.create_function(|_, (path, content): (String, String)| {
            let p = expand_tilde(&path);
            if let Some(parent) = p.as_ref().parent() {
                let _ = fs::create_dir_all(parent);
            }
            match fs::write(p.as_ref(), content) {
                Ok(_) => Ok(true),
                Err(e) => Err(mlua::Error::runtime(format!("Ошибка записи файла '{}': {}", p.as_ref().display(), e))),
            }
        })?,
    )?;

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
