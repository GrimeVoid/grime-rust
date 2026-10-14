use colored::Colorize;
use notify::{Event, RecursiveMode, Watcher};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::sync::RwLock;

use crate::orchestrator::Orchestrator;
use crate::pipeline::parse_pipeline_args;

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct ClientRequest {
    pub cwd: String,
    pub args: Vec<String>,
    pub env: HashMap<String, String>,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct DaemonResponse {
    pub success: bool,
    pub exit_code: i32,
    pub result: Option<String>,
    pub error: Option<String>,
}

pub fn get_socket_path() -> PathBuf {
    if let Ok(runtime_dir) = std::env::var("XDG_RUNTIME_DIR") {
        return PathBuf::from(runtime_dir).join("grime.sock");
    }

    let uid = unsafe { libc::getuid() };
    let run_user = PathBuf::from(format!("/run/user/{}", uid));
    if run_user.exists() {
        return run_user.join("grime.sock");
    }

    PathBuf::from(format!("/tmp/grime-{}.sock", uid))
}

pub async fn run_daemon(modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> Result<(), Box<dyn std::error::Error>> {
    let sock_path = get_socket_path();
    if sock_path.exists() {
        let _ = fs::remove_file(&sock_path);
    }

    if let Some(parent) = sock_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let listener = UnixListener::bind(&sock_path)?;
    println!(
        "{} Демон grimed запущен на сокете: {}",
        "[grimed]".green().bold(),
        sock_path.display()
    );

    let orchestrator = Arc::new(RwLock::new(Orchestrator::new(
        modules_dir.clone(),
        config_path,
    )?));

    // Настройка Hot-Reload через notify
    let mod_dir_to_watch = modules_dir.unwrap_or_else(|| PathBuf::from("modules"));
    if mod_dir_to_watch.exists() {
        let orch_reload = orchestrator.clone();
        let watch_dir = mod_dir_to_watch.clone();
        let conf_p = config_path.map(|p| p.to_path_buf());

        std::thread::spawn(move || {
            let (tx, rx) = std::sync::mpsc::channel();
            let mut watcher = match notify::recommended_watcher(tx) {
                Ok(w) => w,
                Err(e) => {
                    eprintln!("Не удалось запустить watcher: {}", e);
                    return;
                }
            };

            if let Err(e) = watcher.watch(&watch_dir, RecursiveMode::Recursive) {
                eprintln!("Ошибка наблюдения за директорией {:?}: {}", watch_dir, e);
                return;
            }

            println!(
                "{} Hot-reload активен для каталога: {}",
                "[grimed]".green().bold(),
                watch_dir.display()
            );

            for res in rx {
                if let Ok(Event { paths, .. }) = res {
                    let has_lua = paths.iter().any(|p| p.extension().map_or(false, |ext| ext == "lua"));
                    if has_lua {
                        println!(
                            "{} Обнаружено изменение Lua-модулей! Перезагрузка состояния...",
                            "[grimed Hot-Reload]".yellow().bold()
                        );
                        if let Ok(new_orch) = Orchestrator::new(Some(watch_dir.clone()), conf_p.as_deref()) {
                            let mut lock = orch_reload.blocking_write();
                            *lock = new_orch;
                            println!(
                                "{} Модули успешно обновлены в памяти демона.",
                                "[grimed Hot-Reload]".green().bold()
                            );
                        }
                    }
                }
            }
        });
    }

    // Обработка входящих соединений
    loop {
        match listener.accept().await {
            Ok((mut socket, _)) => {
                let orch = orchestrator.clone();
                tokio::spawn(async move {
                    let mut len_buf = [0u8; 4];
                    if socket.read_exact(&mut len_buf).await.is_err() {
                        return;
                    }
                    let payload_len = u32::from_be_bytes(len_buf) as usize;
                    let mut payload = vec![0u8; payload_len];
                    if socket.read_exact(&mut payload).await.is_err() {
                        return;
                    }

                    let req: ClientRequest = match serde_json::from_slice(&payload) {
                        Ok(r) => r,
                        Err(e) => {
                            let resp = DaemonResponse {
                                success: false,
                                exit_code: 1,
                                result: None,
                                error: Some(format!("Ошибка парсинга запроса: {}", e)),
                            };
                            let _ = send_response(&mut socket, &resp).await;
                            return;
                        }
                    };

                    let parsed = parse_pipeline_args(&req.args);
                    let orch_lock = orch.read().await;

                    let resp = match orch_lock.run_pipeline(&parsed).await {
                        Ok(res) => DaemonResponse {
                            success: true,
                            exit_code: 0,
                            result: res,
                            error: None,
                        },
                        Err(err) => DaemonResponse {
                            success: false,
                            exit_code: 1,
                            result: None,
                            error: Some(err),
                        },
                    };

                    let _ = send_response(&mut socket, &resp).await;
                });
            }
            Err(e) => {
                eprintln!("[grimed] Ошибка accept: {}", e);
            }
        }
    }
}

async fn send_response(socket: &mut tokio::net::UnixStream, resp: &DaemonResponse) -> Result<(), std::io::Error> {
    let bytes = serde_json::to_vec(resp)?;
    let len = (bytes.len() as u32).to_be_bytes();
    socket.write_all(&len).await?;
    socket.write_all(&bytes).await?;
    socket.flush().await?;
    Ok(())
}
