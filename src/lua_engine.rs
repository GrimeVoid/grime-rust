use colored::Colorize;
use fuzzy_matcher::skim::SkimMatcherV2;
use fuzzy_matcher::FuzzyMatcher;
use mlua::{Lua, MultiValue, Value};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::cancellation::{attach_lua_cancellation_hook, PipelineCanceller};
use crate::config::GrimeConfig;
use crate::event_bus::{dispatch_event_to_lua, register_event_bus_api, EventBus};
use crate::fs_ops::{copy_recursive, delete_safe, get_latest_mtime, is_newer, move_safe};
use crate::payload::{extract_payload, PipelinePayload};
use crate::pipeline::PipelineStep;

use crate::process::{capture_command, run_command, run_interactive, run_shell};
use crate::state_bus::{register_state_bus_api, StateBus};

#[derive(Debug, Clone)]
pub struct StepExecutionResult {
    pub success: bool,
    pub return_value: Option<String>,
    pub payload: Option<PipelinePayload>,
    pub error_message: Option<String>,
}

pub struct GrimeLuaEngine {
    lua: Lua,
    modules_dir: PathBuf,
    config: GrimeConfig,
    state_bus: Arc<StateBus>,
    event_bus: Arc<EventBus>,
    canceller: PipelineCanceller,
}

pub fn lua_value_to_rmpv(val: &mlua::Value) -> Result<rmpv::Value, mlua::Error> {
    match val {
        mlua::Value::Nil => Ok(rmpv::Value::Nil),
        mlua::Value::Boolean(b) => Ok(rmpv::Value::Boolean(*b)),
        mlua::Value::Integer(i) => Ok(rmpv::Value::Integer((*i).into())),
        mlua::Value::Number(n) => Ok(rmpv::Value::F64(*n)),
        mlua::Value::String(s) => {
            if let Ok(utf8) = s.to_str() {
                Ok(rmpv::Value::String(rmpv::Utf8String::from(utf8.as_ref())))
            } else {
                Ok(rmpv::Value::Binary(s.as_bytes().to_vec()))
            }
        }
        mlua::Value::Table(tbl) => {
            let len = tbl.raw_len();
            let mut is_array = len > 0;
            if is_array {
                for i in 1..=len {
                    if tbl.get::<mlua::Value>(i).is_err() {
                        is_array = false;
                        break;
                    }
                }
            }
            if is_array {
                let mut arr = Vec::with_capacity(len);
                for i in 1..=len {
                    let item: mlua::Value = tbl.get(i)?;
                    arr.push(lua_value_to_rmpv(&item)?);
                }
                Ok(rmpv::Value::Array(arr))
            } else {
                let mut map = Vec::new();
                for pair in tbl.pairs::<mlua::Value, mlua::Value>() {
                    let (k, v) = pair?;
                    map.push((lua_value_to_rmpv(&k)?, lua_value_to_rmpv(&v)?));
                }
                Ok(rmpv::Value::Map(map))
            }
        }
        mlua::Value::UserData(ud) => {
            if let Ok(p) = ud.borrow::<PipelinePayload>() {
                Ok(rmpv::Value::Binary(p.as_slice().to_vec()))
            } else {
                Ok(rmpv::Value::Nil)
            }
        }
        _ => Ok(rmpv::Value::Nil),
    }
}

pub fn rmpv_to_lua_value(lua: &mlua::Lua, val: rmpv::Value) -> Result<mlua::Value, mlua::Error> {
    match val {
        rmpv::Value::Nil => Ok(mlua::Value::Nil),
        rmpv::Value::Boolean(b) => Ok(mlua::Value::Boolean(b)),
        rmpv::Value::Integer(i) => {
            if let Some(n) = i.as_i64() {
                Ok(mlua::Value::Integer(n))
            } else if let Some(u) = i.as_u64() {
                Ok(mlua::Value::Integer(u as i64))
            } else {
                Ok(mlua::Value::Integer(0))
            }
        }
        rmpv::Value::F32(f) => Ok(mlua::Value::Number(f as f64)),
        rmpv::Value::F64(f) => Ok(mlua::Value::Number(f)),
        rmpv::Value::String(s) => {
            if let Some(utf8) = s.as_str() {
                Ok(mlua::Value::String(lua.create_string(utf8)?))
            } else {
                Ok(mlua::Value::String(lua.create_string(s.into_bytes())?))
            }
        }
        rmpv::Value::Binary(bytes) => Ok(mlua::Value::String(lua.create_string(&bytes)?)),
        rmpv::Value::Array(arr) => {
            let tbl = lua.create_table()?;
            for (idx, item) in arr.into_iter().enumerate() {
                tbl.set(idx + 1, rmpv_to_lua_value(lua, item)?)?;
            }
            Ok(mlua::Value::Table(tbl))
        }
        rmpv::Value::Map(map) => {
            let tbl = lua.create_table()?;
            for (k, v) in map {
                let l_k = rmpv_to_lua_value(lua, k)?;
                let l_v = rmpv_to_lua_value(lua, v)?;
                tbl.set(l_k, l_v)?;
            }
            Ok(mlua::Value::Table(tbl))
        }
        rmpv::Value::Ext(_, bytes) => Ok(mlua::Value::String(lua.create_string(&bytes)?)),
    }
}

impl GrimeLuaEngine {
    pub fn new(modules_dir: Option<PathBuf>, custom_config: Option<&Path>) -> Result<Self, mlua::Error> {
        let state_bus = Arc::new(StateBus::new());
        let event_bus = Arc::new(EventBus::default());
        let canceller = PipelineCanceller::new();
        Self::new_with_bus(modules_dir, custom_config, state_bus, event_bus, canceller)
    }

    pub fn new_with_bus(
        modules_dir: Option<PathBuf>,
        custom_config: Option<&Path>,
        state_bus: Arc<StateBus>,
        event_bus: Arc<EventBus>,
        canceller: PipelineCanceller,
    ) -> Result<Self, mlua::Error> {
        let config = GrimeConfig::load_or_default(custom_config);

        let mod_dir = match modules_dir {
            Some(d) => d,
            None => Self::discover_modules_dir(),
        };

        let lua = Lua::new();

        let engine = GrimeLuaEngine {
            lua,
            modules_dir: mod_dir,
            config,
            state_bus,
            event_bus,
            canceller,
        };

        engine.init_runtime()?;
        Ok(engine)
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

    fn discover_modules_dir() -> PathBuf {
        if let Ok(dir) = std::env::var("PROJECT_MODULES_DIR") {
            let p = PathBuf::from(dir);
            if p.exists() {
                return p;
            }
        }

        let local_dir = Path::new("modules");
        if local_dir.exists() {
            return local_dir.to_path_buf();
        }

        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let candidate = parent.join("modules");
                if candidate.exists() {
                    return candidate;
                }
                if let Some(p2) = parent.parent() {
                    let candidate2 = p2.join("modules");
                    if candidate2.exists() {
                        return candidate2;
                    }
                }
            }
        }

        PathBuf::from("modules")
    }

    fn init_runtime(&self) -> Result<(), mlua::Error> {
        let lua = &self.lua;

        // 1. Настройка package.path
        let modules_str = self.modules_dir.to_string_lossy();
        let lua_setup = format!(
            "package.path = '{0}/?.lua;{0}/?/init.lua;{0}/languages/?.lua;' .. package.path",
            modules_str
        );
        lua.load(&lua_setup).exec()?;

        // 2. Создание глобальной таблицы grime
        let grime_tbl = lua.create_table()?;

        // grime.process
        let proc_tbl = lua.create_table()?;
        proc_tbl.set(
            "run",
            lua.create_function(|_, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
                let code = match cmd {
                    Value::String(s) => {
                        let cmd_str = s.to_str()?;
                        run_shell(&cmd_str, &cwd_path, env.as_ref())
                    }
                    Value::Table(tbl) => {
                        let mut args = Vec::new();
                        for item in tbl.sequence_values::<String>() {
                            args.push(item?);
                        }
                        run_command(&args, &cwd_path, env.as_ref())
                    }
                    _ => 1,
                };
                Ok(code)
            })?,
        )?;

        proc_tbl.set(
            "run_interactive",
            lua.create_function(|_, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
                let code = match cmd {
                    Value::String(s) => {
                        let cmd_str = s.to_str()?;
                        let parts = vec!["sh".to_string(), "-c".to_string(), cmd_str.to_string()];
                        run_interactive(&parts, &cwd_path, env.as_ref())
                    }
                    Value::Table(tbl) => {
                        let mut args = Vec::new();
                        for item in tbl.sequence_values::<String>() {
                            args.push(item?);
                        }
                        run_interactive(&args, &cwd_path, env.as_ref())
                    }
                    _ => 1,
                };
                Ok(code)
            })?,
        )?;

        proc_tbl.set(
            "capture",
            lua.create_function(|lua, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let cwd_path = cwd.map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
                let res = match cmd {
                    Value::String(s) => {
                        let cmd_str = s.to_str()?;
                        let parts = vec!["sh".to_string(), "-c".to_string(), cmd_str.to_string()];
                        capture_command(&parts, &cwd_path, env.as_ref())
                    }
                    Value::Table(tbl) => {
                        let mut args = Vec::new();
                        for item in tbl.sequence_values::<String>() {
                            args.push(item?);
                        }
                        capture_command(&args, &cwd_path, env.as_ref())
                    }
                    _ => return Err(mlua::Error::runtime("Ожидалась строка или таблица для команды")),
                };

                let res_tbl = lua.create_table()?;
                res_tbl.set("code", res.exit_code)?;
                res_tbl.set("stdout", res.stdout)?;
                res_tbl.set("stderr", res.stderr)?;
                Ok(res_tbl)
            })?,
        )?;
        grime_tbl.set("process", proc_tbl)?;

        // grime.fs
        let fs_tbl = lua.create_table()?;
        fs_tbl.set(
            "normalize",
            lua.create_function(|_, path: String| {
                let expanded = shellexpand::tilde(&path).to_string();
                let p = PathBuf::from(&expanded);
                let normalized = crate::fs_ops::normalize_path(&p);
                Ok(normalized.to_string_lossy().to_string())
            })?,
        )?;

        fs_tbl.set(
            "exists",
            lua.create_function(|_, path: String| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                Ok(p.exists())
            })?,
        )?;

        fs_tbl.set(
            "is_dir",
            lua.create_function(|_, path: String| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                Ok(p.is_dir())
            })?,
        )?;

        fs_tbl.set(
            "is_file",
            lua.create_function(|_, path: String| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                Ok(p.is_file())
            })?,
        )?;

        fs_tbl.set(
            "mkdir_p",
            lua.create_function(|_, path: String| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                match fs::create_dir_all(&p) {
                    Ok(_) => Ok(true),
                    Err(e) => Err(mlua::Error::runtime(format!("mkdir_p failed: {}", e))),
                }
            })?,
        )?;

        fs_tbl.set(
            "delete",
            lua.create_function(|_, (path, missing_ok): (String, Option<bool>)| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                match delete_safe(&p, missing_ok.unwrap_or(true)) {
                    Ok(val) => Ok(val),
                    Err(e) => Err(mlua::Error::runtime(e)),
                }
            })?,
        )?;

        fs_tbl.set(
            "copy",
            lua.create_function(|_, (src, dst): (String, String)| {
                let s = PathBuf::from(shellexpand::tilde(&src).to_string());
                let d = PathBuf::from(shellexpand::tilde(&dst).to_string());
                match copy_recursive(&s, &d) {
                    Ok(res) => Ok(res.to_string_lossy().to_string()),
                    Err(e) => Err(mlua::Error::runtime(e)),
                }
            })?,
        )?;

        fs_tbl.set(
            "move",
            lua.create_function(|_, (src, dst): (String, String)| {
                let s = PathBuf::from(shellexpand::tilde(&src).to_string());
                let d = PathBuf::from(shellexpand::tilde(&dst).to_string());
                match move_safe(&s, &d) {
                    Ok(res) => Ok(res.to_string_lossy().to_string()),
                    Err(e) => Err(mlua::Error::runtime(e)),
                }
            })?,
        )?;

        fs_tbl.set(
            "mtime",
            lua.create_function(|_, path: String| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                Ok(get_latest_mtime(&p))
            })?,
        )?;

        fs_tbl.set(
            "is_newer",
            lua.create_function(|_, (src, target): (String, String)| {
                let s = PathBuf::from(shellexpand::tilde(&src).to_string());
                let t = PathBuf::from(shellexpand::tilde(&target).to_string());
                Ok(is_newer(&s, &t))
            })?,
        )?;
        grime_tbl.set("fs", fs_tbl)?;

        // grime.config
        let cfg = self.config.clone();
        let cfg_tbl = lua.create_table()?;
        let cfg_for_get = cfg.clone();
        cfg_tbl.set(
            "get",
            lua.create_function(move |_, (key, default): (String, Option<String>)| {
                Ok(cfg_for_get.get_opt(&key, default.as_deref()))
            })?,
        )?;

        let cfg_dir = cfg.clone();
        cfg_tbl.set(
            "config_dir",
            lua.create_function(move |_, ()| {
                Ok(cfg_dir.config_dir().to_string_lossy().to_string())
            })?,
        )?;

        let cfg_for_all = cfg.clone();
        cfg_tbl.set(
            "get_all",
            lua.create_function(move |lua, ()| {
                let tbl = lua.create_table()?;
                for (k, v) in &cfg_for_all.paths {
                    tbl.set(k.as_str(), v.as_str())?;
                }
                Ok(tbl)
            })?,
        )?;

        let cfg_proj = cfg.clone();
        cfg_tbl.set(
            "projects_root",
            lua.create_function(move |_, ()| {
                Ok(cfg_proj.projects_root().to_string_lossy().to_string())
            })?,
        )?;

        let cfg_tpl = cfg.clone();
        cfg_tbl.set(
            "templates_root",
            lua.create_function(move |_, ()| {
                Ok(cfg_tpl.templates_root().to_string_lossy().to_string())
            })?,
        )?;

        let cfg_apps = cfg.clone();
        cfg_tbl.set(
            "apps_root",
            lua.create_function(move |_, ()| {
                Ok(cfg_apps.apps_root().to_string_lossy().to_string())
            })?,
        )?;
        grime_tbl.set("config", cfg_tbl)?;

        // grime.paths (единый реестр путей)
        let paths_tbl = lua.create_table()?;
        for (k, v) in &self.config.paths {
            paths_tbl.set(k.as_str(), v.as_str())?;
        }
        grime_tbl.set("paths", paths_tbl.clone())?;

        // grime.msgpack
        let msgpack_tbl = lua.create_table()?;
        msgpack_tbl.set(
            "encode",
            lua.create_function(|_lua, val: Value| {
                let rmpv_val = lua_value_to_rmpv(&val)?;
                let mut buf = Vec::new();
                rmpv::encode::write_value(&mut buf, &rmpv_val)
                    .map_err(|e| mlua::Error::runtime(format!("MsgPack encode error: {}", e)))?;
                Ok(PipelinePayload::from_vec(buf))
            })?,
        )?;

        msgpack_tbl.set(
            "decode",
            lua.create_function(|lua, val: Value| {
                let bytes = match val {
                    Value::String(s) => s.as_bytes().to_vec(),
                    Value::UserData(ud) => {
                        if let Ok(p) = ud.borrow::<PipelinePayload>() {
                            p.as_slice().to_vec()
                        } else {
                            return Err(mlua::Error::runtime("Ожидалась строка или PipelinePayload для декодирования"));
                        }
                    }
                    _ => return Err(mlua::Error::runtime("Ожидалась строка или PipelinePayload для декодирования")),
                };

                let mut cursor = std::io::Cursor::new(bytes);
                let rmpv_val = rmpv::decode::read_value(&mut cursor)
                    .map_err(|e| mlua::Error::runtime(format!("MsgPack decode error: {}", e)))?;
                rmpv_to_lua_value(lua, rmpv_val)
            })?,
        )?;
        grime_tbl.set("msgpack", msgpack_tbl)?;

        // grime.ui
        let ui_tbl = lua.create_table()?;
        ui_tbl.set(
            "log",
            lua.create_function(|_, msg: String| {
                eprintln!("{} {}", "[Grime]".cyan().bold(), msg);
                Ok(())
            })?,
        )?;
        ui_tbl.set(
            "error",
            lua.create_function(|_, msg: String| {
                eprintln!("{} {}", "[Grime Error]".red().bold(), msg);
                Ok(())
            })?,
        )?;
        ui_tbl.set(
            "warn",
            lua.create_function(|_, msg: String| {
                eprintln!("{} {}", "[Grime Warning]".yellow().bold(), msg);
                Ok(())
            })?,
        )?;
        ui_tbl.set(
            "success",
            lua.create_function(|_, msg: String| {
                eprintln!("{} {}", "[Grime Success]".green().bold(), msg);
                Ok(())
            })?,
        )?;
        grime_tbl.set("ui", ui_tbl)?;

        // grime.fuzzy
        let fuzzy_tbl = lua.create_table()?;
        fuzzy_tbl.set(
            "match_best",
            lua.create_function(|_, (query, candidates): (String, Vec<String>)| {
                let matcher = SkimMatcherV2::default();
                let mut best_score = None;
                let mut best_candidate = None;

                for c in &candidates {
                    if let Some(score) = matcher.fuzzy_match(c, &query) {
                        if best_score.is_none() || score > best_score.unwrap() {
                            best_score = Some(score);
                            best_candidate = Some(c.clone());
                        }
                    }
                }
                Ok(best_candidate)
            })?,
        )?;
        grime_tbl.set("fuzzy", fuzzy_tbl)?;

        // grime.ctx (инициализируем пустой контекст)
        let ctx_tbl = lua.create_table()?;
        ctx_tbl.set("args", lua.create_table()?)?;
        ctx_tbl.set("paths", paths_tbl)?;
        ctx_tbl.set("target_dir", ".")?;
        ctx_tbl.set("pipeline_input", Value::Nil)?;
        ctx_tbl.set("payload", Value::Nil)?;
        ctx_tbl.set("step_index", 0)?;
        ctx_tbl.set("total_steps", 1)?;
        ctx_tbl.set("has_next_step", false)?;
        ctx_tbl.set("is_last_step", true)?;
        ctx_tbl.set("_status", true)?;
        ctx_tbl.set("_error_message", Value::Nil)?;
        ctx_tbl.set("_return_value", Value::Nil)?;
        ctx_tbl.set("_return_payload", Value::Nil)?;

        // Получение payload в виде UserData
        ctx_tbl.set(
            "get_payload",
            lua.create_function(|lua_ctx, ()| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                c.get::<Value>("payload")
            })?,
        )?;

        // Установка payload в виде UserData / String
        ctx_tbl.set(
            "set_payload",
            lua.create_function(|lua_ctx, val: Value| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                if let Some(p) = extract_payload(val) {
                    c.set("payload", p.clone())?;
                    c.set("_return_payload", p)?;
                }
                Ok(())
            })?,
        )?;

        ctx_tbl.set(
            "success",
            lua.create_function(|lua_ctx, val: Option<Value>| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
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

        ctx_tbl.set(
            "fail",
            lua.create_function(|lua_ctx, msg: Option<String>| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                c.set("_status", false)?;
                c.set("_error_message", msg.unwrap_or_else(|| "Шаг завершился ошибкой".to_string()))?;
                c.set("_return_value", Value::Nil)?;
                c.set("_return_payload", Value::Nil)?;
                Ok(())
            })?,
        )?;

        ctx_tbl.set(
            "module_return",
            lua.create_function(|lua_ctx, val: Option<Value>| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let succ_fn: mlua::Function = c.get("success")?;
                succ_fn.call::<()>(val)?;
                Ok(())
            })?,
        )?;

        grime_tbl.set("ctx", ctx_tbl)?;

        lua.globals().set("grime", grime_tbl)?;

        // 3. Регистрация API Shared State Bus (`grime.bus.*`)
        register_state_bus_api(lua, self.state_bus.clone())?;

        // 4. Регистрация API Event Bus (`grime.events.*`)
        register_event_bus_api(lua, self.event_bus.clone())?;

        // 5. Установка хука безопасного прерывания (Cancellation Hook)
        attach_lua_cancellation_hook(lua, self.canceller.clone());

        Ok(())
    }

    pub fn set_step_context(
        &self,
        step: &PipelineStep,
        step_index: usize,
        total_steps: usize,
        target_dir: &Path,
        pipeline_input: Option<&str>,
        payload: Option<&PipelinePayload>,
    ) -> Result<(), mlua::Error> {
        let lua = &self.lua;
        let globals = lua.globals();
        let grime: mlua::Table = globals.get("grime")?;
        let ctx: mlua::Table = grime.get("ctx")?;

        let args_tbl = lua.create_table()?;
        for (i, arg) in step.args.iter().enumerate() {
            args_tbl.set(i + 1, arg.as_str())?;
        }

        let has_next = step_index < total_steps.saturating_sub(1);
        let is_last = !has_next;

        let paths_tbl = lua.create_table()?;
        for (k, v) in &self.config.paths {
            paths_tbl.set(k.as_str(), v.as_str())?;
        }
        ctx.set("paths", paths_tbl)?;

        ctx.set("args", args_tbl)?;
        ctx.set("target_dir", target_dir.to_string_lossy().to_string())?;
        ctx.set("step_index", step_index as i64)?;
        ctx.set("total_steps", total_steps as i64)?;
        ctx.set("has_next_step", has_next)?;
        ctx.set("is_last_step", is_last)?;
        ctx.set("_status", true)?;
        ctx.set("_error_message", Value::Nil)?;
        ctx.set("_return_value", Value::Nil)?;
        ctx.set("_return_payload", Value::Nil)?;

        if let Some(pipe_in) = pipeline_input {
            ctx.set("pipeline_input", pipe_in)?;
        } else {
            ctx.set("pipeline_input", Value::Nil)?;
        }

        if let Some(p) = payload {
            ctx.set("payload", p.clone())?;
        } else {
            ctx.set("payload", Value::Nil)?;
        }

        Ok(())
    }

    pub fn execute_module(&self, module_name: &str) -> Result<StepExecutionResult, mlua::Error> {
        // Проверка отмены перед запуском модуля
        if self.canceller.is_cancelled() {
            let reason = self
                .canceller
                .get_reason()
                .unwrap_or_else(|| "Выполнение прервано".to_string());
            return Ok(StepExecutionResult {
                success: false,
                return_value: None,
                payload: None,
                error_message: Some(format!("Конвейер отменен: {}", reason)),
            });
        }

        let lua = &self.lua;

        let mod_file = self.modules_dir.join(format!("{}.lua", module_name));
        if !mod_file.exists() {
            return Ok(StepExecutionResult {
                success: false,
                return_value: None,
                payload: None,
                error_message: Some(format!("Модуль '{}.lua' не найден в {:?}", module_name, self.modules_dir)),
            });
        }

        let content = fs::read_to_string(&mod_file)
            .map_err(|e| mlua::Error::runtime(format!("Ошибка чтения модуля '{}': {}", mod_file.display(), e)))?;

        // Запуск скрипта
        let chunk = lua.load(&content).set_name(format!("@{}", mod_file.display()));
        let chunk_res: Result<Value, mlua::Error> = chunk.call(MultiValue::new());

        if let Err(e) = chunk_res {
            return Ok(StepExecutionResult {
                success: false,
                return_value: None,
                payload: None,
                error_message: Some(format!("Ошибка исполнения модуля '{}': {}", module_name, e)),
            });
        }

        // Если есть функция main, вызываем её
        let globals = lua.globals();
        if let Ok(main_fn) = globals.get::<mlua::Function>("main") {
            let res: Result<(), mlua::Error> = main_fn.call(());
            let _ = globals.set("main", Value::Nil);
            if let Err(e) = res {
                return Ok(StepExecutionResult {
                    success: false,
                    return_value: None,
                    payload: None,
                    error_message: Some(format!("Ошибка в main() модуля '{}': {}", module_name, e)),
                });
            }
        }

        // Читаем результаты из grime.ctx
        let grime: mlua::Table = globals.get("grime")?;
        let ctx: mlua::Table = grime.get("ctx")?;

        let status: bool = ctx.get("_status").unwrap_or(true);
        let error_msg: Option<String> = ctx.get("_error_message").ok();
        let ret_val: Option<String> = ctx.get("_return_value").ok();
        let ret_payload: Option<PipelinePayload> = ctx.get::<Option<PipelinePayload>>("_return_payload").ok().flatten();

        Ok(StepExecutionResult {
            success: status,
            return_value: ret_val,
            payload: ret_payload,
            error_message: error_msg,
        })
    }

    /// Вызов функции cleanup() для указанного модуля при прерывании или ошибке.
    pub fn call_cleanup(&self, module_name: &str) {
        let globals = self.lua.globals();
        if let Ok(cleanup_fn) = globals.get::<mlua::Function>("cleanup") {
            eprintln!(
                "{} Вызов cleanup() для модуля '{}'...",
                "[Grime]".cyan().bold(),
                module_name
            );
            self.canceller.set_cleaning_up(true);
            let _ = cleanup_fn.call::<()>(());
            self.canceller.set_cleaning_up(false);
            let _ = globals.set("cleanup", Value::Nil);
        }
    }

    /// Публикация события в EventBus и отправка в Lua.
    pub fn emit_event(&self, name: &str, payload: serde_json::Value) {
        self.event_bus.emit(name, payload.clone());
        let _ = dispatch_event_to_lua(&self.lua, name, &payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lua_fs_is_dir_and_is_file() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let res: bool = lua
            .load("return grime.fs.is_dir('.')")
            .eval()
            .expect("eval is_dir");
        assert!(res);

        let res_file: bool = lua
            .load("return grime.fs.is_file('Cargo.toml')")
            .eval()
            .expect("eval is_file");
        assert!(res_file);

        let res_file_neg: bool = lua
            .load("return grime.fs.is_file('.')")
            .eval()
            .expect("eval is_file on dir");
        assert!(!res_file_neg);
    }

    #[test]
    fn test_lua_bus_and_events_integration() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        // Тест grime.bus в Lua
        lua.load(
            r#"
            grime.bus.set("pipeline.score", 100)
            grime.bus.set("modules.cmd.flag", "active")
        "#,
        )
        .exec()
        .expect("bus set");

        assert_eq!(
            engine.state_bus().get("pipeline.score").unwrap(),
            serde_json::json!(100)
        );
        assert_eq!(
            engine.state_bus().get("modules.cmd.flag").unwrap(),
            serde_json::json!("active")
        );

        let val_back: i64 = lua
            .load("return grime.bus.get('pipeline.score')")
            .eval()
            .expect("bus get");
        assert_eq!(val_back, 100);

        // Тест grime.events в Lua
        lua.load(
            r#"
            _test_received = nil
            grime.events.on("custom.event", function(payload)
                _test_received = payload.message
            end)
            grime.events.emit("custom.event", { message = "hello event" })
        "#,
        )
        .exec()
        .expect("events emit");

        let received: String = lua.load("return _test_received").eval().expect("received");
        assert_eq!(received, "hello event");
    }

    #[test]
    fn test_lua_msgpack_encode_decode() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            local orig = {
                name = "grime",
                version = 2,
                nested = { active = true, tags = { "fast", "reliable" } }
            }
            local encoded = grime.msgpack.encode(orig)
            local decoded = grime.msgpack.decode(encoded)

            assert(decoded.name == "grime")
            assert(decoded.version == 2)
            assert(decoded.nested.active == true)
            assert(decoded.nested.tags[1] == "fast")
            assert(decoded.nested.tags[2] == "reliable")
            return decoded.name
        "#;

        let name: String = lua.load(script).eval().expect("msgpack eval");
        assert_eq!(name, "grime");
    }

    #[test]
    fn test_lua_config_api() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            local dir = grime.config.config_dir()
            assert(dir ~= nil and #dir > 0)
            local nonexistent = grime.config.get("nonexistent_key_xyz")
            assert(nonexistent == nil)
            local with_default = grime.config.get("nonexistent_key_xyz", "my_default")
            assert(with_default == "my_default")
            return dir
        "#;

        let dir: String = lua.load(script).eval().expect("config api eval");
        assert!(!dir.is_empty());
    }

    #[test]
    fn test_lua_paths_registry() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            -- 1. Проверка grime.paths
            assert(grime.paths ~= nil, "grime.paths should exist")
            assert(grime.paths.config ~= nil, "grime.paths.config should exist")
            assert(grime.paths.projects ~= nil, "grime.paths.projects should exist")
            assert(grime.paths.templates ~= nil, "grime.paths.templates should exist")
            assert(grime.paths.apps ~= nil, "grime.paths.apps should exist")

            -- 2. Проверка grime.ctx.paths
            assert(grime.ctx.paths ~= nil, "grime.ctx.paths should exist")
            assert(grime.ctx.paths.apps == grime.paths.apps)
            assert(grime.ctx.paths.projects == grime.paths.projects)
            assert(grime.ctx.paths.templates == grime.paths.templates)

            -- 3. Проверка grime.config.get_all()
            local all = grime.config.get_all()
            assert(all.apps == grime.paths.apps)

            return grime.paths.apps
        "#;

        let apps_path: String = lua.load(script).eval().expect("paths registry eval");
        assert!(!apps_path.is_empty());
    }
}



