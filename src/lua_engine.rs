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

        if let Some(home) = dirs::home_dir() {
            let user_modules = home.join(".config").join("grime").join("modules");
            if user_modules.exists() {
                return user_modules;
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

        fs_tbl.set(
            "join",
            lua.create_function(|_, parts: MultiValue| {
                let mut res = PathBuf::new();
                for val in parts {
                    if let Value::String(s) = val {
                        let part = s.to_str()?;
                        if !part.is_empty() {
                            let expanded = shellexpand::tilde(part.as_ref()).to_string();
                            res.push(expanded);
                        }
                    }
                }
                let normalized = crate::fs_ops::normalize_path(&res);
                Ok(normalized.to_string_lossy().to_string())
            })?,
        )?;

        fs_tbl.set(
            "read",
            lua.create_function(|_, path: String| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                match fs::read_to_string(&p) {
                    Ok(s) => Ok(Some(s)),
                    Err(_) => Ok(None),
                }
            })?,
        )?;

        fs_tbl.set(
            "write",
            lua.create_function(|_, (path, content): (String, String)| {
                let p = PathBuf::from(shellexpand::tilde(&path).to_string());
                if let Some(parent) = p.parent() {
                    let _ = fs::create_dir_all(parent);
                }
                match fs::write(&p, content) {
                    Ok(_) => Ok(true),
                    Err(e) => Err(mlua::Error::runtime(format!("fs.write failed: {}", e))),
                }
            })?,
        )?;

        fs_tbl.set(
            "list",
            lua.create_function(|lua, path: Option<String>| {
                let p_str = path.unwrap_or_else(|| ".".to_string());
                let p = PathBuf::from(shellexpand::tilde(&p_str).to_string());
                let tbl = lua.create_table()?;
                if let Ok(entries) = fs::read_dir(&p) {
                    for (idx, entry) in entries.flatten().enumerate() {
                        let name = entry.file_name().to_string_lossy().to_string();
                        tbl.set(idx + 1, name)?;
                    }
                }
                Ok(tbl)
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

        // grime.json
        let json_tbl = lua.create_table()?;
        json_tbl.set(
            "decode",
            lua.create_function(|lua, s: String| {
                let val: serde_json::Value = serde_json::from_str(&s)
                    .map_err(|e| mlua::Error::runtime(format!("JSON decode error: {}", e)))?;
                crate::state_bus::json_to_lua(lua, &val)
            })?,
        )?;
        json_tbl.set(
            "encode",
            lua.create_function(|_, val: Value| {
                let json_val = crate::state_bus::lua_to_json(val)?;
                let s = serde_json::to_string(&json_val)
                    .map_err(|e| mlua::Error::runtime(format!("JSON encode error: {}", e)))?;
                Ok(s)
            })?,
        )?;
        grime_tbl.set("json", &json_tbl)?;

        // grime.str
        let str_tbl = lua.create_table()?;
        str_tbl.set(
            "to_snake_case",
            lua.create_function(|_, s: String| {
                let mut result = String::new();
                let chars: Vec<char> = s.chars().collect();
                for i in 0..chars.len() {
                    let c = chars[i];
                    if c.is_whitespace() || c == '-' {
                        if !result.ends_with('_') && !result.is_empty() {
                            result.push('_');
                        }
                    } else if c.is_uppercase() {
                        if i > 0 && !result.ends_with('_') {
                            let prev = chars[i - 1];
                            if prev.is_lowercase() || prev.is_numeric() {
                                result.push('_');
                            }
                        }
                        for lc in c.to_lowercase() {
                            result.push(lc);
                        }
                    } else {
                        result.push(c);
                    }
                }
                Ok(result.trim_matches('_').to_string())
            })?,
        )?;
        str_tbl.set(
            "to_kebab_case",
            lua.create_function(|_, s: String| {
                let mut result = String::new();
                let chars: Vec<char> = s.chars().collect();
                for i in 0..chars.len() {
                    let c = chars[i];
                    if c.is_whitespace() || c == '_' {
                        if !result.ends_with('-') && !result.is_empty() {
                            result.push('-');
                        }
                    } else if c.is_uppercase() {
                        if i > 0 && !result.ends_with('-') {
                            let prev = chars[i - 1];
                            if prev.is_lowercase() || prev.is_numeric() {
                                result.push('-');
                            }
                        }
                        for lc in c.to_lowercase() {
                            result.push(lc);
                        }
                    } else {
                        result.push(c);
                    }
                }
                Ok(result.trim_matches('-').to_string())
            })?,
        )?;
        str_tbl.set(
            "trim",
            lua.create_function(|_, s: String| {
                Ok(s.trim().to_string())
            })?,
        )?;
        str_tbl.set(
            "split",
            lua.create_function(|lua, (s, sep): (String, Option<String>)| {
                let tbl = lua.create_table()?;
                let separator = sep.unwrap_or_else(|| " ".to_string());
                if separator.is_empty() {
                    for (idx, ch) in s.chars().enumerate() {
                        tbl.set(idx + 1, ch.to_string())?;
                    }
                } else {
                    for (idx, part) in s.split(&separator).enumerate() {
                        tbl.set(idx + 1, part.to_string())?;
                    }
                }
                Ok(tbl)
            })?,
        )?;
        str_tbl.set(
            "starts_with",
            lua.create_function(|_, (s, prefix): (String, String)| {
                Ok(s.starts_with(&prefix))
            })?,
        )?;
        str_tbl.set(
            "ends_with",
            lua.create_function(|_, (s, suffix): (String, String)| {
                Ok(s.ends_with(&suffix))
            })?,
        )?;
        str_tbl.set(
            "pad_left",
            lua.create_function(|_, (s, len, ch): (String, usize, Option<String>)| {
                let pad_char = ch.and_then(|c| c.chars().next()).unwrap_or(' ');
                let cur_len = s.chars().count();
                if cur_len >= len {
                    Ok(s)
                } else {
                    let pad: String = std::iter::repeat(pad_char).take(len - cur_len).collect();
                    Ok(format!("{}{}", pad, s))
                }
            })?,
        )?;
        str_tbl.set(
            "pad_right",
            lua.create_function(|_, (s, len, ch): (String, usize, Option<String>)| {
                let pad_char = ch.and_then(|c| c.chars().next()).unwrap_or(' ');
                let cur_len = s.chars().count();
                if cur_len >= len {
                    Ok(s)
                } else {
                    let pad: String = std::iter::repeat(pad_char).take(len - cur_len).collect();
                    Ok(format!("{}{}", s, pad))
                }
            })?,
        )?;
        grime_tbl.set("str", &str_tbl)?;

        // grime.table
        let tbl_tbl = lua.create_table()?;
        tbl_tbl.set(
            "keys",
            lua.create_function(|lua, tbl: mlua::Table| {
                let res = lua.create_table()?;
                let mut idx = 1;
                for pair in tbl.pairs::<Value, Value>() {
                    let (k, _) = pair?;
                    res.set(idx, k)?;
                    idx += 1;
                }
                Ok(res)
            })?,
        )?;
        tbl_tbl.set(
            "values",
            lua.create_function(|lua, tbl: mlua::Table| {
                let res = lua.create_table()?;
                let mut idx = 1;
                for pair in tbl.pairs::<Value, Value>() {
                    let (_, v) = pair?;
                    res.set(idx, v)?;
                    idx += 1;
                }
                Ok(res)
            })?,
        )?;
        tbl_tbl.set(
            "contains",
            lua.create_function(|_, (tbl, target): (mlua::Table, Value)| {
                for pair in tbl.pairs::<Value, Value>() {
                    let (_, v) = pair?;
                    if v == target {
                        return Ok(true);
                    }
                }
                Ok(false)
            })?,
        )?;
        tbl_tbl.set(
            "merge",
            lua.create_function(|lua, (t1, t2): (mlua::Table, mlua::Table)| {
                let res = lua.create_table()?;
                for pair in t1.pairs::<Value, Value>() {
                    let (k, v) = pair?;
                    res.set(k, v)?;
                }
                for pair in t2.pairs::<Value, Value>() {
                    let (k, v) = pair?;
                    res.set(k, v)?;
                }
                Ok(res)
            })?,
        )?;
        tbl_tbl.set(
            "filter",
            lua.create_function(|lua, (tbl, pred): (mlua::Table, mlua::Function)| {
                let res = lua.create_table()?;
                let mut out_idx = 1;
                let len = tbl.raw_len();
                if len > 0 {
                    for i in 1..=len {
                        let val: Value = tbl.get(i)?;
                        if pred.call::<bool>(val.clone())? {
                            res.set(out_idx, val)?;
                            out_idx += 1;
                        }
                    }
                } else {
                    for pair in tbl.pairs::<Value, Value>() {
                        let (k, v) = pair?;
                        if pred.call::<bool>((v.clone(), k.clone()))? {
                            res.set(k, v)?;
                        }
                    }
                }
                Ok(res)
            })?,
        )?;
        tbl_tbl.set(
            "map",
            lua.create_function(|lua, (tbl, mapper): (mlua::Table, mlua::Function)| {
                let res = lua.create_table()?;
                let len = tbl.raw_len();
                if len > 0 {
                    for i in 1..=len {
                        let val: Value = tbl.get(i)?;
                        let mapped: Value = mapper.call(val)?;
                        res.set(i, mapped)?;
                    }
                } else {
                    for pair in tbl.pairs::<Value, Value>() {
                        let (k, v) = pair?;
                        let mapped: Value = mapper.call((v, k.clone()))?;
                        res.set(k, mapped)?;
                    }
                }
                Ok(res)
            })?,
        )?;
        tbl_tbl.set(
            "slice",
            lua.create_function(|lua, (tbl, start, end_idx): (mlua::Table, usize, Option<usize>)| {
                let res = lua.create_table()?;
                let len = tbl.raw_len();
                let finish = end_idx.unwrap_or(len).min(len);
                let mut out_idx = 1;
                for i in start..=finish {
                    let val: Value = tbl.get(i)?;
                    res.set(out_idx, val)?;
                    out_idx += 1;
                }
                Ok(res)
            })?,
        )?;
        grime_tbl.set("table", tbl_tbl)?;

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
        ui_tbl.set(
            "print_table",
            lua.create_function(|_, (rows, headers): (Vec<Vec<String>>, Option<Vec<String>>)| {
                let mut col_widths: Vec<usize> = Vec::new();
                if let Some(ref hdrs) = headers {
                    for (col_idx, h) in hdrs.iter().enumerate() {
                        if col_widths.len() <= col_idx {
                            col_widths.push(h.chars().count());
                        } else {
                            col_widths[col_idx] = col_widths[col_idx].max(h.chars().count());
                        }
                    }
                }
                for row in &rows {
                    for (col_idx, cell) in row.iter().enumerate() {
                        let cell_len = cell.chars().count();
                        if col_widths.len() <= col_idx {
                            col_widths.push(cell_len);
                        } else {
                            col_widths[col_idx] = col_widths[col_idx].max(cell_len);
                        }
                    }
                }

                if let Some(ref hdrs) = headers {
                    let mut header_line = String::new();
                    for (i, h) in hdrs.iter().enumerate() {
                        let width = col_widths.get(i).copied().unwrap_or(h.len());
                        header_line.push_str(&format!("{:<width$}  ", h, width = width));
                    }
                    println!("{}", header_line.bold());
                    let sep_len: usize = col_widths.iter().map(|w| w + 2).sum();
                    println!("{}", "-".repeat(sep_len).dimmed());
                }

                for row in &rows {
                    let mut row_line = String::new();
                    for (i, cell) in row.iter().enumerate() {
                        let width = col_widths.get(i).copied().unwrap_or(cell.len());
                        row_line.push_str(&format!("{:<width$}  ", cell, width = width));
                    }
                    println!("{}", row_line);
                }
                Ok(())
            })?,
        )?;
        ui_tbl.set(
            "format_columns",
            lua.create_function(|lua, (items, max_width): (Vec<String>, Option<usize>)| {
                let limit = max_width.unwrap_or(80);
                let max_item_len = items.iter().map(|s| s.chars().count()).max().unwrap_or(0);
                let col_width = max_item_len + 2;
                let num_cols = (limit / col_width.max(1)).max(1);
                let mut out_lines = Vec::new();

                let mut current_line = String::new();
                let mut col_count = 0;
                for item in &items {
                    if col_count >= num_cols {
                        out_lines.push(current_line);
                        current_line = String::new();
                        col_count = 0;
                    }
                    current_line.push_str(&format!("{:<width$}", item, width = col_width));
                    col_count += 1;
                }
                if !current_line.is_empty() {
                    out_lines.push(current_line);
                }

                let res_tbl = lua.create_table()?;
                for (idx, l) in out_lines.into_iter().enumerate() {
                    res_tbl.set(idx + 1, l)?;
                }
                Ok(res_tbl)
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
        fuzzy_tbl.set(
            "similarity",
            lua.create_function(|_, (s1, s2): (String, String)| {
                Ok(crate::args::flag_similarity(&s1, &s2))
            })?,
        )?;
        fuzzy_tbl.set(
            "damerau_levenshtein",
            lua.create_function(|_, (s1, s2): (String, String)| {
                Ok(crate::args::damerau_levenshtein(&s1, &s2))
            })?,
        )?;
        fuzzy_tbl.set(
            "match_flag",
            lua.create_function(|_, (token, candidates, threshold): (String, Vec<String>, Option<f64>)| {
                let thresh = threshold.unwrap_or(0.75);
                let cand_refs: Vec<&str> = candidates.iter().map(|s| s.as_str()).collect();
                Ok(crate::args::fuzzy_match_flag(&token, &cand_refs, thresh).map(|s| s.to_string()))
            })?,
        )?;
        fuzzy_tbl.set(
            "fuzzy_match_flag",
            lua.create_function(|_, (token, candidates, threshold): (String, Vec<String>, Option<f64>)| {
                let thresh = threshold.unwrap_or(0.75);
                let cand_refs: Vec<&str> = candidates.iter().map(|s| s.as_str()).collect();
                Ok(crate::args::fuzzy_match_flag(&token, &cand_refs, thresh).map(|s| s.to_string()))
            })?,
        )?;
        fuzzy_tbl.set(
            "find_best_match",
            lua.create_function(|lua, (query, candidates, threshold): (String, Value, Option<f64>)| {
                let thresh = threshold.unwrap_or(0.75);
                let mut cand_list = Vec::new();
                if let Value::Table(tbl) = candidates {
                    let len = tbl.raw_len();
                    if len > 0 {
                        for i in 1..=len {
                            if let Ok(s) = tbl.get::<String>(i) {
                                if !s.is_empty() {
                                    cand_list.push(s);
                                }
                            }
                        }
                    } else {
                        for pair in tbl.pairs::<Value, Value>() {
                            if let Ok((k, _)) = pair {
                                if let Value::String(s) = k {
                                    if let Ok(utf8) = s.to_str() {
                                        if !utf8.is_empty() {
                                            cand_list.push(utf8.to_string());
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                let cand_refs: Vec<&str> = cand_list.iter().map(|s| s.as_str()).collect();
                if let Some(matched) = crate::args::fuzzy_match_entity(&query, &cand_refs, thresh) {
                    let sim = crate::args::flag_similarity(&query, matched);
                    let m_str = lua.create_string(matched)?;
                    let mut multi = MultiValue::new();
                    multi.push_back(Value::String(m_str));
                    multi.push_back(Value::Number(sim));
                    Ok(multi)
                } else {
                    let mut multi = MultiValue::new();
                    multi.push_back(Value::Nil);
                    multi.push_back(Value::Number(0.0));
                    Ok(multi)
                }
            })?,
        )?;
        fuzzy_tbl.set(
            "fuzzy_match",
            fuzzy_tbl.get::<Value>("find_best_match")?,
        )?;
        fuzzy_tbl.set(
            "normalize_flags",
            lua.create_function(|lua, (args, known_flags, threshold): (Vec<String>, Vec<String>, Option<f64>)| {
                let thresh = threshold.unwrap_or(0.75);
                let cand_refs: Vec<&str> = known_flags.iter().map(|s| s.as_str()).collect();
                let res_tbl = lua.create_table()?;
                for (idx, arg) in args.iter().enumerate() {
                    let replaced = if arg.starts_with('-') && arg != "--" {
                        crate::args::fuzzy_match_flag(arg, &cand_refs, thresh)
                            .map(|s| s.to_string())
                            .unwrap_or_else(|| arg.clone())
                    } else {
                        arg.clone()
                    };
                    res_tbl.set(idx + 1, replaced)?;
                }
                Ok(res_tbl)
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
            lua.create_function(|lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let proc_tbl: mlua::Table = g.get("process")?;
                let effective_cwd = cwd.or_else(|| c.get::<Option<String>>("target_dir").ok().flatten());
                let run_fn: mlua::Function = proc_tbl.get("run_interactive")?;
                run_fn.call::<i32>((cmd, effective_cwd, env))
            })?,
        )?;
        ctx_tbl.set("run_interactive", ctx_tbl.get::<Value>("run_process")?)?;

        ctx_tbl.set(
            "run_shell",
            lua.create_function(|lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let proc_tbl: mlua::Table = g.get("process")?;
                let effective_cwd = cwd.or_else(|| c.get::<Option<String>>("target_dir").ok().flatten());
                let run_fn: mlua::Function = proc_tbl.get("run")?;
                run_fn.call::<i32>((cmd, effective_cwd, env))
            })?,
        )?;

        ctx_tbl.set(
            "capture",
            lua.create_function(|lua_ctx, (cmd, cwd, env): (Value, Option<String>, Option<HashMap<String, String>>)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let proc_tbl: mlua::Table = g.get("process")?;
                let effective_cwd = cwd.or_else(|| c.get::<Option<String>>("target_dir").ok().flatten());
                let cap_fn: mlua::Function = proc_tbl.get("capture")?;
                cap_fn.call::<Value>((cmd, effective_cwd, env))
            })?,
        )?;

        // Файловые операции через ctx
        ctx_tbl.set(
            "exists",
            lua.create_function(|lua_ctx, path: String| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("exists")?;
                f.call::<bool>(path)
            })?,
        )?;
        ctx_tbl.set(
            "is_dir",
            lua.create_function(|lua_ctx, path: String| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("is_dir")?;
                f.call::<bool>(path)
            })?,
        )?;
        ctx_tbl.set(
            "is_file",
            lua.create_function(|lua_ctx, path: String| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("is_file")?;
                f.call::<bool>(path)
            })?,
        )?;
        ctx_tbl.set(
            "mkdir_p",
            lua.create_function(|lua_ctx, path: String| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("mkdir_p")?;
                f.call::<bool>(path)
            })?,
        )?;
        ctx_tbl.set(
            "delete",
            lua.create_function(|lua_ctx, (path, missing_ok): (String, Option<bool>)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("delete")?;
                f.call::<bool>((path, missing_ok))
            })?,
        )?;
        ctx_tbl.set("remove", ctx_tbl.get::<Value>("delete")?)?;

        ctx_tbl.set(
            "copy",
            lua.create_function(|lua_ctx, (src, dst): (String, String)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("copy")?;
                f.call::<String>((src, dst))
            })?,
        )?;
        ctx_tbl.set(
            "move",
            lua.create_function(|lua_ctx, (src, dst): (String, String)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("move")?;
                f.call::<String>((src, dst))
            })?,
        )?;
        ctx_tbl.set("rename", ctx_tbl.get::<Value>("move")?)?;

        ctx_tbl.set(
            "mtime",
            lua.create_function(|lua_ctx, path: String| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("mtime")?;
                f.call::<f64>(path)
            })?,
        )?;
        ctx_tbl.set(
            "is_newer",
            lua.create_function(|lua_ctx, (src, target): (String, String)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("is_newer")?;
                f.call::<bool>((src, target))
            })?,
        )?;
        ctx_tbl.set("needs_rebuild", ctx_tbl.get::<Value>("is_newer")?)?;

        ctx_tbl.set(
            "normalize_path",
            lua.create_function(|lua_ctx, path: String| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let f: mlua::Function = fs_tbl.get("normalize")?;
                f.call::<String>(path)
            })?,
        )?;
        ctx_tbl.set("normalize", ctx_tbl.get::<Value>("normalize_path")?)?;

        ctx_tbl.set(
            "join",
            lua.create_function(|lua_ctx, parts: MultiValue| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let fs_tbl: mlua::Table = g.get("fs")?;
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
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                if let Some(n) = name {
                    if let Ok(paths) = c.get::<mlua::Table>("paths") {
                        if let Ok(val) = paths.get::<String>(n.as_str()) {
                            if !val.is_empty() && val != "auto" {
                                return Ok(Some(val));
                            }
                        }
                    }
                    if let Ok(paths) = g.get::<mlua::Table>("paths") {
                        if let Ok(val) = paths.get::<String>(n.as_str()) {
                            if !val.is_empty() && val != "auto" {
                                return Ok(Some(val));
                            }
                        }
                    }
                    if let Ok(cfg) = g.get::<mlua::Table>("config") {
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
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let get_path_fn: mlua::Function = c.get("get_path")?;
                let default_p = dirs::home_dir().map(|h| h.join("Projects").to_string_lossy().to_string()).unwrap_or_else(|| "./projects".to_string());
                let p: String = get_path_fn.call(("projects", Some(default_p)))?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
                norm_fn.call::<String>(p)
            })?,
        )?;

        ctx_tbl.set(
            "templates_root",
            lua.create_function(|lua_ctx, ()| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let get_path_fn: mlua::Function = c.get("get_path")?;
                let default_p = dirs::home_dir().map(|h| h.join(".config").join("grime").join("templates").to_string_lossy().to_string()).unwrap_or_else(|| "./templates".to_string());
                let p: String = get_path_fn.call(("templates", Some(default_p)))?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
                norm_fn.call::<String>(p)
            })?,
        )?;

        ctx_tbl.set(
            "apps_root",
            lua.create_function(|lua_ctx, ()| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let get_path_fn: mlua::Function = c.get("get_path")?;
                let default_p = dirs::home_dir().map(|h| h.join(".config").join("grime").join("apps").to_string_lossy().to_string()).unwrap_or_else(|| "./apps".to_string());
                let p: String = get_path_fn.call(("apps", Some(default_p)))?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
                norm_fn.call::<String>(p)
            })?,
        )?;

        ctx_tbl.set(
            "config_dir",
            lua.create_function(|lua_ctx, ()| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let c: mlua::Table = g.get("ctx")?;
                let get_path_fn: mlua::Function = c.get("get_path")?;
                let default_p = dirs::home_dir().map(|h| h.join(".config").join("grime").to_string_lossy().to_string()).unwrap_or_else(|| ".".to_string());
                let p: String = get_path_fn.call(("config", Some(default_p)))?;
                let fs_tbl: mlua::Table = g.get("fs")?;
                let norm_fn: mlua::Function = fs_tbl.get("normalize")?;
                norm_fn.call::<String>(p)
            })?,
        )?;

        ctx_tbl.set(
            "get_config",
            lua.create_function(|lua_ctx, (key, default): (String, Option<String>)| {
                let globals = lua_ctx.globals();
                let g: mlua::Table = globals.get("grime")?;
                let cfg: mlua::Table = g.get("config")?;
                let get_fn: mlua::Function = cfg.get("get")?;
                get_fn.call::<Option<String>>((key, default))
            })?,
        )?;

        ctx_tbl.set("json", json_tbl.clone())?;
        ctx_tbl.set("to_snake_case", str_tbl.get::<Value>("to_snake_case")?)?;

        grime_tbl.set("ctx", ctx_tbl.clone())?;

        lua.globals().set("grime", grime_tbl)?;
        lua.globals().set("ctx", ctx_tbl)?;

        // Встроенный прелюд Grime (prelude) для стандартных хелперов и совместимости
        let prelude = r#"
            package.preload["helper"] = function()
                return {
                    ctx = grime.ctx,
                    normalize_path = grime.fs.normalize,
                    join = grime.fs.join,
                    path_join = grime.fs.join,
                    to_snake_case = grime.str.to_snake_case,
                    to_kebab_case = grime.str.to_kebab_case,
                    json_decode = grime.json.decode,
                    json_encode = grime.json.encode,
                    damerau_levenshtein = grime.fuzzy.damerau_levenshtein,
                    similarity = grime.fuzzy.similarity,
                    fuzzy_match_flag = grime.fuzzy.match_flag,
                    normalize_flags = grime.fuzzy.normalize_flags,
                    find_best_match = grime.fuzzy.find_best_match,
                    fuzzy_match = grime.fuzzy.find_best_match,
                }
            end
            _G.ctx = grime.ctx
        "#;
        lua.load(prelude).set_name("@grime/prelude.lua").exec()?;

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

        globals.set("ctx", ctx)?;

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

        let mut target_mod_name = module_name.to_string();
        let mut mod_file = self.modules_dir.join(format!("{}.lua", target_mod_name));
        if !mod_file.exists() {
            let mut available: Vec<String> = Vec::new();
            if let Ok(entries) = fs::read_dir(&self.modules_dir) {
                for entry in entries.flatten() {
                    let path = entry.path();
                    if path.is_file() && path.extension().and_then(|e| e.to_str()) == Some("lua") {
                        if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                            available.push(stem.to_string());
                        }
                    }
                }
            }

            let cand_refs: Vec<&str> = available.iter().map(|s| s.as_str()).collect();
            if let Some(matched) = crate::args::fuzzy_match_entity(module_name, &cand_refs, 0.75) {
                eprintln!(
                    "{} Модуль '{}' не найден, запущен похожий модуль '{}'",
                    "[Grime]".cyan().bold(),
                    module_name,
                    matched
                );
                target_mod_name = matched.to_string();
                mod_file = self.modules_dir.join(format!("{}.lua", target_mod_name));
            } else {
                return Ok(StepExecutionResult {
                    success: false,
                    return_value: None,
                    payload: None,
                    error_message: Some(format!("Модуль '{}.lua' не найден в {:?}", module_name, self.modules_dir)),
                });
            }
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

    #[test]
    fn test_lua_json_encode_decode() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            local encoded = grime.json.encode({ name = "GrimeApp", score = 42, active = true })
            local decoded = grime.json.decode(encoded)
            assert(decoded.name == "GrimeApp")
            assert(decoded.score == 42)
            assert(decoded.active == true)
            return true
        "#;

        let res: bool = lua.load(script).eval().expect("json encode/decode eval");
        assert!(res);
    }

    #[test]
    fn test_lua_str_api() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            assert(grime.str.to_snake_case("HelloWorld") == "hello_world")
            assert(grime.str.to_snake_case("my-super-app") == "my_super_app")
            assert(grime.str.to_kebab_case("HelloWorld") == "hello-world")
            assert(grime.str.trim("   hello world   ") == "hello world")
            local parts = grime.str.split("a,b,c", ",")
            assert(#parts == 3 and parts[1] == "a" and parts[2] == "b" and parts[3] == "c")
            assert(grime.str.starts_with("prefix_val", "prefix") == true)
            assert(grime.str.ends_with("val_suffix", "suffix") == true)
            assert(grime.str.pad_left("5", 3, "0") == "005")
            assert(grime.str.pad_right("abc", 5, " ") == "abc  ")
            return true
        "#;
        let res: bool = lua.load(script).eval().expect("str api eval");
        assert!(res);
    }

    #[test]
    fn test_lua_table_api() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            local t = { a = 1, b = 2 }
            local keys = grime.table.keys(t)
            assert(#keys == 2)
            assert(grime.table.contains(keys, "a") or grime.table.contains(keys, "b"))

            local merged = grime.table.merge({ x = 1 }, { y = 2 })
            assert(merged.x == 1 and merged.y == 2)

            local list = { 1, 2, 3, 4, 5 }
            local evens = grime.table.filter(list, function(v) return v % 2 == 0 end)
            assert(#evens == 2 and evens[1] == 2 and evens[2] == 4)

            local doubled = grime.table.map(list, function(v) return v * 2 end)
            assert(#doubled == 5 and doubled[1] == 2 and doubled[5] == 10)

            local sliced = grime.table.slice(list, 2, 4)
            assert(#sliced == 3 and sliced[1] == 2 and sliced[3] == 4)
            return true
        "#;
        let res: bool = lua.load(script).eval().expect("table api eval");
        assert!(res);
    }

    #[test]
    fn test_lua_fuzzy_and_fs_and_ctx_native() {
        let engine = GrimeLuaEngine::new(None, None).expect("Init lua engine");
        let lua = &engine.lua;

        let script = r#"
            -- 1. Fuzzy match
            local best, score = grime.fuzzy.find_best_match("pckg", { "pkg", "app", "box" }, 0.75)
            assert(best == "pkg", "find_best_match pckg -> pkg")
            assert(score > 0.75)

            -- Поиск по словарю с ключами
            local dict_candidates = { ["pacman"] = true, ["cargo"] = true, ["nix"] = true }
            local best_dict = grime.fuzzy.find_best_match("pacmn", dict_candidates, 0.75)
            assert(best_dict == "pacman", "find_best_match with dict keys")

            -- Флаги
            local flags = { "--help", "-h", "--all", "-a" }
            assert(grime.fuzzy.match_flag("--al", flags, 0.75) == "--all")
            assert(grime.fuzzy.fuzzy_match_flag("--halp", flags, 0.75) == "--help")

            local normalized = grime.fuzzy.normalize_flags({ "--al", "my_pkg", "-hlp" }, flags, 0.75)
            assert(#normalized == 3)
            assert(normalized[1] == "--all")
            assert(normalized[2] == "my_pkg")
            assert(normalized[3] == "--help")

            -- 2. FS
            local joined = grime.fs.join("foo", "bar", "baz")
            assert(joined:find("foo/bar/baz") ~= nil)

            -- 3. Context native
            assert(ctx ~= nil, "global ctx exists")
            assert(ctx.normalize_path ~= nil)
            assert(ctx.projects_root ~= nil and #ctx.projects_root() > 0)
            assert(ctx.apps_root ~= nil and #ctx.apps_root() > 0)
            assert(ctx.templates_root ~= nil and #ctx.templates_root() > 0)
            assert(ctx.config_dir ~= nil and #ctx.config_dir() > 0)
            assert(ctx.to_snake_case("AppTest") == "app_test")

            -- 4. Обратная совместимость через package.preload['helper']
            local helper = require("helper")
            assert(helper ~= nil, "helper preloaded")
            assert(helper.ctx == ctx, "helper.ctx is same as ctx")
            assert(helper.find_best_match("proj", { "project", "pkg" }, 0.75) == "project")

            return true
        "#;
        let res: bool = lua.load(script).eval().expect("fuzzy fs ctx native eval");
        assert!(res);
    }
}



