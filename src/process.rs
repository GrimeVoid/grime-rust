use std::collections::HashMap;
use std::io::Read;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};

use crate::cancellation::{ChildRegistration, PipelineCanceller};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProcessCaptureResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Исполняемый ли обычный файл по пути (с разыменованием симлинков): `mode & 0o111 != 0`.
fn is_executable_file(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Поиск исполняемого файла как `which`, но без порождения процесса.
/// Имя с `/` проверяется напрямую; иначе обходятся каталоги `path_var` (пустой элемент — текущий каталог).
pub fn which_in(name: &str, path_var: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    if name.contains('/') {
        let p = PathBuf::from(name);
        return is_executable_file(&p).then_some(p);
    }
    let path_var = path_var?;
    std::env::split_paths(path_var)
        .map(|dir| if dir.as_os_str().is_empty() { PathBuf::from(".") } else { dir })
        .map(|dir| dir.join(name))
        .find(|candidate| is_executable_file(candidate))
}

#[inline]
fn extract_exit_code(status: ExitStatus) -> i32 {
    if let Some(code) = status.code() {
        code
    } else if let Some(sig) = status.signal() {
        128 + sig
    } else {
        1
    }
}

#[inline]
fn resolve_effective_cwd(cwd: &Path) -> &Path {
    if cwd.exists() && cwd.is_dir() {
        cwd
    } else {
        Path::new(".")
    }
}

/// Общий билдер `Command`: аргументы, рабочий каталог (с откатом на `.`) и окружение.
fn build_command(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
) -> Command {
    let mut command = Command::new(&cmd[0]);
    command.args(&cmd[1..]);
    command.current_dir(resolve_effective_cwd(cwd));
    if let Some(envs) = env {
        command.envs(envs);
    }
    command
}

/// Является ли stdin процесса-родителя терминалом.
/// Для TTY-stdin дочерний процесс нельзя выносить в отдельную группу процессов:
/// фоновая группа получила бы SIGTTIN при чтении с терминала.
fn stdin_is_tty() -> bool {
    unsafe { libc::isatty(0) == 1 }
}

fn execute_command_internal(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
    canceller: Option<&PipelineCanceller>,
    interactive: bool,
    err_prefix: &str,
) -> i32 {
    if cmd.is_empty() {
        return 0;
    }

    let mut command = build_command(cmd, cwd, env);
    command.stdin(Stdio::inherit());

    // Неинтерактивный процесс делаем лидером собственной группы, чтобы при отмене сигнал
    // получали и подпроцессы (sh -c ...), но только если stdin не терминал (иначе SIGTTIN).
    // Отмена по PID продолжает работать и без отдельной группы.
    let own_group = !interactive && !stdin_is_tty();
    if interactive {
        command.stdout(Stdio::inherit());
        command.stderr(Stdio::inherit());
    } else if own_group {
        command.process_group(0);
    }

    let reg = ChildRegistration {
        process_group: own_group,
        interactive,
    };

    match command.spawn() {
        Ok(mut child) => {
            let pid = child.id();
            if let Some(c) = canceller {
                c.register_child(pid, reg);
            }
            let wait_res = child.wait();
            if let Some(c) = canceller {
                c.unregister_child_pid(pid);
            }
            match wait_res {
                Ok(status) => extract_exit_code(status),
                Err(e) => {
                    eprintln!("[Grime] {} '{}': {}", err_prefix, cmd[0], e);
                    1
                }
            }
        }
        Err(e) => {
            eprintln!("[Grime] {} '{}': {}", err_prefix, cmd[0], e);
            1
        }
    }
}

pub fn run_command(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
    canceller: Option<&PipelineCanceller>,
) -> i32 {
    execute_command_internal(
        cmd,
        cwd,
        env,
        canceller,
        false,
        "Ошибка выполнения",
    )
}

pub fn run_interactive(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
    canceller: Option<&PipelineCanceller>,
) -> i32 {
    execute_command_internal(
        cmd,
        cwd,
        env,
        canceller,
        true,
        "Ошибка интерактивного процесса",
    )
}

pub fn run_shell(
    cmd_str: &str,
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
    canceller: Option<&PipelineCanceller>,
) -> i32 {
    let parts = [
        "sh".to_string(),
        "-c".to_string(),
        cmd_str.to_string(),
    ];
    execute_command_internal(
        &parts,
        cwd,
        env,
        canceller,
        false,
        "Ошибка shell-команды",
    )
}

pub fn capture_command(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
    stdin_input: Option<&str>,
    canceller: Option<&PipelineCanceller>,
) -> ProcessCaptureResult {
    if cmd.is_empty() {
        return ProcessCaptureResult {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        };
    }

    let mut command = build_command(cmd, cwd, env);

    if stdin_input.is_some() {
        command.stdin(Stdio::piped());
    } else {
        command.stdin(Stdio::null());
    }
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());
    command.process_group(0);

    match command.spawn() {
        Ok(mut child) => {
            let pid = child.id();
            if let Some(c) = canceller {
                c.register_child(
                    pid,
                    ChildRegistration {
                        process_group: true,
                        interactive: false,
                    },
                );
            }

            let stdin_writer = if let Some(data) = stdin_input {
                if let Some(mut sin) = child.stdin.take() {
                    let owned_bytes = data.as_bytes().to_vec();
                    Some(std::thread::spawn(move || {
                        use std::io::Write;
                        let _ = sin.write_all(&owned_bytes);
                        let _ = sin.flush();
                    }))
                } else {
                    None
                }
            } else {
                None
            };

            let stdout_reader = child.stdout.take().map(|mut out| {
                std::thread::spawn(move || {
                    let mut buf = Vec::new();
                    let _ = out.read_to_end(&mut buf);
                    buf
                })
            });

            let stderr_reader = child.stderr.take().map(|mut err| {
                std::thread::spawn(move || {
                    let mut buf = Vec::new();
                    let _ = err.read_to_end(&mut buf);
                    buf
                })
            });

            let status_res = child.wait();
            if let Some(c) = canceller {
                c.unregister_child_pid(pid);
            }

            if let Some(handle) = stdin_writer {
                let _ = handle.join();
            }
            let stdout_bytes = stdout_reader
                .and_then(|h| h.join().ok())
                .unwrap_or_default();
            let stderr_bytes = stderr_reader
                .and_then(|h| h.join().ok())
                .unwrap_or_default();

            match status_res {
                Ok(status) => ProcessCaptureResult {
                    exit_code: extract_exit_code(status),
                    stdout: String::from_utf8_lossy(&stdout_bytes).to_string(),
                    stderr: String::from_utf8_lossy(&stderr_bytes).to_string(),
                },
                Err(e) => ProcessCaptureResult {
                    exit_code: 1,
                    stdout: String::new(),
                    stderr: format!("Ошибка ожидания процесса: {}", e),
                },
            }
        }
        Err(e) => ProcessCaptureResult {
            exit_code: 1,
            stdout: String::new(),
            stderr: format!("Ошибка запуска процесса: {}", e),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn test_capture_command_large_stdin_no_deadlock() {
        // 256 KB данных (больше 64 KB pipe buffer ядра Linux)
        let large_input = "A".repeat(256 * 1024);
        let cmd = vec!["cat".to_string()];
        let res = capture_command(&cmd, Path::new("."), None, Some(&large_input), None);
        assert_eq!(res.exit_code, 0);
        assert_eq!(res.stdout.len(), large_input.len());
    }

    #[test]
    fn test_non_interactive_command_reading_stdin_does_not_hang() {
        // Неинтерактивная команда, читающая stdin, не должна зависать по SIGTTIN:
        // при TTY-stdin она остаётся в foreground-группе, иначе получает свою группу.
        // Здесь stdin родителя перенаправлен в /dev/null через sh, чтобы тест был детерминирован.
        let cmd = vec![
            "sh".to_string(),
            "-c".to_string(),
            "read x < /dev/null; exit 0".to_string(),
        ];
        let start = Instant::now();
        assert_eq!(run_command(&cmd, Path::new("."), None, None), 0);
        assert!(start.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn test_signal_exit_code_128_plus_sig() {
        let cmd = vec![
            "sh".to_string(),
            "-c".to_string(),
            "kill -9 $$".to_string(),
        ];
        let res = capture_command(&cmd, Path::new("/nonexistent_cwd_fallback"), None, None, None);
        assert_eq!(res.exit_code, 128 + 9);
    }

    #[test]
    fn test_pipeline_canceller_terminates_long_running_child() {
        let canceller = PipelineCanceller::new();
        let c_for_thread = canceller.clone();

        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(80));
            c_for_thread.cancel("Тестовая отмена долгого процесса");
        });

        let start = Instant::now();
        let cmd = vec![
            "sh".to_string(),
            "-c".to_string(),
            "sleep 30".to_string(),
        ];
        let code = run_command(&cmd, Path::new("."), None, Some(&canceller));
        let elapsed = start.elapsed();

        assert_ne!(code, 0, "Прерванный процесс не должен возвращать 0");
        assert!(
            elapsed < Duration::from_secs(3),
            "Процесс должен быть прерван за ~80мс, а не спать 30с (прошло {:?})",
            elapsed
        );
        assert_eq!(canceller.active_child_count(), 0);
    }
}

