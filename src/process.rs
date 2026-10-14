use std::collections::HashMap;
use std::fs::File;
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::path::Path;
use std::process::{Command, Stdio};

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ProcessCaptureResult {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
}

pub fn run_command(
    cmd: &[String],
    cwd: &Path,
    env: Option<&HashMap<String, String>>,
) -> i32 {
    if cmd.is_empty() {
        return 0;
    }

    let effective_cwd = if cwd.exists() && cwd.is_dir() {
        cwd
    } else {
        Path::new(".")
    };

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
        Ok(status) => status.code().unwrap_or(1),
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
    let effective_cwd = if cwd.exists() && cwd.is_dir() {
        cwd
    } else {
        Path::new(".")
    };

    let mut command = Command::new("sh");
    command.arg("-c").arg(cmd_str);
    command.current_dir(effective_cwd);

    if let Some(envs) = env {
        command.envs(envs);
    }
    command.stdin(Stdio::inherit());

    match command.status() {
        Ok(status) => status.code().unwrap_or(1),
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

    let effective_cwd = if cwd.exists() && cwd.is_dir() {
        cwd
    } else {
        Path::new(".")
    };

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
            if let Some(data) = stdin_input {
                if let Some(mut sin) = child.stdin.take() {
                    use std::io::Write;
                    let _ = sin.write_all(data.as_bytes());
                    let _ = sin.flush();
                    drop(sin);
                }
            }

            match child.wait_with_output() {
                Ok(out) => ProcessCaptureResult {
                    exit_code: out.status.code().unwrap_or(0),
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

    let mut command = Command::new(&cmd[0]);
    if cmd.len() > 1 {
        command.args(&cmd[1..]);
    }
    command.current_dir(cwd);

    if let Some(envs) = env {
        command.envs(envs);
    }

    // Проверяем, является ли stdin терминалом
    let is_stdin_tty = unsafe { libc::isatty(libc::STDIN_FILENO) == 1 };
    let tty_in = if is_stdin_tty {
        File::open("/dev/tty").ok()
    } else {
        None
    };
    let tty_out = File::options().write(true).open("/dev/tty").ok();

    if let (Some(tin), Some(tout)) = (&tty_in, &tty_out) {
        unsafe {
            let in_fd = tin.as_raw_fd();
            let out_fd = tout.as_raw_fd();
            command.stdin(Stdio::from_raw_fd(libc::dup(in_fd)));
            command.stdout(Stdio::from_raw_fd(libc::dup(out_fd)));
            command.stderr(Stdio::from_raw_fd(libc::dup(out_fd)));
        }
    } else {
        command.stdin(Stdio::inherit());
        if let Some(tout) = &tty_out {
            unsafe {
                let out_fd = tout.as_raw_fd();
                command.stdout(Stdio::from_raw_fd(libc::dup(out_fd)));
                command.stderr(Stdio::from_raw_fd(libc::dup(out_fd)));
            }
        } else {
            command.stdout(Stdio::inherit());
            command.stderr(Stdio::inherit());
        }
    }

    match command.status() {
        Ok(status) => status.code().unwrap_or(0),
        Err(e) => {
            eprintln!("[Grime] Ошибка интерактивного процесса '{}': {}", cmd[0], e);
            1
        }
    }
}
