//! API реестра модулей для Lua (`grime.modules`).
//!
//! - `grime.modules.list()` -> массив `{ name, description, aliases, boundary, wraps, chain, path, paths }`
//! - `grime.modules.get(name_or_alias)` -> такая же таблица или `nil`
//! - `requires` в таблице модуля — массив `{ kind = "module"|"bin"|"nix", name, optional }`
//! - `grime.modules.deps(name)` -> порядок разрешения модулей (зависимости раньше, сам модуль последним)
//!   либо `nil, сообщение` (цикл, отсутствующий обязательный модуль)
//! - `grime.modules.resolve(name)` -> каноническое имя (точное → алиас → fuzzy) или `nil`

use mlua::{Lua, Table};
use std::sync::Arc;

use crate::modules::{ModuleMeta, ModuleRegistry};

fn meta_to_table(lua: &Lua, meta: &ModuleMeta) -> mlua::Result<Table> {
    let t = lua.create_table()?;
    t.set("name", meta.name.as_str())?;
    t.set("description", meta.description.as_str())?;
    let aliases = lua.create_table()?;
    for (i, a) in meta.aliases.iter().enumerate() {
        aliases.set(i + 1, a.as_str())?;
    }
    t.set("aliases", aliases)?;
    t.set("boundary", meta.boundary)?;
    t.set("wraps", meta.wraps.as_deref())?;
    t.set("chain", meta.chain.as_deref())?;
    t.set("path", meta.path.to_string_lossy().to_string())?;
    let paths = lua.create_table()?;
    for (k, v) in &meta.paths {
        paths.set(k.as_str(), v.as_str())?;
    }
    t.set("paths", paths)?;
    let requires = lua.create_table()?;
    for (i, d) in meta.requires.iter().enumerate() {
        let e = lua.create_table()?;
        e.set("kind", d.kind.as_str())?;
        e.set("name", d.name.as_str())?;
        e.set("optional", d.optional)?;
        requires.set(i + 1, e)?;
    }
    t.set("requires", requires)?;
    Ok(t)
}

/// Регистрирует `grime.modules`.
pub fn register_modules_api(
    lua: &Lua,
    grime_tbl: &Table,
    registry: Arc<ModuleRegistry>,
) -> Result<(), mlua::Error> {
    let tbl = lua.create_table()?;

    let reg = registry.clone();
    tbl.set(
        "list",
        lua.create_function(move |lua, ()| {
            let out = lua.create_table()?;
            for (i, meta) in reg.list().iter().enumerate() {
                out.set(i + 1, meta_to_table(lua, meta)?)?;
            }
            Ok(out)
        })?,
    )?;

    let reg = registry.clone();
    tbl.set(
        "get",
        lua.create_function(move |lua, name: String| {
            reg.get(&name).map(|m| meta_to_table(lua, &m)).transpose()
        })?,
    )?;

    let reg = registry.clone();
    tbl.set(
        "deps",
        lua.create_function(move |lua, name: String| {
            let canonical = reg.canonical_name(&name);
            match crate::deps::resolve_order(&reg, &[canonical]) {
                Ok(order) => {
                    let out = lua.create_table()?;
                    for (i, n) in order.iter().enumerate() {
                        out.set(i + 1, n.as_str())?;
                    }
                    Ok((Some(out), None))
                }
                Err(errs) => Ok((None, Some(errs.join("; ")))),
            }
        })?,
    )?;

    tbl.set(
        "resolve",
        lua.create_function(move |_, name: String| Ok(registry.resolve(&name)))?,
    )?;

    grime_tbl.set("modules", tbl)?;
    Ok(())
}
