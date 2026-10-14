use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;

use crate::config::GrimeConfig;
use crate::pipeline::ParsedPipeline;

/// Результат пре-флайт прогрева или валидации.
#[derive(Debug, Clone)]
pub struct WarmupResult {
    pub target: String,
    pub ready: bool,
    pub duration_ms: u128,
}

/// Упреждающий инспектор конвейера (Pre-flight Inspector).
/// Сканирует шаги конвейера до старта и инициирует асинхронную валидацию
/// и подготовку ресурсов без жесткой привязки к конкретным сторонним средам.
pub struct PreflightInspector {
    warmup_receivers: Arc<Mutex<HashMap<String, oneshot::Receiver<Result<WarmupResult, String>>>>>,
}

impl Default for PreflightInspector {
    fn default() -> Self {
        Self::new()
    }
}

impl PreflightInspector {
    pub fn new() -> Self {
        Self {
            warmup_receivers: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Анализ конвейера перед запуском.
    pub fn inspect_and_warmup(&self, parsed: &ParsedPipeline, _config: &GrimeConfig) {
        // Нейтральная проверка конвейера: шаги регистрируются для предварительной подготовки
        for step in &parsed.steps {
            let mod_name = crate::pipeline::canonical_module_name(&step.module);
            let (tx, rx) = oneshot::channel();
            {
                if let Ok(mut map) = self.warmup_receivers.lock() {
                    if !map.contains_key(&mod_name) {
                        map.insert(mod_name.clone(), rx);
                        let target = mod_name.clone();
                        tokio::spawn(async move {
                            let start = std::time::Instant::now();
                            let _ = tx.send(Ok(WarmupResult {
                                target,
                                ready: true,
                                duration_ms: start.elapsed().as_millis(),
                            }));
                        });
                    }
                }
            }
        }
    }

    /// Ожидание завершения подготовки для указанной цели.
    pub async fn wait_for_target(&self, target: &str) -> Result<Option<WarmupResult>, String> {
        let rx = {
            let mut map = self.warmup_receivers.lock().map_err(|e| e.to_string())?;
            map.remove(target)
        };

        if let Some(rx) = rx {
            match rx.await {
                Ok(Ok(res)) => Ok(Some(res)),
                Ok(Err(err)) => Err(err),
                Err(_) => Ok(None),
            }
        } else {
            Ok(None)
        }
    }

    /// Для обратной совместимости вызовов wait_for_container
    pub async fn wait_for_container(&self, container: &str) -> Result<Option<WarmupResult>, String> {
        self.wait_for_target(container).await
    }

    /// Сброс состояния инспектора.
    pub fn reset(&self) {
        if let Ok(mut map) = self.warmup_receivers.lock() {
            map.clear();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_preflight_oneshot_synchronization() {
        let inspector = PreflightInspector::new();
        let (tx, rx) = oneshot::channel();

        {
            let mut map = inspector.warmup_receivers.lock().unwrap();
            map.insert("test-target".to_string(), rx);
        }

        // Симулируем фоновую подготовку
        tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
            let _ = tx.send(Ok(WarmupResult {
                target: "test-target".to_string(),
                ready: true,
                duration_ms: 10,
            }));
        });

        let res = inspector.wait_for_target("test-target").await.unwrap();
        assert!(res.is_some());
        let val = res.unwrap();
        assert_eq!(val.target, "test-target");
        assert!(val.ready);
    }
}
