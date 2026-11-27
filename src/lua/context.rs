//! Модуль управления контекстом исполнения конвейера (grime.ctx и глобальный ctx).
//!
//! Обеспечивает сквозную передачу данных между шагами конвейера (ctx.input, ctx.payload),
//! доступ к аргументам, путям и файловым/процессным операциям.

use colored::Colorize;
use mlua::{Lua, Table, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::cancellation::PipelineCanceller;
use crate::config::GrimeConfig;
use crate::modules::PathResolver;
use crate::payload::{extract_payload, PipelinePayload};
use crate::pipeline::PipelineStep;

use super::api_fs::install_fs_ops;
use super::api_process::{capture_value, run_value, RunMode};

/// Таблица `grime.ctx` текущей Lua VM.
fn ctx_table(lua: &Lua) -> mlua::Result<Table> {
    lua.globals().get::<Table>("grime")?.get::<Table>("ctx")
}

/// Разрешает относительный путь от `ctx.target_dir` (абсолютные и `~` остаются как есть).
fn resolve_against_target(lua: &Lua, raw: &str) -> String {
    let p = Path::new(raw);
    if p.is_absolute() || raw.starts_with('~') {
        return raw.to_string();
    }
    match ctx_table(lua).and_then(|c| c.get::<String>("target_dir")) {
        Ok(target_dir) if !target_dir.is_empty() && target_dir != "." => {
            crate::fs_ops::expand_tilde(&target_dir)
                .as_ref()
                .join(p)
                .to_string_lossy()
                .to_string()
        }
        _ => raw.to_string(),
    }
}

/// Резолвер путей `ctx.*`: относительно `target_dir`; пустой путь отклоняется с ошибкой.
fn resolve_ctx_path(lua: &Lua, raw: &str) -> mlua::Result<PathBuf> {
    if raw.trim().is_empty() {
        return Err(mlua::Error::runtime("Пустой путь недопустим"));
    }
    Ok(crate::fs_ops::expand_tilde(&resolve_against_target(lua, raw)).into_owned())
}

/// Эффективное окружение: явное, иначе непустое `ctx.env`.
fn effective_env(lua: &Lua, explicit: Option<HashMap<String, String>>) -> Option<HashMap<String, String>> {
    if explicit.is_some() {
        return explicit;
    }
    let env_tbl: Table = ctx_table(lua).ok()?.get("env").ok()?;
    let map: HashMap<String, String> = env_tbl.pairs::<String, String>().flatten().collect();
    (!map.is_empty()).then_some(map)
}

/// Эффективный рабочий каталог: явный (относительно `target_dir`) или сам `target_dir`.
fn effective_cwd(lua: &Lua, cwd: Option<String>) -> Option<String> {
    match cwd {
        Some(c) => Some(resolve_against_target(lua, &c)),
        None => ctx_table(lua).ok()?.get::<Option<String>>("target_dir").ok().flatten(),
    }
}

/// Инициализирует начальную таблицу контекста `grime.ctx` и глобальную `_G.ctx`.
pub fn init_context_table(
    lua: &Lua,
    grime_tbl: &Table,
    config: Arc<GrimeConfig>,
    resolver: PathResolver,
    canceller: PipelineCanceller,
) -> Result<Table, mlua::Error> {
    let ctx_tbl = lua.create_table()?;

    let paths_tbl = lua.create_table()?;
    for (k, v) in resolver.all() {
        paths_tbl.set(k, v)?;
    }

    ctx_tbl.set("args", lua.create_table()?)?;
    ctx_tbl.set("paths", paths_tbl)?;
    ctx_tbl.set("target_dir", ".")?;
    ctx_tbl.set("input", Value::Nil)?;
    ctx_tbl.set("pipeline_input", Value::Nil)?;
    ctx_tbl.set("payload", Value::Nil)?;
    ctx_tbl.set("step_index", 0)?;
    ctx_tbl.set("total_steps", 1)?;
    ctx_tbl.set("has_next_step", false)?;
    ctx_tbl.set("is_last_step", true)?;
    ctx_tbl.set("force", false)?;
    let flags_init = lua.create_table()?;
    flags_init.set("force", false)?;
    ctx_tbl.set("flags", flags_init)?;
    ctx_tbl.set("env", lua.create_table()?)?;
    ctx_tbl.set("_status", true)?;
    ctx_tbl.set("_exit_code", 0)?;
    ctx_tbl.set("_error_message", Value::Nil)?;
    ctx_tbl.set("_return_value", Value::Nil)?;
    ctx_tbl.set("_return_payload", Value::Nil)?;
    ctx_tbl.set("_target_dir_changed", false)?;
    ctx_tbl.set("_requested_target_dir", Value::Nil)?;

    // Явная установка рабочей директории модуля (ctx.set_target_dir)
    ctx_tbl.set(
        "set_target_dir",
        lua.create_function(|lua_ctx, path: String| {
            let c = ctx_table(lua_ctx)?;
            let normalized = crate::fs_ops::expand_and_normalize(&path).to_string_lossy().to_string();
            c.set("target_dir", normalized.clone())?;
            c.set("_target_dir_changed", true)?;
            c.set("_requested_target_dir", normalized)?;
            Ok(())
        })?,
    )?;

    // Получение payload в виде UserData
    ctx_tbl.set(
        "get_payload",
        lua.create_function(|lua_ctx, ()| {
            let c = ctx_table(lua_ctx)?;
            c.get::<Value>("payload")
        })?,
    )?;

    // Установка payload в виде UserData / String
    ctx_tbl.set(
        "set_payload",
        lua.create_function(|lua_ctx, val: Value| {
            let c = ctx_table(lua_ctx)?;
            if let Some(p) = extract_payload(val) {
                c.set("payload", p.clone())?;
                c.set("_return_payload", p)?;
            }
            Ok(())
        })?,
    )?;

    // ctx.success(val)
    ctx_tbl.set(
        "success",
        lua.create_function(|lua_ctx, val: Option<Value>| {
            let c = ctx_table(lua_ctx)?;
            c.set("_status", true)?;
            c.set("_error_message", Value::Nil)?;
            c.set("_ui_error_msg", Value::Nil)?;

            if let Some(v) = val {
                if let Some(payload) = extract_payload(v.clone()) {
                    let text = payload.to_string_lossy();
                    c.set("_return_value", text)?;
                    c.set("_return_payload", payload)?;
                } else {
                    let s = match v {
                        Value::String(st) => st.to_string_lossy().to_string(),
                        Value::Integer(i) => i.to_string(),
                        Value::Number(n) => n.to_string(),
                        Value::Boolean(b) => b.to_string(),
                        Value::Table(_) => {
                            if let Ok(json_val) = crate::state_bus::lua_to_json(v.clone()) {
                                serde_json::to_string(&json_val).unwrap_or_else(|_| format!("{:?}", v))
                            } else {
                                format!("{:?}", v)
                            }
                        }
                        _ => format!("{:?}", v),
                    };
                    c.set("_return_value", s.clone())?;
                    c.set("_return_payload", PipelinePayload::from_string(s))?;
                }
            } else {
                c.set("_return_value", Value::Nil)?;
                c.set("_return_payload", Value::Nil)?;
            }
            Ok(())
        })?,
    )?;

    // ctx.fail(msg) — сохраняет первопричину ошибки при каскадных вызовах
    ctx_tbl.set(
        "fail",
        lua.create_function(|lua_ctx, msg: Option<String>| {
            let c = ctx_table(lua_ctx)?;
            c.set("_status", false)?;
            let new_msg = msg.unwrap_or_else(|| "Шаг конвейера завершился ошибкой".to_string());
            if let Ok(Value::String(existing)) = c.get::<Value>("_error_message") {
                let existing_str = existing.to_str()?.to_string();
                if !existing_str.is_empty() && existing_str != "Шаг конвейера завершился ошибкой" {
                    c.set("_return_value", Value::Nil)?;
                    c.set("_return_payload", Value::Nil)?;
                    return Ok(());
                }
            }
            c.set("_error_message", new_msg)?;
            c.set("_return_value", Value::Nil)?;
            c.set("_return_payload", Value::Nil)?;
            Ok(())
        })?,
    )?;

    // ctx.module_return(val)
    ctx_tbl.set(
        "module_return",
        lua.create_function(|lua_ctx, val: Option<Value>| {
            let c = ctx_table(lua_ctx)?;
            let succ_fn: mlua::Function = c.get("success")?;
            succ_fn.call::<()>(val)?;
            Ok(())
        })?,
    )?;

    // ctx.done(ok, val_or_err) — единый компактный шаблон завершения шага
    ctx_tbl.set(
        "done",
        lua.create_function(|lua_ctx, (ok, val_or_err): (bool, Option<Value>)| {
            let c = ctx_table(lua_ctx)?;
            if ok {
                let succ_fn: mlua::Function = c.get("success")?;
                succ_fn.call::<()>(val_or_err)?;
            } else {
                let fail_fn: mlua::Function = c.get("fail")?;
                let err_str = match val_or_err {
                    Some(Value::String(s)) => s.to_str()?.to_string(),
                    Some(other) => format!("{:?}", other),
                    None => "Шаг конвейера завершился ошибкой".to_string(),
                };
                fail_fn.call::<()>(Some(err_str))?;
            }
            Ok(())
        })?,
    )?;

    // Логирование и вывод через ctx
    ctx_tbl.set(
        "log",
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime]".cyan().bold(), msg);
            Ok(())
        })?,
    )?;
    ctx_tbl.set(
        "warn",
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime Warning]".yellow().bold(), msg);
            Ok(())
        })?,
    )?;
    ctx_tbl.set(
        "error",
        lua.create_function(|lua_ctx, msg: String| {
            super::api_ui::print_formatted_error(lua_ctx, &msg);
            Ok(())
        })?,
    )?;

    // Запуск процессов через ctx: (имя в ctx, режим). `run_process` исторически интерактивный.
    for (name, mode) in [("run_process", RunMode::Interactive), ("run_shell", RunMode::Shell)] {
        let c = canceller.clone();
        ctx_tbl.set(
            name,
            lua.create_function(
                move |lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                    run_value(mode, &cmd, effective_cwd(lua_ctx, cwd), effective_env(lua_ctx, env), &c)
                },
            )?,
        )?;
    }
    ctx_tbl.set("run_interactive", ctx_tbl.get::<Value>("run_process")?)?;

    type CaptureArgs = (Value, Option<String>, Option<HashMap<String, String>>, Option<String>);
    let c_cap = canceller;
    ctx_tbl.set(
        "capture",
        lua.create_function(move |lua_ctx, (cmd, cwd, env, stdin_input): CaptureArgs| {
            capture_value(
                lua_ctx,
                &cmd,
                effective_cwd(lua_ctx, cwd),
                effective_env(lua_ctx, env),
                stdin_input,
                &c_cap,
            )
        })?,
    )?;

    // Файловые операции через ctx (с прозрачным разрешением относительно target_dir)
    // генерируются из той же таблицы FS_OPS, что и grime.fs.*
    install_fs_ops(lua, &ctx_tbl, resolve_ctx_path)?;

    // Нормализация и склейка путей не зависят от target_dir: переиспользуем grime.fs
    let fs_tbl: Table = grime_tbl.get("fs")?;
    for (ctx_name, fs_name) in [
        ("normalize_path", "normalize"),
        ("normalize", "normalize"),
        ("join", "join"),
        ("path_join", "join"),
    ] {
        ctx_tbl.set(ctx_name, fs_tbl.get::<Value>(fs_name)?)?;
    }

    // Именованные пути: конфиг → аннотации path.* модулей → fallback
    let get_path_resolver = resolver.clone();
    ctx_tbl.set(
        "get_path",
        lua.create_function(move |_, (name, fallback): (Option<String>, Option<String>)| {
            Ok(name.and_then(|n| get_path_resolver.get(&n)).or(fallback))
        })?,
    )?;

    let cfg_dir = config.clone();
    ctx_tbl.set(
        "config_dir",
        lua.create_function(move |_, ()| {
            Ok(crate::fs_ops::normalize_path(&cfg_dir.config_dir())
                .to_string_lossy()
                .to_string())
        })?,
    )?;

    let cfg_get = config;
    ctx_tbl.set(
        "get_config",
        lua.create_function(move |_, (key, default): (String, Option<String>)| {
            Ok(cfg_get.get_opt(&key, default.as_deref()))
        })?,
    )?;

    if let Ok(json_tbl) = grime_tbl.get::<Table>("json") {
        ctx_tbl.set("json", json_tbl)?;
    }
    if let Ok(str_tbl) = grime_tbl.get::<Table>("str") {
        if let Ok(to_snake) = str_tbl.get::<Value>("to_snake_case") {
            ctx_tbl.set("to_snake_case", to_snake)?;
        }
    }

    // Парсинг аргументов через нативный движок ядра (ctx.parse_args)
    ctx_tbl.set(
        "parse_args",
        lua.create_function(|lua_ctx, (spec_tbl, raw_args): (Table, Option<Value>)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let a: Table = g.get("args")?;
            let parse_fn: mlua::Function = a.get("parse")?;
            parse_fn.call::<Table>((spec_tbl, raw_args, Value::Nil))
        })?,
    )?;

    grime_tbl.set("ctx", ctx_tbl.clone())?;
    lua.globals().set("ctx", ctx_tbl.clone())?;

    Ok(ctx_tbl)
}

/// Обновляет параметры контекста перед запуском очередного шага конвейера.
#[allow(clippy::too_many_arguments)]
pub fn update_step_context(
    lua: &Lua,
    step: &PipelineStep,
    step_index: usize,
    total_steps: usize,
    target_dir: &Path,
    pipeline_input: Option<&str>,
    payload: Option<&PipelinePayload>,
    force: bool,
) -> Result<(), mlua::Error> {
    let globals = lua.globals();
    let grime: Table = globals.get("grime")?;
    let ctx: Table = grime.get("ctx")?;

    let args_tbl = lua.create_table_with_capacity(step.args.len(), 0)?;
    for (i, arg) in step.args.iter().enumerate() {
        args_tbl.set(i + 1, arg.as_str())?;
    }

    let has_next = step_index < total_steps.saturating_sub(1);
    let is_last = !has_next;

    ctx.set("args", args_tbl)?;
    ctx.set("target_dir", target_dir.to_string_lossy().to_string())?;
    ctx.set("step_index", step_index as i64)?;
    ctx.set("total_steps", total_steps as i64)?;
    ctx.set("has_next_step", has_next)?;
    ctx.set("is_last_step", is_last)?;
    ctx.set("force", force)?;
    let flags_tbl = lua.create_table()?;
    flags_tbl.set("force", force)?;
    ctx.set("flags", flags_tbl)?;
    ctx.set("_status", true)?;
    ctx.set("_exit_code", 0)?;
    ctx.set("_error_message", Value::Nil)?;
    ctx.set("_ui_error_msg", Value::Nil)?;
    ctx.set("_return_value", Value::Nil)?;
    ctx.set("_return_payload", Value::Nil)?;
    ctx.set("_target_dir_changed", false)?;
    ctx.set("_requested_target_dir", Value::Nil)?;

    // Устанавливаем и input, и pipeline_input для сквозной передачи данных
    if let Some(pipe_in) = pipeline_input {
        ctx.set("input", pipe_in)?;
        ctx.set("pipeline_input", pipe_in)?;
    } else {
        ctx.set("input", Value::Nil)?;
        ctx.set("pipeline_input", Value::Nil)?;
    }

    if let Some(p) = payload {
        ctx.set("payload", p.clone())?;
    } else {
        ctx.set("payload", Value::Nil)?;
    }

    globals.set("ctx", ctx)?;
    Ok(())
}

/// Устанавливает переданные переменные окружения в контексте Lua (`ctx.env`).
pub fn set_environment(lua: &Lua, env: &HashMap<String, String>) -> Result<(), mlua::Error> {
    let globals = lua.globals();
    let grime: Table = globals.get("grime")?;
    let ctx: Table = grime.get("ctx")?;
    let env_tbl = lua.create_table_with_capacity(0, env.len())?;
    for (k, v) in env {
        env_tbl.set(k.as_str(), v.as_str())?;
    }
    ctx.set("env", env_tbl)?;
    globals.set("ctx", ctx)?;
    Ok(())
}
