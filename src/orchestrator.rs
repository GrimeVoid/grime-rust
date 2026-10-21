use colored::Colorize;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::event_bus::EventBus;
use crate::lua_engine::GrimeLuaEngine;
use crate::payload::PipelinePayload;
use crate::pipeline::{
    canonical_module_name, format_subpipeline_cli, is_host_step, ParsedPipeline, PipelineStep,
};
use crate::state_bus::StateBus;

const BOX_ONE_SHOT_ACTIONS: &[&str] = &[
    "list", "ls", "status", "ps", "stop", "create", "new", "init", "rm", "delete", "remove",
    "del", "export", "exp", "keepalive", "idle", "help", "-h", "--help", "run", "runner", "exec",
    "wrap", "do",
];

fn extract_box_env_switch(step: &PipelineStep, config: &GrimeConfig) -> Option<String> {
    if step
        .args
        .iter()
        .any(|a| a.starts_with('-') || BOX_ONE_SHOT_ACTIONS.contains(&a.to_lowercase().as_str()))
    {
        return None;
    }

    match step.args.len() {
        0 => Some(
            config
                .get_opt("distrobox_default", Some("default"))
                .unwrap_or_else(|| "default".to_string()),
        ),
        1 => {
            let first = step.args[0].to_lowercase();
            if matches!(first.as_str(), "enter" | "shell" | "sh") {
                Some(
                    config
                        .get_opt("distrobox_default", Some("default"))
                        .unwrap_or_else(|| "default".to_string()),
                )
            } else {
                Some(step.args[0].clone())
            }
        }
        2 => {
            let first = step.args[0].to_lowercase();
            if matches!(first.as_str(), "enter" | "shell" | "sh") {
                Some(step.args[1].clone())
            } else {
                None
            }
        }
        _ => None,
    }
}

pub struct Orchestrator {
    engine: GrimeLuaEngine,
    config: GrimeConfig,
    state_bus: Arc<StateBus>,
    event_bus: Arc<EventBus>,
    canceller: PipelineCanceller,
}

impl Orchestrator {
    pub fn new(modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> Result<Self, mlua::Error> {
        let state_bus = Arc::new(StateBus::new());
        let event_bus = Arc::new(EventBus::default());
        let canceller = PipelineCanceller::new();
        Self::new_with_shared(modules_dir, config_path, state_bus, event_bus, canceller)
    }

    pub fn new_with_shared(
        modules_dir: Option<PathBuf>,
        config_path: Option<&Path>,
        state_bus: Arc<StateBus>,
        event_bus: Arc<EventBus>,
        canceller: PipelineCanceller,
    ) -> Result<Self, mlua::Error> {
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

    pub fn set_environment(&self, env: &std::collections::HashMap<String, String>) -> Result<(), mlua::Error> {
        self.engine.set_environment(env)
    }

    fn run_cleanup(engine: &GrimeLuaEngine, executed_modules: &[String]) {
        for m in executed_modules.iter().rev() {
            engine.call_cleanup(m);
        }
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

                Self::run_cleanup(&self.engine, &executed_modules);

                self.engine.emit_event(
                    "pipeline.failed",
                    serde_json::json!({
                        "cancelled": true,
                        "reason": reason
                    }),
                );
                return Err(format!("Конвейер прерван: {}", reason));
            }

            let raw_step = &steps[step_idx];
            let mod_name = canonical_module_name(&raw_step.module);

            // Рубеж сред `: box <name> : ... : host :`
            let mut next_step_idx = step_idx + 1;
            let effective_step: std::borrow::Cow<'_, PipelineStep> =
                if mod_name == "box" && step_idx + 1 < total_steps {
                    if let Some(box_name) = extract_box_env_switch(raw_step, &self.config) {
                        let host_idx = steps
                            .iter()
                            .enumerate()
                            .skip(step_idx + 1)
                            .find(|(_, candidate)| is_host_step(&candidate.module))
                            .map(|(idx, _)| idx);

                        let end_sub_idx = host_idx.unwrap_or(total_steps);
                        let sub_steps = &steps[(step_idx + 1)..end_sub_idx];
                        if !sub_steps.is_empty() {
                            let sub_cli = format_subpipeline_cli(sub_steps);
                            eprintln!(
                                "{} Переключение среды в контейнер '{}' -> {}",
                                "[Grime Box]".cyan().bold(),
                                box_name,
                                sub_cli
                            );

                            let mut synth_args = vec![
                                "run".to_string(),
                                box_name,
                                "--".to_string(),
                                "grime".to_string(),
                            ];
                            if parsed.force {
                                synth_args.push("-f".to_string());
                            }
                            for (i, s) in sub_steps.iter().enumerate() {
                                if i > 0 {
                                    synth_args.push(":".to_string());
                                }
                                synth_args.push(s.module.clone());
                                synth_args.extend(s.args.clone());
                            }

                            next_step_idx = host_idx.map_or(total_steps, |h| h + 1);
                            std::borrow::Cow::Owned(PipelineStep {
                                module: "box".to_string(),
                                args: synth_args,
                            })
                        } else {
                            std::borrow::Cow::Borrowed(raw_step)
                        }
                    } else {
                        std::borrow::Cow::Borrowed(raw_step)
                    }
                } else {
                    std::borrow::Cow::Borrowed(raw_step)
                };

            // Установка контекста шага с передачей PipelinePayload (Zero-Copy bytes::Bytes) и флага force
            if let Err(e) = self.engine.set_step_context(
                &effective_step,
                step_idx,
                total_steps,
                &current_target_dir,
                pipeline_data.as_deref(),
                pipeline_payload.as_ref(),
                parsed.force,
            ) {
                Self::run_cleanup(&self.engine, &executed_modules);
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
                    Self::run_cleanup(&self.engine, &executed_modules);
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

                // Вызов функции cleanup() у задействованных модулей в порядке LIFO
                Self::run_cleanup(&self.engine, &executed_modules);

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

            // Смена рабочей директории: ТОЛЬКО если шаг явно запросил это через ctx.set_target_dir()
            // или если это первый шаг конвейера (step_idx == 0), вернувший существующий путь/директорию
            if let Some(new_dir) = result.changed_target_dir {
                current_target_dir = crate::fs_ops::normalize_path(&new_dir);
            } else if step_idx == 0 {
                if let Some(ref data) = result.return_value {
                    let trimmed = data.trim();
                    if !trimmed.is_empty()
                        && trimmed.len() < 4096
                        && !trimmed.contains('\n')
                        && !trimmed.starts_with('{')
                        && !trimmed.starts_with('[')
                    {
                        let candidate = PathBuf::from(trimmed);
                        if candidate.exists() {
                            let dir = if candidate.is_file() {
                                candidate.parent().unwrap_or(&candidate).to_path_buf()
                            } else {
                                candidate
                            };
                            current_target_dir = crate::fs_ops::normalize_path(&dir);
                        }
                    }
                }
            }

            // Обновляем данные для следующего шага
            pipeline_data = result.return_value;
            pipeline_payload = result.payload;

            // Инкрементальная сборка мусора Lua между шагами для предотвращения накопления памяти
            self.engine.gc_step(100);

            // Событие успешного завершения шага
            self.engine.emit_event(
                "pipeline.step.finish",
                serde_json::json!({
                    "module": mod_name,
                    "step_index": step_idx,
                    "success": result.success
                }),
            );

            step_idx = next_step_idx;
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
