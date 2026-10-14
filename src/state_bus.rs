use std::collections::HashMap;
use std::sync::{Arc, RwLock};
use mlua::{Lua, Value};
use serde_json::{json, Value as JsonValue};

/// Потокобезопасная шина разделяемого состояния Grime (Shared State Bus).
///
/// Поддерживает пространства имен:
/// - `system.*` - системные данные процесса/демона (версия, pid, время запуска)
/// - `env.*` - переменные окружения
/// - `pipeline.*` - сессионные данные конвейера (очищаются по завершении через RAII)
/// - `modules.<name>.*` - изолированное состояние модулей
#[derive(Clone, Debug)]
pub struct StateBus {
    data: Arc<RwLock<HashMap<String, JsonValue>>>,
}

impl Default for StateBus {
    fn default() -> Self {
        Self::new()
    }
}

impl StateBus {
    pub fn new() -> Self {
        let bus = Self {
            data: Arc::new(RwLock::new(HashMap::new())),
        };
        bus.init_defaults();
        bus
    }

    /// Проверка соответствия ключа допустимым пространствам имен:
    /// `system.*`, `env.*`, `pipeline.*`, `modules.<name>.*`.
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

    /// Получить значение по ключу.
    pub fn get(&self, key: &str) -> Option<JsonValue> {
        let map = self.data.read().ok()?;
        map.get(key).cloned()
    }

    /// Сохранить значение по ключу с валидацией пространства имен.
    pub fn set(&self, key: &str, value: JsonValue) -> Result<(), String> {
        Self::validate_namespace(key)?;
        let mut map = self.data.write().map_err(|e| e.to_string())?;
        map.insert(key.to_string(), value);
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
            map.remove(key).is_some()
        } else {
            false
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
                .filter(|k| prefix.map_or(true, |p| k.starts_with(p)))
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

/// Конвертация `mlua::Value` в `serde_json::Value`.
pub fn lua_to_json(val: Value) -> Result<JsonValue, mlua::Error> {
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
                            arr.push(lua_to_json(v)?);
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
                obj.insert(key_str, lua_to_json(v)?);
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
                Ok(JsonValue::String(format!("[UserData]")))
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
                .map_err(|e| mlua::Error::runtime(e))?;
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
        let bus = Arc::new(StateBus::new());
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
    }
}
