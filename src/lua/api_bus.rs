//! Модуль шины состояний и событий для Lua (grime.bus и grime.events).
//!
//! Интегрирует потокобезопасный Key-Value StateBus и шину событий EventBus.

use mlua::{Lua, Table};
use std::sync::Arc;

use crate::event_bus::{register_event_bus_api, EventBus};
use crate::state_bus::{register_state_bus_api, StateBus};

/// Регистрирует подтаблицы `grime.bus` и `grime.events` в Lua.
pub fn register_bus_api(
    lua: &Lua,
    _grime_tbl: &Table,
    state_bus: Arc<StateBus>,
    event_bus: Arc<EventBus>,
) -> Result<(), mlua::Error> {
    // 1. Регистрация StateBus API (grime.bus)
    register_state_bus_api(lua, state_bus)?;

    // 2. Регистрация EventBus API (grime.events)
    register_event_bus_api(lua, event_bus)?;

    Ok(())
}
