//! Модуль файловых операций для Lua (grime.fs).
//!
//! Обеспечивает безопасное взаимодействие с файловой системой без паник,
//! с развертыванием путей пользователя (`~`), проверками и нормализацией.

use mlua::{Lua, MultiValue, Table, Value};
use std::fs;
use std::path::PathBuf;

use crate::fs_ops::{copy_recursive, delete_safe, get_latest_mtime, is_newer, move_safe, normalize_path};

/// Регистрирует подтаблицу `grime.fs` со всеми файловыми функциями.
pub fn register_fs_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let fs_tbl = lua.create_table()?;

    // grime.fs.normalize(path) -> string
    fs_tbl.set(
        "normalize",
        lua.create_function(|_, path: String| {
            let expanded = shellexpand::tilde(&path).to_string();
            let p = PathBuf::from(&expanded);
            let normalized = normalize_path(&p);
            Ok(normalized.to_string_lossy().to_string())
        })?,
    )?;

    // grime.fs.exists(path) -> bool
    fs_tbl.set(
        "exists",
        lua.create_function(|_, path: String| {
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            Ok(p.exists())
        })?,
    )?;

    // grime.fs.is_dir(path) -> bool
    fs_tbl.set(
        "is_dir",
        lua.create_function(|_, path: String| {
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            Ok(p.is_dir())
        })?,
    )?;

    // grime.fs.is_file(path) -> bool
    fs_tbl.set(
        "is_file",
        lua.create_function(|_, path: String| {
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            Ok(p.is_file())
        })?,
    )?;

    // grime.fs.mkdir_p(path) -> bool
    fs_tbl.set(
        "mkdir_p",
        lua.create_function(|_, path: String| {
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            match fs::create_dir_all(&p) {
                Ok(_) => Ok(true),
                Err(e) => Err(mlua::Error::runtime(format!("Ошибка создания каталога '{}': {}", p.display(), e))),
            }
        })?,
    )?;

    // grime.fs.delete(path, missing_ok) -> bool
    fs_tbl.set(
        "delete",
        lua.create_function(|_, (path, missing_ok): (String, Option<bool>)| {
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            match delete_safe(&p, missing_ok.unwrap_or(true)) {
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
            let s = PathBuf::from(shellexpand::tilde(&src).to_string());
            let d = PathBuf::from(shellexpand::tilde(&dst).to_string());
            match copy_recursive(&s, &d) {
                Ok(res) => Ok(res.to_string_lossy().to_string()),
                Err(e) => Err(mlua::Error::runtime(e)),
            }
        })?,
    )?;

    // grime.fs.move(src, dst) -> string
    fs_tbl.set(
        "move",
        lua.create_function(|_, (src, dst): (String, String)| {
            let s = PathBuf::from(shellexpand::tilde(&src).to_string());
            let d = PathBuf::from(shellexpand::tilde(&dst).to_string());
            match move_safe(&s, &d) {
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
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            Ok(get_latest_mtime(&p))
        })?,
    )?;

    // grime.fs.is_newer(src, target) -> bool
    fs_tbl.set(
        "is_newer",
        lua.create_function(|_, (src, target): (String, String)| {
            let s = PathBuf::from(shellexpand::tilde(&src).to_string());
            let t = PathBuf::from(shellexpand::tilde(&target).to_string());
            Ok(is_newer(&s, &t))
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
                        let expanded = shellexpand::tilde(part.as_ref()).to_string();
                        res.push(expanded);
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
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            match fs::read_to_string(&p) {
                Ok(s) => Ok(Some(s)),
                Err(_) => Ok(None),
            }
        })?,
    )?;

    // grime.fs.write(path, content) -> bool
    fs_tbl.set(
        "write",
        lua.create_function(|_, (path, content): (String, String)| {
            let p = PathBuf::from(shellexpand::tilde(&path).to_string());
            if let Some(parent) = p.parent() {
                let _ = fs::create_dir_all(parent);
            }
            match fs::write(&p, content) {
                Ok(_) => Ok(true),
                Err(e) => Err(mlua::Error::runtime(format!("Ошибка записи файла '{}': {}", p.display(), e))),
            }
        })?,
    )?;

    // grime.fs.list(path) -> table
    fs_tbl.set(
        "list",
        lua.create_function(|lua, path: Option<String>| {
            let p_str = path.unwrap_or_else(|| ".".to_string());
            let p = PathBuf::from(shellexpand::tilde(&p_str).to_string());
            let tbl = lua.create_table()?;
            if let Ok(entries) = fs::read_dir(&p) {
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
