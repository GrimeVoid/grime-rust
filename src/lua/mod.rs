//! Модульная реализация движка Lua Grime-RS.
//!
//! Обеспечивает интеграцию среды Lua с подсистемами хоста: процессами,
//! файловой системой, шинами состояний и событий, прерываниями и конвейером.

pub mod api_bus;
pub mod api_fs;
pub mod api_fuzzy;
pub mod api_process;
pub mod api_str_table;
pub mod api_ui;
pub mod context;
pub mod prelude;

use colored::Colorize;
use mlua::{Lua, MultiValue, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::cancellation::{attach_lua_cancellation_hook, PipelineCanceller};
use crate::config::GrimeConfig;
use crate::event_bus::{dispatch_event_to_lua, EventBus};
use crate::payload::{extract_payload, PipelinePayload};
use crate::pipeline::PipelineStep;
use crate::state_bus::StateBus;

/// Результат выполнения шага конвейера в движке Lua.
#[derive(Debug, Clone)]
pub struct StepExecutionResult {
    pub success: bool,
    pub return_value: Option<String>,
    pub payload: Option<PipelinePayload>,
    pub error_message: Option<String>,
}

/// Основной исполнительный движок Lua Grime.
pub struct GrimeLuaEngine {
    lua: Lua,
    modules_dir: PathBuf,
    config: GrimeConfig,
    state_bus: Arc<StateBus>,
    event_bus: Arc<EventBus>,
    canceller: PipelineCanceller,
}

/// Преобразует значение mlua::Value в бинарное представление rmpv::Value.
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

/// Преобразует rmpv::Value обратно в mlua::Value.
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
    /// Создает новый экземпляр движка с дефолтными шинами.
    pub fn new(modules_dir: Option<PathBuf>, custom_config: Option<&Path>) -> Result<Self, mlua::Error> {
        let state_bus = Arc::new(StateBus::new());
        let event_bus = Arc::new(EventBus::default());
        let canceller = PipelineCanceller::new();
        Self::new_with_bus(modules_dir, custom_config, state_bus, event_bus, canceller)
    }

    /// Создает новый экземпляр движка с заданными шинами и контроллером прерывания.
    pub fn new_with_bus(
        modules_dir: Option<PathBuf>,
        custom_config: Option<&Path>,
        state_bus: Arc<StateBus>,
        event_bus: Arc<EventBus>,
        canceller: PipelineCanceller,
    ) -> Result<Self, mlua::Error> {
        let lua = Lua::new();
        let config = GrimeConfig::load_or_default(custom_config);
        let resolved_modules = modules_dir.unwrap_or_else(Self::discover_modules_dir);

        let engine = Self {
            lua,
            modules_dir: resolved_modules,
            config,
            state_bus,
            event_bus,
            canceller,
        };

        engine.init_runtime()?;
        Ok(engine)
    }

    /// Возвращает ссылку на шину состояния.
    pub fn state_bus(&self) -> &Arc<StateBus> {
        &self.state_bus
    }

    /// Возвращает ссылку на шину событий.
    pub fn event_bus(&self) -> &Arc<EventBus> {
        &self.event_bus
    }

    /// Возвращает ссылку на токен отмены.
    pub fn canceller(&self) -> &PipelineCanceller {
        &self.canceller
    }

    /// Поиск директории с модулями.
    fn discover_modules_dir() -> PathBuf {
        let cur = PathBuf::from("modules");
        if cur.exists() {
            return cur;
        }

        if let Ok(exe_p) = std::env::current_exe() {
            if let Some(parent) = exe_p.parent() {
                let candidate = parent.join("../share/grime/modules");
                if candidate.exists() {
                    return candidate;
                }
                let cand_rel = parent.join("modules");
                if cand_rel.exists() {
                    return cand_rel;
                }
            }
        }

        if let Some(home) = dirs::home_dir() {
            let dotfiles_modules = home.join("dotfiles/grime/modules");
            if dotfiles_modules.exists() {
                return dotfiles_modules;
            }
            let user_modules = home.join(".config/grime/modules");
            if user_modules.exists() {
                return user_modules;
            }
        }

        PathBuf::from("modules")
    }

    /// Инициализация runtime: регистрация модульных API, путей и прелюда.
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

        // 3. Регистрация API процессов (grime.process)
        api_process::register_process_api(lua, &grime_tbl)?;

        // 4. Регистрация API файловой системы (grime.fs)
        api_fs::register_fs_api(lua, &grime_tbl)?;

        // 5. Регистрация API конфигурации и единого реестра путей (grime.config, grime.paths)
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

        let paths_tbl = lua.create_table()?;
        for (k, v) in &self.config.paths {
            paths_tbl.set(k.as_str(), v.as_str())?;
        }
        grime_tbl.set("paths", paths_tbl)?;

        // 6. Регистрация grime.msgpack
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

        // 7. Регистрация grime.json
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

        // 8. Регистрация строк и таблиц (grime.str, grime.table)
        api_str_table::register_str_table_api(lua, &grime_tbl)?;

        // 9. Регистрация UI форматирования (grime.ui)
        api_ui::register_ui_api(lua, &grime_tbl)?;

        // 10. Регистрация нечёткого поиска (grime.fuzzy)
        api_fuzzy::register_fuzzy_api(lua, &grime_tbl)?;

        // 11. Инициализация контекста конвейера (grime.ctx и _G.ctx)
        context::init_context_table(lua, &grime_tbl, &self.config)?;

        lua.globals().set("grime", grime_tbl)?;

        // 12. Регистрация прелюда (package.preload["helper"] и _G.ctx)
        prelude::register_prelude(lua)?;

        // 13. Регистрация шин (grime.bus и grime.events)
        api_bus::register_bus_api(lua, &lua.globals().get::<mlua::Table>("grime")?, self.state_bus.clone(), self.event_bus.clone())?;

        // 14. Установка хука безопасного прерывания (Cancellation Hook)
        attach_lua_cancellation_hook(lua, self.canceller.clone());

        Ok(())
    }

    /// Устанавливает контекст перед запуском шага конвейера.
    pub fn set_step_context(
        &self,
        step: &PipelineStep,
        step_index: usize,
        total_steps: usize,
        target_dir: &Path,
        pipeline_input: Option<&str>,
        payload: Option<&PipelinePayload>,
    ) -> Result<(), mlua::Error> {
        context::update_step_context(
            &self.lua,
            &self.config,
            step,
            step_index,
            total_steps,
            target_dir,
            pipeline_input,
            payload,
        )
    }

    /// Выполняет модуль по имени (с поиском, fuzzy match, вызовом main и обработкой возвращаемых значений).
    pub fn execute_module(&self, module_name: &str) -> Result<StepExecutionResult, mlua::Error> {
        // Проверка отмены перед запуском модуля
        if self.canceller.is_cancelled() {
            let reason = self
                .canceller
                .get_reason()
                .unwrap_or_else(|| "Выполнение конвейера отменено".to_string());
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
                    error_message: Some(format!(
                        "Модуль '{}.lua' не найден в {:?}",
                        module_name, self.modules_dir
                    )),
                });
            }
        }

        let content = fs::read_to_string(&mod_file).map_err(|e| {
            mlua::Error::runtime(format!(
                "Ошибка чтения модуля '{}': {}",
                mod_file.display(),
                e
            ))
        })?;

        // Запуск скрипта
        let chunk = lua.load(&content).set_name(format!("@{}", mod_file.display()));
        let chunk_res: Result<Value, mlua::Error> = chunk.call(MultiValue::new());

        let mut direct_return_value: Option<Value> = None;
        match chunk_res {
            Ok(v) => {
                if v != Value::Nil {
                    direct_return_value = Some(v);
                }
            }
            Err(e) => {
                return Ok(StepExecutionResult {
                    success: false,
                    return_value: None,
                    payload: None,
                    error_message: Some(format!("Ошибка исполнения модуля '{}': {}", module_name, e)),
                });
            }
        }

        // Если модуль экспортирует функцию main(), вызываем её
        let globals = lua.globals();
        if let Ok(main_fn) = globals.get::<mlua::Function>("main") {
            let res: Result<Value, mlua::Error> = main_fn.call(());
            let _ = globals.set("main", Value::Nil);
            match res {
                Ok(v) => {
                    if v != Value::Nil {
                        direct_return_value = Some(v);
                    }
                }
                Err(e) => {
                    return Ok(StepExecutionResult {
                        success: false,
                        return_value: None,
                        payload: None,
                        error_message: Some(format!("Ошибка в main() модуля '{}': {}", module_name, e)),
                    });
                }
            }
        }

        // Читаем результаты из grime.ctx
        let grime: mlua::Table = globals.get("grime")?;
        let ctx: mlua::Table = grime.get("ctx")?;

        let status: bool = ctx.get("_status").unwrap_or(true);
        let error_msg: Option<String> = ctx.get("_error_message").ok();
        let mut ret_val: Option<String> = ctx.get("_return_value").ok();
        let mut ret_payload: Option<PipelinePayload> = ctx
            .get::<Option<PipelinePayload>>("_return_payload")
            .ok()
            .flatten();

        // Если модуль вернул значение напрямую (через return в скрипте/main), но не вызвал ctx.success(val):
        if ret_val.is_none() && ret_payload.is_none() {
            if let Some(val) = direct_return_value {
                if let Some(payload) = extract_payload(val.clone()) {
                    let text = payload.to_string_lossy();
                    ret_val = Some(text);
                    ret_payload = Some(payload);
                } else {
                    let s = match val {
                        Value::String(st) => st.to_string_lossy().to_string(),
                        Value::Integer(i) => i.to_string(),
                        Value::Number(n) => n.to_string(),
                        Value::Boolean(b) => b.to_string(),
                        _ => format!("{:?}", val),
                    };
                    ret_payload = Some(PipelinePayload::from_string(s.clone()));
                    ret_val = Some(s);
                }
            }
        }

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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
        let lua = &engine.lua;

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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
        let lua = &engine.lua;

        let script = r#"
            assert(grime.paths ~= nil, "grime.paths should exist")
            assert(grime.paths.config ~= nil, "grime.paths.config should exist")
            assert(grime.paths.projects ~= nil, "grime.paths.projects should exist")
            assert(grime.paths.templates ~= nil, "grime.paths.templates should exist")
            assert(grime.paths.apps ~= nil, "grime.paths.apps should exist")

            assert(grime.ctx.paths ~= nil, "grime.ctx.paths should exist")
            assert(grime.ctx.paths.apps == grime.paths.apps)
            assert(grime.ctx.paths.projects == grime.paths.projects)
            assert(grime.ctx.paths.templates == grime.paths.templates)

            local all = grime.config.get_all()
            assert(all.apps == grime.paths.apps)

            return grime.paths.apps
        "#;

        let apps_path: String = lua.load(script).eval().expect("paths registry eval");
        assert!(!apps_path.is_empty());
    }

    #[test]
    fn test_lua_json_encode_decode() {
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
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
        let engine = GrimeLuaEngine::new(None, None).expect("Инициализация lua engine");
        let lua = &engine.lua;

        let script = r#"
            local best, score = grime.fuzzy.find_best_match("pckg", { "pkg", "app", "box" }, 0.75)
            assert(best == "pkg", "find_best_match pckg -> pkg")
            assert(score > 0.75)

            local dict_candidates = { ["pacman"] = true, ["cargo"] = true, ["nix"] = true }
            local best_dict = grime.fuzzy.find_best_match("pacmn", dict_candidates, 0.75)
            assert(best_dict == "pacman", "find_best_match with dict keys")

            local flags = { "--help", "-h", "--all", "-a" }
            assert(grime.fuzzy.match_flag("--al", flags, 0.75) == "--all")
            assert(grime.fuzzy.fuzzy_match_flag("--halp", flags, 0.75) == "--help")

            local normalized = grime.fuzzy.normalize_flags({ "--al", "my_pkg", "-hlp" }, flags, 0.75)
            assert(#normalized == 3)
            assert(normalized[1] == "--all")
            assert(normalized[2] == "my_pkg")
            assert(normalized[3] == "--help")

            local joined = grime.fs.join("foo", "bar", "baz")
            assert(joined:find("foo/bar/baz") ~= nil)

            assert(ctx ~= nil, "global ctx exists")
            assert(ctx.input == nil)
            assert(ctx.pipeline_input == nil)
            assert(ctx.normalize_path ~= nil)
            assert(ctx.projects_root ~= nil and #ctx.projects_root() > 0)
            assert(ctx.apps_root ~= nil and #ctx.apps_root() > 0)
            assert(ctx.templates_root ~= nil and #ctx.templates_root() > 0)
            assert(ctx.config_dir ~= nil and #ctx.config_dir() > 0)
            assert(ctx.to_snake_case("AppTest") == "app_test")

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
