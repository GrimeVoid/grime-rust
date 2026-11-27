//! API эфемерных ресурсов для Lua (`grime.ephemeral`), см. [`crate::ephemeral`].
//!
//! - `grime.ephemeral.dir(prefix?)` -> путь нового каталога (0700)
//! - `grime.ephemeral.file(content?, suffix?)` -> путь нового файла (0600), запись атомарна
//!
//! Всё удаляется ядром в конце конвейера (успех, ошибка, отмена, паника).

use mlua::{Lua, Table};
use std::sync::Arc;

use crate::ephemeral::EphemeralSession;

fn to_lua_err(e: std::io::Error) -> mlua::Error {
    mlua::Error::runtime(format!("grime.ephemeral: {}", e))
}

/// Регистрирует `grime.ephemeral`.
pub fn register_ephemeral_api(
    lua: &Lua,
    grime_tbl: &Table,
    session: Arc<EphemeralSession>,
) -> Result<(), mlua::Error> {
    let tbl = lua.create_table()?;

    let s = session.clone();
    tbl.set(
        "dir",
        lua.create_function(move |_, prefix: Option<String>| {
            let p = s.dir(prefix.as_deref()).map_err(to_lua_err)?;
            Ok(p.to_string_lossy().into_owned())
        })?,
    )?;

    tbl.set(
        "file",
        lua.create_function(move |_, (content, suffix): (Option<mlua::String>, Option<String>)| {
            let bytes = content.as_ref().map(|c| c.as_bytes());
            let p = session.file(bytes.as_deref(), suffix.as_deref()).map_err(to_lua_err)?;
            Ok(p.to_string_lossy().into_owned())
        })?,
    )?;

    grime_tbl.set("ephemeral", tbl)?;
    Ok(())
}
