//! Модуль API управления процессами для Lua (grime.process).
//!
//! Предоставляет функции запуска команд, скриптов оболочки и захвата вывода.

use mlua::{Lua, Table, Value};
use std::collections::HashMap;
use std::path::PathBuf;

use crate::cancellation::PipelineCanceller;
use crate::process::{capture_command, run_command, run_interactive, run_shell};

/// Режим запуска команды без захвата вывода.
#[derive(Clone, Copy)]
pub enum RunMode {
    /// `grime.process.run`: строка выполняется через `run_shell`.
    Shell,
    /// `grime.process.run_interactive`: процесс наследует stdout/stderr.
    Interactive,
}

type EnvMap = Option<HashMap<String, String>>;

/// Команда из Lua: строка (shell-строка) или таблица аргументов.
fn command_args(cmd: &Value) -> mlua::Result<Option<Vec<String>>> {
    match cmd {
        Value::Table(tbl) => {
            let mut args = Vec::new();
            for item in tbl.clone().sequence_values::<String>() {
                args.push(item?);
            }
            Ok(Some(args))
        }
        _ => Ok(None),
    }
}

/// Запуск без захвата вывода (общая реализация для `grime.process.*` и `ctx.run_*`).
pub fn run_value(
    mode: RunMode,
    cmd: &Value,
    cwd: Option<String>,
    env: EnvMap,
    canceller: &PipelineCanceller,
) -> mlua::Result<i32> {
    let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let env_ref = env.as_ref();
    let code = match (cmd, mode) {
        (Value::String(s), RunMode::Shell) => run_shell(&s.to_str()?, &cwd_path, env_ref, Some(canceller)),
        (Value::String(s), RunMode::Interactive) => {
            let parts = vec!["sh".to_string(), "-c".to_string(), s.to_str()?.to_string()];
            run_interactive(&parts, &cwd_path, env_ref, Some(canceller))
        }
        (Value::Table(_), _) => {
            let args = command_args(cmd)?.unwrap_or_default();
            match mode {
                RunMode::Shell => run_command(&args, &cwd_path, env_ref, Some(canceller)),
                RunMode::Interactive => run_interactive(&args, &cwd_path, env_ref, Some(canceller)),
            }
        }
        _ => 1,
    };
    Ok(code)
}

/// Запуск с захватом вывода: возвращает таблицу `{ code, stdout, stderr }`.
pub fn capture_value(
    lua: &Lua,
    cmd: &Value,
    cwd: Option<String>,
    env: EnvMap,
    stdin_input: Option<String>,
    canceller: &PipelineCanceller,
) -> mlua::Result<Table> {
    let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let args = match (cmd, command_args(cmd)?) {
        (_, Some(args)) => args,
        (Value::String(s), None) => {
            vec!["sh".to_string(), "-c".to_string(), s.to_str()?.to_string()]
        }
        _ => return Err(mlua::Error::runtime("Ожидалась строка или таблица аргументов команды")),
    };
    let res = capture_command(&args, &cwd_path, env.as_ref(), stdin_input.as_deref(), Some(canceller));

    let res_tbl = lua.create_table()?;
    res_tbl.set("code", res.exit_code)?;
    res_tbl.set("stdout", res.stdout)?;
    res_tbl.set("stderr", res.stderr)?;
    Ok(res_tbl)
}

pub use crate::process::which_in;

/// Регистрирует подтаблицу `grime.process` со всеми функциями исполнения.
pub fn register_process_api(
    lua: &Lua,
    grime_tbl: &Table,
    canceller: PipelineCanceller,
) -> Result<(), mlua::Error> {
    let proc_tbl = lua.create_table()?;

    // grime.process.run(cmd, cwd, env) -> exit_code
    // grime.process.run_interactive(cmd, cwd, env) -> exit_code
    for (name, mode) in [("run", RunMode::Shell), ("run_interactive", RunMode::Interactive)] {
        let c = canceller.clone();
        proc_tbl.set(
            name,
            lua.create_function(move |_, (cmd, cwd, env): (Value, Option<String>, EnvMap)| {
                run_value(mode, &cmd, cwd, env, &c)
            })?,
        )?;
    }

    // grime.process.capture(cmd, cwd, env, stdin_input) -> { code = ..., stdout = ..., stderr = ... }
    let c_cap = canceller;
    proc_tbl.set(
        "capture",
        lua.create_function(
            move |lua, (cmd, cwd, env, stdin_input): (Value, Option<String>, EnvMap, Option<String>)| {
                capture_value(lua, &cmd, cwd, env, stdin_input, &c_cap)
            },
        )?,
    )?;

    // grime.process.memory_rss_kb() -> usize
    proc_tbl.set(
        "memory_rss_kb",
        lua.create_function(|_, ()| {
            if let Ok(content) = std::fs::read_to_string("/proc/self/statm") {
                if let Some(second) = content.split_whitespace().nth(1) {
                    if let Ok(pages) = second.parse::<usize>() {
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

    // grime.process.which(name) -> путь к исполняемому файлу или nil (обход $PATH без порождения процессов)
    proc_tbl.set(
        "which",
        lua.create_function(|_, name: String| {
            Ok(which_in(&name, std::env::var_os("PATH").as_deref()).map(|p| p.to_string_lossy().into_owned()))
        })?,
    )?;

    // grime.process.exe_path() -> путь текущего исполняемого файла (для самозапуска)
    proc_tbl.set(
        "exe_path",
        lua.create_function(|_, ()| {
            std::env::current_exe()
                .map(|p| p.to_string_lossy().into_owned())
                .map_err(|e| mlua::Error::external(format!("не удалось определить путь к исполняемому файлу: {}", e)))
        })?,
    )?;

    // grime.process.daemon_socket() -> путь Unix-сокета демона (единый источник правды с ядром)
    proc_tbl.set(
        "daemon_socket",
        lua.create_function(|_, ()| {
            Ok(crate::daemon::get_socket_path().to_string_lossy().into_owned())
        })?,
    )?;

    grime_tbl.set("process", proc_tbl)?;
    Ok(())
}

#[cfg(test)]
mod exe_path_tests {
    use super::*;

    #[test]
    fn exe_path_возвращает_текущий_бинарь() {
        let lua = Lua::new();
        let grime = lua.create_table().unwrap();
        register_process_api(&lua, &grime, PipelineCanceller::new()).unwrap();
        let proc_tbl: Table = grime.get("process").unwrap();
        let f: mlua::Function = proc_tbl.get("exe_path").unwrap();
        let got: String = f.call(()).unwrap();
        let expected = std::env::current_exe().unwrap();
        assert_eq!(got, expected.to_string_lossy());
        assert!(std::path::Path::new(&got).is_absolute());
    }
}

#[cfg(test)]
mod which_tests {
    use super::*;
    use std::path::Path;
    use std::ffi::OsString;
    use std::os::unix::fs::PermissionsExt;

    fn tmp_dir(tag: &str) -> crate::test_support::TempDir {
        crate::test_support::TempDir::new(&format!("which_{}", tag))
    }

    fn make(dir: &Path, name: &str, mode: u32) -> PathBuf {
        let p = dir.join(name);
        std::fs::write(&p, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(mode)).unwrap();
        p
    }

    #[test]
    fn which_ищет_по_path_и_проверяет_бит_исполнения() {
        let a = tmp_dir("a");
        let b = tmp_dir("b");
        make(&a, "noexec", 0o644);
        make(&a, "tool", 0o755);
        let b_tool = make(&b, "tool", 0o755);
        make(&b, "noexec", 0o755);
        std::fs::create_dir_all(a.join("dir")).unwrap();
        let path: OsString = std::env::join_paths([a.path(), b.path()]).unwrap();

        assert_eq!(which_in("tool", Some(&path)), Some(a.join("tool")));
        // Неисполняемый в первом каталоге пропускается, берётся из второго
        assert_eq!(which_in("noexec", Some(&path)), Some(b.join("noexec")));
        assert_eq!(which_in("dir", Some(&path)), None, "каталог — не исполняемый файл");
        assert_eq!(which_in("нет-такого", Some(&path)), None);
        assert_eq!(which_in("tool", None), None);
        assert_eq!(which_in("", Some(&path)), None);
        // Только второй каталог
        assert_eq!(which_in("tool", Some(b.as_os_str())), Some(b_tool.clone()));

        // Путь с '/' проверяется напрямую, PATH не нужен
        assert_eq!(which_in(b_tool.to_str().unwrap(), None), Some(b_tool));
        assert_eq!(which_in(a.join("noexec").to_str().unwrap(), None), None);
    }

    #[test]
    fn which_доступен_из_lua() {
        let lua = Lua::new();
        let grime = lua.create_table().unwrap();
        register_process_api(&lua, &grime, PipelineCanceller::new()).unwrap();
        lua.globals().set("grime", grime).unwrap();
        let found: Option<String> = lua.load("return grime.process.which('sh')").eval().unwrap();
        assert!(found.is_some_and(|p| p.ends_with("/sh")));
        let missing: Option<String> = lua.load("return grime.process.which('нет-такой-команды-xyz')").eval().unwrap();
        assert!(missing.is_none());
    }
}
