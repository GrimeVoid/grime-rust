use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};
use mlua::{Lua, Value};
use serde_json::{json, Value as JsonValue};

/// Потокобезопасная шина разделяемого состояния Grime (Shared State Bus).
///
/// Поддерживает пространства имен:
/// - `system.*` - системные данные процесса/демона (версия, pid, время запуска)
/// - `env.*` - переменные окружения
/// - `pipeline.*` - сессионные данные конвейера (очищаются по завершении через RAII)
/// - `modules.<name>.*`, `log.*`, `daemon.*`, `git.*`, `session.*` и др. - персистентные пространства имен
#[derive(Clone, Debug)]
pub struct StateBus {
    data: Arc<RwLock<HashMap<String, JsonValue>>>,
    persistence_path: Option<PathBuf>,
}

impl Default for StateBus {
    fn default() -> Self {
        Self::new()
    }
}

impl StateBus {
    pub fn new() -> Self {
        Self::with_persistence_path(Some(Self::default_persistence_path()))
    }

    pub fn with_persistence_path(persistence_path: Option<PathBuf>) -> Self {
        let bus = Self {
            data: Arc::new(RwLock::new(HashMap::new())),
            persistence_path,
        };
        bus.init_defaults();
        bus.load_persisted();
        bus
    }

    /// Путь по умолчанию для хранения персистентного состояния: `~/.config/grime/state.json`.
    pub fn default_persistence_path() -> PathBuf {
        if let Ok(env_file) = std::env::var("GRIME_STATE_FILE") {
            if !env_file.trim().is_empty() {
                return PathBuf::from(env_file);
            }
        }
        if cfg!(test)
            || std::env::current_exe()
                .ok()
                .and_then(|p| p.to_str().map(|s| s.contains("/deps/")))
                .unwrap_or(false)
        {
            return std::env::temp_dir().join(format!("grime_test_state_{}.json", std::process::id()));
        }
        let home = crate::fs_ops::get_cached_home_dir()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        home.join(".config").join("grime").join("state.json")
    }

    /// Проверяет, подлежит ли ключ сохранению на диск (все ключи, кроме `pipeline.*`, `system.*`, `env.*`).
    #[inline]
    pub fn is_persistent_key(key: &str) -> bool {
        !key.starts_with("pipeline.") && !key.starts_with("system.") && !key.starts_with("env.")
    }

    /// Проверка соответствия ключа допустимым пространствам имен.
    pub fn validate_namespace(key: &str) -> Result<(), String> {
        let parts: Vec<&str> = key.split('.').collect();
        if parts.len() < 2 || parts.iter().any(|p| p.is_empty()) {
            return Err(format!(
                "Некорректный ключ '{}': ключ должен иметь префикс пространства имен (например, 'pipeline.foo', 'log.history' или 'modules.cmd.bar')",
                key
            ));
        }

        Ok(())
    }

    /// Инициализация стандартных системных параметров и окружения.
    pub fn init_defaults(&self) {
        if let Ok(mut map) = self.data.write() {
            map.insert("system.version".to_string(), json!(env!("CARGO_PKG_VERSION")));
            map.insert("system.pid".to_string(), json!(std::process::id()));
            map.insert("system.os".to_string(), json!(std::env::consts::OS));
            map.insert("system.arch".to_string(), json!(std::env::consts::ARCH));

            for (k, v) in std::env::vars() {
                map.insert(format!("env.{}", k), json!(v));
            }
        }
    }

    /// Загрузка сохраненного состояния с диска в память.
    pub fn load_persisted(&self) {
        let Some(ref path) = self.persistence_path else {
            return;
        };
        if !path.exists() {
            return;
        }
        if let Ok(content) = fs::read_to_string(path) {
            if let Ok(JsonValue::Object(obj)) = serde_json::from_str::<JsonValue>(&content) {
                if let Ok(mut map) = self.data.write() {
                    for (k, v) in obj {
                        if Self::validate_namespace(&k).is_ok() && Self::is_persistent_key(&k) {
                            map.insert(k, v);
                        }
                    }
                }
            }
        }
    }

    /// Атомарное сохранение всех персистентных ключей на диск через `.state.json.tmp` и `fs::rename`.
    fn persist_map(&self, map: &HashMap<String, JsonValue>) {
        let Some(ref path) = self.persistence_path else {
            return;
        };
        Self::write_persisted_to_file(path, map);
    }

    fn write_persisted_to_file(path: &Path, map: &HashMap<String, JsonValue>) {
        let mut persistent_obj = serde_json::Map::new();
        for (k, v) in map {
            if Self::is_persistent_key(k) {
                persistent_obj.insert(k.clone(), v.clone());
            }
        }

        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }

        let tmp_name = format!(
            ".{}.{}.tmp",
            path.file_name().and_then(|n| n.to_str()).unwrap_or("state.json"),
            std::process::id()
        );
        let tmp_path = path.with_file_name(tmp_name);

        if let Ok(serialized) = serde_json::to_string_pretty(&JsonValue::Object(persistent_obj)) {
            if fs::write(&tmp_path, serialized).is_ok() {
                let _ = fs::rename(&tmp_path, path);
            }
        }
    }

    /// Получить значение по ключу.
    pub fn get(&self, key: &str) -> Option<JsonValue> {
        let map = self.data.read().ok()?;
        map.get(key).cloned()
    }

    /// Сохранить значение по ключу с валидацией пространства имен и автосохранением на диск.
    pub fn set(&self, key: &str, value: JsonValue) -> Result<(), String> {
        Self::validate_namespace(key)?;
        let mut map = self.data.write().map_err(|e| e.to_string())?;
        map.insert(key.to_string(), value);
        if Self::is_persistent_key(key) {
            self.persist_map(&map);
        }
        Ok(())
    }

    /// Проверить наличие ключа.
    pub fn has(&self, key: &str) -> bool {
        if let Ok(map) = self.data.read() {
            map.contains_key(key)
        } else {
            false
        }
    }

    /// Удалить значение по ключу.
    pub fn delete(&self, key: &str) -> bool {
        if let Ok(mut map) = self.data.write() {
            let existed = map.remove(key).is_some();
            if existed && Self::is_persistent_key(key) {
                self.persist_map(&map);
            }
            existed
        } else {
            false
        }
    }

    /// Очистить все ключи указанного пространства имен (например, `"log."` или `"modules.cmd."`).
    pub fn clear_namespace(&self, prefix: &str) -> usize {
        let normalized_prefix = if prefix.ends_with('.') {
            prefix.to_string()
        } else {
            format!("{}.", prefix)
        };

        if let Ok(mut map) = self.data.write() {
            let before = map.len();
            let mut removed_persistent = false;
            map.retain(|k, _| {
                if k.starts_with(&normalized_prefix) {
                    if Self::is_persistent_key(k) {
                        removed_persistent = true;
                    }
                    false
                } else {
                    true
                }
            });
            let removed = before.saturating_sub(map.len());
            if removed_persistent {
                self.persist_map(&map);
            }
            removed
        } else {
            0
        }
    }

    /// Очистить все сессионные данные `pipeline.*`.
    pub fn clear_pipeline(&self) {
        if let Ok(mut map) = self.data.write() {
            map.retain(|k, _| !k.starts_with("pipeline."));
        }
    }

    /// Список ключей по опциональному префиксу.
    pub fn keys(&self, prefix: Option<&str>) -> Vec<String> {
        if let Ok(map) = self.data.read() {
            map.keys()
                .filter(|k| prefix.is_none_or(|p| k.starts_with(p)))
                .cloned()
                .collect()
        } else {
            Vec::new()
        }
    }

    /// Создать RAII-страж для конвейера, гарантирующий очистку `pipeline.*` при завершении/панике/отмене.
    pub fn create_session_guard(self: &Arc<Self>) -> PipelineSessionGuard {
        PipelineSessionGuard {
            bus: Arc::clone(self),
        }
    }
}

/// RAII-страж для сессионных данных `pipeline.*`.
pub struct PipelineSessionGuard {
    bus: Arc<StateBus>,
}

impl Drop for PipelineSessionGuard {
    fn drop(&mut self) {
        self.bus.clear_pipeline();
    }
}

pub const MAX_RECURSION_DEPTH: usize = 64;

/// Конвертация `mlua::Value` в `serde_json::Value` с защитой от переполнения стека.
pub fn lua_to_json(val: Value) -> Result<JsonValue, mlua::Error> {
    lua_to_json_depth(val, 0, MAX_RECURSION_DEPTH)
}

/// Рекурсивная конвертация `mlua::Value` в `serde_json::Value` с ограничением максимальной глубины.
pub fn lua_to_json_depth(val: Value, depth: usize, max_depth: usize) -> Result<JsonValue, mlua::Error> {
    if depth > max_depth {
        return Err(mlua::Error::runtime(
            "Превышена максимальная глубина вложенности таблицы Lua (возможна циклическая ссылка)",
        ));
    }

    match val {
        Value::Nil => Ok(JsonValue::Null),
        Value::Boolean(b) => Ok(JsonValue::Bool(b)),
        Value::Integer(i) => Ok(json!(i)),
        Value::Number(n) => {
            if let Some(num) = serde_json::Number::from_f64(n) {
                Ok(JsonValue::Number(num))
            } else {
                Ok(JsonValue::Null)
            }
        }
        Value::String(s) => Ok(JsonValue::String(s.to_str()?.to_string())),
        Value::Table(tbl) => {
            // Проверяем, является ли таблица последовательным массивом (1..len)
            let len = tbl.raw_len();
            if len > 0 {
                let mut arr = Vec::with_capacity(len);
                let mut is_array = true;
                for i in 1..=len {
                    match tbl.raw_get::<Value>(i as i64) {
                        Ok(v) if v != Value::Nil => {
                            arr.push(lua_to_json_depth(v, depth + 1, max_depth)?);
                        }
                        _ => {
                            is_array = false;
                            break;
                        }
                    }
                }
                if is_array {
                    return Ok(JsonValue::Array(arr));
                }
            }

            // Иначе таблица - словарь (object)
            let mut obj = serde_json::Map::new();
            for pair in tbl.pairs::<Value, Value>() {
                let (k, v) = pair?;
                let key_str = match k {
                    Value::String(s) => s.to_str()?.to_string(),
                    Value::Integer(i) => i.to_string(),
                    Value::Number(n) => n.to_string(),
                    Value::Boolean(b) => b.to_string(),
                    _ => format!("{:?}", k),
                };
                obj.insert(key_str, lua_to_json_depth(v, depth + 1, max_depth)?);
            }
            Ok(JsonValue::Object(obj))
        }
        Value::UserData(ud) => {
            if let Ok(bytes) = ud.borrow::<crate::payload::PipelinePayload>() {
                if let Some(s) = bytes.as_str() {
                    Ok(JsonValue::String(s.to_string()))
                } else {
                    Ok(json!(bytes.as_slice()))
                }
            } else {
                Ok(JsonValue::String("[UserData]".to_string()))
            }
        }
        _ => Ok(JsonValue::String(format!("{:?}", val))),
    }
}

/// Конвертация `serde_json::Value` в `mlua::Value`.
pub fn json_to_lua(lua: &Lua, val: &JsonValue) -> Result<Value, mlua::Error> {
    match val {
        JsonValue::Null => Ok(Value::Nil),
        JsonValue::Bool(b) => Ok(Value::Boolean(*b)),
        JsonValue::Number(n) => {
            if let Some(i) = n.as_i64() {
                Ok(Value::Integer(i))
            } else if let Some(f) = n.as_f64() {
                Ok(Value::Number(f))
            } else {
                Ok(Value::Nil)
            }
        }
        JsonValue::String(s) => Ok(Value::String(lua.create_string(s)?)),
        JsonValue::Array(arr) => {
            let tbl = lua.create_table()?;
            for (idx, item) in arr.iter().enumerate() {
                tbl.set(idx + 1, json_to_lua(lua, item)?)?;
            }
            Ok(Value::Table(tbl))
        }
        JsonValue::Object(map) => {
            let tbl = lua.create_table()?;
            for (k, v) in map {
                tbl.set(k.as_str(), json_to_lua(lua, v)?)?;
            }
            Ok(Value::Table(tbl))
        }
    }
}

/// Регистрация `grime.bus` в среде Lua.
pub fn register_state_bus_api(lua: &Lua, bus: Arc<StateBus>) -> Result<(), mlua::Error> {
    let globals = lua.globals();
    let grime: mlua::Table = globals.get("grime")?;

    let bus_tbl = lua.create_table()?;

    let bus_get = bus.clone();
    bus_tbl.set(
        "get",
        lua.create_function(move |lua, key: String| {
            if let Some(val) = bus_get.get(&key) {
                json_to_lua(lua, &val)
            } else {
                Ok(Value::Nil)
            }
        })?,
    )?;

    let bus_set = bus.clone();
    bus_tbl.set(
        "set",
        lua.create_function(move |_, (key, val): (String, Value)| {
            let json_val = lua_to_json(val)?;
            bus_set
                .set(&key, json_val)
                .map_err(mlua::Error::runtime)?;
            Ok(true)
        })?,
    )?;

    let bus_has = bus.clone();
    bus_tbl.set(
        "has",
        lua.create_function(move |_, key: String| Ok(bus_has.has(&key)))?,
    )?;

    let bus_del = bus.clone();
    bus_tbl.set(
        "delete",
        lua.create_function(move |_, key: String| Ok(bus_del.delete(&key)))?,
    )?;

    let bus_clear_ns = bus.clone();
    bus_tbl.set(
        "clear_namespace",
        lua.create_function(move |_, prefix: String| Ok(bus_clear_ns.clear_namespace(&prefix)))?,
    )?;

    let bus_keys = bus.clone();
    bus_tbl.set(
        "keys",
        lua.create_function(move |lua, prefix: Option<String>| {
            let keys = bus_keys.keys(prefix.as_deref());
            let tbl = lua.create_table()?;
            for (i, k) in keys.into_iter().enumerate() {
                tbl.set(i + 1, k)?;
            }
            Ok(tbl)
        })?,
    )?;

    bus_tbl.set("state", bus_tbl.clone())?;
    grime.set("bus", bus_tbl)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_namespaces() {
        assert!(StateBus::validate_namespace("pipeline.my_key").is_ok());
        assert!(StateBus::validate_namespace("system.version").is_ok());
        assert!(StateBus::validate_namespace("env.HOME").is_ok());
        assert!(StateBus::validate_namespace("modules.cmd.last_code").is_ok());
        assert!(StateBus::validate_namespace("log.history").is_ok());
        assert!(StateBus::validate_namespace("log.latest").is_ok());
        assert!(StateBus::validate_namespace("git.branch").is_ok());
        assert!(StateBus::validate_namespace("session.user").is_ok());
        assert!(StateBus::validate_namespace("custom.arbitrary_module").is_ok());

        assert!(StateBus::validate_namespace("invalid_no_namespace").is_err());
        assert!(StateBus::validate_namespace("").is_err());
        assert!(StateBus::validate_namespace(".leading_dot").is_err());
        assert!(StateBus::validate_namespace("trailing_dot.").is_err());
    }

    #[test]
    fn test_bus_crud_and_raii() {
        let tmp_state = std::env::temp_dir().join(format!("grime_state_test_{}.json", std::process::id()));
        let bus = Arc::new(StateBus::with_persistence_path(Some(tmp_state.clone())));
        bus.set("pipeline.test_val", json!({"score": 42})).unwrap();
        bus.set("modules.aider.model", json!("gpt-4o")).unwrap();

        assert!(bus.has("pipeline.test_val"));
        assert_eq!(
            bus.get("pipeline.test_val").unwrap()["score"],
            json!(42)
        );

        {
            let _guard = bus.create_session_guard();
            bus.set("pipeline.temp", json!("ephemeral")).unwrap();
            assert!(bus.has("pipeline.temp"));
        } // guard drops here

        // pipeline.* должен быть очищен
        assert!(!bus.has("pipeline.temp"));
        assert!(!bus.has("pipeline.test_val"));
        // modules.* должен остаться
        assert!(bus.has("modules.aider.model"));

        let _ = fs::remove_file(&tmp_state);
    }

    #[test]
    fn test_state_bus_persistence_across_instances() {
        let tmp_state = std::env::temp_dir().join(format!("grime_persist_test_{}.json", std::process::id()));
        let _ = fs::remove_file(&tmp_state);

        {
            let bus1 = StateBus::with_persistence_path(Some(tmp_state.clone()));
            bus1.set("log.history", json!(["event1", "event2"])).unwrap();
            bus1.set("daemon.terminal_dump", json!({"cmd": "cargo build", "status": 0})).unwrap();
            bus1.set("pipeline.ephemeral", json!("do_not_save")).unwrap();
        }

        assert!(tmp_state.exists(), "Файл state.json должен быть создан на диске");

        // Новый инстанс StateBus должен автоматически подгрузить сохраненные данные
        let bus2 = StateBus::with_persistence_path(Some(tmp_state.clone()));
        assert_eq!(bus2.get("log.history"), Some(json!(["event1", "event2"])));
        assert_eq!(bus2.get("daemon.terminal_dump").unwrap()["cmd"], json!("cargo build"));
        assert!(!bus2.has("pipeline.ephemeral"), "Сессионные ключи pipeline.* не должны сохраняться на диск");

        // Проверяем clear_namespace и delete
        let removed = bus2.clear_namespace("log");
        assert_eq!(removed, 1);
        assert!(!bus2.has("log.history"));

        let bus3 = StateBus::with_persistence_path(Some(tmp_state.clone()));
        assert!(!bus3.has("log.history"), "Удаленное пространство имен не должно восстанавливаться с диска");
        assert!(bus3.has("daemon.terminal_dump"));

        assert!(bus3.delete("daemon.terminal_dump"));
        let bus4 = StateBus::with_persistence_path(Some(tmp_state.clone()));
        assert!(!bus4.has("daemon.terminal_dump"));

        let _ = fs::remove_file(&tmp_state);
    }

    #[test]
    fn test_lua_to_json_recursion_limit() {
        let lua = Lua::new();
        let t = lua.create_table().unwrap();
        // Создаем циклическую ссылку t.self = t
        t.set("self", t.clone()).unwrap();

        let res = lua_to_json(Value::Table(t));
        assert!(res.is_err(), "Ожидалась ошибка при циклической ссылке в таблице");
        let err_msg = res.unwrap_err().to_string();
        assert!(
            err_msg.contains("Превышена максимальная глубина вложенности таблицы Lua"),
            "Сообщение об ошибке не содержит ожидаемый текст: {}",
            err_msg
        );
    }
}
