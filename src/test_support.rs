//! Общие тестовые хелперы (компилируются только под `cfg(test)`).

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};

static COUNTER: AtomicUsize = AtomicUsize::new(0);

/// RAII-каталог в `temp_dir()`: при `Drop` удаляется рекурсивно (включая `.lock`-файлы).
pub struct TempDir {
    path: PathBuf,
}

impl TempDir {
    /// Создаёт пустой каталог с уникальным именем `grime_<tag>_<pid>_<n>`.
    pub fn new(tag: &str) -> Self {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("grime_{}_{}_{}", tag, std::process::id(), n));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("не удалось создать временный каталог");
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn join(&self, p: impl AsRef<Path>) -> PathBuf {
        self.path.join(p)
    }
}

impl std::ops::Deref for TempDir {
    type Target = Path;
    fn deref(&self) -> &Path {
        &self.path
    }
}

impl AsRef<Path> for TempDir {
    fn as_ref(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
