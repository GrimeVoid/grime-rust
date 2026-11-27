use mlua::{HookTriggers, Lua, VmState};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

/// Пауза между мягким `SIGTERM` и принудительным `SIGKILL` для дочерних процессов,
/// не завершившихся после отмены конвейера.
pub const CHILD_KILL_GRACE: Duration = Duration::from_secs(2);

/// Параметры регистрации дочернего OS-процесса в контроллере отмены.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ChildRegistration {
    /// Процесс запущен лидером собственной группы (`process_group(0)`):
    /// сигнал отправляется всей группе (`kill(-pid)`), включая внуков (`sh -c ...`).
    pub process_group: bool,
    /// Интерактивный процесс, наследующий TTY. Такой процесс не выносится в отдельную группу
    /// (иначе фоновая группа получит SIGTTIN/SIGTTOU), а при пользовательском Ctrl+C
    /// не добивается ядром: терминал сам доставляет ему SIGINT, и процесс решает, как реагировать
    /// (например, REPL прерывает текущую операцию).
    pub interactive: bool,
}

/// Контроллер безопасной отмены конвейера при Ctrl+C, SIGINT или таймаутах.
#[derive(Clone, Debug)]
pub struct PipelineCanceller {
    is_cancelled: Arc<AtomicBool>,
    is_cleaning_up: Arc<AtomicBool>,
    reason: Arc<RwLock<Option<String>>>,
    /// Активные дочерние процессы шагов конвейера (PID -> параметры регистрации).
    /// PID удаляется из реестра строго ДО того, как процесс будет «пожат» (reaped) через `wait()`,
    /// поэтому зарегистрированный PID гарантированно не может быть переиспользован ОС.
    active_pids: Arc<Mutex<HashMap<u32, ChildRegistration>>>,
}

impl Default for PipelineCanceller {
    fn default() -> Self {
        Self::new()
    }
}

/// Отправка сигнала процессу (или всей его группе) через `libc::kill`.
fn send_signal(pid: u32, reg: ChildRegistration, sig: libc::c_int) {
    let Ok(raw) = libc::pid_t::try_from(pid) else {
        return;
    };
    if raw <= 0 {
        return;
    }
    unsafe {
        if reg.process_group {
            // Сначала вся группа (лидер + внуки), затем страховочно сам лидер
            libc::kill(-raw, sig);
        }
        libc::kill(raw, sig);
    }
}

impl PipelineCanceller {
    pub fn new() -> Self {
        Self {
            is_cancelled: Arc::new(AtomicBool::new(false)),
            is_cleaning_up: Arc::new(AtomicBool::new(false)),
            reason: Arc::new(RwLock::new(None)),
            active_pids: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Инициировать отмену выполнения с указанием причины.
    /// Все зарегистрированные дочерние процессы получают `SIGTERM`, а не завершившиеся
    /// за [`CHILD_KILL_GRACE`] — `SIGKILL` (Watchdog-таймаут, `KillTask`).
    pub fn cancel(&self, reason: &str) {
        self.cancel_impl(reason, true);
    }

    /// Отмена по пользовательскому прерыванию (первый Ctrl+C в терминале).
    /// Неинтерактивные дочерние процессы завершаются так же, как в [`Self::cancel`],
    /// а интерактивные (наследующие TTY) не трогаются: SIGINT им уже доставил терминал.
    pub fn cancel_user_interrupt(&self, reason: &str) {
        self.cancel_impl(reason, false);
    }

    fn cancel_impl(&self, reason: &str, include_interactive: bool) {
        if let Ok(mut r) = self.reason.write() {
            if r.is_none() {
                *r = Some(reason.to_string());
            }
        }
        self.is_cancelled.store(true, Ordering::SeqCst);
        self.terminate_children(include_interactive);
    }

    /// Отправляет `SIGTERM` зарегистрированным процессам и планирует эскалацию до `SIGKILL`.
    fn terminate_children(&self, include_interactive: bool) {
        let targets: Vec<(u32, ChildRegistration)> = match self.active_pids.lock() {
            Ok(map) => {
                let list: Vec<_> = map
                    .iter()
                    .filter(|(_, reg)| include_interactive || !reg.interactive)
                    .map(|(pid, reg)| (*pid, *reg))
                    .collect();
                // Сигналы отправляются под замком реестра: пока PID в реестре, процесс не «пожат»
                for (pid, reg) in &list {
                    send_signal(*pid, *reg, libc::SIGTERM);
                }
                list
            }
            Err(_) => return,
        };

        if targets.is_empty() {
            return;
        }

        let registry = Arc::clone(&self.active_pids);
        std::thread::spawn(move || {
            std::thread::sleep(CHILD_KILL_GRACE);
            if let Ok(map) = registry.lock() {
                for (pid, reg) in targets {
                    if map.contains_key(&pid) {
                        send_signal(pid, reg, libc::SIGKILL);
                    }
                }
            }
        });
    }

    /// Зарегистрировать дочерний процесс (сигнал отправляется только по PID).
    /// Если конвейер уже отменён — процесс немедленно получает `SIGTERM`.
    pub fn register_child_pid(&self, pid: u32) {
        self.register_child(pid, ChildRegistration::default());
    }

    /// Зарегистрировать дочерний процесс с явными параметрами (группа процессов / интерактивность).
    /// Если конвейер уже отменён — процесс (или группа) немедленно получает `SIGTERM`.
    pub fn register_child(&self, pid: u32, reg: ChildRegistration) {
        if let Ok(mut map) = self.active_pids.lock() {
            map.insert(pid, reg);
            if self.is_cancelled() && !self.is_cleaning_up() {
                send_signal(pid, reg, libc::SIGTERM);
            }
        }
    }

    /// Снять регистрацию дочернего процесса (вызывается после его завершения, до `wait()`).
    pub fn unregister_child_pid(&self, pid: u32) {
        if let Ok(mut map) = self.active_pids.lock() {
            map.remove(&pid);
        }
    }

    /// Количество активных зарегистрированных дочерних процессов.
    pub fn active_child_count(&self) -> usize {
        self.active_pids.lock().map(|m| m.len()).unwrap_or(0)
    }

    /// Проверить, отменен ли конвейер.
    pub fn is_cancelled(&self) -> bool {
        self.is_cancelled.load(Ordering::SeqCst)
    }

    /// Получить причину отмены.
    pub fn get_reason(&self) -> Option<String> {
        self.reason.read().ok().and_then(|r| r.clone())
    }

    /// Установить режим выполнения cleanup (при этом хук отмены не прерывает очистку).
    pub fn set_cleaning_up(&self, val: bool) {
        self.is_cleaning_up.store(val, Ordering::SeqCst);
    }

    /// Проверить, находится ли система в процессе очистки ресурсов.
    pub fn is_cleaning_up(&self) -> bool {
        self.is_cleaning_up.load(Ordering::SeqCst)
    }

    /// Сбросить флаг отмены для нового запуска.
    pub fn reset(&self) {
        self.is_cancelled.store(false, Ordering::SeqCst);
        self.is_cleaning_up.store(false, Ordering::SeqCst);
        if let Ok(mut r) = self.reason.write() {
            *r = None;
        }
    }
}

/// Установка периодического хука в Lua для прерывания бесконечных циклов
/// или долгих вычислений при флаге отмены.
pub fn attach_lua_cancellation_hook(lua: &Lua, canceller: PipelineCanceller) {
    let canceller_clone = canceller.clone();
    lua.set_hook(
        HookTriggers::default().every_nth_instruction(10_000),
        move |_lua, _debug| {
            if canceller_clone.is_cancelled() && !canceller_clone.is_cleaning_up() {
                let reason = canceller_clone
                    .get_reason()
                    .unwrap_or_else(|| "Конвейер был прерван пользователем (SIGINT)".to_string());
                Err(mlua::Error::runtime(format!("[CANCELLATION] {}", reason)))
            } else {
                Ok(VmState::Continue)
            }
        },
    );
}

/// Асинхронный двухэтапный слушатель сигнала Ctrl+C:
/// 1. При первом сигнале — мягкая отмена активных шагов конвейера.
/// 2. При повторном сигнале — немедленное принудительное завершение (код 130).
pub fn spawn_ctrl_c_watcher(canceller: PipelineCanceller) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            eprintln!("\n[Grime] Получен сигнал прерывания. Завершение активных шагов (нажмите Ctrl+C повторно для принудительного выхода)...");
            canceller.cancel_user_interrupt("Прервано пользователем (Ctrl+C)");

            // Ожидание повторного нажатия Ctrl+C для немедленного принудительного завершения
            if tokio::signal::ctrl_c().await.is_ok() {
                eprintln!("\n[Grime] Повторный сигнал Ctrl+C. Принудительное завершение процесса...");
                std::process::exit(130);
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn test_lua_infinite_loop_cancellation() {
        let lua = Lua::new();
        let canceller = PipelineCanceller::new();

        attach_lua_cancellation_hook(&lua, canceller.clone());

        // Запускаем отмену через 50 миллисекунд в отдельном потоке
        let c = canceller.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            c.cancel("Тестовый таймаут прерывания");
        });

        // Бесконечный цикл в Lua
        let result: Result<(), mlua::Error> = lua
            .load("local x = 0; while true do x = x + 1 end")
            .exec();

        assert!(result.is_err());
        let err_str = result.unwrap_err().to_string();
        assert!(err_str.contains("[CANCELLATION]"));
        assert!(err_str.contains("Тестовый таймаут прерывания"));
    }
}
