use colored::Colorize;
use std::collections::HashMap;
use std::process::Command;
use std::sync::{Arc, Mutex};
use tokio::sync::oneshot;

use crate::config::GrimeConfig;
use crate::distrobox::{get_default_box_name, get_distrobox_containers};
use crate::pipeline::{canonical_module_name, ParsedPipeline};

/// Результат пре-флайт прогрева контейнера.
#[derive(Debug, Clone)]
pub struct WarmupResult {
    pub container: String,
    pub already_running: bool,
    pub duration_ms: u128,
}

/// Упреждающий инспектор конвейера (Pre-flight Inspector).
/// Сканирует шаги до запуска и инициирует асинхронный прогрев сред (podman start).
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

    /// Анализ конвейера и запуск фонового прогрева требуемых окружений.
    pub fn inspect_and_warmup(&self, parsed: &ParsedPipeline, config: &GrimeConfig) {
        let mut target_boxes = Vec::new();
        let containers = get_distrobox_containers();
        let cfg_default = config.get("distrobox_default", None);

        for step in &parsed.steps {
            let mod_name = canonical_module_name(&step.module);
            if mod_name == "box" {
                let specified_box = step
                    .args
                    .iter()
                    .find(|a| !a.starts_with('-'))
                    .map(|s| s.as_str());

                if let Some(resolved) = get_default_box_name(
                    &containers,
                    specified_box.or_else(|| {
                        if cfg_default.is_empty() {
                            None
                        } else {
                            Some(&cfg_default)
                        }
                    }),
                ) {
                    if !target_boxes.contains(&resolved) {
                        target_boxes.push(resolved);
                    }
                }
            }
        }

        // Запуск асинхронного прогрева через oneshot для каждого бокса
        for box_name in target_boxes {
            let (tx, rx) = oneshot::channel();
            {
                if let Ok(mut map) = self.warmup_receivers.lock() {
                    map.insert(box_name.clone(), rx);
                }
            }

            let container = box_name.clone();
            tokio::spawn(async move {
                let start_time = std::time::Instant::now();
                eprintln!(
                    "{} [Pre-flight] Упреждающий запуск окружения Distrobox/Podman '{}'...",
                    "[Grime]".cyan().bold(),
                    container
                );

                // Запускаем podman start в отдельном блокирующем пуле tokio
                let res = tokio::task::spawn_blocking({
                    let name = container.clone();
                    move || -> Result<WarmupResult, String> {
                        // 1. Проверяем статус контейнера
                        let check_out = Command::new("podman")
                            .args(["container", "inspect", &name, "--format", "{{.State.Running}}"])
                            .output();

                        if let Ok(out) = check_out {
                            let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
                            if text == "true" {
                                return Ok(WarmupResult {
                                    container: name,
                                    already_running: true,
                                    duration_ms: start_time.elapsed().as_millis(),
                                });
                            }
                        }

                        // 2. Если не запущен, выполняем podman start
                        let start_out = Command::new("podman")
                            .args(["start", &name])
                            .output();

                        match start_out {
                            Ok(out) if out.status.success() => Ok(WarmupResult {
                                container: name,
                                already_running: false,
                                duration_ms: start_time.elapsed().as_millis(),
                            }),
                            Ok(out) => {
                                let stderr = String::from_utf8_lossy(&out.stderr);
                                Err(format!("Не удалось запустить контейнер '{}': {}", name, stderr))
                            }
                            Err(e) => {
                                // Если podman не установлен или ошибка вызова, пробуем distrobox enter с no-op
                                Err(format!("podman error: {}", e))
                            }
                        }
                    }
                })
                .await;

                let send_res = match res {
                    Ok(inner_res) => inner_res,
                    Err(e) => Err(format!("Pre-flight task join error: {}", e)),
                };

                let _ = tx.send(send_res);
            });
        }
    }

    /// Ожидание завершения прогрева для указанного контейнера.
    /// Если контейнер уже прогрет, oneshot завершается мгновенно (0 мс задержки).
    pub async fn wait_for_container(&self, container: &str) -> Result<Option<WarmupResult>, String> {
        let rx = {
            let mut map = self.warmup_receivers.lock().map_err(|e| e.to_string())?;
            map.remove(container)
        };

        if let Some(rx) = rx {
            match rx.await {
                Ok(Ok(res)) => {
                    if res.already_running {
                        eprintln!(
                            "{} [Pre-flight] Окружение '{}' уже готово (0 ms задержки).",
                            "[Grime]".green().bold(),
                            container
                        );
                    } else {
                        eprintln!(
                            "{} [Pre-flight] Окружение '{}' успешно прогрето за {} ms.",
                            "[Grime]".green().bold(),
                            container,
                            res.duration_ms
                        );
                    }
                    Ok(Some(res))
                }
                Ok(Err(err)) => {
                    eprintln!(
                        "{} [Pre-flight Warning] Ошибка прогрева '{}': {}",
                        "[Grime]".yellow().bold(),
                        container,
                        err
                    );
                    Err(err)
                }
                Err(_) => {
                    // Канал был закрыт до отправки
                    Ok(None)
                }
            }
        } else {
            // Прогрев не запускался
            Ok(None)
        }
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
            map.insert("test-box".to_string(), rx);
        }

        // Симулируем фоновый прогрев
        tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(10)).await;
            let _ = tx.send(Ok(WarmupResult {
                container: "test-box".to_string(),
                already_running: true,
                duration_ms: 10,
            }));
        });

        let res = inspector.wait_for_container("test-box").await.unwrap();
        assert!(res.is_some());
        let val = res.unwrap();
        assert_eq!(val.container, "test-box");
        assert!(val.already_running);
    }
}
