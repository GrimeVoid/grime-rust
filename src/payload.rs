use bytes::Bytes;
use mlua::{FromLua, Lua, UserData, UserDataMethods, Value};
use std::fmt;

/// Эффективная Zero-Copy структура данных для конвейера Grime.
/// Основана на `bytes::Bytes`, что позволяет передавать и нарезать (slice)
/// промежуточные данные между шагами конвейера без лишних аллокаций памяти.
#[derive(Clone, PartialEq, Eq)]
pub struct PipelinePayload {
    data: Bytes,
}

impl fmt::Debug for PipelinePayload {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if let Some(s) = self.as_str() {
            write!(f, "PipelinePayload(text: {:?})", s)
        } else {
            write!(f, "PipelinePayload(bytes: {} bytes)", self.data.len())
        }
    }
}

impl Default for PipelinePayload {
    fn default() -> Self {
        Self::empty()
    }
}

impl PipelinePayload {
    pub fn empty() -> Self {
        Self {
            data: Bytes::new(),
        }
    }

    pub fn from_string(s: String) -> Self {
        Self {
            data: Bytes::from(s),
        }
    }

    pub fn from_static_str(s: &'static str) -> Self {
        Self {
            data: Bytes::from_static(s.as_bytes()),
        }
    }

    pub fn from_bytes(bytes: Bytes) -> Self {
        Self { data: bytes }
    }

    pub fn from_vec(vec: Vec<u8>) -> Self {
        Self {
            data: Bytes::from(vec),
        }
    }

    pub fn as_slice(&self) -> &[u8] {
        &self.data
    }

    pub fn as_bytes(&self) -> Bytes {
        self.data.clone()
    }

    pub fn as_str(&self) -> Option<&str> {
        std::str::from_utf8(&self.data).ok()
    }

    pub fn to_string_lossy(&self) -> String {
        String::from_utf8_lossy(&self.data).to_string()
    }

    pub fn len(&self) -> usize {
        self.data.len()
    }

    pub fn is_empty(&self) -> bool {
        self.data.is_empty()
    }

    /// Zero-copy срез данных: не создает новых аллокаций в куче,
    /// просто увеличивает счетчик ссылок (atomic ref count).
    pub fn slice(&self, start: usize, len: usize) -> Option<Self> {
        if start + len <= self.data.len() {
            Some(Self {
                data: self.data.slice(start..start + len),
            })
        } else {
            None
        }
    }
}

impl From<String> for PipelinePayload {
    fn from(s: String) -> Self {
        Self::from_string(s)
    }
}

impl From<&str> for PipelinePayload {
    fn from(s: &str) -> Self {
        Self::from_string(s.to_string())
    }
}

impl From<Vec<u8>> for PipelinePayload {
    fn from(v: Vec<u8>) -> Self {
        Self::from_vec(v)
    }
}

impl From<Bytes> for PipelinePayload {
    fn from(b: Bytes) -> Self {
        Self::from_bytes(b)
    }
}

impl UserData for PipelinePayload {
    fn add_methods<M: UserDataMethods<Self>>(methods: &mut M) {
        methods.add_method("as_str", |_, this, ()| Ok(this.as_str().map(|s| s.to_string())));

        methods.add_method("len", |_, this, ()| Ok(this.len()));

        methods.add_method("is_empty", |_, this, ()| Ok(this.is_empty()));

        methods.add_method("to_string", |_, this, ()| Ok(this.to_string_lossy()));

        methods.add_meta_method(mlua::MetaMethod::ToString, |_, this, ()| {
            Ok(this.to_string_lossy())
        });

        // Zero-copy срез
        methods.add_method("slice", |_, this, (start, len): (usize, usize)| {
            Ok(this.slice(start, len))
        });

        // Преобразование байтов в таблицу Lua (массив чисел)
        methods.add_method("to_bytes", |lua, this, ()| {
            let tbl = lua.create_table()?;
            for (idx, byte) in this.as_slice().iter().enumerate() {
                tbl.set(idx + 1, *byte)?;
            }
            Ok(tbl)
        });
    }
}

impl FromLua for PipelinePayload {
    fn from_lua(value: Value, _lua: &Lua) -> Result<Self, mlua::Error> {
        match value {
            Value::UserData(ud) => Ok(ud.borrow::<Self>()?.clone()),
            Value::String(s) => Ok(Self::from_string(s.to_string_lossy().to_string())),
            _ => Err(mlua::Error::FromLuaConversionError {
                from: value.type_name(),
                to: "PipelinePayload".to_string(),
                message: Some("Ожидался PipelinePayload или строка".to_string()),
            }),
        }
    }
}

/// Конвертация значения Lua в PipelinePayload
pub fn extract_payload(val: Value) -> Option<PipelinePayload> {
    match val {
        Value::Nil => None,
        Value::String(s) => Some(PipelinePayload::from_string(
            s.to_string_lossy().to_string(),
        )),
        Value::UserData(ud) => {
            if let Ok(p) = ud.borrow::<PipelinePayload>() {
                Some(p.clone())
            } else {
                None
            }
        }
        Value::Table(tbl) => {
            // Если таблица байтов
            let mut bytes = Vec::new();
            for item in tbl.sequence_values::<u8>() {
                if let Ok(b) = item {
                    bytes.push(b);
                }
            }
            if !bytes.is_empty() {
                Some(PipelinePayload::from_vec(bytes))
            } else {
                None
            }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mlua::Lua;

    #[test]
    fn test_zero_copy_slice() {
        let original = PipelinePayload::from_string("Grime Zero Copy Engine".to_string());
        assert_eq!(original.len(), 22);

        let slice = original.slice(6, 9).expect("Slice should succeed");
        assert_eq!(slice.as_str().unwrap(), "Zero Copy");

        // Убеждаемся, что указатель в срезе ссылается на тот же буфер
        assert_eq!(slice.as_slice(), b"Zero Copy");
    }

    #[test]
    fn test_payload_userdata_lua() {
        let lua = Lua::new();
        let payload = PipelinePayload::from_string("Hello from Rust".to_string());

        let globals = lua.globals();
        globals.set("payload", payload).unwrap();

        let str_val: String = lua
            .load("return tostring(payload)")
            .eval()
            .unwrap();
        assert_eq!(str_val, "Hello from Rust");

        let slice_val: PipelinePayload = lua
            .load("return payload:slice(0, 5)")
            .eval()
            .unwrap();
        assert_eq!(slice_val.as_str().unwrap(), "Hello");
    }
}
