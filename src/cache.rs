//! Приватный дисковый кэш Grime (`$XDG_CACHE_HOME/grime` или `~/.cache/grime`).
//!
//! Используется индексом модулей и кэшем байткода. Каталог создаётся с правами 0700,
//! файлы — 0600 и записываются атомарно (tmp + rename). При чтении проверяется, что файл
//! обычный, принадлежит текущему пользователю и недоступен другим: любое несоответствие
//! трактуется как отсутствие кэша (тихий пересбор).

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// Время модификации в наносекундах от эпохи (с отрицательными значениями для дат до 1970).
pub fn mtime_ns(meta: &fs::Metadata) -> i64 {
    meta.mtime().saturating_mul(1_000_000_000).saturating_add(meta.mtime_nsec())
}

/// `SystemTime` из наносекунд эпохи (для обратной совместимости полей с временем).
pub fn system_time_from_ns(ns: i64) -> SystemTime {
    if ns >= 0 {
        SystemTime::UNIX_EPOCH + std::time::Duration::from_nanos(ns as u64)
    } else {
        SystemTime::UNIX_EPOCH - std::time::Duration::from_nanos(ns.unsigned_abs())
    }
}

/// Изолированный корень (тесты, встраивание): при заданном кэш живёт в `<корень>/cache/grime`,
/// эфемерные ресурсы — в `<корень>/run/grime/eph`; переменные окружения и реальный `~/.cache`
/// не затрагиваются. Это явный параметр процесса (не `set_var`), потокобезопасный.
static ISOLATED_ROOT: std::sync::RwLock<Option<PathBuf>> = std::sync::RwLock::new(None);

/// Задаёт (или снимает, `None`) изолированный корень кэша и эфемерных ресурсов.
pub fn set_isolated_root(dir: Option<PathBuf>) {
    *ISOLATED_ROOT.write().unwrap_or_else(|e| e.into_inner()) = dir;
}

/// Действующий изолированный корень. В unit-тестах самой библиотеки (`cfg(test)`) без явной
/// установки используется временный каталог процесса, удаляемый при выходе.
pub fn isolated_root() -> Option<PathBuf> {
    if let Some(d) = ISOLATED_ROOT.read().unwrap_or_else(|e| e.into_inner()).clone() {
        return Some(d);
    }
    #[cfg(test)]
    let fallback = Some(test_root());
    #[cfg(not(test))]
    let fallback = None;
    fallback
}

#[cfg(test)]
fn test_root() -> PathBuf {
    use std::sync::OnceLock;
    static ROOT: OnceLock<PathBuf> = OnceLock::new();
    extern "C" fn remove_at_exit() {
        if let Some(p) = ROOT.get() {
            let _ = std::fs::remove_dir_all(p);
        }
    }
    ROOT.get_or_init(|| {
        // SAFETY: регистрируется extern "C" функция без аргументов
        unsafe { libc::atexit(remove_at_exit) };
        std::env::temp_dir().join(format!("grime_unit_root_{}", std::process::id()))
    })
    .clone()
}

/// Корневой каталог кэша Grime: `$XDG_CACHE_HOME/grime` (абсолютный путь) либо `~/.cache/grime`.
pub fn grime_cache_dir() -> Option<PathBuf> {
    if let Some(root) = isolated_root() {
        return Some(root.join("cache").join("grime"));
    }
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| crate::fs_ops::get_cached_home_dir().map(|h| h.join(".cache")))?;
    Some(base.join("grime"))
}

/// Создаёт каталог (и недостающих предков) с правами 0700.
pub fn ensure_private_dir(dir: &Path) -> std::io::Result<()> {
    DirBuilder::new().recursive(true).mode(0o700).create(dir)
}

/// Читает приватный файл кэша: обычный файл (без симлинков), владелец — текущий пользователь,
/// группа и остальные не имеют прав. Иначе `None`.
pub fn read_private(path: &Path) -> Option<Vec<u8>> {
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    // SAFETY: geteuid не имеет предусловий и всегда успешен
    let euid = unsafe { libc::geteuid() };
    if !meta.is_file() || meta.uid() != euid || meta.mode() & 0o077 != 0 {
        return None;
    }
    let mut buf = Vec::with_capacity(meta.len() as usize);
    file.read_to_end(&mut buf).ok()?;
    Some(buf)
}

/// Атомарно записывает приватный файл (0600): временный файл рядом + `rename`.
pub fn write_private_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let dir = path
        .parent()
        .ok_or_else(|| std::io::Error::other("путь кэша без родительского каталога"))?;
    ensure_private_dir(dir)?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("cache");
    let tmp = dir.join(format!(".{}.{}.tmp", name, std::process::id()));
    let _ = fs::remove_file(&tmp);
    let result = (|| {
        let mut f: File = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(&tmp)?;
        f.write_all(data)?;
        fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> crate::test_support::TempDir {
        crate::test_support::TempDir::new(&format!("cache_{}", tag))
    }

    #[test]
    fn test_atomic_write_and_private_read() {
        let d = tmp("rw");
        let f = d.join("sub").join("x.bin");
        write_private_atomic(&f, b"abc").unwrap();
        assert_eq!(read_private(&f).as_deref(), Some(&b"abc"[..]));
        assert_eq!(fs::metadata(&f).unwrap().mode() & 0o777, 0o600);
        assert_eq!(fs::metadata(d.join("sub")).unwrap().mode() & 0o777, 0o700);
        write_private_atomic(&f, b"zzzz").unwrap();
        assert_eq!(read_private(&f).as_deref(), Some(&b"zzzz"[..]));
    }

    #[test]
    fn test_read_rejects_open_permissions_and_symlink() {
        let d = tmp("perm");
        let f = d.join("y.bin");
        write_private_atomic(&f, b"1").unwrap();
        fs::set_permissions(&f, std::os::unix::fs::PermissionsExt::from_mode(0o644)).unwrap();
        assert!(read_private(&f).is_none());
        fs::set_permissions(&f, std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
        let link = d.join("l.bin");
        std::os::unix::fs::symlink(&f, &link).unwrap();
        assert!(read_private(&link).is_none());
        assert!(read_private(&d.join("нет")).is_none());
    }

    #[test]
    fn test_mtime_roundtrip() {
        let t = system_time_from_ns(1_700_000_000_123_456_789);
        let d = t.duration_since(SystemTime::UNIX_EPOCH).unwrap();
        assert_eq!(d.as_nanos(), 1_700_000_000_123_456_789);
    }
}
