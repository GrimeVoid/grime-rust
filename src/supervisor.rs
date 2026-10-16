use colored::Colorize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
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
    pub finished_at: Arc<AtomicU64>,
    pub last_heartbeat: Arc<AtomicU64>,
    pub is_step_active: Arc<AtomicBool>,
    pub status: Arc<RwLock<TaskStatus>>,
    pub canceller: PipelineCanceller,
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
            finished_at: Arc::new(AtomicU64::new(0)),
            last_heartbeat: Arc::new(AtomicU64::new(now_sec)),
            is_step_active: Arc::new(AtomicBool::new(false)),
            status: Arc::new(RwLock::new(TaskStatus::Running)),
            canceller,
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

    /// Установка флага активного выполнения шага конвейера.
    pub fn set_step_active(&self, active: bool) {
        self.is_step_active.store(active, Ordering::SeqCst);
    }

    /// Проверка, выполняется ли в данный момент шаг конвейера.
    pub fn is_step_active(&self) -> bool {
        self.is_step_active.load(Ordering::SeqCst)
    }

    /// Текущий статус задачи с безопасной обработкой lock poisoning.
    pub fn get_status(&self) -> TaskStatus {
        self.status
            .read()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }

    /// Обновление статуса задачи с безопасной обработкой lock poisoning.
    pub fn set_status(&self, new_status: TaskStatus) {
        let is_terminal = matches!(
            new_status,
            TaskStatus::Succeeded
                | TaskStatus::Failed(_)
                | TaskStatus::TerminatedByTimeout
                | TaskStatus::Cancelled
        );
        if is_terminal {
            let now_sec = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs();
            self.finished_at.store(now_sec, Ordering::SeqCst);
        }

        let mut st = self.status
            .write()
            .unwrap_or_else(|e| e.into_inner());
        *st = new_status;
    }

    /// Время завершения задачи (UNIX timestamp в секундах), если завершена.
    pub fn get_finished_at(&self) -> Option<u64> {
        let ts = self.finished_at.load(Ordering::SeqCst);
        if ts > 0 {
            Some(ts)
        } else {
            None
        }
    }
}

/// Супервизор открепленных задач демона с Heartbeat-мониторингом, контролем зависаний и политикой удержания (Retention Policy).
pub struct TaskSupervisor {
    tasks: Arc<Mutex<HashMap<String, Arc<DetachedTask>>>>,
    idle_timeout_secs: u64,
    check_interval: Duration,
}

impl Default for TaskSupervisor {
    fn default() -> Self {
        Self::new(60)
    }
}

impl TaskSupervisor {
    pub fn new(idle_timeout_secs: u64) -> Self {
        Self::with_check_interval(idle_timeout_secs, Duration::from_millis(500))
    }

    pub fn with_check_interval(idle_timeout_secs: u64, check_interval: Duration) -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
            idle_timeout_secs,
            check_interval,
        }
    }

    /// Очистка устаревших завершенных задач (Retention Policy).
    /// Задачи, завершенные более 1 часа назад (3600с), удаляются.
    /// Если количество завершенных задач превышает 500, старейшие удаляются.
    pub async fn prune_completed_tasks(&self) {
        let mut map = self.tasks.lock().await;
        let now_sec = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        // 1. Очистка завершенных задач старше 1 часа
        map.retain(|_, task| {
            if let Some(finished) = task.get_finished_at() {
                now_sec.saturating_sub(finished) <= 3600
            } else {
                true
            }
        });

        // 2. Ограничение пула завершенных задач лимитом в 500
        let mut completed: Vec<(String, u64)> = map
            .iter()
            .filter_map(|(id, t)| t.get_finished_at().map(|ts| (id.clone(), ts)))
            .collect();

        const MAX_COMPLETED_TASKS: usize = 500;
        if completed.len() > MAX_COMPLETED_TASKS {
            completed.sort_by_key(|(_, ts)| *ts);
            let excess = completed.len() - MAX_COMPLETED_TASKS;
            for (id, _) in completed.into_iter().take(excess) {
                map.remove(&id);
            }
        }
    }

    /// Регистрация и асинхронный запуск открепленного конвейера.
    pub async fn spawn_detached_pipeline(
        &self,
        mut parsed: ParsedPipeline,
        modules_dir: Option<PathBuf>,
        config_path: Option<PathBuf>,
        cwd: Option<String>,
        env: Option<HashMap<String, String>>,
    ) -> String {
        // Очистка устаревших задач согласно Retention Policy
        self.prune_completed_tasks().await;

        if parsed.work_path.is_none() {
            if let Some(ref c) = cwd {
                if !c.is_empty() {
                    parsed.work_path = Some(PathBuf::from(c));
                }
            }
        }

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
        let check_interval = self.check_interval;
        let task_for_monitor = task.clone();

        // 1. Монитор неактивности (Heartbeat Watchdog)
        let watchdog_handle = tokio::spawn(async move {
            loop {
                tokio::time::sleep(check_interval).await;

                if task_for_monitor.get_status() != TaskStatus::Running {
                    break;
                }

                // Если активен шаг конвейера, задача не считается зависшей
                if task_for_monitor.is_step_active() {
                    task_for_monitor.touch_heartbeat();
                    continue;
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

                    task_for_monitor.set_status(TaskStatus::TerminatedByTimeout);

                    let reason = format!(
                        "Превышен таймаут простоя (Inactivity Timeout > {}s)",
                        idle_timeout
                    );
                    task_for_monitor.canceller.cancel(&reason);
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
                    task_for_exec.set_status(TaskStatus::Failed(format!("Ошибка запуска оркестратора: {}", e)));
                    watchdog_handle.abort();
                    return;
                }
            };

            if let Some(ref env_map) = env {
                let _ = orchestrator.set_environment(env_map);
            }

            // Подписка на шину событий: отслеживание активности шагов и сброс таймаута активности
            let mut event_rx = orchestrator.event_bus().subscribe();
            let task_heartbeat = task_for_exec.clone();
            let heartbeat_listener = tokio::spawn(async move {
                while let Ok(evt) = event_rx.recv().await {
                    match evt.name.as_str() {
                        "pipeline.step.start" => {
                            task_heartbeat.set_step_active(true);
                            task_heartbeat.touch_heartbeat();
                        }
                        "pipeline.step.finish" => {
                            task_heartbeat.set_step_active(false);
                            task_heartbeat.touch_heartbeat();
                        }
                        _ => {
                            task_heartbeat.touch_heartbeat();
                        }
                    }
                }
            });

            let exec_res = orchestrator.run_pipeline(&parsed).await;
            heartbeat_listener.abort();
            watchdog_handle.abort();

            if task_for_exec.get_status() == TaskStatus::Running {
                match exec_res {
                    Ok(val) => {
                        task_for_exec.set_status(TaskStatus::Succeeded);
                        eprintln!(
                            "{} [Supervisor] Задача '{}' успешно завершена: {:?}",
                            "[Supervisor]".green().bold(),
                            task_for_exec.id,
                            val
                        );
                    }
                    Err(err) => {
                        task_for_exec.set_status(TaskStatus::Failed(err.clone()));
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
            task.set_status(TaskStatus::Cancelled);
            task.canceller.cancel("Задача остановлена пользователем");
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
                    task_clone.set_status(TaskStatus::TerminatedByTimeout);
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

    #[tokio::test]
    async fn test_supervisor_active_step_prevents_timeout() {
        let canceller = PipelineCanceller::new();
        let task = Arc::new(DetachedTask::new("active_step_task".to_string(), "heavy_build".to_string(), canceller.clone()));

        // Устанавливаем активность шага
        task.set_step_active(true);

        let task_clone = task.clone();
        tokio::spawn(async move {
            let check_interval = Duration::from_millis(100);
            for _ in 0..15 {
                tokio::time::sleep(check_interval).await;
                if task_clone.is_step_active() {
                    task_clone.touch_heartbeat();
                    continue;
                }
                let last = task_clone.last_heartbeat.load(Ordering::SeqCst);
                let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
                if now.saturating_sub(last) >= 1 {
                    task_clone.set_status(TaskStatus::TerminatedByTimeout);
                    task_clone.canceller.cancel("Timeout");
                    break;
                }
            }
        });

        // Ждем 1.2 секунды — благодаря активности шага задача должна оставаться Running
        tokio::time::sleep(Duration::from_millis(1200)).await;
        assert_eq!(task.get_status(), TaskStatus::Running);
        assert!(!canceller.is_cancelled());

        // Завершаем шаг
        task.set_step_active(false);
    }

    #[tokio::test]
    async fn test_supervisor_retention_policy_prune() {
        let supervisor = TaskSupervisor::new(60);
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();

        // Добавляем 505 недавних завершенных задач (< 1 часа назад)
        {
            let mut map = supervisor.tasks.lock().await;
            for i in 1..=505 {
                let canceller = PipelineCanceller::new();
                let task = Arc::new(DetachedTask::new(format!("task_{}", i), "cmd".to_string(), canceller));
                task.set_status(TaskStatus::Succeeded);
                // Задачи завершились недавно, с возрастающим временем завершения
                task.finished_at.store(now - (505 - i) as u64, Ordering::SeqCst);
                map.insert(format!("task_{}", i), task);
            }

            // Добавим также задачу, завершившуюся 2 часа назад (> 3600с)
            let canceller = PipelineCanceller::new();
            let old_task = Arc::new(DetachedTask::new("task_expired".to_string(), "old".to_string(), canceller));
            old_task.set_status(TaskStatus::Succeeded);
            old_task.finished_at.store(now.saturating_sub(7200), Ordering::SeqCst);
            map.insert("task_expired".to_string(), old_task);
        }

        // Проверяем, что до очистки 506 задач
        {
            let map = supervisor.tasks.lock().await;
            assert_eq!(map.len(), 506);
        }

        // Запускаем очистку
        supervisor.prune_completed_tasks().await;

        // Задача task_expired старше 1 часа удалена, а из 505 недавних оставлено ровно 500 новейших (task_1..task_5 удалены)
        {
            let map = supervisor.tasks.lock().await;
            assert_eq!(map.len(), 500);
            assert!(!map.contains_key("task_expired"));
            assert!(!map.contains_key("task_1"));
            assert!(!map.contains_key("task_5"));
            assert!(map.contains_key("task_6"));
            assert!(map.contains_key("task_505"));
        }
    }

    #[tokio::test]
    async fn test_supervisor_lock_poison_recovery() {
        let canceller = PipelineCanceller::new();
        let task = Arc::new(DetachedTask::new("poison_test".to_string(), "test".to_string(), canceller));

        // Намеренно травим RwLock паникой внутри потока
        let status_arc = task.status.clone();
        let _ = std::thread::spawn(move || {
            let _lock = status_arc.write().unwrap();
            panic!("Имитация неожиданной паники для проверки Lock Poisoning");
        }).join();

        // Проверяем, что get_status() и set_status() не паникуют и восстанавливают доступ
        assert_eq!(task.get_status(), TaskStatus::Running);
        task.set_status(TaskStatus::Succeeded);
        assert_eq!(task.get_status(), TaskStatus::Succeeded);
    }
}
