//! Встроенный виртуальный модуль предзагрузки Lua (prelude).
//!
//! Регистрирует `package.preload["helper"]` и связывает глобали для обеспечения
//! прозрачной обратной совместимости со всеми существующими скриптами.

use mlua::Lua;

/// Регистрирует виртуальный модуль `helper` в таблице `package.preload`.
pub fn register_prelude(lua: &Lua) -> Result<(), mlua::Error> {
    let prelude = r#"
        package.preload["helper"] = function()
            return {
                ctx = grime.ctx,
                normalize_path = grime.fs.normalize,
                join = grime.fs.join,
                path_join = grime.fs.join,
                to_snake_case = grime.str.to_snake_case,
                to_kebab_case = grime.str.to_kebab_case,
                json_decode = grime.json.decode,
                json_encode = grime.json.encode,
                damerau_levenshtein = grime.fuzzy.damerau_levenshtein,
                similarity = grime.fuzzy.similarity,
                fuzzy_match_flag = grime.fuzzy.match_flag,
                normalize_flags = grime.fuzzy.normalize_flags,
                find_best_match = grime.fuzzy.find_best_match,
                fuzzy_match = grime.fuzzy.find_best_match,
            }
        end
        _G.ctx = grime.ctx
    "#;

    lua.load(prelude).set_name("@grime/prelude.lua").exec()?;
    Ok(())
}
