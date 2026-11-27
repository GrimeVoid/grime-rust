use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::SystemTime;
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
    last_loaded_mtime: Arc<Mutex<Option<SystemTime>>>,
    /// Счётчик фактических записей на диск (для диагностики и тестов пакетной записи).
    persist_count: Arc<AtomicUsize>,
}

impl Default for StateBus {
    fn default() -> Self {
        Self::new()
    }
}

impl StateBus {
    pub fn new() -> Self {
        // Тестовые бинарии не должны писать state/.lock в общий /tmp: шина живёт только в памяти,
        // если путь явно не задан через GRIME_STATE_FILE.
        let in_test = cfg!(test)
            || std::env::current_exe()
                .ok()
                .and_then(|p| p.to_str().map(|s| s.contains("/deps/")))
                .unwrap_or(false);
        let explicit = std::env::var("GRIME_STATE_FILE").map(|v| !v.trim().is_empty()).unwrap_or(false);
        if in_test && !explicit {
            return Self::with_persistence_path(None);
        }
        Self::with_persistence_path(Some(Self::default_persistence_path()))
    }

    pub fn with_persistence_path(persistence_path: Option<PathBuf>) -> Self {
        let bus = Self {
            data: Arc::new(RwLock::new(HashMap::new())),
            persistence_path,
            last_loaded_mtime: Arc::new(Mutex::new(None)),
            persist_count: Arc::new(AtomicUsize::new(0)),
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
        let Ok(mut map) = self.data.write() else {
            return;
        };
        self.sync_from_disk_if_modified(&mut map);
    }

    /// Проверяет `mtime` файла `state.json` и при наличии внешних изменений перечитывает персистентные ключи.
    fn sync_from_disk_if_modified(&self, map: &mut HashMap<String, JsonValue>) {
        let Some(ref path) = self.persistence_path else {
            return;
        };
        let Ok(disk_mtime) = fs::metadata(path).and_then(|m| m.modified()) else {
            return;
        };

        let should_reload = match self.last_loaded_mtime.lock() {
            Ok(guard) => match *guard {
                Some(prev) => disk_mtime != prev,
                None => true,
            },
            Err(_) => true,
        };

        if !should_reload {
            return;
        }

        if let Ok(content) = fs::read_to_string(path) {
            if let Ok(JsonValue::Object(obj)) = serde_json::from_str::<JsonValue>(&content) {
                // Очищаем прежние персистентные ключи, оставляя транзиентные (`pipeline.*`, `system.*`, `env.*`)
                map.retain(|k, _| !Self::is_persistent_key(k));
                for (k, v) in obj {
                    if Self::validate_namespace(&k).is_ok() && Self::is_persistent_key(&k) {
                        map.insert(k, v);
                    }
                }
                if let Ok(mut guard) = self.last_loaded_mtime.lock() {
                    *guard = Some(disk_mtime);
                }
            }
        }
    }

    /// Быстрая проверка необходимости синхронизации перед операциями чтения.
    fn ensure_synced_for_read(&self) {
        let Some(ref path) = self.persistence_path else {
            return;
        };
        let Ok(disk_mtime) = fs::metadata(path).and_then(|m| m.modified()) else {
            return;
        };
        let needs_sync = match self.last_loaded_mtime.lock() {
            Ok(guard) => match *guard {
                Some(prev) => disk_mtime != prev,
                None => true,
            },
            Err(_) => false,
        };
        if needs_sync {
            if let Ok(mut map) = self.data.write() {
                self.sync_from_disk_if_modified(&mut map);
            }
        }
    }

    /// Эксклюзивная блокировка `flock` на `<state>.lock` для безопасного read-modify-write
    /// между несколькими процессами (CLI и демон). Блокировка снимается при закрытии файла.
    fn lock_file(&self) -> Option<fs::File> {
        let path = self.persistence_path.as_ref()?;
        let lock_name = format!(
            "{}.lock",
            path.file_name().and_then(|n| n.to_str()).unwrap_or("state.json")
        );
        let lock_path = path.with_file_name(lock_name);
        if let Some(parent) = lock_path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(lock_path)
            .ok()?;
        use std::os::unix::io::AsRawFd;
        // Блокирующий LOCK_EX: операции записи короткие
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) };
        (rc == 0).then_some(file)
    }

    /// Атомарное сохранение всех персистентных ключей на диск через `.state.json.tmp` и `fs::rename`.
    fn persist_map(&self, map: &HashMap<String, JsonValue>) {
        let Some(ref path) = self.persistence_path else {
            return;
        };
        Self::write_persisted_to_file(path, map);
        self.persist_count.fetch_add(1, Ordering::Relaxed);
        if let Ok(mtime) = fs::metadata(path).and_then(|m| m.modified()) {
            if let Ok(mut guard) = self.last_loaded_mtime.lock() {
                *guard = Some(mtime);
            }
        }
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

        if let Ok(serialized) = serde_json::to_string(&JsonValue::Object(persistent_obj)) {
            if fs::write(&tmp_path, serialized).is_ok() {
                let _ = fs::rename(&tmp_path, path);
            }
        }
    }

    /// Получить значение по ключу.
    pub fn get(&self, key: &str) -> Option<JsonValue> {
        if Self::is_persistent_key(key) {
            self.ensure_synced_for_read();
        }
        let map = self.data.read().ok()?;
        map.get(key).cloned()
    }

    /// Сохранить значение по ключу с валидацией пространства имен и автосохранением на диск.
    pub fn set(&self, key: &str, value: JsonValue) -> Result<(), String> {
        self.set_many(vec![(key.to_string(), value)])
    }

    /// Пакетная запись: все ключи валидируются до записи (при ошибке не пишется ничего),
    /// затем берётся один `flock` и выполняется один persist на весь набор.
    pub fn set_many(&self, entries: Vec<(String, JsonValue)>) -> Result<(), String> {
        for (key, _) in &entries {
            Self::validate_namespace(key)?;
        }
        if entries.is_empty() {
            return Ok(());
        }
        let persistent = entries.iter().any(|(k, _)| Self::is_persistent_key(k));
        let _file_lock = if persistent { self.lock_file() } else { None };
        let mut map = self.data.write().map_err(|e| e.to_string())?;
        if persistent {
            self.sync_from_disk_if_modified(&mut map);
        }
        for (key, value) in entries {
            map.insert(key, value);
        }
        if persistent {
            self.persist_map(&map);
        }
        Ok(())
    }

    /// Число выполненных записей состояния на диск (общий счётчик для клонов шины).
    pub fn persist_count(&self) -> usize {
        self.persist_count.load(Ordering::Relaxed)
    }

    /// Проверить наличие ключа.
    pub fn has(&self, key: &str) -> bool {
        if Self::is_persistent_key(key) {
            self.ensure_synced_for_read();
        }
        if let Ok(map) = self.data.read() {
            map.contains_key(key)
        } else {
            false
        }
    }

    /// Удалить значение по ключу.
    pub fn delete(&self, key: &str) -> bool {
        let _file_lock = if Self::is_persistent_key(key) { self.lock_file() } else { None };
        if let Ok(mut map) = self.data.write() {
            if Self::is_persistent_key(key) {
                self.sync_from_disk_if_modified(&mut map);
            }
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

        let _file_lock = if Self::is_persistent_key(&normalized_prefix) { self.lock_file() } else { None };
        if let Ok(mut map) = self.data.write() {
            if Self::is_persistent_key(&normalized_prefix) {
                self.sync_from_disk_if_modified(&mut map);
            }
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
        self.ensure_synced_for_read();
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

/// Единый предел глубины рекурсии конвертаций Lua <-> JSON/MsgPack на весь крейт.
pub const MAX_RECURSION_DEPTH: usize = 64;

/// Проверяет, является ли таблица Lua чистым последовательным массивом `1..=len` без дополнительных ключей.
pub fn is_pure_lua_array(tbl: &mlua::Table) -> Result<bool, mlua::Error> {
    let len = tbl.raw_len();
    if len == 0 {
        return Ok(false);
    }
    for i in 1..=len {
        match tbl.raw_get::<Value>(i as i64) {
            Ok(v) if v != Value::Nil => {}
            _ => return Ok(false),
        }
    }
    let mut pair_count = 0usize;
    for pair in tbl.clone().pairs::<Value, Value>() {
        let _ = pair?;
        pair_count += 1;
        if pair_count > len {
            return Ok(false);
        }
    }
    Ok(pair_count == len)
}

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
            // Таблица сериализуется как массив только если это чистый последовательный массив 1..=len без строковых/разреженных ключей
            if is_pure_lua_array(&tbl)? {
                let len = tbl.raw_len();
                let mut arr = Vec::with_capacity(len);
                for i in 1..=len {
                    let v: Value = tbl.raw_get(i as i64)?;
                    arr.push(lua_to_json_depth(v, depth + 1, max_depth)?);
                }
                return Ok(JsonValue::Array(arr));
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

    let bus_set_many = bus.clone();
    bus_tbl.set(
        "set_many",
        lua.create_function(move |_, tbl: mlua::Table| {
            let mut entries = Vec::new();
            for pair in tbl.pairs::<String, Value>() {
                let (key, val) = pair?;
                entries.push((key, lua_to_json(val)?));
            }
            bus_set_many.set_many(entries).map_err(mlua::Error::runtime)?;
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
        let _td = crate::test_support::TempDir::new("state_test");
        let tmp_state = _td.join("state.json");
        let bus = Arc::new(StateBus::with_persistence_path(Some(tmp_state.clone())));
        bus.set("pipeline.test_val", json!({"score": 42})).unwrap();
        bus.set("modules.ai.model", json!("gpt-4o")).unwrap();

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
        assert!(bus.has("modules.ai.model"));
    }

    #[test]
    fn test_state_bus_persistence_across_instances() {
        let _td = crate::test_support::TempDir::new("persist_test");
        let tmp_state = _td.join("state.json");

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
    }

    #[test]
    fn test_state_file_is_compact_and_lock_file_created() {
        let _td = crate::test_support::TempDir::new("compact_test");
        let tmp_state = _td.join("state.json");
        let bus = StateBus::with_persistence_path(Some(tmp_state.clone()));
        bus.set("log.a", json!({"k": [1, 2, 3]})).unwrap();
        bus.set("log.b", json!("x")).unwrap();

        let content = fs::read_to_string(&tmp_state).unwrap();
        assert!(!content.contains('\n'), "JSON должен быть компактным: {}", content);
        assert!(tmp_state.with_file_name(format!(
            "{}.lock",
            tmp_state.file_name().unwrap().to_string_lossy()
        )).exists());
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

    #[test]
    fn test_lua_to_json_mixed_and_sparse_tables() {
        let lua = Lua::new();

        // Смешанная таблица: { "item1", key = "val" }
        let mixed: Value = lua
            .load(r#"return { "item1", key = "val" }"#)
            .eval()
            .unwrap();
        let json_mixed = lua_to_json(mixed).expect("mixed table to json");
        assert!(json_mixed.is_object(), "Смешанная таблица должна сериализоваться как Object");
        assert_eq!(json_mixed["1"], json!("item1"));
        assert_eq!(json_mixed["key"], json!("val"));

        // Разреженная таблица: { [1] = "a", [3] = "c" }
        let sparse: Value = lua
            .load(r#"return { [1] = "a", [3] = "c" }"#)
            .eval()
            .unwrap();
        let json_sparse = lua_to_json(sparse).expect("sparse table to json");
        assert!(json_sparse.is_object(), "Разреженная таблица должна сериализоваться как Object");
        assert_eq!(json_sparse["1"], json!("a"));
        assert_eq!(json_sparse["3"], json!("c"));

        // Чистый массив: { "a", "b", "c" }
        let pure_arr: Value = lua
            .load(r#"return { "a", "b", "c" }"#)
            .eval()
            .unwrap();
        let json_arr = lua_to_json(pure_arr).expect("pure array to json");
        assert_eq!(json_arr, json!(["a", "b", "c"]));
    }

    #[test]
    fn test_state_bus_live_sync_between_two_instances() {
        let _td = crate::test_support::TempDir::new("live_sync_test");
        let tmp_state = _td.join("state.json");

        let daemon_bus = StateBus::with_persistence_path(Some(tmp_state.clone()));
        let cli_bus = StateBus::with_persistence_path(Some(tmp_state.clone()));

        daemon_bus.set("session.daemon_key", json!("from_daemon")).unwrap();
        // Небольшая пауза для гарантированного изменения mtime на файловой системе
        std::thread::sleep(std::time::Duration::from_millis(15));
        cli_bus.set("session.cli_key", json!("from_cli")).unwrap();

        // Оба инстанса должны видеть ключи друг друга без потери данных
        assert_eq!(daemon_bus.get("session.cli_key"), Some(json!("from_cli")));
        assert_eq!(daemon_bus.get("session.daemon_key"), Some(json!("from_daemon")));
        assert_eq!(cli_bus.get("session.daemon_key"), Some(json!("from_daemon")));

        // Если демон записывает ещё один ключ, он не должен затереть cli_key
        std::thread::sleep(std::time::Duration::from_millis(15));
        daemon_bus.set("session.daemon_second", json!(2)).unwrap();
        assert_eq!(cli_bus.get("session.cli_key"), Some(json!("from_cli")));
        assert_eq!(cli_bus.get("session.daemon_second"), Some(json!(2)));
    }

    #[test]
    fn test_set_many_atomic_on_invalid_key() {
        let _td = crate::test_support::TempDir::new("set_many_atomic");
        let tmp = _td.join("state.json");
        let bus = StateBus::with_persistence_path(Some(tmp.clone()));
        let before = bus.persist_count();
        let res = bus.set_many(vec![
            ("session.ok".to_string(), json!(1)),
            ("badkey".to_string(), json!(2)),
        ]);
        assert!(res.is_err());
        assert_eq!(bus.get("session.ok"), None);
        assert_eq!(bus.persist_count(), before);
    }

    #[test]
    fn test_set_many_single_persist_and_cross_instance() {
        let _td = crate::test_support::TempDir::new("set_many_single");
        let tmp = _td.join("state.json");
        let a = StateBus::with_persistence_path(Some(tmp.clone()));
        let b = StateBus::with_persistence_path(Some(tmp.clone()));
        let before = a.persist_count();
        a.set_many(vec![
            ("session.a".to_string(), json!(1)),
            ("session.b".to_string(), json!(2)),
            ("session.c".to_string(), json!(3)),
        ])
        .unwrap();
        assert_eq!(a.persist_count(), before + 1);
        assert_eq!(b.get("session.a"), Some(json!(1)));
        assert_eq!(b.get("session.c"), Some(json!(3)));
    }

    #[test]
    fn test_lua_bus_set_many() {
        let lua = Lua::new();
        lua.globals().set("grime", lua.create_table().unwrap()).unwrap();
        let bus = Arc::new(StateBus::with_persistence_path(None));
        register_state_bus_api(&lua, bus.clone()).unwrap();
        let ok: bool = lua
            .load("return grime.bus.set_many({['pipeline.x']=1, ['pipeline.y']={1,2}})")
            .eval()
            .unwrap();
        assert!(ok);
        assert_eq!(bus.get("pipeline.x"), Some(json!(1)));
        assert_eq!(bus.get("pipeline.y"), Some(json!([1, 2])));
        assert!(lua.load("return grime.bus.set_many({['bad']=1})").eval::<bool>().is_err());
    }
}
