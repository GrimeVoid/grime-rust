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
                    return config;
                }
            }
            config.generate_default(&conf_path);
        }

        config
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
        if let Some(home) = dirs::home_dir() {
            let home_conf = home.join(".config").join("grime").join("gproj.conf");
            if home_conf.exists() {
                return home_conf;
            }
            // По умолчанию пишем в домашнюю папку, если нет локального
            return home_conf;
        }

        PathBuf::from("config/gproj.conf")
    }

    fn read_file(&mut self, path: &Path) {
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
                        let expanded = shellexpand::tilde(trimmed).to_string();
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
    }

    fn generate_default(&mut self, path: &Path) {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
        let default_templates = home.join("Projects").join("templates");
        let default_projects = home.join("Projects");

        let default_content = format!(
            "# Конфигурация путей GrimeProject\n\
             templates={}\n\
             projects={}\n\
             aider=auto\n\
             distrobox_default=fedora-box\n",
            default_templates.display(),
            default_projects.display()
        );

        if let Some(parent) = path.parent() {
            let _ = fs::create_dir_all(parent);
        }
        let _ = fs::write(path, default_content);

        self.paths.insert("templates".to_string(), default_templates.to_string_lossy().to_string());
        self.paths.insert("projects".to_string(), default_projects.to_string_lossy().to_string());
        self.paths.insert("aider".to_string(), "auto".to_string());
        self.paths.insert("distrobox_default".to_string(), "fedora-box".to_string());
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

    pub fn projects_root(&self) -> PathBuf {
        let p = self.get_path("projects")
            .or_else(|| dirs::home_dir().map(|h| h.join("Projects")))
            .unwrap_or_else(|| PathBuf::from("./projects"));
        crate::fs_ops::normalize_path(&p)
    }

    pub fn templates_root(&self) -> PathBuf {
        let p = self.get_path("templates")
            .or_else(|| dirs::home_dir().map(|h| h.join("Projects").join("templates")))
            .unwrap_or_else(|| PathBuf::from("./templates"));
        crate::fs_ops::normalize_path(&p)
    }
}
