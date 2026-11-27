//! Сервис эфемерных ресурсов: временные каталоги и файлы, которые исчезают вместе с сессией.
//!
//! Корень: `$XDG_RUNTIME_DIR/grime/eph/` (0700); если `XDG_RUNTIME_DIR` нет —
//! `<кэш grime>/run/<uid>/eph`. У каждой сессии (оркестратора) свой подкаталог
//! `<pid>-<session_id>` с файлом `.lock`, на который процесс держит эксклюзивный `flock`,
//! пока сессия жива. Подкаталог создаётся лениво — при первом обращении, поэтому сессии без
//! эфемерных ресурсов ничего не стоят и ничего не оставляют.
//!
//! Очистка:
//! - конец `run_pipeline` (успех, ошибка, отмена, паника) — [`EphemeralGuard`];
//! - уничтожение сессии (`Drop`), в том числе detached-задач демона;
//! - подметание осиротевших ([`sweep_default`]): при старте процесса и периодически в демоне.
//!   Каталог считается осиротевшим, если неблокирующий `flock` на его `.lock` удался.
//!   Защита: только каталоги текущего uid, не симлинки, старше [`SWEEP_MIN_AGE`]; удаление
//!   не следует по симлинкам и никогда не выходит за корень.
//!
//! Как пользоваться из Lua-модулей (вместо `/tmp` и `os.tmpname`):
//! ```lua
//! local dir  = grime.ephemeral.dir("build")          -- путь нового каталога (0700)
//! local file = grime.ephemeral.file("текст", ".sh")  -- путь файла (0600), запись атомарна
//! ```
//! Освобождать вручную не нужно: всё удаляется ядром в конце конвейера.

use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use crate::cache;

/// Минимальный возраст каталога для подметания (защита от гонки с создающейся сессией).
pub const SWEEP_MIN_AGE: Duration = Duration::from_secs(5);
/// Период подметания в демоне.
pub const SWEEP_INTERVAL: Duration = Duration::from_secs(600);

const LOCK_NAME: &str = ".lock";

fn euid() -> u32 {
    // SAFETY: geteuid не имеет предусловий и всегда успешен
    unsafe { libc::geteuid() }
}

/// Корень эфемерных ресурсов по умолчанию (без создания).
pub fn default_root() -> Option<PathBuf> {
    if let Some(iso) = cache::isolated_root() {
        return Some(iso.join("run").join("grime").join("eph"));
    }
    if let Some(rt) = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).filter(|p| p.is_absolute()) {
        return Some(rt.join("grime").join("eph"));
    }
    Some(cache::grime_cache_dir()?.join("run").join(euid().to_string()).join("eph"))
}

/// Создаёт корень (0700) и проверяет, что это каталог текущего пользователя, а не симлинк.
fn ensure_root(root: &Path) -> io::Result<()> {
    cache::ensure_private_dir(root)?;
    let md = fs::symlink_metadata(root)?;
    if !md.is_dir() || md.uid() != euid() {
        return Err(io::Error::other("корень эфемерных ресурсов небезопасен (не каталог или чужой владелец)"));
    }
    Ok(())
}

/// Неблокирующий эксклюзивный flock; `true` — замок взят.
fn try_flock(file: &File) -> bool {
    // SAFETY: валидный fd, flock без побочных эффектов на память
    unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) == 0 }
}

fn sanitize(s: &str) -> String {
    s.chars()
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.') { c } else { '_' })
        .collect()
}

struct Active {
    dir: PathBuf,
    /// Удерживаемый flock (закрытие файла снимает замок).
    _lock: File,
}

/// Эфемерные ресурсы одной сессии.
pub struct EphemeralSession {
    root: Option<PathBuf>,
    name: String,
    counter: AtomicU64,
    state: Mutex<Option<Active>>,
}

impl EphemeralSession {
    /// Сессия с корнем по умолчанию.
    pub fn new(session_id: &str) -> Self {
        Self::with_root(default_root(), session_id)
    }

    /// Сессия с явным корнем (тесты).
    pub fn with_root(root: Option<PathBuf>, session_id: &str) -> Self {
        Self {
            root,
            name: sanitize(&format!("{}-{}", std::process::id(), session_id)),
            counter: AtomicU64::new(0),
            state: Mutex::new(None),
        }
    }

    /// Каталог сессии, если уже создан.
    pub fn session_dir(&self) -> Option<PathBuf> {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|a| a.dir.clone())
    }

    /// Создаёт (при необходимости) каталог сессии с замком и возвращает его путь.
    fn ensure_active(&self, state: &mut Option<Active>) -> io::Result<PathBuf> {
        if let Some(a) = state.as_ref() {
            return Ok(a.dir.clone());
        }
        let root = self.root.as_ref().ok_or_else(|| io::Error::other("корень эфемерных ресурсов недоступен"))?;
        ensure_root(root)?;
        let dir = root.join(&self.name);
        DirBuilder::new().mode(0o700).create(&dir)?;
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(dir.join(LOCK_NAME))?;
        if !try_flock(&lock) {
            return Err(io::Error::other("не удалось взять замок сессии"));
        }
        *state = Some(Active { dir: dir.clone(), _lock: lock });
        Ok(dir)
    }

    fn next_name(&self, prefix: &str, suffix: &str) -> String {
        format!("{}{}{}", sanitize(prefix), self.counter.fetch_add(1, Ordering::Relaxed), sanitize(suffix))
    }

    /// Новый пустой каталог (0700) внутри каталога сессии.
    pub fn dir(&self, prefix: Option<&str>) -> io::Result<PathBuf> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let base = self.ensure_active(&mut state)?;
        let path = base.join(self.next_name(prefix.unwrap_or("d"), ""));
        DirBuilder::new().mode(0o700).create(&path)?;
        Ok(path)
    }

    /// Новый файл (0600) с содержимым `content` (пустой, если `None`); запись атомарна (tmp + rename).
    pub fn file(&self, content: Option<&[u8]>, suffix: Option<&str>) -> io::Result<PathBuf> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        let base = self.ensure_active(&mut state)?;
        let path = base.join(self.next_name("f", suffix.unwrap_or("")));
        let tmp = base.join(format!(".{}.tmp", path.file_name().and_then(|n| n.to_str()).unwrap_or("f")));
        let res = (|| {
            let mut f = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(&tmp)?;
            if let Some(c) = content {
                f.write_all(c)?;
            }
            fs::rename(&tmp, &path)
        })();
        if let Err(e) = res {
            let _ = fs::remove_file(&tmp);
            return Err(e);
        }
        Ok(path)
    }

    /// Удаляет каталог сессии со всем содержимым и снимает замок. Идемпотентно;
    /// следующее обращение создаст сессионный каталог заново.
    pub fn cleanup(&self) {
        let active = self.state.lock().unwrap_or_else(|e| e.into_inner()).take();
        if let Some(a) = active {
            remove_tree(&a.dir);
        }
    }

    /// RAII-страж: `cleanup()` при выходе из области видимости (в том числе при панике).
    pub fn guard(self: &Arc<Self>) -> EphemeralGuard {
        EphemeralGuard(self.clone())
    }
}

impl Drop for EphemeralSession {
    fn drop(&mut self) {
        self.cleanup();
    }
}

/// Страж очистки сессии (см. [`EphemeralSession::guard`]).
pub struct EphemeralGuard(Arc<EphemeralSession>);

impl Drop for EphemeralGuard {
    fn drop(&mut self) {
        self.0.cleanup();
    }
}

/// Рекурсивное удаление каталога без следования симлинкам (симлинки удаляются как ссылки).
fn remove_tree(dir: &Path) {
    if fs::symlink_metadata(dir).is_ok_and(|m| m.is_dir()) {
        let _ = fs::remove_dir_all(dir);
    }
}

/// Подметает осиротевшие сессии в `root`; возвращает число удалённых каталогов.
pub fn sweep_orphans(root: &Path, min_age: Duration) -> usize {
    let Ok(rd) = fs::read_dir(root) else {
        return 0;
    };
    // Корень должен быть настоящим каталогом текущего пользователя
    match fs::symlink_metadata(root) {
        Ok(m) if m.is_dir() && m.uid() == euid() => {}
        _ => return 0,
    }
    let mut removed = 0;
    for entry in rd.flatten() {
        let path = entry.path();
        let Ok(md) = fs::symlink_metadata(&path) else {
            continue;
        };
        if !md.is_dir() || md.uid() != euid() {
            continue;
        }
        let age = md.modified().ok().and_then(|t| SystemTime::now().duration_since(t).ok());
        if age.is_none_or(|a| a < min_age) {
            continue;
        }
        // Замок взят — сессия мертва. Держим его на время удаления (защита от повторного захвата)
        let lock = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path.join(LOCK_NAME));
        match lock {
            Ok(f) if !try_flock(&f) => continue,
            Ok(f) => {
                remove_tree(&path);
                drop(f);
                removed += 1;
            }
            // Нет `.lock` у каталога старше порога: сессия не дожила до создания замка
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                remove_tree(&path);
                removed += 1;
            }
            Err(_) => {}
        }
    }
    removed
}

/// Подметание корня по умолчанию (дёшево: при отсутствии корня — один `readdir`).
pub fn sweep_default() -> usize {
    default_root().map_or(0, |r| sweep_orphans(&r, SWEEP_MIN_AGE))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn tmp_root(tag: &str) -> (crate::test_support::TempDir, PathBuf) {
        let d = crate::test_support::TempDir::new(&format!("eph_{}", tag));
        let root = d.join("eph");
        (d, root)
    }

    fn mode(p: &Path) -> u32 {
        fs::metadata(p).unwrap().permissions().mode() & 0o777
    }

    #[test]
    fn права_и_удаление() {
        let (_td, root) = tmp_root("perm");
        let s = Arc::new(EphemeralSession::with_root(Some(root.clone()), "s1"));
        assert!(s.session_dir().is_none(), "ленивое создание");
        let guard = s.guard();
        let d = s.dir(Some("build")).unwrap();
        let f = s.file(Some(b"hello"), Some(".sh")).unwrap();
        let empty = s.file(None, None).unwrap();
        assert_eq!(mode(&d), 0o700);
        assert_eq!(mode(&f), 0o600);
        assert_eq!(fs::read(&f).unwrap(), b"hello");
        assert!(f.to_string_lossy().ends_with(".sh"));
        assert_eq!(fs::read(&empty).unwrap().len(), 0);
        assert_eq!(mode(&root), 0o700);
        let sd = s.session_dir().unwrap();
        assert!(sd.join(LOCK_NAME).exists());
        drop(guard);
        assert!(!sd.exists() && !d.exists() && !f.exists());
        // После очистки сессия работает снова
        assert!(s.dir(None).unwrap().exists());
        drop(s);
        assert_eq!(fs::read_dir(&root).unwrap().count(), 0);
    }

    #[test]
    fn осиротевший_подметается_живой_нет() {
        let (_td, root) = tmp_root("sweep");
        let live = EphemeralSession::with_root(Some(root.clone()), "live");
        let live_dir = live.dir(None).unwrap();
        // Осиротевший: каталог с .lock без удержания
        let orphan = root.join("1-dead");
        fs::create_dir(&orphan).unwrap();
        fs::write(orphan.join(LOCK_NAME), "").unwrap();
        fs::write(orphan.join("data"), "x").unwrap();
        // Без .lock
        let nolock = root.join("2-nolock");
        fs::create_dir(&nolock).unwrap();
        // Слишком молодой не трогается
        assert_eq!(sweep_orphans(&root, Duration::from_secs(3600)), 0);
        assert!(orphan.exists());
        assert_eq!(sweep_orphans(&root, Duration::ZERO), 2);
        assert!(!orphan.exists() && !nolock.exists());
        assert!(live_dir.exists(), "живая сессия не подметается");
        drop(live);
    }

    #[test]
    fn симлинк_внутри_не_ведёт_наружу() {
        let (_td, root) = tmp_root("link");
        let outside = root.parent().unwrap().join("outside");
        fs::create_dir_all(&outside).unwrap();
        fs::write(outside.join("keep"), "1").unwrap();
        let orphan = root.join("9-dead");
        fs::create_dir_all(&orphan).unwrap();
        fs::write(orphan.join(LOCK_NAME), "").unwrap();
        std::os::unix::fs::symlink(&outside, orphan.join("lnk")).unwrap();
        // Симлинк на верхнем уровне корня игнорируется
        std::os::unix::fs::symlink(&outside, root.join("toplink")).unwrap();
        assert_eq!(sweep_orphans(&root, Duration::ZERO), 1);
        assert!(!orphan.exists());
        assert!(outside.join("keep").exists());
        assert!(root.join("toplink").exists());
        // То же для штатной очистки сессии
        let s = EphemeralSession::with_root(Some(root.clone()), "l");
        let d = s.dir(None).unwrap();
        std::os::unix::fs::symlink(&outside, d.join("lnk")).unwrap();
        s.cleanup();
        assert!(outside.join("keep").exists());
    }

    #[test]
    fn параллельные_обращения() {
        let (_td, root) = tmp_root("par");
        let s = Arc::new(EphemeralSession::with_root(Some(root.clone()), "p"));
        let hs: Vec<_> = (0..8)
            .map(|_| {
                let s = s.clone();
                std::thread::spawn(move || (0..10).map(|_| s.file(Some(b"x"), None).unwrap()).collect::<Vec<_>>())
            })
            .collect();
        let mut all: Vec<PathBuf> = hs.into_iter().flat_map(|h| h.join().unwrap()).collect();
        all.sort();
        all.dedup();
        assert_eq!(all.len(), 80);
        drop(s);
    }
}
