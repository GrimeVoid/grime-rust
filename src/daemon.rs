use colored::Colorize;
use notify::{Event, RecursiveMode, Watcher};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tokio::sync::RwLock;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::event_bus::EventBus;
use crate::modules::ModuleRegistry;
use crate::orchestrator::Orchestrator;
use crate::pipeline::parse_pipeline_args;
use crate::state_bus::StateBus;
use crate::supervisor::{TaskStatus, TaskSupervisor};

/// Максимально допустимый размер полезной нагрузки IPC-сообщения (32 MB) для защиты от OOM и DoS.
pub const MAX_IPC_PAYLOAD_SIZE: usize = 32 * 1024 * 1024;

/// Таймаут чтения IPC-заголовка и полезной нагрузки от клиента (5 секунд).
const IPC_READ_TIMEOUT: Duration = Duration::from_secs(5);

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

impl DaemonResponse {
    /// Успешный ответ с необязательным результатом.
    pub fn ok(result: Option<String>) -> Self {
        Self {
            success: true,
            exit_code: 0,
            result,
            error: None,
            detached: false,
            task_id: None,
        }
    }

    /// Ответ с ошибкой (код возврата 1).
    pub fn err(error: impl Into<String>) -> Self {
        Self {
            success: false,
            exit_code: 1,
            result: None,
            error: Some(error.into()),
            detached: false,
            task_id: None,
        }
    }

    /// Привязывает ответ к задаче супервизора.
    pub fn with_task(mut self, task_id: String) -> Self {
        self.task_id = Some(task_id);
        self
    }

    /// Помечает ответ как относящийся к откреплённой задаче.
    pub fn detached(mut self) -> Self {
        self.detached = true;
        self
    }
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

/// Ошибки чтения IPC-фрейма MessagePack.
#[derive(Debug)]
pub enum IpcFrameError {
    PayloadTooLarge(usize),
    Io(std::io::Error),
    Deserialize(String),
}

/// Синхронная отправка IPC-фрейма (`u32` BE длина + полезная нагрузка MessagePack).
pub fn write_ipc_frame_sync<W: Write, T: serde::Serialize>(
    stream: &mut W,
    msg: &T,
) -> std::io::Result<()> {
    let payload = rmp_serde::to_vec_named(msg)
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let len_bytes = (payload.len() as u32).to_be_bytes();
    stream.write_all(&len_bytes)?;
    stream.write_all(&payload)?;
    stream.flush()
}

/// Синхронное чтение IPC-фрейма (`u32` BE длина + полезная нагрузка MessagePack) с проверкой лимита размера.
pub fn read_ipc_frame_sync<R: Read, T: serde::de::DeserializeOwned>(
    stream: &mut R,
) -> Result<T, IpcFrameError> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).map_err(IpcFrameError::Io)?;
    let payload_len = u32::from_be_bytes(len_buf) as usize;
    if payload_len == 0 {
        return Err(IpcFrameError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "Пустой IPC-фрейм",
        )));
    }
    if payload_len > MAX_IPC_PAYLOAD_SIZE {
        return Err(IpcFrameError::PayloadTooLarge(payload_len));
    }
    let mut buf = vec![0u8; payload_len];
    stream.read_exact(&mut buf).map_err(IpcFrameError::Io)?;
    rmp_serde::from_slice(&buf).map_err(|e| IpcFrameError::Deserialize(e.to_string()))
}

/// Асинхронная отправка IPC-фрейма (`u32` BE длина + полезная нагрузка MessagePack).
pub async fn write_ipc_frame_async<W: AsyncWriteExt + Unpin, T: serde::Serialize>(
    stream: &mut W,
    msg: &T,
) -> std::io::Result<()> {
    let bytes = rmp_serde::to_vec_named(msg)
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let len = (bytes.len() as u32).to_be_bytes();
    stream.write_all(&len).await?;
    stream.write_all(&bytes).await?;
    stream.flush().await
}

/// Асинхронное чтение IPC-фрейма (`u32` BE длина + полезная нагрузка MessagePack) с таймаутом и проверкой лимита.
pub async fn read_ipc_frame_async<R: AsyncReadExt + Unpin, T: serde::de::DeserializeOwned>(
    stream: &mut R,
    header_timeout: Duration,
    body_timeout: Duration,
) -> Result<T, IpcFrameError> {
    let mut len_buf = [0u8; 4];
    match tokio::time::timeout(header_timeout, stream.read_exact(&mut len_buf)).await {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => return Err(IpcFrameError::Io(e)),
        Err(_) => {
            return Err(IpcFrameError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Таймаут чтения заголовка IPC",
            )))
        }
    }
    let payload_len = u32::from_be_bytes(len_buf) as usize;
    if payload_len == 0 {
        return Err(IpcFrameError::Io(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "Пустой IPC-фрейм",
        )));
    }
    if payload_len > MAX_IPC_PAYLOAD_SIZE {
        return Err(IpcFrameError::PayloadTooLarge(payload_len));
    }

    let mut payload = vec![0u8; payload_len];
    match tokio::time::timeout(body_timeout, stream.read_exact(&mut payload)).await {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => return Err(IpcFrameError::Io(e)),
        Err(_) => {
            return Err(IpcFrameError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "Таймаут чтения тела IPC",
            )))
        }
    }

    rmp_serde::from_slice(&payload).map_err(|e| IpcFrameError::Deserialize(e.to_string()))
}

/// Синхронная проверка доступности демона через Unix-сокет (`ClientMessage::Ping -> DaemonResponse`).
pub fn ping_daemon_sync() -> bool {
    let sock_path = get_socket_path();
    if !sock_path.exists() {
        return false;
    }

    let Ok(mut stream) = StdUnixStream::connect(&sock_path) else {
        return false;
    };

    let timeout = Some(Duration::from_millis(500));
    let _ = stream.set_read_timeout(timeout);
    let _ = stream.set_write_timeout(timeout);

    if write_ipc_frame_sync(&mut stream, &ClientMessage::Ping).is_err() {
        return false;
    }

    if let Ok(resp) = read_ipc_frame_sync::<_, DaemonResponse>(&mut stream) {
        resp.success && resp.result.as_deref() == Some("pong")
    } else {
        false
    }
}

fn is_relevant_lua_event(ev: &Event) -> bool {
    matches!(
        ev.kind,
        notify::EventKind::Modify(_)
            | notify::EventKind::Create(_)
            | notify::EventKind::Remove(_)
    ) && ev
        .paths
        .iter()
        .any(|p| p.extension().is_some_and(|ext| ext == "lua"))
}

/// Берёт эксклюзивный `flock` на `<сокет>.lock`: защита от гонки двух одновременных автозапусков демона.
/// Блокировка живёт, пока открыт возвращённый файл (то есть всё время работы демона).
fn acquire_daemon_lock(sock_path: &Path) -> Result<fs::File, Box<dyn std::error::Error>> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::os::unix::io::AsRawFd;

    let mut lock_name = sock_path.as_os_str().to_owned();
    lock_name.push(".lock");
    let lock_path = PathBuf::from(lock_name);
    if let Some(parent) = lock_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let file = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .open(&lock_path)?;
    let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        return Err("Демон Grime уже запущен или запускается другим процессом".into());
    }
    Ok(file)
}

/// Создаёт слушающий сокет под umask 0077: права 0600 выставляются сразу, без окна гонки.
fn bind_private_socket(sock_path: &Path) -> std::io::Result<UnixListener> {
    let old_umask = unsafe { libc::umask(0o077) };
    let res = UnixListener::bind(sock_path);
    unsafe { libc::umask(old_umask) };
    let listener = res?;
    // Страховка на случай, если файловая система игнорирует umask
    let _ = fs::set_permissions(sock_path, fs::Permissions::from_mode(0o600));
    Ok(listener)
}

pub async fn run_daemon(modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> Result<(), Box<dyn std::error::Error>> {
    let sock_path = get_socket_path();
    let _daemon_lock = acquire_daemon_lock(&sock_path)?;

    if ping_daemon_sync() {
        return Err("Демон Grime уже запущен и отвечает на запросы".into());
    }

    if sock_path.exists() {
        let _ = fs::remove_file(&sock_path);
    }

    if let Some(parent) = sock_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    let listener = bind_private_socket(&sock_path)?;

    println!(
        "{} Демон grime запущен на сокете: {} (Протокол: MessagePack)",
        "[grime-daemon]".green().bold(),
        sock_path.display()
    );

    let shared_state_bus = Arc::new(StateBus::new());
    let shared_event_bus = Arc::new(EventBus::default());

    // Конфиг и реестр модулей создаются один раз и разделяются всеми оркестраторами демона
    let config = Arc::new(GrimeConfig::load_or_default(config_path));
    let registry = Arc::new(ModuleRegistry::for_config(&config, modules_dir));

    let initial_orch = Orchestrator::new_with_shared(
        config.clone(),
        registry.clone(),
        shared_state_bus.clone(),
        shared_event_bus.clone(),
        PipelineCanceller::new(),
    )?;

    let orchestrator = Arc::new(RwLock::new(initial_orch));

    // Подметание осиротевших эфемерных каталогов (убитые процессы): сразу и периодически
    tokio::spawn(async {
        let mut tick = tokio::time::interval(crate::ephemeral::SWEEP_INTERVAL);
        loop {
            tick.tick().await;
            let _ = tokio::task::spawn_blocking(crate::ephemeral::sweep_default).await;
        }
    });

    let supervisor = Arc::new(TaskSupervisor::with_shared_buses(
        60,
        shared_state_bus.clone(),
        shared_event_bus.clone(),
    ));

    // Настройка Hot-Reload через notify: наблюдаем за всеми существующими каталогами модулей
    let watch_dirs: Vec<PathBuf> = registry.dirs().iter().filter(|d| d.exists()).cloned().collect();

    if !watch_dirs.is_empty() {
        let orch_reload = orchestrator.clone();
        let config_reload = config.clone();
        let registry_reload = registry.clone();
        let state_reload = shared_state_bus.clone();
        let event_reload = shared_event_bus.clone();

        std::thread::spawn(move || {
            let (tx, rx) = std::sync::mpsc::channel();
            // Вотчеры должны жить, пока работает поток
            let mut watchers = Vec::new();
            for dir in &watch_dirs {
                let mut watcher = match notify::recommended_watcher(tx.clone()) {
                    Ok(w) => w,
                    Err(e) => {
                        eprintln!("Не удалось запустить watcher: {}", e);
                        continue;
                    }
                };
                if let Err(e) = watcher.watch(dir, RecursiveMode::Recursive) {
                    eprintln!("Ошибка наблюдения за директорией {:?}: {}", dir, e);
                    continue;
                }
                println!(
                    "{} Hot-reload активен для каталога: {}",
                    "[grime-daemon]".green().bold(),
                    dir.display()
                );
                watchers.push(watcher);
            }
            if watchers.is_empty() {
                return;
            }
            drop(tx);

            while let Ok(res) = rx.recv() {
                let Ok(ev) = res else {
                    continue;
                };
                if !is_relevant_lua_event(&ev) {
                    continue;
                }

                // Антидребезг (debounce 150 мс): дренируем лавину событий сохранения от текстового редактора
                while rx.recv_timeout(Duration::from_millis(150)).is_ok() {}

                println!(
                    "{} Обнаружено изменение Lua-модулей! Перезагрузка состояния...",
                    "[grime-daemon Hot-Reload]".yellow().bold()
                );
                registry_reload.invalidate();
                if let Ok(new_orch) = Orchestrator::new_with_shared(
                    config_reload.clone(),
                    registry_reload.clone(),
                    state_reload.clone(),
                    event_reload.clone(),
                    PipelineCanceller::new(),
                ) {
                    let mut lock = orch_reload.blocking_write();
                    *lock = new_orch;
                    println!(
                        "{} Модули успешно обновлены в памяти демона.",
                        "[grime-daemon Hot-Reload]".green().bold()
                    );
                }
            }
        });
    }

    // Обработка входящих соединений
    loop {
        match listener.accept().await {
            Ok((mut socket, _)) => {
                let orch = orchestrator.clone();
                let sup = supervisor.clone();
                let config = config.clone();
                let registry = registry.clone();

                tokio::spawn(async move {
                    let msg: ClientMessage = match read_ipc_frame_async(
                        &mut socket,
                        IPC_READ_TIMEOUT,
                        IPC_READ_TIMEOUT,
                    )
                    .await
                    {
                        Ok(m) => m,
                        Err(IpcFrameError::PayloadTooLarge(payload_len)) => {
                            eprintln!(
                                "{} Превышен максимальный размер IPC-сообщения: {} байт (лимит: {} байт)",
                                "[grime-daemon Security]".red().bold(),
                                payload_len,
                                MAX_IPC_PAYLOAD_SIZE
                            );
                            let resp = DaemonResponse::err(format!(
                                "Payload size exceeds MAX_IPC_PAYLOAD_SIZE limit ({} > {})",
                                payload_len, MAX_IPC_PAYLOAD_SIZE
                            ));
                            let _ = write_ipc_frame_async(&mut socket, &resp).await;
                            return;
                        }
                        Err(IpcFrameError::Deserialize(e)) => {
                            let resp = DaemonResponse::err(format!("Ошибка парсинга MessagePack: {}", e));
                            let _ = write_ipc_frame_async(&mut socket, &resp).await;
                            return;
                        }
                        Err(IpcFrameError::Io(_)) => return,
                    };

                    let resp = match msg {
                        ClientMessage::Run { cwd, args, env, detach } => {
                            let mut parsed = parse_pipeline_args(&args, &registry);
                            if parsed.work_path.is_none() && !cwd.is_empty() {
                                parsed.work_path = Some(PathBuf::from(&cwd));
                            }

                            if detach || parsed.detach {
                                // Запуск открепленной задачи в супервизоре с Heartbeat, cwd и env
                                let task_id = sup
                                    .spawn_detached_pipeline(parsed, config, registry, Some(cwd), Some(env))
                                    .await;
                                DaemonResponse::ok(Some(format!("Задача успешно откреплена (Task ID: {})", task_id)))
                                    .with_task(task_id)
                                    .detached()
                            } else {
                                // Сервисное выполнение через демон: берем эксклюзивный write-замок
                                // для исключения гонок в разделяемой Lua VM и выполняем в spawn_blocking
                                let orch_guard = orch.write_owned().await;
                                let run_res = tokio::task::spawn_blocking(move || {
                                    // Окружение заменяется при каждом запуске (в том числе пустым),
                                    // чтобы переменные прошлого клиента не просачивались в новый
                                    let _ = orch_guard.set_environment(&env);
                                    orch_guard.run_pipeline(&parsed)
                                })
                                .await
                                .unwrap_or_else(|e| Err(format!("Ошибка выполнения задачи демона: {}", e)));

                                match run_res {
                                    Ok(res) => DaemonResponse::ok(res),
                                    Err(err) => DaemonResponse::err(err),
                                }
                            }
                        }
                        ClientMessage::Ping => DaemonResponse::ok(Some("pong".to_string())),
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
                            let mut resp = DaemonResponse::ok(Some(status_str.to_string())).with_task(task_id);
                            resp.success = status.is_some();
                            resp
                        }
                        ClientMessage::KillTask { task_id } => {
                            if sup.kill_task(&task_id).await {
                                DaemonResponse::ok(Some(format!("Задача '{}' остановлена", task_id)))
                            } else {
                                DaemonResponse::err(format!("Задача '{}' не найдена", task_id))
                            }
                            .with_task(task_id)
                        }
                    };
                    let _ = write_ipc_frame_async(&mut socket, &resp).await;
                });
            }
            Err(e) => {
                eprintln!("[grime-daemon] Ошибка accept: {}", e);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_daemon_response_constructors() {
        let ok = DaemonResponse::ok(Some("x".into())).with_task("t1".into()).detached();
        assert!(ok.success && ok.detached && ok.exit_code == 0);
        assert_eq!(ok.task_id.as_deref(), Some("t1"));
        let err = DaemonResponse::err("boom");
        assert!(!err.success && err.exit_code == 1 && err.error.as_deref() == Some("boom"));
    }

    #[tokio::test]
    async fn test_socket_created_with_private_permissions() {
        let _td = crate::test_support::TempDir::new("sock_test");
        let path = _td.join("d.sock");
        let _listener = bind_private_socket(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn test_daemon_lock_is_exclusive() {
        let _td = crate::test_support::TempDir::new("lock_test");
        let path = _td.join("d.sock");
        let first = acquire_daemon_lock(&path).expect("первая блокировка");
        assert!(acquire_daemon_lock(&path).is_err(), "вторая блокировка должна отказать");
        drop(first);
        assert!(acquire_daemon_lock(&path).is_ok());
    }
}
