use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::daemon::{get_socket_path, ClientMessage, DaemonResponse};
use crate::orchestrator::Orchestrator;
use crate::pipeline::parse_pipeline_args;

pub async fn run_client(raw_args: &[String], modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> i32 {
    let parsed = parse_pipeline_args(raw_args);

    // 1. Если указан флаг --detach / -d: передаем задачу супервизору демона через Unix-сокет
    if parsed.detach {
        let sock_path = get_socket_path();
        if sock_path.exists() {
            if let Ok(mut stream) = UnixStream::connect(&sock_path).await {
                let cwd = std::env::current_dir()
                    .unwrap_or_else(|_| PathBuf::from("."))
                    .to_string_lossy()
                    .to_string();

                let mut env = HashMap::new();
                for (k, v) in std::env::vars() {
                    env.insert(k, v);
                }

                let msg = ClientMessage::Run {
                    cwd,
                    args: raw_args.to_vec(),
                    env,
                    detach: true,
                };

                if let Ok(bytes) = rmp_serde::to_vec_named(&msg) {
                    let len = (bytes.len() as u32).to_be_bytes();
                    if stream.write_all(&len).await.is_ok() && stream.write_all(&bytes).await.is_ok() {
                        let mut len_buf = [0u8; 4];
                        if stream.read_exact(&mut len_buf).await.is_ok() {
                            let resp_len = u32::from_be_bytes(len_buf) as usize;
                            let mut resp_buf = vec![0u8; resp_len];
                            if stream.read_exact(&mut resp_buf).await.is_ok() {
                                if let Ok(resp) = rmp_serde::from_slice::<DaemonResponse>(&resp_buf) {
                                    if let Some(ref res) = resp.result {
                                        println!("{}", res);
                                    }
                                    if let Some(ref err) = resp.error {
                                        eprintln!("[Grime] {}", err);
                                    }
                                    return resp.exit_code;
                                }
                            }
                        }
                    }
                }
            }
        }

        eprintln!("[Grime] Ошибка: Демон grimed не запущен. Для фоновых открепленных задач (--detach) запустите 'grimed'.");
        return 1;
    }

    // 2. Client-First Architecture:
    // Интерактивные TUI-приложения (Neovim, fzf, диалоговый режим Aider) и стандартный конвейер
    // исполняются локально в процессе CLI-клиента с прямым доступом к нативным потокам (stdin/stdout/stderr)
    // и сигналам терминала.
    let orchestrator = match Orchestrator::new(modules_dir, config_path) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("[Grime] Ошибка инициализации оркестратора: {}", e);
            return 1;
        }
    };

    let _ctrl_c = crate::cancellation::spawn_ctrl_c_watcher(orchestrator.canceller().clone());

    match orchestrator.run_pipeline(&parsed).await {
        Ok(Some(result)) => {
            if !result.is_empty() {
                println!("{}", result);
            }
            0
        }
        Ok(None) => 0,
        Err(err) => {
            eprintln!("[Grime] Конвейер остановлен из-за ошибки: {}", err);
            1
        }
    }
}
