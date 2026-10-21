use std::borrow::Cow;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;
use walkdir::WalkDir;

static HOME_DIR: OnceLock<Option<PathBuf>> = OnceLock::new();
static CANONICAL_HOME_DIR: OnceLock<Option<PathBuf>> = OnceLock::new();

/// Возвращает ссылку на закэшированную домашнюю директорию пользователя.
pub fn get_cached_home_dir() -> Option<&'static Path> {
    HOME_DIR.get_or_init(dirs::home_dir).as_deref()
}

/// Возвращает ссылку на закэшированный канонический путь к домашней директории.
pub fn get_cached_canonical_home() -> Option<&'static Path> {
    CANONICAL_HOME_DIR
        .get_or_init(|| get_cached_home_dir().and_then(|h| h.canonicalize().ok()))
        .as_deref()
}

/// Быстрое развертывание тильды `~` в начале пути без избыточных аллокаций.
pub fn expand_tilde<'a, P: ?Sized + AsRef<Path>>(path: &'a P) -> Cow<'a, Path> {
    let p = path.as_ref();
    if let Ok(stripped) = p.strip_prefix("~") {
        if let Some(home) = get_cached_home_dir() {
            return Cow::Owned(home.join(stripped));
        }
    }
    Cow::Borrowed(p)
}

/// Быстрое развертывание тильды и нормализация пути.
pub fn expand_and_normalize<P: AsRef<Path>>(path: P) -> PathBuf {
    let expanded = expand_tilde(path.as_ref());
    normalize_path(expanded.as_ref())
}

pub fn normalize_path(path: &Path) -> PathBuf {
    let mut components = Vec::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if let Some(Component::Normal(_)) = components.last() {
                    components.pop();
                } else if !components.iter().any(|c| matches!(c, Component::RootDir | Component::Prefix(_))) {
                    components.push(component);
                }
            }
            _ => components.push(component),
        }
    }
    components.into_iter().collect()
}

pub static SYSTEM_PROTECTED_DIRS: &[&str] = &[
    "/etc",
    "/usr",
    "/var",
    "/boot",
    "/opt",
    "/root",
    "/nix",
    "/sys",
    "/proc",
    "/dev",
    "/run",
];

/// Проверяет, является ли путь разрешенным подкаталогом/файлом в XDG_RUNTIME_DIR (например `/run/user/<uid>/grime*`)
fn is_allowed_runtime_path(path: &Path) -> bool {
    let uid = unsafe { libc::getuid() };
    let default_runtime = PathBuf::from(format!("/run/user/{}", uid));
    let runtime_dir = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or(default_runtime);

    let runtime_canon = runtime_dir.canonicalize().unwrap_or(runtime_dir);
    if let Ok(rel) = path.strip_prefix(&runtime_canon) {
        if let Some(Component::Normal(name)) = rel.components().next() {
            return name.to_string_lossy().starts_with("grime");
        }
    }
    false
}

fn check_path_against_system_rules(p: &Path) -> bool {
    if p == Path::new("/") {
        return true;
    }

    if let Some(home) = get_cached_home_dir() {
        if p == home {
            return true;
        }
    }
    if let Some(home_canon) = get_cached_canonical_home() {
        if p == home_canon {
            return true;
        }
    }

    for &sys in SYSTEM_PROTECTED_DIRS {
        let sys_path = Path::new(sys);
        if p == sys_path || p.starts_with(sys_path) {
            if sys == "/run" && is_allowed_runtime_path(p) {
                continue;
            }
            return true;
        }
    }

    false
}

/// Проверяет, является ли путь системным каталогом, корнем `/` или `$HOME`, удаление которых запрещено.
pub fn is_system_or_root_path(path: &Path) -> bool {
    // 1. Проверяем канонический путь
    if let Ok(canonical) = path.canonicalize() {
        if check_path_against_system_rules(&canonical) {
            return true;
        }
    }

    // 2. Проверяем нормализованный абсолютный путь на случай несуществующего пути
    let normalized = if path.is_absolute() {
        normalize_path(path)
    } else if let Ok(cwd) = std::env::current_dir() {
        normalize_path(&cwd.join(path))
    } else {
        normalize_path(path)
    };

    check_path_against_system_rules(&normalized)
}

/// Безопасное удаление файла, директории или символической ссылки.
pub fn delete_safe(path: &Path, missing_ok: bool) -> Result<bool, String> {
    let root_meta = match fs::symlink_metadata(path) {
        Ok(m) => m,
        Err(_) => {
            if missing_ok {
                return Ok(false);
            }
            return Err(format!("Путь не существует: {}", path.display()));
        }
    };

    if is_system_or_root_path(path) {
        return Err(format!(
            "Попытка удаления защищенного системного каталога: '{}'!",
            path.display()
        ));
    }

    if root_meta.file_type().is_symlink() {
        // Символическую ссылку удаляем напрямую БЕЗ изменения прав целевого файла!
        fs::remove_file(path)
            .map_err(|e| format!("Ошибка удаления симлинка '{}': {}", path.display(), e))?;
    } else if root_meta.is_dir() {
        // Снимаем защиту от записи со всех вложенных файлов (исключая симлинки!)
        for entry in WalkDir::new(path).into_iter().filter_map(|e| e.ok()) {
            let p = entry.path();
            if let Ok(metadata) = fs::symlink_metadata(p) {
                // Если файл является символической ссылкой, НЕ вызывать set_permissions!
                if !metadata.file_type().is_symlink() {
                    let mut perms = metadata.permissions();
                    if perms.readonly() {
                        perms.set_mode(if metadata.is_dir() { 0o755 } else { 0o644 });
                        let _ = fs::set_permissions(p, perms);
                    }
                }
            }
        }
        fs::remove_dir_all(path)
            .map_err(|e| format!("Ошибка удаления каталога '{}': {}", path.display(), e))?;
    } else {
        let mut perms = root_meta.permissions();
        if perms.readonly() {
            perms.set_mode(0o644);
            let _ = fs::set_permissions(path, perms);
        }
        fs::remove_file(path)
            .map_err(|e| format!("Ошибка удаления файла '{}': {}", path.display(), e))?;
    }

    Ok(true)
}

pub fn copy_recursive(src: &Path, dst: &Path) -> Result<PathBuf, String> {
    let src_meta = fs::symlink_metadata(src)
        .map_err(|_| format!("Исходный путь не найден: {}", src.display()))?;

    if src_meta.file_type().is_symlink() {
        let link_target = fs::read_link(src)
            .map_err(|e| format!("Ошибка чтения симлинка '{}': {}", src.display(), e))?;
        let dest_link = if dst.is_dir() {
            dst.join(src.file_name().unwrap_or_default())
        } else {
            if let Some(parent) = dst.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            dst.to_path_buf()
        };
        if fs::symlink_metadata(&dest_link).is_ok() {
            let _ = fs::remove_file(&dest_link);
        }
        std::os::unix::fs::symlink(&link_target, &dest_link).map_err(|e| {
            format!(
                "Ошибка создания симлинка '{}' -> '{}': {}",
                dest_link.display(),
                link_target.display(),
                e
            )
        })?;
        return Ok(dest_link);
    }

    if src_meta.is_file() {
        let dest_file = if dst.is_dir() {
            dst.join(src.file_name().unwrap_or_default())
        } else {
            if let Some(parent) = dst.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            dst.to_path_buf()
        };

        fs::copy(src, &dest_file).map_err(|e| {
            format!(
                "Ошибка копирования файла '{}' в '{}': {}",
                src.display(),
                dest_file.display(),
                e
            )
        })?;
        return Ok(dest_file);
    }

    // Рекурсивное копирование каталога
    fs::create_dir_all(dst).map_err(|e| e.to_string())?;

    for entry in WalkDir::new(src).into_iter().filter_map(|e| e.ok()) {
        let entry_path = entry.path();
        if entry_path == src {
            continue;
        }

        let rel_path = match entry_path.strip_prefix(src) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let target_path = dst.join(rel_path);

        if entry.file_type().is_symlink() {
            if let Some(parent) = target_path.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            let link_target = fs::read_link(entry_path).map_err(|e| {
                format!(
                    "Ошибка чтения симлинка '{}': {}",
                    entry_path.display(),
                    e
                )
            })?;
            if fs::symlink_metadata(&target_path).is_ok() {
                let _ = fs::remove_file(&target_path);
            }
            std::os::unix::fs::symlink(&link_target, &target_path).map_err(|e| {
                format!(
                    "Ошибка создания симлинка '{}' -> '{}': {}",
                    target_path.display(),
                    link_target.display(),
                    e
                )
            })?;
        } else if entry.file_type().is_dir() {
            fs::create_dir_all(&target_path).map_err(|e| e.to_string())?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target_path.parent() {
                fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            fs::copy(entry_path, &target_path).map_err(|e| {
                format!(
                    "Ошибка копирования '{}' в '{}': {}",
                    entry_path.display(),
                    target_path.display(),
                    e
                )
            })?;
        }
    }

    Ok(dst.to_path_buf())
}

pub fn move_safe(src: &Path, dst: &Path) -> Result<PathBuf, String> {
    if fs::symlink_metadata(src).is_err() {
        return Err(format!("Исходный путь не найден: {}", src.display()));
    }

    if is_system_or_root_path(src) {
        return Err(format!(
            "Попытка перемещения защищенного системного каталога: '{}'!",
            src.display()
        ));
    }

    if is_system_or_root_path(dst) {
        return Err(format!(
            "Попытка перезаписи защищенного системного каталога при перемещении: '{}'!",
            dst.display()
        ));
    }

    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    // Попытка прямого fs::rename
    if fs::rename(src, dst).is_ok() {
        return Ok(dst.to_path_buf());
    }

    // Fallback: копирование с удалением оригинала
    copy_recursive(src, dst)?;
    delete_safe(src, true)?;

    Ok(dst.to_path_buf())
}

pub fn get_latest_mtime(target: &Path) -> f64 {
    if !target.exists() {
        return 0.0;
    }

    if target.is_file() {
        if let Ok(metadata) = fs::metadata(target) {
            if let Ok(modified) = metadata.modified() {
                if let Ok(duration) = modified.duration_since(std::time::UNIX_EPOCH) {
                    return duration.as_secs_f64();
                }
            }
        }
        return 0.0;
    }

    let mut latest: f64 = 0.0;
    for entry in WalkDir::new(target).into_iter().filter_map(|e| e.ok()) {
        if entry.file_type().is_file() {
            if let Ok(metadata) = entry.metadata() {
                if let Ok(modified) = metadata.modified() {
                    if let Ok(duration) = modified.duration_since(std::time::UNIX_EPOCH) {
                        let secs = duration.as_secs_f64();
                        if secs > latest {
                            latest = secs;
                        }
                    }
                }
            }
        }
    }

    latest
}

pub fn is_newer(src: &Path, target: &Path) -> bool {
    if !target.exists() {
        return true;
    }

    let src_mtime = get_latest_mtime(src);
    let target_mtime = get_latest_mtime(target);

    src_mtime > target_mtime
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_path() {
        assert_eq!(
            normalize_path(Path::new("/foo//bar///baz")),
            PathBuf::from("/foo/bar/baz")
        );
        assert_eq!(
            normalize_path(Path::new("/foo/bar/../baz")),
            PathBuf::from("/foo/baz")
        );
        assert_eq!(
            normalize_path(Path::new("/foo/bar/./baz")),
            PathBuf::from("/foo/bar/baz")
        );
        assert_eq!(
            normalize_path(Path::new("/home/user/projects//rust/app")),
            PathBuf::from("/home/user/projects/rust/app")
        );
    }

    #[test]
    fn test_expand_tilde() {
        if let Some(home) = get_cached_home_dir() {
            assert_eq!(expand_tilde(Path::new("~")).as_ref(), home);
            assert_eq!(expand_tilde(Path::new("~/test")).as_ref(), home.join("test"));
        }
        assert_eq!(expand_tilde(Path::new("/abs/path")).as_ref(), Path::new("/abs/path"));
        assert_eq!(expand_tilde(Path::new("rel/path")).as_ref(), Path::new("rel/path"));
    }

    #[test]
    fn test_is_system_or_root_path_and_delete_protection() {
        // Проверка корневых системных путей
        assert!(is_system_or_root_path(Path::new("/")));
        assert!(is_system_or_root_path(Path::new("/etc")));
        assert!(is_system_or_root_path(Path::new("/etc/passwd")));
        assert!(is_system_or_root_path(Path::new("/usr")));
        assert!(is_system_or_root_path(Path::new("/usr/bin")));
        assert!(is_system_or_root_path(Path::new("/var")));
        assert!(is_system_or_root_path(Path::new("/boot")));
        assert!(is_system_or_root_path(Path::new("/opt")));
        assert!(is_system_or_root_path(Path::new("/root")));
        assert!(is_system_or_root_path(Path::new("/nix")));
        assert!(is_system_or_root_path(Path::new("/sys")));
        assert!(is_system_or_root_path(Path::new("/proc")));
        assert!(is_system_or_root_path(Path::new("/dev")));
        assert!(is_system_or_root_path(Path::new("/run")));

        if let Some(home) = get_cached_home_dir() {
            assert!(is_system_or_root_path(home));
        }

        // Попытка удаления системного каталога через delete_safe
        let res_etc = delete_safe(Path::new("/etc"), false);
        assert!(res_etc.is_err());
        assert!(res_etc.unwrap_err().contains("Попытка удаления защищенного системного каталога"));

        let res_usr = delete_safe(Path::new("/usr"), false);
        assert!(res_usr.is_err());
        assert!(res_usr.unwrap_err().contains("Попытка удаления защищенного системного каталога"));

        // Проверка резолва через симлинк на системный каталог
        let test_dir = std::env::temp_dir().join(format!("grime_sys_protect_test_{}", std::process::id()));
        let _ = fs::create_dir_all(&test_dir);
        let link_to_etc = test_dir.join("link_to_etc");
        let _ = std::os::unix::fs::symlink("/etc", &link_to_etc);

        let res_link = delete_safe(&link_to_etc, false);
        assert!(res_link.is_err(), "Симлинк, ведущий в /etc, должен быть заблокирован от удаления через delete_safe");
        assert!(res_link.unwrap_err().contains("Попытка удаления защищенного системного каталога"));

        // Обычная поддиректория удаляется успешно
        let normal_dir = test_dir.join("normal_dir");
        fs::create_dir_all(&normal_dir).unwrap();
        assert!(delete_safe(&normal_dir, false).is_ok());

        let _ = fs::remove_file(&link_to_etc);
        let _ = fs::remove_dir_all(&test_dir);
    }

    #[test]
    fn test_symlink_deletion_without_modifying_target_permissions() {
        let test_root = std::env::temp_dir().join(format!("grime_symlink_test_{}", std::process::id()));
        let _ = fs::create_dir_all(&test_root);

        // 1. Создаем целевой файл с правами readonly (0o444)
        let target_file = test_root.join("target_file.txt");
        fs::write(&target_file, "read-only payload").unwrap();
        let mut perms = fs::metadata(&target_file).unwrap().permissions();
        perms.set_mode(0o444);
        fs::set_permissions(&target_file, perms).unwrap();

        assert_eq!(
            fs::metadata(&target_file).unwrap().permissions().mode() & 0o777,
            0o444,
            "Целевой файл должен быть readonly"
        );

        // 2. Тестируем прямое удаление симлинка
        let single_symlink = test_root.join("single_symlink");
        std::os::unix::fs::symlink(&target_file, &single_symlink).unwrap();

        let del_res = delete_safe(&single_symlink, false);
        assert!(del_res.is_ok(), "delete_safe должен успешно удалить одиночный симлинк: {:?}", del_res);
        assert!(fs::symlink_metadata(&single_symlink).is_err(), "Симлинк должен быть удален");
        assert!(target_file.exists(), "Целевой файл не должен быть удален");
        assert_eq!(
            fs::metadata(&target_file).unwrap().permissions().mode() & 0o777,
            0o444,
            "Права целевого файла не должны измениться после удаления одиночного симлинка"
        );

        // 3. Тестируем удаление каталога, содержащего симлинк на readonly файл
        let nested_dir = test_root.join("nested_dir");
        fs::create_dir_all(&nested_dir).unwrap();
        let symlink_in_dir = nested_dir.join("link_inside");
        std::os::unix::fs::symlink(&target_file, &symlink_in_dir).unwrap();

        let del_dir_res = delete_safe(&nested_dir, false);
        assert!(del_dir_res.is_ok(), "delete_safe должен успешно удалить каталог с симлинком");
        assert!(!nested_dir.exists(), "Каталог должен быть удален");
        assert!(target_file.exists(), "Целевой файл должен остаться");
        assert_eq!(
            fs::metadata(&target_file).unwrap().permissions().mode() & 0o777,
            0o444,
            "Права целевого файла не должны измениться после рекурсивного удаления каталога с симлинком"
        );

        // Cleanup
        let mut cleanup_perms = fs::metadata(&target_file).unwrap().permissions();
        cleanup_perms.set_mode(0o644);
        let _ = fs::set_permissions(&target_file, cleanup_perms);
        let _ = fs::remove_file(&target_file);
        let _ = fs::remove_dir_all(&test_root);
    }

    #[test]
    fn test_move_safe_protection_and_copy_recursive_symlinks() {
        let test_root = std::env::temp_dir().join(format!("grime_move_copy_test_{}", std::process::id()));
        let _ = fs::create_dir_all(&test_root);

        let dummy_src = test_root.join("dummy_src.txt");
        fs::write(&dummy_src, "hello").unwrap();

        // Попытка переместить /etc или перезаписать /etc должна блокироваться
        assert!(move_safe(Path::new("/etc"), &test_root.join("etc_moved")).is_err());
        assert!(move_safe(&dummy_src, Path::new("/etc/passwd")).is_err());

        // Копирование директории с симлинком
        let src_dir = test_root.join("src_with_link");
        fs::create_dir_all(&src_dir).unwrap();
        let real_file = src_dir.join("real.txt");
        fs::write(&real_file, "symlinked content").unwrap();
        let sym_file = src_dir.join("sym.txt");
        std::os::unix::fs::symlink("real.txt", &sym_file).unwrap();

        let dst_dir = test_root.join("dst_with_link");
        copy_recursive(&src_dir, &dst_dir).expect("copy_recursive with symlink");

        let copied_sym = dst_dir.join("sym.txt");
        let meta = fs::symlink_metadata(&copied_sym).expect("copied symlink metadata");
        assert!(meta.file_type().is_symlink(), "Скопированный файл должен оставаться симлинком");
        assert_eq!(fs::read_link(&copied_sym).unwrap(), PathBuf::from("real.txt"));
        assert_eq!(fs::read_to_string(&copied_sym).unwrap(), "symlinked content");

        let _ = fs::remove_dir_all(&test_root);
    }
}


