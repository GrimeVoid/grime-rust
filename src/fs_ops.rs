use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Component, Path, PathBuf};
use walkdir::WalkDir;

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

pub fn is_system_or_root_path(path: &Path) -> bool {
    let canonical = match path.canonicalize() {
        Ok(c) => c,
        Err(_) => path.to_path_buf(),
    };

    if canonical == Path::new("/") {
        return true;
    }

    if let Some(home) = dirs::home_dir() {
        if let Ok(home_canon) = home.canonicalize() {
            if canonical == home_canon {
                return true;
            }
        }
    }

    false
}

pub fn delete_safe(path: &Path, missing_ok: bool) -> Result<bool, String> {
    if !path.exists() {
        if missing_ok {
            return Ok(false);
        }
        return Err(format!("Путь не существует: {}", path.display()));
    }

    if is_system_or_root_path(path) {
        return Err(format!(
            "Защита безопасности: попытка удаления системного/домашнего пути '{}'!",
            path.display()
        ));
    }

    // Если это директория
    if path.is_dir() {
        // Снимаем защиту от записи со всех вложенных файлов
        for entry in WalkDir::new(path).into_iter().filter_map(|e| e.ok()) {
            let p = entry.path();
            if let Ok(metadata) = fs::symlink_metadata(p) {
                let mut perms = metadata.permissions();
                if perms.readonly() {
                    perms.set_mode(0o755);
                    let _ = fs::set_permissions(p, perms);
                }
            }
        }
        fs::remove_dir_all(path)
            .map_err(|e| format!("Ошибка удаления каталога '{}': {}", path.display(), e))?;
    } else {
        if let Ok(metadata) = fs::symlink_metadata(path) {
            let mut perms = metadata.permissions();
            if perms.readonly() {
                perms.set_mode(0o644);
                let _ = fs::set_permissions(path, perms);
            }
        }
        fs::remove_file(path)
            .map_err(|e| format!("Ошибка удаления файла '{}': {}", path.display(), e))?;
    }

    Ok(true)
}

pub fn copy_recursive(src: &Path, dst: &Path) -> Result<PathBuf, String> {
    if !src.exists() {
        return Err(format!("Исходный путь не найден: {}", src.display()));
    }

    if src.is_file() {
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

        if entry.file_type().is_dir() {
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
    if !src.exists() {
        return Err(format!("Исходный путь не найден: {}", src.display()));
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
}

