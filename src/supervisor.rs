use colored::Colorize;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::Mutex;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::event_bus::EventBus;
use crate::modules::ModuleRegistry;
use crate::orchestrator::Orchestrator;
use crate::pipeline::ParsedPipeline;
use crate::state_bus::StateBus;

/// Текущее время в секундах UNIX-эпохи.
pub fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Относится ли событие шины к сессии данной задачи (heartbeat чужих задач игнорируется).
pub fn heartbeat_applies(evt: &crate::event_bus::GrimeEvent, session_id: &str) -> bool {
    evt.session_id.as_deref() == Some(session_id)
}

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
        Self {
            id,
            command,
            started_at: Instant::now(),
            finished_at: Arc::new(AtomicU64::new(0)),
            last_heartbeat: Arc::new(AtomicU64::new(now_secs())),
            is_step_active: Arc::new(AtomicBool::new(false)),
            status: Arc::new(RwLock::new(TaskStatus::Running)),
            canceller,
        }
    }

    /// Сброс таймера активности (Heartbeat).
    pub fn touch_heartbeat(&self) {
        self.last_heartbeat.store(now_secs(), Ordering::SeqCst);
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
            self.finished_at.store(now_secs(), Ordering::SeqCst);
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
    shared_state_bus: Option<Arc<StateBus>>,
    shared_event_bus: Option<Arc<EventBus>>,
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
            shared_state_bus: None,
            shared_event_bus: None,
        }
    }

    pub fn with_shared_buses(
        idle_timeout_secs: u64,
        state_bus: Arc<StateBus>,
        event_bus: Arc<EventBus>,
    ) -> Self {
        Self {
            tasks: Arc::new(Mutex::new(HashMap::new())),
            idle_timeout_secs,
            check_interval: Duration::from_millis(500),
            shared_state_bus: Some(state_bus),
            shared_event_bus: Some(event_bus),
        }
    }

    /// Очистка устаревших завершенных задач (Retention Policy).
    /// Задачи, завершенные более 1 часа назад (3600с), удаляются.
    /// Если количество завершенных задач превышает 500, старейшие удаляются.
    pub async fn prune_completed_tasks(&self) {
        let mut map = self.tasks.lock().await;
        let now_sec = now_secs();

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
        config: Arc<GrimeConfig>,
        registry: Arc<ModuleRegistry>,
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
        // Контролирует максимальное время выполнения шага без событий (idle_timeout_secs),
        // реально отменяя зависший шаг через task_for_monitor.canceller.cancel(&reason).
        let watchdog_handle = tokio::spawn(async move {
            loop {
                tokio::time::sleep(check_interval).await;

                if task_for_monitor.get_status() != TaskStatus::Running {
                    break;
                }

                // Пока у задачи есть живые дочерние процессы (например `sleep 90` или сборка),
                // она не зависла, а лишь «молчит»: сбрасываем таймер и не убиваем её.
                if task_for_monitor.canceller.active_child_count() > 0 {
                    task_for_monitor.touch_heartbeat();
                    continue;
                }

                let last = task_for_monitor.last_heartbeat.load(Ordering::SeqCst);
                let now = now_secs();

                if now.saturating_sub(last) >= idle_timeout {
                    eprintln!(
                        "{} [Supervisor] Задача '{}' зависла (отсутствие событий активности > {}с). Принудительное завершение...",
                        "[Supervisor]".red().bold(),
                        task_for_monitor.id,
                        idle_timeout
                    );

                    task_for_monitor.set_status(TaskStatus::TerminatedByTimeout);

                    let reason = format!(
                        "Превышен таймаут выполнения шага без событий (Timeout > {}s)",
                        idle_timeout
                    );
                    task_for_monitor.canceller.cancel(&reason);
                    break;
                }
            }
        });

        // 2. Исполнитель конвейера (с передачей canceller задачи и разделяемых шин демона)
        let task_for_exec = task.clone();
        let shared_state = self
            .shared_state_bus
            .clone()
            .unwrap_or_else(|| Arc::new(StateBus::new()));
        let shared_event = self
            .shared_event_bus
            .clone()
            .unwrap_or_else(|| Arc::new(EventBus::default()));

        tokio::spawn(async move {
            let orch_res = Orchestrator::new_with_shared(
                config,
                registry,
                shared_state,
                shared_event,
                canceller.clone(),
            );
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

            // Подписка на шину событий: отслеживание переходов между шагами и пользовательских событий
            let mut event_rx = orchestrator.event_bus().subscribe();
            let task_heartbeat = task_for_exec.clone();
            let session_id = orchestrator.session_id().to_string();
            let heartbeat_listener = tokio::spawn(async move {
                loop {
                    let evt = match event_rx.recv().await {
                        Ok(evt) => evt,
                        // Слушатель отстал от шины: пропущенные события не критичны
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    };
                    // Шина общая для всех задач демона: учитываем только события своей сессии
                    if !heartbeat_applies(&evt, &session_id) {
                        continue;
                    }
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

            let exec_res = tokio::task::spawn_blocking(move || {
                orchestrator.run_pipeline(&parsed)
            })
            .await
            .unwrap_or_else(|e| Err(format!("Паника в задаче оркестратора: {}", e)));

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
                let now = now_secs();
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
    async fn test_supervisor_cancels_hanging_lua_step() {
        let tmp_dir = crate::test_support::TempDir::new("sup_hang_test");
        std::fs::write(
            tmp_dir.join("hang_mod.lua"),
            r#"
            function main()
                local x = 0
                while true do
                    x = x + 1
                end
            end
            "#,
        )
        .unwrap();

        let supervisor = TaskSupervisor::with_check_interval(1, Duration::from_millis(100));
        let config = Arc::new(GrimeConfig::load_or_default(Some(&tmp_dir.join("gproj.conf"))));
        let registry = Arc::new(ModuleRegistry::scan(vec![tmp_dir.to_path_buf()]));
        let parsed = crate::pipeline::parse_pipeline_args(&["hang_mod".to_string()], &registry);
        let task_id = supervisor
            .spawn_detached_pipeline(parsed, config, registry, None, None)
            .await;

        tokio::time::sleep(Duration::from_millis(1500)).await;
        let status = supervisor.get_task_status(&task_id).await;
        assert_eq!(
            status,
            Some(TaskStatus::TerminatedByTimeout),
            "Зависший в бесконечном цикле Lua-шаг должен быть принудительно прерван Watchdog-ом"
        );

    }

    #[tokio::test]
    async fn test_supervisor_retention_policy_prune() {
        let supervisor = TaskSupervisor::new(60);
        let now = now_secs();

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

    #[test]
    fn test_heartbeat_filtered_by_session_id() {
        use crate::event_bus::GrimeEvent;
        let own = GrimeEvent::new("pipeline.step.start", serde_json::json!(null)).with_session("sess_a");
        let foreign = GrimeEvent::new("pipeline.step.start", serde_json::json!(null)).with_session("sess_b");
        let anonymous = GrimeEvent::new("x", serde_json::json!(null));
        assert!(heartbeat_applies(&own, "sess_a"));
        assert!(!heartbeat_applies(&foreign, "sess_a"));
        assert!(!heartbeat_applies(&anonymous, "sess_a"));
    }

    #[tokio::test]
    async fn test_watchdog_keeps_task_with_active_child_process() {
        let tmp_dir = crate::test_support::TempDir::new("sup_child_test");
        std::fs::write(
            tmp_dir.join("sleeper.lua"),
            "function main()\n  grime.process.run('sleep 3')\nend\n",
        )
        .unwrap();

        let supervisor = TaskSupervisor::with_check_interval(1, Duration::from_millis(100));
        let config = Arc::new(GrimeConfig::load_or_default(Some(&tmp_dir.join("gproj.conf"))));
        let registry = Arc::new(ModuleRegistry::scan(vec![tmp_dir.to_path_buf()]));
        let parsed = crate::pipeline::parse_pipeline_args(&["sleeper".to_string()], &registry);
        let task_id = supervisor
            .spawn_detached_pipeline(parsed, config, registry, None, None)
            .await;

        // Шаг молчит дольше idle_timeout (1с), но у него живой дочерний процесс
        tokio::time::sleep(Duration::from_millis(2000)).await;
        assert_eq!(
            supervisor.get_task_status(&task_id).await,
            Some(TaskStatus::Running),
            "Watchdog не должен убивать задачу с активным дочерним процессом"
        );
        tokio::time::sleep(Duration::from_millis(2500)).await;
        assert_eq!(supervisor.get_task_status(&task_id).await, Some(TaskStatus::Succeeded));

    }

    #[tokio::test]
    async fn test_detached_new_module_succeeds_and_missing_fails() {
        let tmp_dir = crate::test_support::TempDir::new("sup_fresh_test");
        let supervisor = TaskSupervisor::new(30);
        let config = Arc::new(GrimeConfig::load_or_default(Some(&tmp_dir.join("gproj.conf"))));
        let registry = Arc::new(ModuleRegistry::scan(vec![tmp_dir.to_path_buf()]));

        async fn wait_final(sup: &TaskSupervisor, id: &str) -> TaskStatus {
            for _ in 0..200 {
                match sup.get_task_status(id).await {
                    Some(TaskStatus::Running) | None => tokio::time::sleep(Duration::from_millis(25)).await,
                    Some(s) => return s,
                }
            }
            panic!("задача не завершилась");
        }

        for i in 0..50 {
            let name = format!("detmod_{i}");
            std::fs::write(tmp_dir.join(format!("{name}.lua")), "function main() grime.ctx.success('ok') end\n")
                .unwrap();
            let parsed = crate::pipeline::parse_pipeline_args(&[name], &registry);
            let id = supervisor
                .spawn_detached_pipeline(parsed, config.clone(), registry.clone(), None, None)
                .await;
            assert_eq!(wait_final(&supervisor, &id).await, TaskStatus::Succeeded, "итерация {i}");
        }

        let parsed = crate::pipeline::parse_pipeline_args(&["no_such_module_xyz".to_string()], &registry);
        let id = supervisor
            .spawn_detached_pipeline(parsed, config, registry, None, None)
            .await;
        assert!(matches!(wait_final(&supervisor, &id).await, TaskStatus::Failed(_)));
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
