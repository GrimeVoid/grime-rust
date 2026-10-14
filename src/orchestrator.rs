use colored::Colorize;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::event_bus::EventBus;
use crate::lua_engine::GrimeLuaEngine;
use crate::payload::PipelinePayload;
use crate::pipeline::{canonical_module_name, is_host_step, ParsedPipeline};
use crate::preflight::PreflightInspector;
use crate::state_bus::StateBus;

pub struct Orchestrator {
    engine: GrimeLuaEngine,
    config: GrimeConfig,
    state_bus: Arc<StateBus>,
    event_bus: Arc<EventBus>,
    canceller: PipelineCanceller,
    preflight: PreflightInspector,
}

impl Orchestrator {
    pub fn new(modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> Result<Self, mlua::Error> {
        let state_bus = Arc::new(StateBus::new());
        let event_bus = Arc::new(EventBus::default());
        let canceller = PipelineCanceller::new();
        let preflight = PreflightInspector::new();

        let engine = GrimeLuaEngine::new_with_bus(
            modules_dir,
            config_path,
            state_bus.clone(),
            event_bus.clone(),
            canceller.clone(),
        )?;
        let config = GrimeConfig::load_or_default(config_path);

        Ok(Orchestrator {
            engine,
            config,
            state_bus,
            event_bus,
            canceller,
            preflight,
        })
    }

    pub fn state_bus(&self) -> &Arc<StateBus> {
        &self.state_bus
    }

    pub fn event_bus(&self) -> &Arc<EventBus> {
        &self.event_bus
    }

    pub fn canceller(&self) -> &PipelineCanceller {
        &self.canceller
    }

    pub fn config(&self) -> &GrimeConfig {
        &self.config
    }

    pub async fn run_pipeline(&self, parsed: &ParsedPipeline) -> Result<Option<String>, String> {
        let steps = &parsed.steps;
        if steps.is_empty() {
            eprintln!("{} Нет шагов для исполнения.", "[Grime]".cyan().bold());
            return Ok(None);
        }

        // 1. RAII очистка сессионных данных pipeline.* после завершения конвейера
        let _session_guard = self.state_bus.create_session_guard();

        // 2. Сброс состояния прерывания
        self.canceller.reset();

        // 3. Упреждающая инициализация и валидация шагов (Pre-flight Inspection)
        self.preflight.inspect_and_warmup(parsed, &self.config);

        let raw_work_path = parsed
            .work_path
            .clone()
            .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
        let mut current_target_dir = crate::fs_ops::normalize_path(&raw_work_path);

        let total_steps = steps.len();
        let mut step_idx = 0;
        let mut pipeline_data: Option<String> = None;
        let mut pipeline_payload: Option<PipelinePayload> = None;
        let mut executed_modules: Vec<String> = Vec::new();

        // Публикация события старта конвейера
        self.engine.emit_event(
            "pipeline.start",
            serde_json::json!({
                "target_dir": current_target_dir.to_string_lossy(),
                "total_steps": total_steps,
                "steps": steps.iter().map(|s| &s.module).collect::<Vec<_>>()
            }),
        );

        while step_idx < total_steps {
            // Проверка безопасной отмены конвейера при Ctrl+C / SIGINT
            if self.canceller.is_cancelled() {
                let reason = self
                    .canceller
                    .get_reason()
                    .unwrap_or_else(|| "Конвейер прерван пользователем".to_string());
                eprintln!("{} {}", "[Grime Cancelled]".yellow().bold(), reason);

                for m in &executed_modules {
                    self.engine.call_cleanup(m);
                }

                self.engine.emit_event(
                    "pipeline.failed",
                    serde_json::json!({
                        "cancelled": true,
                        "reason": reason
                    }),
                );
                return Err(format!("Конвейер прерван: {}", reason));
            }

            let step = &steps[step_idx];
            let mod_name = canonical_module_name(&step.module);

            // Если шаг хоста — no-op
            if is_host_step(&mod_name) {
                step_idx += 1;
                continue;
            }

            // Выполнение шага Lua модуля: авто-определение рабочей директории из выхода прошлого шага
            if let Some(ref data) = pipeline_data {
                let candidate = PathBuf::from(data.trim());
                if candidate.exists() {
                    let dir = if candidate.is_file() {
                        candidate.parent().unwrap_or(&candidate).to_path_buf()
                    } else {
                        candidate
                    };
                    current_target_dir = crate::fs_ops::normalize_path(&dir);
                }
            }

            // Установка контекста шага с передачей PipelinePayload (Zero-Copy bytes::Bytes)
            if let Err(e) = self.engine.set_step_context(
                step,
                step_idx,
                total_steps,
                &current_target_dir,
                pipeline_data.as_deref(),
                pipeline_payload.as_ref(),
            ) {
                for m in &executed_modules {
                    self.engine.call_cleanup(m);
                }
                return Err(format!("Ошибка установки контекста для '{}': {}", mod_name, e));
            }

            // Событие старта шага
            self.engine.emit_event(
                "pipeline.step.start",
                serde_json::json!({
                    "module": mod_name,
                    "step_index": step_idx,
                    "total_steps": total_steps
                }),
            );

            executed_modules.push(mod_name.clone());

            let result = match self.engine.execute_module(&mod_name) {
                Ok(res) => res,
                Err(e) => {
                    for m in &executed_modules {
                        self.engine.call_cleanup(m);
                    }
                    self.engine.emit_event(
                        "pipeline.failed",
                        serde_json::json!({
                            "module": mod_name,
                            "error": e.to_string()
                        }),
                    );
                    return Err(format!("Ошибка выполнения модуля '{}': {}", mod_name, e));
                }
            };

            if !result.success {
                let err_msg = result
                    .error_message
                    .unwrap_or_else(|| format!("Модуль '{}' завершился со статусом ошибки", mod_name));
                eprintln!("{} {}", "[Grime Error]".red().bold(), err_msg);

                // Вызов функции cleanup() у задействованных модулей
                for m in &executed_modules {
                    self.engine.call_cleanup(m);
                }

                self.engine.emit_event(
                    "pipeline.failed",
                    serde_json::json!({
                        "module": mod_name,
                        "error": err_msg
                    }),
                );

                if !parsed.force {
                    return Err(err_msg);
                }
            }

            // Обновляем данные для следующего шага
            pipeline_data = result.return_value;
            pipeline_payload = result.payload;

            // Событие успешного завершения шага
            self.engine.emit_event(
                "pipeline.step.finish",
                serde_json::json!({
                    "module": mod_name,
                    "step_index": step_idx,
                    "success": result.success
                }),
            );

            step_idx += 1;
        }

        // Публикация события успешного завершения всего конвейера
        self.engine.emit_event(
            "pipeline.finish",
            serde_json::json!({
                "success": true,
                "result": pipeline_data
            }),
        );

        Ok(pipeline_data)
    }
}
