use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct GrimeConfig {
    pub paths: HashMap<String, String>,
    pub config_file: PathBuf,
}

impl GrimeConfig {
    pub fn load_or_default(custom_path: Option<&Path>) -> Self {
        let conf_path = match custom_path {
            Some(p) => p.to_path_buf(),
            None => Self::discover_config_path(),
        };

        let mut config = GrimeConfig {
            paths: HashMap::new(),
            config_file: conf_path.clone(),
        };

        if conf_path.exists() {
            config.read_file(&conf_path);
        } else {
            // Проверяем наличие example файла
            let example_path = conf_path.with_extension("conf.example");
            if example_path.exists() {
                if let Ok(content) = fs::read_to_string(&example_path) {
                    let _ = fs::create_dir_all(conf_path.parent().unwrap_or(&conf_path));
                    let _ = fs::write(&conf_path, &content);
                    config.read_file(&conf_path);
                    config.ensure_defaults();
                    return config;
                }
            }
            config.generate_default(&conf_path);
        }

        config.ensure_defaults();
        config
    }

    /// Получение дефолтных путей Grime:
    /// - config: $HOME/.config/grime
    /// - projects: $HOME/Projects
    /// - templates: $HOME/.config/grime/templates
    /// - apps: $HOME/.config/grime/apps
    pub fn default_paths() -> HashMap<String, String> {
        let home = crate::fs_ops::get_cached_home_dir()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from("/tmp"));
        let mut map = HashMap::new();

        let cfg_dir = home.join(".config").join("grime");
        map.insert(
            "config".to_string(),
            crate::fs_ops::normalize_path(&cfg_dir).to_string_lossy().to_string(),
        );

        let projects_dir = home.join("Projects");
        map.insert(
            "projects".to_string(),
            crate::fs_ops::normalize_path(&projects_dir).to_string_lossy().to_string(),
        );

        let templates_dir = home.join(".config").join("grime").join("templates");
        map.insert(
            "templates".to_string(),
            crate::fs_ops::normalize_path(&templates_dir).to_string_lossy().to_string(),
        );

        let apps_dir = home.join(".config").join("grime").join("apps");
        map.insert(
            "apps".to_string(),
            crate::fs_ops::normalize_path(&apps_dir).to_string_lossy().to_string(),
        );

        map
    }

    /// Дополнение отсутствующих путей дефолтными значениями
    pub fn ensure_defaults(&mut self) {
        let defaults = Self::default_paths();
        for (key, default_val) in defaults {
            self.paths.entry(key).or_insert(default_val);
        }
    }

    fn discover_config_path() -> PathBuf {
        // 1. PROJECT_CONFIG_PATH
        if let Ok(env_path) = std::env::var("PROJECT_CONFIG_PATH") {
            let p = PathBuf::from(env_path);
            if p.exists() {
                return p;
            }
        }

        // 2. config/gproj.conf в текущей или родительской директории
        let local_conf = Path::new("config/gproj.conf");
        if local_conf.exists() {
            return local_conf.to_path_buf();
        }

        // 3. Директория относительно бинарника
        if let Ok(exe) = std::env::current_exe() {
            if let Some(parent) = exe.parent() {
                let candidate = parent.join("config/gproj.conf");
                if candidate.exists() {
                    return candidate;
                }
                if let Some(parent2) = parent.parent() {
                    let candidate2 = parent2.join("config/gproj.conf");
                    if candidate2.exists() {
                        return candidate2;
                    }
                }
            }
        }

        // 4. Домашняя папка ~/.config/grime/gproj.conf
        if let Some(home) = crate::fs_ops::get_cached_home_dir() {
            let home_conf = home.join(".config").join("grime").join("gproj.conf");
            if home_conf.exists() {
                return home_conf;
            }
            // По умолчанию пишем в домашнюю папку, если нет локального
            return home_conf;
        }

        PathBuf::from("config/gproj.conf")
    }

    pub fn read_file(&mut self, path: &Path) {
        if let Ok(content) = fs::read_to_string(path) {
            let base_dir = path.parent().unwrap_or(path);
            for line in content.lines() {
                let line = line.trim();
                if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                    continue;
                }
                if let Some((key, val)) = line.split_once('=') {
                    let key = key.trim().to_string();
                    let val = val.trim().trim_matches('"').trim_matches('\'').to_string();

                    if val.eq_ignore_ascii_case("auto") {
                        self.paths.insert(key, "auto".to_string());
                    } else {
                        let trimmed = val.trim_end_matches('/');
                        let expanded = match shellexpand::full(trimmed) {
                            Ok(exp) => exp.to_string(),
                            Err(_) => shellexpand::tilde(trimmed).to_string(),
                        };
                        let p = PathBuf::from(&expanded);
                        let resolved = if p.is_absolute() {
                            crate::fs_ops::normalize_path(&p)
                        } else {
                            crate::fs_ops::normalize_path(&base_dir.join(p))
                        };
                        self.paths.insert(key, resolved.to_string_lossy().to_string());
                    }
                }
            }
        }
        self.ensure_defaults();
    }

    fn generate_default(&mut self, path: &Path) {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        let default_config = crate::fs_ops::normalize_path(&home.join(".config").join("grime"));
        let default_projects = crate::fs_ops::normalize_path(&home.join("Projects"));
        let default_templates = crate::fs_ops::normalize_path(&home.join(".config").join("grime").join("templates"));
        let default_apps = crate::fs_ops::normalize_path(&home.join(".config").join("grime").join("apps"));

        let default_content = format!(
            "# Конфигурация путей GrimeProject\n\
             config={}\n\
             projects={}\n\
             templates={}\n\
             apps={}\n\
             aider=auto\n\
             distrobox_default=fedora-box\n",
            default_config.display(),
            default_projects.display(),
            default_templates.display(),
            default_apps.display()
        );

        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(path, default_content);
        self.read_file(path);
    }

    pub fn get_path(&self, key: &str) -> Option<PathBuf> {
        self.paths.get(key).and_then(|val| {
            if val.eq_ignore_ascii_case("auto") {
                None
            } else {
                Some(PathBuf::from(val))
            }
        })
    }

    pub fn get(&self, key: &str, default: Option<&str>) -> String {
        self.paths
            .get(key)
            .cloned()
            .unwrap_or_else(|| default.unwrap_or("").to_string())
    }

    pub fn get_opt(&self, key: &str, default: Option<&str>) -> Option<String> {
        self.paths
            .get(key)
            .cloned()
            .or_else(|| default.map(|d| d.to_string()))
    }

    pub fn config_dir(&self) -> PathBuf {
        self.get_path("config")
            .unwrap_or_else(|| {
                self.config_file
                    .parent()
                    .map(|p| crate::fs_ops::normalize_path(p))
                    .unwrap_or_else(|| PathBuf::from("."))
            })
    }

    pub fn projects_root(&self) -> PathBuf {
        self.get_path("projects")
            .unwrap_or_else(|| {
                let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
                crate::fs_ops::normalize_path(&home.join("Projects"))
            })
    }

    pub fn templates_root(&self) -> PathBuf {
        self.get_path("templates")
            .unwrap_or_else(|| {
                let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
                crate::fs_ops::normalize_path(&home.join(".config").join("grime").join("templates"))
            })
    }

    pub fn apps_root(&self) -> PathBuf {
        self.get_path("apps")
            .unwrap_or_else(|| {
                let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
                crate::fs_ops::normalize_path(&home.join(".config").join("grime").join("apps"))
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_paths_exist() {
        let defaults = GrimeConfig::default_paths();
        assert!(defaults.contains_key("config"));
        assert!(defaults.contains_key("projects"));
        assert!(defaults.contains_key("templates"));
        assert!(defaults.contains_key("apps"));
    }

    #[test]
    fn test_custom_paths_and_defaults_fallback() {
        let mut config = GrimeConfig {
            paths: HashMap::new(),
            config_file: PathBuf::from("/tmp/fake_gproj.conf"),
        };

        // Зададим кастомный путь для projects и произвольный ключ
        config.paths.insert("projects".to_string(), "/custom/projects".to_string());
        config.paths.insert("my_custom_cache".to_string(), "/var/cache/my_app".to_string());

        config.ensure_defaults();

        // projects должен остаться кастомным
        assert_eq!(config.get("projects", None), "/custom/projects");
        // my_custom_cache должен сохраниться
        assert_eq!(config.get("my_custom_cache", None), "/var/cache/my_app");
        // templates, apps, config должны дополниться дефолтами
        assert!(!config.get("templates", None).is_empty());
        assert!(!config.get("apps", None).is_empty());
        assert!(!config.get("config", None).is_empty());
    }
}
