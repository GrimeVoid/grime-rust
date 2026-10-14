use mlua::{HookTriggers, Lua, VmState};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};

/// Контроллер безопасной отмены конвейера при Ctrl+C, SIGINT или таймаутах.
#[derive(Clone, Debug)]
pub struct PipelineCanceller {
    is_cancelled: Arc<AtomicBool>,
    is_cleaning_up: Arc<AtomicBool>,
    reason: Arc<RwLock<Option<String>>>,
}

impl Default for PipelineCanceller {
    fn default() -> Self {
        Self::new()
    }
}

impl PipelineCanceller {
    pub fn new() -> Self {
        Self {
            is_cancelled: Arc::new(AtomicBool::new(false)),
            is_cleaning_up: Arc::new(AtomicBool::new(false)),
            reason: Arc::new(RwLock::new(None)),
        }
    }

    /// Инициировать отмену выполнения с указанием причины.
    pub fn cancel(&self, reason: &str) {
        if let Ok(mut r) = self.reason.write() {
            if r.is_none() {
                *r = Some(reason.to_string());
            }
        }
        self.is_cancelled.store(true, Ordering::SeqCst);
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
        HookTriggers::default().every_nth_instruction(250),
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

/// Снятие хука прерывания с виртуальной машины Lua.
pub fn detach_lua_cancellation_hook(lua: &Lua) {
    lua.remove_hook();
}

/// Асинхронный слушатель сигнала Ctrl+C для установки флага отмены.
pub fn spawn_ctrl_c_watcher(canceller: PipelineCanceller) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            eprintln!("\n[Grime] Получен сигнал прерывания (Ctrl+C). Остановка конвейера...");
            canceller.cancel("Прерывание пользователем по сигналу SIGINT / Ctrl+C");
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
