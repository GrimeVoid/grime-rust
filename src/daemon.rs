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
use crate::supervisor::{TaskStatus, TaskSupervisor};

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub enum ClientMessage {
    Run {
        cwd: String,
        args: Vec<String>,
        env: HashMap<String, String>,
        detach: bool,
    },
    Ping,
    TaskStatus {
        task_id: String,
    },
    KillTask {
        task_id: String,
    },
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
pub struct DaemonResponse {
    pub success: bool,
    pub exit_code: i32,
    pub result: Option<String>,
    pub error: Option<String>,
    pub detached: bool,
    pub task_id: Option<String>,
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
        "{} Демон grimed запущен на сокете: {} (Протокол: MessagePack)",
        "[grimed]".green().bold(),
        sock_path.display()
    );

    let orchestrator = Arc::new(RwLock::new(Orchestrator::new(
        modules_dir.clone(),
        config_path,
    )?));

    let supervisor = Arc::new(TaskSupervisor::default());

    // Настройка Hot-Reload через notify
    let mod_dir_to_watch = modules_dir.clone().unwrap_or_else(|| PathBuf::from("modules"));
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

    let conf_path_buf = config_path.map(|p| p.to_path_buf());

    // Обработка входящих соединений
    loop {
        match listener.accept().await {
            Ok((mut socket, _)) => {
                let orch = orchestrator.clone();
                let sup = supervisor.clone();
                let m_dir = modules_dir.clone();
                let c_path = conf_path_buf.clone();

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

                    // Десериализация MessagePack
                    let msg: ClientMessage = match rmp_serde::from_slice(&payload) {
                        Ok(m) => m,
                        Err(e) => {
                            let resp = DaemonResponse {
                                success: false,
                                exit_code: 1,
                                result: None,
                                error: Some(format!("Ошибка парсинга MessagePack: {}", e)),
                                detached: false,
                                task_id: None,
                            };
                            let _ = send_msgpack_response(&mut socket, &resp).await;
                            return;
                        }
                    };

                    match msg {
                        ClientMessage::Run { args, detach, .. } => {
                            let parsed = parse_pipeline_args(&args);

                            if detach || parsed.detach {
                                // Запуск открепленной задачи в супервизоре с Heartbeat
                                let task_id = sup
                                    .spawn_detached_pipeline(parsed, m_dir, c_path)
                                    .await;

                                let resp = DaemonResponse {
                                    success: true,
                                    exit_code: 0,
                                    result: Some(format!("Задача успешно откреплена (Task ID: {})", task_id)),
                                    error: None,
                                    detached: true,
                                    task_id: Some(task_id),
                                };
                                let _ = send_msgpack_response(&mut socket, &resp).await;
                            } else {
                                // Сервисное выполнение через демон
                                let orch_lock = orch.read().await;
                                let resp = match orch_lock.run_pipeline(&parsed).await {
                                    Ok(res) => DaemonResponse {
                                        success: true,
                                        exit_code: 0,
                                        result: res,
                                        error: None,
                                        detached: false,
                                        task_id: None,
                                    },
                                    Err(err) => DaemonResponse {
                                        success: false,
                                        exit_code: 1,
                                        result: None,
                                        error: Some(err),
                                        detached: false,
                                        task_id: None,
                                    },
                                };
                                let _ = send_msgpack_response(&mut socket, &resp).await;
                            }
                        }
                        ClientMessage::Ping => {
                            let resp = DaemonResponse {
                                success: true,
                                exit_code: 0,
                                result: Some("pong".to_string()),
                                error: None,
                                detached: false,
                                task_id: None,
                            };
                            let _ = send_msgpack_response(&mut socket, &resp).await;
                        }
                        ClientMessage::TaskStatus { task_id } => {
                            let status = sup.get_task_status(&task_id).await;
                            let status_str = match status {
                                Some(TaskStatus::Running) => "running",
                                Some(TaskStatus::Succeeded) => "succeeded",
                                Some(TaskStatus::Failed(ref e)) => e.as_str(),
                                Some(TaskStatus::TerminatedByTimeout) => "terminated_by_timeout",
                                Some(TaskStatus::Cancelled) => "cancelled",
                                None => "not_found",
                            };
                            let resp = DaemonResponse {
                                success: status.is_some(),
                                exit_code: 0,
                                result: Some(status_str.to_string()),
                                error: None,
                                detached: false,
                                task_id: Some(task_id),
                            };
                            let _ = send_msgpack_response(&mut socket, &resp).await;
                        }
                        ClientMessage::KillTask { task_id } => {
                            let killed = sup.kill_task(&task_id).await;
                            let resp = DaemonResponse {
                                success: killed,
                                exit_code: if killed { 0 } else { 1 },
                                result: if killed {
                                    Some(format!("Задача '{}' остановлена", task_id))
                                } else {
                                    None
                                },
                                error: if killed {
                                    None
                                } else {
                                    Some(format!("Задача '{}' не найдена", task_id))
                                },
                                detached: false,
                                task_id: Some(task_id),
                            };
                            let _ = send_msgpack_response(&mut socket, &resp).await;
                        }
                    }
                });
            }
            Err(e) => {
                eprintln!("[grimed] Ошибка accept: {}", e);
            }
        }
    }
}

async fn send_msgpack_response(
    socket: &mut tokio::net::UnixStream,
    resp: &DaemonResponse,
) -> Result<(), std::io::Error> {
    let bytes = rmp_serde::to_vec_named(resp)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
    let len = (bytes.len() as u32).to_be_bytes();
    socket.write_all(&len).await?;
    socket.write_all(&bytes).await?;
    socket.flush().await?;
    Ok(())
}
