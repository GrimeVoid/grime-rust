//! Модуль управления контекстом исполнения конвейера (grime.ctx и глобальный ctx).
//!
//! Обеспечивает сквозную передачу данных между шагами конвейера (ctx.input, ctx.payload),
//! доступ к аргументам, путям и файловым/процессным операциям.

use colored::Colorize;
use mlua::{Lua, MultiValue, Table, Value};
use std::collections::HashMap;
use std::path::Path;

use crate::config::GrimeConfig;
use crate::payload::{extract_payload, PipelinePayload};
use crate::pipeline::PipelineStep;

/// Инициализирует начальную таблицу контекста `grime.ctx` и глобальную `_G.ctx`.
pub fn init_context_table(
    lua: &Lua,
    grime_tbl: &Table,
    config: &GrimeConfig,
) -> Result<Table, mlua::Error> {
    let ctx_tbl = lua.create_table()?;

    let paths_tbl = lua.create_table()?;
    for (k, v) in &config.paths {
        paths_tbl.set(k.as_str(), v.as_str())?;
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
    ctx_tbl.set("_status", true)?;
    ctx_tbl.set("_error_message", Value::Nil)?;
    ctx_tbl.set("_return_value", Value::Nil)?;
    ctx_tbl.set("_return_payload", Value::Nil)?;

    // Получение payload в виде UserData
    ctx_tbl.set(
        "get_payload",
        lua.create_function(|lua_ctx, ()| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            c.get::<Value>("payload")
        })?,
    )?;

    // Установка payload в виде UserData / String
    ctx_tbl.set(
        "set_payload",
        lua.create_function(|lua_ctx, val: Value| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
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
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            c.set("_status", true)?;
            c.set("_error_message", Value::Nil)?;

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

    // ctx.fail(msg)
    ctx_tbl.set(
        "fail",
        lua.create_function(|lua_ctx, msg: Option<String>| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            c.set("_status", false)?;
            c.set(
                "_error_message",
                msg.unwrap_or_else(|| "Шаг конвейера завершился ошибкой".to_string()),
            )?;
            c.set("_return_value", Value::Nil)?;
            c.set("_return_payload", Value::Nil)?;
            Ok(())
        })?,
    )?;

    // ctx.module_return(val)
    ctx_tbl.set(
        "module_return",
        lua.create_function(|lua_ctx, val: Option<Value>| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            let succ_fn: mlua::Function = c.get("success")?;
            succ_fn.call::<()>(val)?;
            Ok(())
        })?,
    )?;

    // ctx.done(ok, val_or_err) — единый компактный шаблон завершения шага
    ctx_tbl.set(
        "done",
        lua.create_function(|lua_ctx, (ok, val_or_err): (bool, Option<Value>)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
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
        lua.create_function(|_, msg: String| {
            eprintln!("{} {}", "[Grime Error]".red().bold(), msg);
            Ok(())
        })?,
    )?;

    // Запуск процессов через ctx
    ctx_tbl.set(
        "run_process",
        lua.create_function(
            |lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let globals = lua_ctx.globals();
                let g: Table = globals.get("grime")?;
                let c: Table = g.get("ctx")?;
                let proc_tbl: Table = g.get("process")?;
                let effective_cwd = cwd.or_else(|| c.get::<Option<String>>("target_dir").ok().flatten());
                let run_fn: mlua::Function = proc_tbl.get("run_interactive")?;
                run_fn.call::<i32>((cmd, effective_cwd, env))
            },
        )?,
    )?;
    ctx_tbl.set("run_interactive", ctx_tbl.get::<Value>("run_process")?)?;

    ctx_tbl.set(
        "run_shell",
        lua.create_function(
            |lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let globals = lua_ctx.globals();
                let g: Table = globals.get("grime")?;
                let c: Table = g.get("ctx")?;
                let proc_tbl: Table = g.get("process")?;
                let effective_cwd = cwd.or_else(|| c.get::<Option<String>>("target_dir").ok().flatten());
                let run_fn: mlua::Function = proc_tbl.get("run")?;
                run_fn.call::<i32>((cmd, effective_cwd, env))
            },
        )?,
    )?;

    ctx_tbl.set(
        "capture",
        lua.create_function(
            |lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let globals = lua_ctx.globals();
                let g: Table = globals.get("grime")?;
                let c: Table = g.get("ctx")?;
                let proc_tbl: Table = g.get("process")?;
                let effective_cwd = cwd.or_else(|| c.get::<Option<String>>("target_dir").ok().flatten());
                let cap_fn: mlua::Function = proc_tbl.get("capture")?;
                cap_fn.call::<Value>((cmd, effective_cwd, env))
            },
        )?,
    )?;

    // Файловые операции через ctx
    ctx_tbl.set(
        "exists",
        lua.create_function(|lua_ctx, path: String| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("exists")?;
            f.call::<bool>(path)
        })?,
    )?;
    ctx_tbl.set(
        "is_dir",
        lua.create_function(|lua_ctx, path: String| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("is_dir")?;
            f.call::<bool>(path)
        })?,
    )?;
    ctx_tbl.set(
        "is_file",
        lua.create_function(|lua_ctx, path: String| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("is_file")?;
            f.call::<bool>(path)
        })?,
    )?;
    ctx_tbl.set(
        "mkdir_p",
        lua.create_function(|lua_ctx, path: String| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("mkdir_p")?;
            f.call::<bool>(path)
        })?,
    )?;
    ctx_tbl.set(
        "delete",
        lua.create_function(|lua_ctx, (path, missing_ok): (String, Option<bool>)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("delete")?;
            f.call::<bool>((path, missing_ok))
        })?,
    )?;
    ctx_tbl.set("remove", ctx_tbl.get::<Value>("delete")?)?;

    ctx_tbl.set(
        "copy",
        lua.create_function(|lua_ctx, (src, dst): (String, String)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("copy")?;
            f.call::<String>((src, dst))
        })?,
    )?;
    ctx_tbl.set(
        "move",
        lua.create_function(|lua_ctx, (src, dst): (String, String)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("move")?;
            f.call::<String>((src, dst))
        })?,
    )?;
    ctx_tbl.set("rename", ctx_tbl.get::<Value>("move")?)?;

    ctx_tbl.set(
        "mtime",
        lua.create_function(|lua_ctx, path: String| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("mtime")?;
            f.call::<f64>(path)
        })?,
    )?;
    ctx_tbl.set(
        "is_newer",
        lua.create_function(|lua_ctx, (src, target): (String, String)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("is_newer")?;
            f.call::<bool>((src, target))
        })?,
    )?;
    ctx_tbl.set("needs_rebuild", ctx_tbl.get::<Value>("is_newer")?)?;

    ctx_tbl.set(
        "normalize_path",
        lua.create_function(|lua_ctx, path: String| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("normalize")?;
            f.call::<String>(path)
        })?,
    )?;
    ctx_tbl.set("normalize", ctx_tbl.get::<Value>("normalize_path")?)?;

    ctx_tbl.set(
        "join",
        lua.create_function(|lua_ctx, parts: MultiValue| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let fs_tbl: Table = g.get("fs")?;
            let f: mlua::Function = fs_tbl.get("join")?;
            f.call::<String>(parts)
        })?,
    )?;
    ctx_tbl.set("path_join", ctx_tbl.get::<Value>("join")?)?;

    // Получение путей и конфигураций через ctx
    ctx_tbl.set(
        "get_path",
        lua.create_function(|lua_ctx, (name, fallback): (Option<String>, Option<String>)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            if let Some(n) = name {
                if let Ok(paths) = c.get::<Table>("paths") {
                    if let Ok(val) = paths.get::<String>(n.as_str()) {
                        if !val.is_empty() && val != "auto" {
                            return Ok(Some(val));
                        }
                    }
                }
                if let Ok(paths) = g.get::<Table>("paths") {
                    if let Ok(val) = paths.get::<String>(n.as_str()) {
                        if !val.is_empty() && val != "auto" {
                            return Ok(Some(val));
                        }
                    }
                }
                if let Ok(cfg) = g.get::<Table>("config") {
                    if let Ok(get_fn) = cfg.get::<mlua::Function>("get") {
                        if let Ok(val) = get_fn.call::<Option<String>>(n.as_str()) {
                            if let Some(v) = val {
                                if !v.is_empty() && v != "auto" {
                                    return Ok(Some(v));
                                }
                            }
                        }
                    }
                }
            }
            Ok(fallback)
        })?,
    )?;

    ctx_tbl.set(
        "projects_root",
        lua.create_function(|lua_ctx, ()| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            let get_path_fn: mlua::Function = c.get("get_path")?;
            let default_p = dirs::home_dir()
                .map(|h| h.join("Projects").to_string_lossy().to_string())
                .unwrap_or_else(|| "./projects".to_string());
            let p: String = get_path_fn.call(("projects", Some(default_p)))?;
            let fs_tbl: Table = g.get("fs")?;
            let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
            norm_fn.call::<String>(p)
        })?,
    )?;

    ctx_tbl.set(
        "templates_root",
        lua.create_function(|lua_ctx, ()| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            let get_path_fn: mlua::Function = c.get("get_path")?;
            let default_p = dirs::home_dir()
                .map(|h| {
                    h.join(".config")
                        .join("grime")
                        .join("templates")
                        .to_string_lossy()
                        .to_string()
                })
                .unwrap_or_else(|| "./templates".to_string());
            let p: String = get_path_fn.call(("templates", Some(default_p)))?;
            let fs_tbl: Table = g.get("fs")?;
            let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
            norm_fn.call::<String>(p)
        })?,
    )?;

    ctx_tbl.set(
        "apps_root",
        lua.create_function(|lua_ctx, ()| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            let get_path_fn: mlua::Function = c.get("get_path")?;
            let default_p = dirs::home_dir()
                .map(|h| {
                    h.join(".config")
                        .join("grime")
                        .join("apps")
                        .to_string_lossy()
                        .to_string()
                })
                .unwrap_or_else(|| "./apps".to_string());
            let p: String = get_path_fn.call(("apps", Some(default_p)))?;
            let fs_tbl: Table = g.get("fs")?;
            let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
            norm_fn.call::<String>(p)
        })?,
    )?;

    ctx_tbl.set(
        "config_dir",
        lua.create_function(|lua_ctx, ()| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let c: Table = g.get("ctx")?;
            let get_path_fn: mlua::Function = c.get("get_path")?;
            let default_p = dirs::home_dir()
                .map(|h| {
                    h.join(".config")
                        .join("grime")
                        .to_string_lossy()
                        .to_string()
                })
                .unwrap_or_else(|| ".".to_string());
            let p: String = get_path_fn.call(("config", Some(default_p)))?;
            let fs_tbl: Table = g.get("fs")?;
            let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
            norm_fn.call::<String>(p)
        })?,
    )?;

    ctx_tbl.set(
        "get_config",
        lua.create_function(|lua_ctx, (key, default): (String, Option<String>)| {
            let globals = lua_ctx.globals();
            let g: Table = globals.get("grime")?;
            let cfg: Table = g.get("config")?;
            let get_fn: mlua::Function = cfg.get("get")?;
            get_fn.call::<Option<String>>((key, default))
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

    grime_tbl.set("ctx", ctx_tbl.clone())?;
    lua.globals().set("ctx", ctx_tbl.clone())?;

    Ok(ctx_tbl)
}

/// Обновляет параметры контекста перед запуском очередного шага конвейера.
pub fn update_step_context(
    lua: &Lua,
    _config: &GrimeConfig,
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
    ctx.set("_error_message", Value::Nil)?;
    ctx.set("_return_value", Value::Nil)?;
    ctx.set("_return_payload", Value::Nil)?;

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
