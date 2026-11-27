use colored::Colorize;
use std::borrow::Cow;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::event_bus::EventBus;
use crate::lua_engine::{GrimeLuaEngine, WrapOutcome};
use crate::modules::ModuleRegistry;
use crate::payload::PipelinePayload;
use crate::pipeline::{ParsedPipeline, PipelineStep};
use crate::state_bus::StateBus;

/// Уникальный идентификатор сессии оркестратора (метка его событий в общей шине).
fn next_session_id() -> String {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    format!(
        "sess_{}_{}_{}",
        std::process::id(),
        nanos,
        COUNTER.fetch_add(1, Ordering::SeqCst)
    )
}

/// Собирает argv подконвейера для хука `wrap_pipeline`:
/// `grime -p <target_dir> [-f] <модуль1> <арги...> : <модуль2> ...`.
fn build_rest_argv(target_dir: &Path, force: bool, sub_steps: &[PipelineStep]) -> Vec<String> {
    let mut argv = vec![
        "grime".to_string(),
        "-p".to_string(),
        target_dir.to_string_lossy().to_string(),
    ];
    if force {
        argv.push("-f".to_string());
    }
    for (i, s) in sub_steps.iter().enumerate() {
        if i > 0 {
            argv.push(":".to_string());
        }
        argv.push(s.module.clone());
        argv.extend(s.args.iter().cloned());
    }
    argv
}

/// План исполнения шага: какой шаг реально выполнить и с какого индекса продолжить.
enum StepPlan<'a> {
    /// Пропустить шаг (уже в нужной среде).
    Skip,
    Run {
        step: Cow<'a, PipelineStep>,
        next_idx: usize,
    },
}

pub struct Orchestrator {
    engine: GrimeLuaEngine,
    config: Arc<GrimeConfig>,
    registry: Arc<ModuleRegistry>,
    state_bus: Arc<StateBus>,
    event_bus: Arc<EventBus>,
    canceller: PipelineCanceller,
    session_id: String,
}

impl Orchestrator {
    pub fn new(modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> Result<Self, mlua::Error> {
        let config = Arc::new(GrimeConfig::load_or_default(config_path));
        let registry = Arc::new(ModuleRegistry::for_config(&config, modules_dir));
        Self::new_with_shared(
            config,
            registry,
            Arc::new(StateBus::new()),
            Arc::new(EventBus::default()),
            PipelineCanceller::new(),
        )
    }

    /// Создаёт оркестратор поверх общих компонентов: один `Arc<GrimeConfig>` и реестр на всех.
    pub fn new_with_shared(
        config: Arc<GrimeConfig>,
        registry: Arc<ModuleRegistry>,
        state_bus: Arc<StateBus>,
        event_bus: Arc<EventBus>,
        canceller: PipelineCanceller,
    ) -> Result<Self, mlua::Error> {
        let session_id = next_session_id();
        let engine = GrimeLuaEngine::from_parts(
            config.clone(),
            registry.clone(),
            state_bus.clone(),
            event_bus.clone(),
            canceller.clone(),
            session_id.clone(),
        )?;

        Ok(Orchestrator {
            engine,
            config,
            registry,
            state_bus,
            event_bus,
            canceller,
            session_id,
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

    pub fn config(&self) -> &Arc<GrimeConfig> {
        &self.config
    }

    pub fn registry(&self) -> &Arc<ModuleRegistry> {
        &self.registry
    }

    /// Идентификатор сессии, которым помечаются все события этого оркестратора.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Разбор аргументов командной строки с реестром этого оркестратора.
    pub fn parse_args(&self, raw_args: &[String]) -> ParsedPipeline {
        crate::pipeline::parse_pipeline_args(raw_args, &self.registry)
    }

    pub fn set_environment(&self, env: &std::collections::HashMap<String, String>) -> Result<(), mlua::Error> {
        self.engine.set_environment(env)
    }

    /// Вызов `cleanup()` задействованных модулей в порядке LIFO.
    /// `verbose` включает сообщение о вызове: только для аварийного пути, не для штатного завершения.
    fn run_cleanup(&self, executed_modules: &[String], verbose: bool) {
        for m in executed_modules.iter().rev() {
            self.engine.call_cleanup(m, verbose);
        }
    }

    /// Единая точка аварийного завершения: cleanup (LIFO), событие `pipeline.failed`, текст ошибки.
    fn abort(&self, executed_modules: &[String], event: serde_json::Value, err: String) -> String {
        self.run_cleanup(executed_modules, true);
        self.engine.emit_event("pipeline.failed", event);
        err
    }

    /// Аварийное завершение по отмене конвейера (Ctrl+C, таймаут, KillTask).
    fn abort_cancelled(&self, executed_modules: &[String], module: Option<&str>) -> String {
        let reason = self
            .canceller
            .get_reason()
            .unwrap_or_else(|| "Конвейер прерван пользователем".to_string());
        eprintln!("{} {}", "[Grime Cancelled]".yellow().bold(), reason);
        let mut event = serde_json::json!({ "cancelled": true, "reason": reason });
        if let Some(m) = module {
            event["module"] = serde_json::json!(m);
        }
        self.abort(executed_modules, event, format!("Конвейер прерван: {}", reason))
    }

    /// Аварийное завершение по ошибке шага.
    fn abort_error(&self, executed_modules: &[String], module: &str, event_error: &str, err: String) -> String {
        eprintln!("{} {}", "[Grime Error]".red().bold(), err);
        self.abort(
            executed_modules,
            serde_json::json!({ "module": module, "error": event_error }),
            err,
        )
    }

    /// Планирует шаг: для модуля с `wraps: pipeline` спрашивает хук `wrap_pipeline`,
    /// нужно ли выполнить подконвейер (до следующего модуля-рубежа) в другой среде.
    fn plan_step<'a>(
        &self,
        steps: &'a [PipelineStep],
        step_idx: usize,
        mod_name: &str,
        target_dir: &Path,
        force: bool,
    ) -> Result<StepPlan<'a>, String> {
        let raw_step = &steps[step_idx];
        let plain = || StepPlan::Run {
            step: Cow::Borrowed(raw_step),
            next_idx: step_idx + 1,
        };

        let wraps = self.registry.get(mod_name).is_some_and(|m| m.wraps_pipeline());
        if !wraps || step_idx + 1 >= steps.len() {
            return Ok(plain());
        }

        let boundary_idx = (step_idx + 1..steps.len()).find(|&i| self.registry.is_boundary(&steps[i].module));
        let sub_steps = &steps[step_idx + 1..boundary_idx.unwrap_or(steps.len())];
        if sub_steps.is_empty() {
            return Ok(plain());
        }

        let rest_argv = build_rest_argv(target_dir, force, sub_steps);
        let outcome = self
            .engine
            .set_step_context(raw_step, step_idx, steps.len(), target_dir, None, None, force)
            .and_then(|_| self.engine.call_wrap_hook(mod_name, &raw_step.args, &rest_argv))
            .map_err(|e| format!("Ошибка хука wrap_pipeline модуля '{}': {}", mod_name, e))?;

        Ok(match outcome {
            WrapOutcome::None => plain(),
            WrapOutcome::Skip => StepPlan::Skip,
            WrapOutcome::Args(args) => StepPlan::Run {
                step: Cow::Owned(PipelineStep {
                    module: mod_name.to_string(),
                    args,
                }),
                // Подконвейер поглощён хуком: продолжаем после рубежа (или завершаем)
                next_idx: boundary_idx.map_or(steps.len(), |b| b + 1),
            },
        })
    }

    /// Проверка требований (`requires:`) модулей всех шагов: один отчёт по всем проблемам.
    /// Без `--force` обязательные проблемы — отказ; с ним (и для необязательных) — предупреждения.
    fn preflight(&self, parsed: &ParsedPipeline) -> Result<(), String> {
        let roots: Vec<String> = parsed.steps.iter().map(|s| self.registry.canonical_name(&s.module)).collect();
        let rep = crate::deps::preflight(&self.registry, &roots);
        for w in &rep.warnings {
            eprintln!("{} {}", "[Grime Warning]".yellow().bold(), w);
        }
        if rep.errors.is_empty() {
            return Ok(());
        }
        if parsed.force {
            for e in &rep.errors {
                eprintln!("{} {} (продолжаем из-за --force)", "[Grime Warning]".yellow().bold(), e);
            }
            return Ok(());
        }
        let mut msg = String::from("Не выполнены требования модулей:");
        for e in &rep.errors {
            msg.push_str("\n  - ");
            msg.push_str(e);
        }
        msg.push_str("\n  (используйте -f, чтобы продолжить несмотря на это)");
        eprintln!("{} {}", "[Grime Error]".red().bold(), msg);
        Err(msg)
    }

    pub fn run_pipeline(&self, parsed: &ParsedPipeline) -> Result<Option<String>, String> {
        let steps = &parsed.steps;
        if steps.is_empty() {
            eprintln!("{} Нет шагов для исполнения.", "[Grime]".cyan().bold());
            return Ok(None);
        }

        // 1. RAII очистка сессионных данных pipeline.* после завершения конвейера
        let _session_guard = self.state_bus.create_session_guard();

        // 1.1. RAII удаление эфемерных ресурсов сессии (успех, ошибка, отмена, паника)
        let _eph_guard = self.engine.ephemeral().guard();

        // 1.2. Pre-flight: зависимости (module:/bin:) всех шагов проверяются до первого шага
        self.preflight(parsed)?;

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
        let mut had_failures = false;

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
                return Err(self.abort_cancelled(&executed_modules, None));
            }

            let mod_name = self.registry.canonical_name(&steps[step_idx].module);

            let (effective_step, next_step_idx) =
                match self.plan_step(steps, step_idx, &mod_name, &current_target_dir, parsed.force) {
                    Ok(StepPlan::Skip) => {
                        step_idx += 1;
                        continue;
                    }
                    Ok(StepPlan::Run { step, next_idx }) => (step, next_idx),
                    Err(err) => return Err(self.abort_error(&executed_modules, &mod_name, &err, err.clone())),
                };

            let effective_total_steps = if next_step_idx >= total_steps {
                step_idx + 1
            } else {
                total_steps
            };

            // Установка контекста шага с передачей PipelinePayload (Zero-Copy bytes::Bytes) и флага force
            if let Err(e) = self.engine.set_step_context(
                &effective_step,
                step_idx,
                effective_total_steps,
                &current_target_dir,
                pipeline_data.as_deref(),
                pipeline_payload.as_ref(),
                parsed.force,
            ) {
                let err_msg = format!("Ошибка установки контекста для '{}': {}", mod_name, e);
                return Err(self.abort_error(&executed_modules, &mod_name, &err_msg, err_msg.clone()));
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
                    let err_str = e.to_string();
                    if self.canceller.is_cancelled() || err_str.contains("[CANCELLATION]") {
                        return Err(self.abort_cancelled(&executed_modules, Some(&mod_name)));
                    }
                    let full_err = format!("Ошибка выполнения модуля '{}': {}", mod_name, err_str);
                    return Err(self.abort_error(&executed_modules, &mod_name, &err_str, full_err));
                }
            };

            if !result.success {
                let err_msg = result
                    .error_message
                    .clone()
                    .unwrap_or_else(|| format!("Модуль '{}' завершился со статусом ошибки", mod_name));
                let clean_display = err_msg
                    .trim_start_matches("[Grime Error] ")
                    .trim_start_matches("[Grime] ")
                    .trim_start_matches("[ERROR] ");
                if parsed.force {
                    eprintln!("{} {}", "[Grime Ignored Error]".yellow().bold(), clean_display);
                } else {
                    eprintln!("{} {}", "[Grime Error]".red().bold(), clean_display);
                }
                had_failures = true;

                // Вызов cleanup() у задействованных модулей в порядке LIFO
                let event = serde_json::json!({ "module": mod_name, "error": err_msg });
                self.abort(&executed_modules, event, String::new());
                if !parsed.force {
                    return Err(err_msg);
                }
                // С --force конвейер продолжается: cleanup уже выполнен, список очищаем
                executed_modules.clear();
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

            // Событие завершения шага
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

        // Штатное завершение: cleanup() задействованных модулей в порядке LIFO
        self.run_cleanup(&executed_modules, false);

        // Публикация события завершения всего конвейера (при -f с ошибками шагов success = false)
        self.engine.emit_event(
            "pipeline.finish",
            serde_json::json!({
                "success": !had_failures,
                "result": pipeline_data
            }),
        );

        Ok(pipeline_data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_rest_argv_layout() {
        let steps = vec![
            PipelineStep { module: "pkg".into(), args: vec!["install".into(), "fzf".into()] },
            PipelineStep { module: "cmd".into(), args: vec!["echo".into(), "hello world".into()] },
        ];
        assert_eq!(
            build_rest_argv(Path::new("/w"), true, &steps),
            vec!["grime", "-p", "/w", "-f", "pkg", "install", "fzf", ":", "cmd", "echo", "hello world"]
        );
        assert_eq!(
            build_rest_argv(Path::new("/w"), false, &steps[..1]),
            vec!["grime", "-p", "/w", "pkg", "install", "fzf"]
        );
    }

    #[test]
    fn test_session_ids_unique() {
        assert_ne!(next_session_id(), next_session_id());
    }
}
