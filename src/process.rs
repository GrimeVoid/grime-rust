use std::collections::HashMap;
use std::os::unix::process::ExitStatusExt;
use std::path::Path;
use std::process::{Command, ExitStatus, Stdio};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProcessCaptureResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
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

pub fn run_command(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
) -> i32 {
    if cmd.is_empty() {
        return 0;
    }

    let effective_cwd = resolve_effective_cwd(cwd);

    let mut command = Command::new(&cmd[0]);
    if cmd.len() > 1 {
        command.args(&cmd[1..]);
    }
    command.current_dir(effective_cwd);

    if let Some(envs) = env {
        command.envs(envs);
    }
    command.stdin(Stdio::inherit());

    match command.status() {
        Ok(status) => extract_exit_code(status),
        Err(e) => {
            eprintln!("[Grime] Ошибка выполнения '{}': {}", cmd[0], e);
            1
        }
    }
}

pub fn run_shell(
    cmd_str: &str,
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
) -> i32 {
    let effective_cwd = resolve_effective_cwd(cwd);

    let mut command = Command::new("sh");
    command.arg("-c").arg(cmd_str);
    command.current_dir(effective_cwd);

    if let Some(envs) = env {
        command.envs(envs);
    }
    command.stdin(Stdio::inherit());

    match command.status() {
        Ok(status) => extract_exit_code(status),
        Err(e) => {
            eprintln!("[Grime] Ошибка shell-команды '{}': {}", cmd_str, e);
            1
        }
    }
}

pub fn capture_command(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
    stdin_input: Option<&str>,
) -> ProcessCaptureResult {
    if cmd.is_empty() {
        return ProcessCaptureResult {
            exit_code: 0,
            stdout: String::new(),
            stderr: String::new(),
        };
    }

    let effective_cwd = resolve_effective_cwd(cwd);

    let mut command = Command::new(&cmd[0]);
    if cmd.len() > 1 {
        command.args(&cmd[1..]);
    }
    command.current_dir(effective_cwd);
    if let Some(envs) = env {
        command.envs(envs);
    }

    if stdin_input.is_some() {
        command.stdin(Stdio::piped());
    } else {
        command.stdin(Stdio::null());
    }
    command.stdout(Stdio::piped());
    command.stderr(Stdio::piped());

    match command.spawn() {
        Ok(mut child) => {
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

            let out_res = child.wait_with_output();
            if let Some(handle) = stdin_writer {
                let _ = handle.join();
            }

            match out_res {
                Ok(out) => ProcessCaptureResult {
                    exit_code: extract_exit_code(out.status),
                    stdout: String::from_utf8_lossy(&out.stdout).to_string(),
                    stderr: String::from_utf8_lossy(&out.stderr).to_string(),
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

pub fn run_interactive(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
) -> i32 {
    if cmd.is_empty() {
        return 0;
    }

    let effective_cwd = resolve_effective_cwd(cwd);

    let mut command = Command::new(&cmd[0]);
    if cmd.len() > 1 {
        command.args(&cmd[1..]);
    }
    command.current_dir(effective_cwd);

    if let Some(envs) = env {
        command.envs(envs);
    }

    command.stdin(Stdio::inherit());
    command.stdout(Stdio::inherit());
    command.stderr(Stdio::inherit());

    match command.status() {
        Ok(status) => extract_exit_code(status),
        Err(e) => {
            eprintln!("[Grime] Ошибка интерактивного процесса '{}': {}", cmd[0], e);
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_capture_command_large_stdin_no_deadlock() {
        // 256 KB данных (больше 64 KB pipe buffer ядра Linux)
        let large_input = "A".repeat(256 * 1024);
        let cmd = vec!["cat".to_string()];
        let res = capture_command(&cmd, Path::new("."), None, Some(&large_input));
        assert_eq!(res.exit_code, 0);
        assert_eq!(res.stdout.len(), large_input.len());
    }

    #[test]
    fn test_signal_exit_code_128_plus_sig() {
        let cmd = vec![
            "sh".to_string(),
            "-c".to_string(),
            "kill -9 $$".to_string(),
        ];
        let res = capture_command(&cmd, Path::new("/nonexistent_cwd_fallback"), None, None);
        assert_eq!(res.exit_code, 128 + 9);
    }
}

