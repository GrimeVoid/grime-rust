use colored::Colorize;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::event_bus::EventBus;
use crate::lua_engine::GrimeLuaEngine;
use crate::payload::PipelinePayload;
use crate::pipeline::{
    canonical_module_name, format_subpipeline_cli, is_env_wrapper_step, is_host_step,
    ParsedPipeline, PipelineStep,
};
use crate::preflight::PreflightInspector;
use crate::process::run_interactive;
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

        // 3. Упреждающая инициализация окружений (Pre-flight Inspection)
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
            let has_subsequent = step_idx < total_steps - 1;

            // 1. Проверяем Tail Delegation (переключатель среды box или nix)
            if is_env_wrapper_step(&mod_name, &step.args, has_subsequent) {
                // Если шаг box, ожидаем завершения упреждающего прогрева (Pre-flight Inspection)
                if mod_name == "box" {
                    let containers = crate::distrobox::get_distrobox_containers();
                    let specified_box = step
                        .args
                        .iter()
                        .find(|a| !a.starts_with('-'))
                        .map(|s| s.as_str());
                    let cfg_def = self.config.get("distrobox_default", None);
                    if let Some(resolved_box) = crate::distrobox::get_default_box_name(
                        &containers,
                        specified_box.or_else(|| {
                            if cfg_def.is_empty() {
                                None
                            } else {
                                Some(&cfg_def)
                            }
                        }),
                    ) {
                        let _ = self.preflight.wait_for_container(&resolved_box).await;
                    }
                }

                // Ищем рубеж возврата на хост
                let mut host_rel_idx: Option<usize> = None;
                for (idx, sub_step) in steps[step_idx + 1..].iter().enumerate() {
                    if is_host_step(&sub_step.module) {
                        host_rel_idx = Some(idx);
                        break;
                    }
                }

                let sub_steps: &[PipelineStep];
                let next_step_idx: usize;

                if let Some(h_idx) = host_rel_idx {
                    sub_steps = &steps[step_idx + 1..step_idx + 1 + h_idx];
                    next_step_idx = step_idx + 1 + h_idx + 1;
                } else {
                    sub_steps = &steps[step_idx + 1..];
                    next_step_idx = total_steps;
                }

                if !sub_steps.is_empty() {
                    let sub_cli = format_subpipeline_cli(sub_steps);
                    let ret = self.execute_env_subpipeline(
                        &mod_name,
                        &step.args,
                        &sub_cli,
                        &current_target_dir,
                    )?;

                    if ret != 0 {
                        let err = format!(
                            "Подконвейер внутри окружения '{}' завершился с кодом ошибки {}",
                            mod_name, ret
                        );
                        if !parsed.force {
                            for m in &executed_modules {
                                self.engine.call_cleanup(m);
                            }
                            self.engine.emit_event(
                                "pipeline.failed",
                                serde_json::json!({
                                    "error": err,
                                    "module": mod_name
                                }),
                            );
                            return Err(err);
                        }
                    } else {
                        let dir_str = current_target_dir.to_string_lossy().to_string();
                        pipeline_data = Some(dir_str.clone());
                        pipeline_payload = Some(PipelinePayload::from_string(dir_str));
                    }

                    step_idx = next_step_idx;
                    continue;
                } else {
                    step_idx = next_step_idx;
                    continue;
                }
            }

            // 2. Если шаг хоста вне переключения сред — no-op
            if is_host_step(&mod_name) {
                step_idx += 1;
                continue;
            }

            // 3. Выполнение шага Lua модуля
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

            // Установка контекста шага с передачей PipelinePayload
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

    fn execute_env_subpipeline(
        &self,
        env_mod_name: &str,
        env_args: &[String],
        sub_cli: &str,
        target_dir: &Path,
    ) -> Result<i32, String> {
        let escaped_dir = target_dir.to_string_lossy().replace('\'', "'\\''");

        if env_mod_name == "box" {
            let containers = crate::distrobox::get_distrobox_containers();
            let specified_box = env_args
                .iter()
                .find(|a| !a.starts_with('-'))
                .map(|s| s.as_str());

            let cfg_def = self.config.get("distrobox_default", None);
            let resolved_box = match crate::distrobox::get_default_box_name(
                &containers,
                specified_box.or_else(|| if cfg_def.is_empty() { None } else { Some(&cfg_def) }),
            ) {
                Some(b) => b,
                None => {
                    return Err("Не найден целевой контейнер Distrobox.".to_string());
                }
            };

            let inner_cmd = format!(
                "export PATH=\"$PATH:$HOME/.local/bin\"; cd '{}' && grime {}",
                escaped_dir, sub_cli
            );
            let cmd = vec![
                "distrobox".to_string(),
                "enter".to_string(),
                resolved_box.clone(),
                "--".to_string(),
                "bash".to_string(),
                "-c".to_string(),
                inner_cmd,
            ];

            eprintln!(
                "{} Запуск подконвейера в [{}]: grime {} (директория: {})",
                "[Grime]".cyan().bold(),
                resolved_box,
                sub_cli,
                target_dir.display()
            );
            Ok(run_interactive(&cmd, target_dir, None))
        } else if env_mod_name == "nix" {
            let pure = env_args.iter().any(|a| a == "--pure" || a == "-p");
            let has_flake = target_dir.join("flake.nix").exists();

            let inner_cmd = format!(
                "export PATH=\"$PATH:$HOME/.local/bin\"; cd '{}' && grime {}",
                escaped_dir, sub_cli
            );

            let cmd = if has_flake {
                let mut c = vec!["nix".to_string(), "develop".to_string()];
                if pure {
                    c.push("--pure".to_string());
                }
                c.extend(vec![
                    "--command".to_string(),
                    "bash".to_string(),
                    "-c".to_string(),
                    inner_cmd,
                ]);
                c
            } else {
                let mut c = vec!["nix-shell".to_string()];
                if pure {
                    c.push("--pure".to_string());
                }
                c.extend(vec![
                    "--run".to_string(),
                    format!("bash -c \"{}\"", inner_cmd.replace('\"', "\\\"")),
                ]);
                c
            };

            eprintln!(
                "{} Запуск подконвейера в Nix DevShell: grime {} (директория: {})",
                "[Grime]".cyan().bold(),
                sub_cli,
                target_dir.display()
            );
            Ok(run_interactive(&cmd, target_dir, None))
        } else {
            Err(format!("Неизвестный тип окружения: {}", env_mod_name))
        }
    }
}
