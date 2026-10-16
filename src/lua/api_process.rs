//! Модуль API управления процессами для Lua (grime.process).
//!
//! Предоставляет функции запуска команд, скриптов оболочки и захвата вывода.

use mlua::{Lua, Table, Value};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::process::{capture_command, run_command, run_interactive, run_shell};

/// Регистрирует подтаблицу `grime.process` со всеми функциями исполнения.
pub fn register_process_api(lua: &Lua, grime_tbl: &Table) -> Result<(), mlua::Error> {
    let proc_tbl = lua.create_table()?;

    // grime.process.run(cmd, cwd, env) -> exit_code
    proc_tbl.set(
        "run",
        lua.create_function(|_, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
            let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
            let code = match cmd {
                Value::String(s) => {
                    let cmd_str = s.to_str()?;
                    run_shell(&cmd_str, &cwd_path, env.as_ref())
                }
                Value::Table(tbl) => {
                    let mut args = Vec::new();
                    for item in tbl.sequence_values::<String>() {
                        args.push(item?);
                    }
                    run_command(&args, &cwd_path, env.as_ref())
                }
                _ => 1,
            };
            Ok(code)
        })?,
    )?;

    // grime.process.run_interactive(cmd, cwd, env) -> exit_code
    proc_tbl.set(
        "run_interactive",
        lua.create_function(|_, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
            let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
            let code = match cmd {
                Value::String(s) => {
                    let cmd_str = s.to_str()?;
                    let parts = vec!["sh".to_string(), "-c".to_string(), cmd_str.to_string()];
                    run_interactive(&parts, &cwd_path, env.as_ref())
                }
                Value::Table(tbl) => {
                    let mut args = Vec::new();
                    for item in tbl.sequence_values::<String>() {
                        args.push(item?);
                    }
                    run_interactive(&args, &cwd_path, env.as_ref())
                }
                _ => 1,
            };
            Ok(code)
        })?,
    )?;

    // grime.process.capture(cmd, cwd, env, stdin_input) -> { code = ..., stdout = ..., stderr = ... }
    proc_tbl.set(
        "capture",
        lua.create_function(|lua, (cmd, cwd, env, stdin_input): (Value, Option<String>, Option<HashMap<String, String>>, Option<String>)| {
            let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
            let stdin_ref = stdin_input.as_deref();
            let res = match cmd {
                Value::String(s) => {
                    let cmd_str = s.to_str()?;
                    let parts = vec!["sh".to_string(), "-c".to_string(), cmd_str.to_string()];
                    capture_command(&parts, &cwd_path, env.as_ref(), stdin_ref)
                }
                Value::Table(tbl) => {
                    let mut args = Vec::new();
                    for item in tbl.sequence_values::<String>() {
                        args.push(item?);
                    }
                    capture_command(&args, &cwd_path, env.as_ref(), stdin_ref)
                }
                _ => return Err(mlua::Error::runtime("Ожидалась строка или таблица аргументов команды")),
            };

            let res_tbl = lua.create_table()?;
            res_tbl.set("code", res.exit_code)?;
            res_tbl.set("stdout", res.stdout)?;
            res_tbl.set("stderr", res.stderr)?;
            Ok(res_tbl)
        })?,
    )?;

    // grime.process.memory_rss_kb() -> usize
    proc_tbl.set(
        "memory_rss_kb",
        lua.create_function(|_, ()| {
            if let Ok(content) = std::fs::read_to_string("/proc/self/statm") {
                let parts: Vec<&str> = content.split_whitespace().collect();
                if parts.len() > 1 {
                    if let Ok(pages) = parts[1].parse::<usize>() {
                        let page_size_kb = {
                            let sz = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
                            if sz > 0 {
                                (sz as usize) / 1024
                            } else {
                                4
                            }
                        };
                        return Ok(pages * page_size_kb);
                    }
                }
            }
            Ok(0)
        })?,
    )?;

    grime_tbl.set("process", proc_tbl)?;
    Ok(())
}
