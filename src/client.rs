use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::daemon::{get_socket_path, ClientRequest, DaemonResponse};
use crate::orchestrator::Orchestrator;
use crate::pipeline::parse_pipeline_args;

pub async fn run_client(raw_args: &[String], modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> i32 {
    let sock_path = get_socket_path();

    // 1. Попытка подключения к демону grimed
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

            let req = ClientRequest {
                cwd,
                args: raw_args.to_vec(),
                env,
            };

            if let Ok(bytes) = serde_json::to_vec(&req) {
                let len = (bytes.len() as u32).to_be_bytes();
                if stream.write_all(&len).await.is_ok() && stream.write_all(&bytes).await.is_ok() {
                    let mut len_buf = [0u8; 4];
                    if stream.read_exact(&mut len_buf).await.is_ok() {
                        let resp_len = u32::from_be_bytes(len_buf) as usize;
                        let mut resp_buf = vec![0u8; resp_len];
                        if stream.read_exact(&mut resp_buf).await.is_ok() {
                            if let Ok(resp) = serde_json::from_slice::<DaemonResponse>(&resp_buf) {
                                if let Some(ref res) = resp.result {
                                    if !res.is_empty() {
                                        println!("{}", res);
                                    }
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

    // 2. Fallback: прямой запуск в текущем процессе (in-process runner)
    let parsed = parse_pipeline_args(raw_args);

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
