//! Дисковый кэш байткода Lua-модулей: `<кэш grime>/bc/<hash(путь)>.luac`.
//!
//! Один файл на путь модуля; внутри заголовок с отпечатком исходника (mtime_ns, size) и версией
//! сборки. Любое несоответствие, порча или несовпадение формата байткода — тихая перекомпиляция.
//! Байткод хранится с отладочной информацией (strip=false), чтобы в сообщениях об ошибках модулей
//! оставались имя файла и номера строк.

use std::path::{Path, PathBuf};

use crate::cache;

const MAGIC: &[u8; 6] = b"GRBC1\0";
/// Версия сборки, влияющая на формат байткода (Lua 5.4 в составе mlua 0.10).
const BUILD_TAG: &str = concat!(env!("CARGO_PKG_VERSION"), "/mlua0.10/lua54");

/// Стабильный 64-битный хэш FNV-1a (имя файла кэша не должно зависеть от версии rustc).
fn fnv1a(data: &[u8]) -> u64 {
    data.iter().fold(0xcbf2_9ce4_8422_2325, |h, b| (h ^ u64::from(*b)).wrapping_mul(0x0100_0000_01b3))
}

/// Путь файла кэша для модуля.
pub fn cache_path(module_path: &Path) -> Option<PathBuf> {
    use std::os::unix::ffi::OsStrExt;
    let h = fnv1a(module_path.as_os_str().as_bytes());
    Some(cache::grime_cache_dir()?.join("bc").join(format!("{:016x}.luac", h)))
}

fn header(mtime_ns: i64, size: u64) -> Vec<u8> {
    let mut h = Vec::with_capacity(64);
    h.extend_from_slice(MAGIC);
    h.extend_from_slice(&mtime_ns.to_le_bytes());
    h.extend_from_slice(&size.to_le_bytes());
    h.extend_from_slice(&(BUILD_TAG.len() as u16).to_le_bytes());
    h.extend_from_slice(BUILD_TAG.as_bytes());
    h
}

/// Упаковывает байткод вместе с заголовком-отпечатком.
pub fn encode(mtime_ns: i64, size: u64, bytecode: &[u8]) -> Vec<u8> {
    let mut out = header(mtime_ns, size);
    out.extend_from_slice(bytecode);
    out
}

/// Возвращает байткод, если отпечаток исходника и версия сборки совпадают.
pub fn decode(mtime_ns: i64, size: u64, data: &[u8]) -> Option<&[u8]> {
    let h = header(mtime_ns, size);
    data.strip_prefix(h.as_slice())
}

/// Читает кэшированный байткод модуля (проверка владельца/прав и отпечатка).
pub fn load(module_path: &Path, mtime_ns: i64, size: u64) -> Option<Vec<u8>> {
    let data = cache::read_private(&cache_path(module_path)?)?;
    decode(mtime_ns, size, &data).map(<[u8]>::to_vec)
}

/// Сохраняет байткод модуля (best-effort: ошибки записи игнорируются).
pub fn store(module_path: &Path, mtime_ns: i64, size: u64, bytecode: &[u8]) {
    if let Some(p) = cache_path(module_path) {
        let _ = cache::write_private_atomic(&p, &encode(mtime_ns, size, bytecode));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_header_roundtrip_and_mismatch() {
        let enc = encode(5, 10, b"BYTES");
        assert_eq!(decode(5, 10, &enc), Some(&b"BYTES"[..]));
        assert_eq!(decode(6, 10, &enc), None);
        assert_eq!(decode(5, 11, &enc), None);
        assert_eq!(decode(5, 10, "мусор".as_bytes()), None);
        assert_eq!(decode(5, 10, &enc[..4]), None);
    }

    #[test]
    fn test_fnv_stable() {
        assert_eq!(fnv1a(b""), 0xcbf2_9ce4_8422_2325);
        assert_ne!(fnv1a(b"/a/b.lua"), fnv1a(b"/a/c.lua"));
    }

    #[test]
    fn test_dump_load_roundtrip() {
        let lua = mlua::Lua::new();
        let f = lua
            .load("local a = ... ; return (a or 40) + 2")
            .set_name("@x.lua")
            .into_function()
            .unwrap();
        let bc = f.dump(false);
        let g = lua.load(&bc[..]).set_mode(mlua::ChunkMode::Binary).into_function().unwrap();
        assert_eq!(g.call::<i64>(()).unwrap(), 42);
        // Порченый байткод не паникует, а возвращает ошибку
        assert!(lua.load(&bc[..bc.len() / 2]).set_mode(mlua::ChunkMode::Binary).into_function().is_err());
    }
}
