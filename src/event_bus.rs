use mlua::{Function, Lua, Value};
use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::broadcast;

/// Событие шины событий Grime (Event Bus).
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct GrimeEvent {
    pub name: String,
    pub payload: JsonValue,
    pub timestamp: u64,
}

impl GrimeEvent {
    pub fn new(name: impl Into<String>, payload: JsonValue) -> Self {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64;

        Self {
            name: name.into(),
            payload,
            timestamp,
        }
    }
}

/// Потокобезопасный брокер событий на базе `tokio::sync::broadcast`.
#[derive(Clone, Debug)]
pub struct EventBus {
    sender: broadcast::Sender<GrimeEvent>,
}

impl Default for EventBus {
    fn default() -> Self {
        Self::new(1024)
    }
}

impl EventBus {
    pub fn new(capacity: usize) -> Self {
        let (sender, _) = broadcast::channel(capacity);
        Self { sender }
    }

    /// Публикация события в брокер.
    pub fn emit(&self, name: impl Into<String>, payload: JsonValue) -> usize {
        let event = GrimeEvent::new(name, payload);
        self.sender.send(event).unwrap_or(0)
    }

    /// Подписка на поток событий (для внешних Tokio задач / мониторинга).
    pub fn subscribe(&self) -> broadcast::Receiver<GrimeEvent> {
        self.sender.subscribe()
    }
}

/// Регистрация `grime.events` в среде Lua.
///
/// Предоставляет API:
/// - `grime.events.on("event_name", callback)` - подписка на событие
/// - `grime.events.emit("event_name", payload)` - публикация события
pub fn register_event_bus_api(lua: &Lua, event_bus: Arc<EventBus>) -> Result<(), mlua::Error> {
    let globals = lua.globals();

    // Создаем внутреннее хранилище слушателей в _grime_listeners
    let listeners_table = lua.create_table()?;
    globals.set("_grime_event_listeners", listeners_table)?;

    let grime: mlua::Table = globals.get("grime")?;
    let events_tbl = lua.create_table()?;

    // grime.events.on(name, callback)
    events_tbl.set(
        "on",
        lua.create_function(|lua, (event_name, callback): (String, Function)| {
            let globals = lua.globals();
            let listeners: mlua::Table = globals.get("_grime_event_listeners")?;

            let list: mlua::Table = match listeners.get::<mlua::Table>(event_name.as_str()) {
                Ok(tbl) => tbl,
                Err(_) => {
                    let new_tbl = lua.create_table()?;
                    listeners.set(event_name.as_str(), new_tbl.clone())?;
                    new_tbl
                }
            };

            let len = list.raw_len();
            list.set(len + 1, callback)?;
            Ok(true)
        })?,
    )?;

    // grime.events.emit(name, payload)
    let bus_clone = event_bus.clone();
    events_tbl.set(
        "emit",
        lua.create_function(move |lua, (event_name, payload): (String, Option<Value>)| {
            let json_payload = match payload {
                Some(p) => crate::state_bus::lua_to_json(p)?,
                None => JsonValue::Null,
            };

            // Отправляем в broadcast канал Rust
            bus_clone.emit(&event_name, json_payload.clone());

            // Диспетчеризируем слушателям в текущей Lua VM
            let globals = lua.globals();
            if let Ok(listeners) = globals.get::<mlua::Table>("_grime_event_listeners") {
                let call_list = |tbl: mlua::Table| -> Result<(), mlua::Error> {
                    for cb in tbl.sequence_values::<Function>() {
                        if let Ok(func) = cb {
                            let lua_arg = crate::state_bus::json_to_lua(lua, &json_payload)?;
                            let _ = func.call::<()>(lua_arg);
                        }
                    }
                    Ok(())
                };

                if let Ok(exact) = listeners.get::<mlua::Table>(event_name.as_str()) {
                    let _ = call_list(exact);
                }
                if let Ok(wildcard) = listeners.get::<mlua::Table>("*") {
                    let _ = call_list(wildcard);
                }
            }

            Ok(true)
        })?,
    )?;

    grime.set("events", events_tbl)?;
    Ok(())
}

/// Вызов Lua-слушателей при событии из Rust.
pub fn dispatch_event_to_lua(lua: &Lua, event_name: &str, payload: &JsonValue) -> Result<(), mlua::Error> {
    let globals = lua.globals();
    if let Ok(listeners) = globals.get::<mlua::Table>("_grime_event_listeners") {
        let call_list = |tbl: mlua::Table| -> Result<(), mlua::Error> {
            for cb in tbl.sequence_values::<Function>() {
                if let Ok(func) = cb {
                    let lua_arg = crate::state_bus::json_to_lua(lua, payload)?;
                    let _ = func.call::<()>(lua_arg);
                }
            }
            Ok(())
        };

        if let Ok(exact) = listeners.get::<mlua::Table>(event_name) {
            let _ = call_list(exact);
        }
        if let Ok(wildcard) = listeners.get::<mlua::Table>("*") {
            let _ = call_list(wildcard);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn test_broadcast_event_bus() {
        let bus = EventBus::new(16);
        let mut rx = bus.subscribe();

        bus.emit("pipeline.start", json!({"id": 1}));
        let ev = rx.try_recv().expect("Event received");
        assert_eq!(ev.name, "pipeline.start");
        assert_eq!(ev.payload["id"], 1);
    }
}
