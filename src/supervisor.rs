use colored::Colorize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

use crate::cancellation::PipelineCanceller;
use crate::orchestrator::Orchestrator;
use crate::pipeline::ParsedPipeline;

/// Статус открепленной задачи под контролем супервизора.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum TaskStatus {
    Running,
    Succeeded,
    Failed(String),
    TerminatedByTimeout,
    Cancelled,
}

/// Дескриптор открепленной задачи (Detached Task).
pub struct DetachedTask {
    pub id: String,
    pub command: String,
    pub started_at: Instant,
    pub last_heartbeat: Arc<AtomicU64>,
    pub status: Arc<RwLock<TaskStatus>>,
    pub canceller: PipelineCanceller,
    pub child_pid: Arc<AtomicI32>,
}

impl DetachedTask {
    pub fn new(id: String, command: String, canceller: PipelineCanceller) -> Self {
        let now_sec = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        Self {
            id,
            command,
            started_at: Instant::now(),
            last_heartbeat: Arc::new(AtomicU64::new(now_sec)),
            status: Arc::new(RwLock::new(TaskStatus::Running)),
            canceller,
            child_pid: Arc::new(AtomicI32::new(0)),
        }
    }

    /// Сброс таймера активности (Heartbeat).
    pub fn touch_heartbeat(&self) {
        let now_sec = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.last_heartbeat.store(now_sec, Ordering::SeqCst);
    }

    /// Текущий статус задачи.
    pub fn get_status(&self) -> TaskStatus {
        self.status.read().unwrap().clone()
    }
}

/// Супервизор открепленных задач демона с Heartbeat-мониторингом и контролем зависаний.
pub struct TaskSupervisor {
    tasks: Arc<Mutex<HashMap<String, Arc<DetachedTask>>>>,
    idle_timeout_secs: u64,
}

impl Default for TaskSupervisor {
    fn default() -> Self {
        Self::new(60)
    }
}

impl TaskSupervisor {
    pub fn new(idle_timeout_secs: u64) -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
            idle_timeout_secs,
        }
    }

    /// Регистрация и асинхронный запуск открепленного конвейера.
    pub async fn spawn_detached_pipeline(
        &self,
        parsed: ParsedPipeline,
        modules_dir: Option<PathBuf>,
        config_path: Option<PathBuf>,
    ) -> String {
        let now_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis();
        static COUNTER: AtomicU64 = AtomicU64::new(1);
        let count = COUNTER.fetch_add(1, Ordering::SeqCst);
        let task_id = format!("task_{}_{}", now_ms, count);

        let cmd_str = parsed
            .steps
            .iter()
            .map(|s| format!("{} {}", s.module, s.args.join(" ")))
            .collect::<Vec<_>>()
            .join(" : ");

        let canceller = PipelineCanceller::new();
        let task = Arc::new(DetachedTask::new(task_id.clone(), cmd_str, canceller.clone()));

        {
            let mut map = self.tasks.lock().await;
            map.insert(task_id.clone(), task.clone());
        }

        let idle_timeout = self.idle_timeout_secs;
        let task_for_monitor = task.clone();

        // 1. Монитор неактивности (Heartbeat Watchdog)
        let watchdog_handle = tokio::spawn(async move {
            let check_interval = Duration::from_millis(500);
            loop {
                tokio::time::sleep(check_interval).await;

                if task_for_monitor.get_status() != TaskStatus::Running {
                    break;
                }

                let last = task_for_monitor.last_heartbeat.load(Ordering::SeqCst);
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();

                if now.saturating_sub(last) >= idle_timeout {
                    eprintln!(
                        "{} [Supervisor] Задача '{}' зависла (отсутствие активности > {}с). Принудительное завершение...",
                        "[Supervisor]".red().bold(),
                        task_for_monitor.id,
                        idle_timeout
                    );

                    {
                        let mut st = task_for_monitor.status.write().unwrap();
                        *st = TaskStatus::TerminatedByTimeout;
                    }

                    let reason = format!(
                        "Превышен таймаут простоя (Inactivity Timeout > {}s)",
                        idle_timeout
                    );
                    task_for_monitor.canceller.cancel(&reason);

                    let pid = task_for_monitor.child_pid.load(Ordering::SeqCst);
                    if pid > 0 {
                        unsafe {
                            libc::kill(pid, libc::SIGTERM);
                        }
                        tokio::time::sleep(Duration::from_millis(1500)).await;
                        unsafe {
                            libc::kill(pid, libc::SIGKILL);
                        }
                    }
                    break;
                }
            }
        });

        // 2. Исполнитель конвейера
        let task_for_exec = task.clone();
        tokio::spawn(async move {
            let orch_res = Orchestrator::new(modules_dir, config_path.as_deref());
            let orchestrator = match orch_res {
                Ok(o) => o,
                Err(e) => {
                    let mut st = task_for_exec.status.write().unwrap();
                    *st = TaskStatus::Failed(format!("Ошибка запуска оркестратора: {}", e));
                    watchdog_handle.abort();
                    return;
                }
            };

            // Подписка на шину событий: каждый шаг конвейера сбрасывает таймаут активности
            let mut event_rx = orchestrator.event_bus().subscribe();
            let task_heartbeat = task_for_exec.clone();
            let heartbeat_listener = tokio::spawn(async move {
                while let Ok(_evt) = event_rx.recv().await {
                    task_heartbeat.touch_heartbeat();
                }
            });

            let exec_res = orchestrator.run_pipeline(&parsed).await;
            heartbeat_listener.abort();
            watchdog_handle.abort();


            let mut st = task_for_exec.status.write().unwrap();
            if *st == TaskStatus::Running {
                match exec_res {
                    Ok(val) => {
                        *st = TaskStatus::Succeeded;
                        eprintln!(
                            "{} [Supervisor] Задача '{}' успешно завершена: {:?}",
                            "[Supervisor]".green().bold(),
                            task_for_exec.id,
                            val
                        );
                    }
                    Err(err) => {
                        *st = TaskStatus::Failed(err.clone());
                        eprintln!(
                            "{} [Supervisor] Задача '{}' завершилась с ошибкой: {}",
                            "[Supervisor]".red().bold(),
                            task_for_exec.id,
                            err
                        );
                    }
                }
            }
        });

        task_id
    }

    /// Получение статуса задачи.
    pub async fn get_task_status(&self, task_id: &str) -> Option<TaskStatus> {
        let map = self.tasks.lock().await;
        map.get(task_id).map(|t| t.get_status())
    }

    /// Принудительная остановка задачи пользователем.
    pub async fn kill_task(&self, task_id: &str) -> bool {
        let map = self.tasks.lock().await;
        if let Some(task) = map.get(task_id) {
            {
                let mut st = task.status.write().unwrap();
                *st = TaskStatus::Cancelled;
            }
            task.canceller.cancel("Задача остановлена пользователем");
            let pid = task.child_pid.load(Ordering::SeqCst);
            if pid > 0 {
                unsafe {
                    libc::kill(pid, libc::SIGTERM);
                }
                let pid_copy = pid;
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(1000)).await;
                    unsafe {
                        libc::kill(pid_copy, libc::SIGKILL);
                    }
                });
            }
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_supervisor_timeout_and_heartbeat() {
        let supervisor = TaskSupervisor::new(1); // 1 секунда таймаута для быстрого теста
        let task_id = "test_timeout_task".to_string();
        let canceller = PipelineCanceller::new();
        let task = Arc::new(DetachedTask::new(task_id.clone(), "test".to_string(), canceller.clone()));

        {
            let mut map = supervisor.tasks.lock().await;
            map.insert(task_id.clone(), task.clone());
        }

        let task_clone = task.clone();
        tokio::spawn(async move {
            // Симулируем watchdog
            let check_interval = Duration::from_millis(100);
            for _ in 0..20 {
                tokio::time::sleep(check_interval).await;
                let last = task_clone.last_heartbeat.load(Ordering::SeqCst);
                let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
                if now.saturating_sub(last) >= 1 {
                    let mut st = task_clone.status.write().unwrap();
                    *st = TaskStatus::TerminatedByTimeout;
                    task_clone.canceller.cancel("Timeout");
                    break;
                }
            }
        });

        // Ждем 1.2 секунды без heartbeat
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert_eq!(task.get_status(), TaskStatus::TerminatedByTimeout);
        assert!(canceller.is_cancelled());
    }

    #[tokio::test]
    async fn test_supervisor_heartbeat_keeps_alive() {
        let canceller = PipelineCanceller::new();
        let task = Arc::new(DetachedTask::new("alive_task".to_string(), "test".to_string(), canceller.clone()));

        // Посылаем heartbeat каждые 300мс
        let task_clone = task.clone();
        tokio::spawn(async move {
            for _ in 0..4 {
                tokio::time::sleep(Duration::from_millis(300)).await;
                task_clone.touch_heartbeat();
            }
        });

        // Проверяем через 800мс
        tokio::time::sleep(Duration::from_millis(800)).await;
        assert_eq!(task.get_status(), TaskStatus::Running);
        assert!(!canceller.is_cancelled());
    }
}
