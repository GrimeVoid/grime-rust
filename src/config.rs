use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

/// Конфигурация Grime: пары `ключ=значение` из `gproj.conf`.
///
/// В ядре фиксированные умолчания есть только у `config` (каталог конфигурации) и `modules`.
/// Все остальные именованные пути (projects, templates, apps и т.д.) объявляют сами модули
/// через аннотации `--@grime path.<имя>: значение` (см. [`crate::modules`]).
#[derive(Debug, Clone)]
pub struct GrimeConfig {
    pub paths: HashMap<String, String>,
    pub config_file: PathBuf,
}

/// Похоже ли значение на путь (начинается с `/`, `~`, `$`, `./`, `../` либо содержит `/`).
/// Только такие значения раскрываются и нормализуются как пути.
pub fn looks_like_path(val: &str) -> bool {
    val.starts_with('/')
        || val.starts_with('~')
        || val.starts_with('$')
        || val.starts_with("./")
        || val.starts_with("../")
        || val.contains('/')
}

/// Раскрывает значение как путь (`~`, `$VAR`, нормализация), если оно похоже на путь.
/// Относительные пути приклеиваются к `base_dir` (если задан). Прочие значения возвращаются как есть.
pub fn expand_path_value(val: &str, base_dir: Option<&Path>) -> String {
    if !looks_like_path(val) {
        return val.to_string();
    }
    let stripped = val.trim_end_matches('/');
    let trimmed = if stripped.is_empty() && val.starts_with('/') {
        "/"
    } else {
        stripped
    };
    let expanded = match shellexpand::full(trimmed) {
        Ok(exp) => exp.to_string(),
        Err(_) => shellexpand::tilde(trimmed).to_string(),
    };
    let p = PathBuf::from(&expanded);
    let resolved = match (p.is_absolute(), base_dir) {
        (false, Some(base)) => crate::fs_ops::normalize_path(&base.join(p)),
        _ => crate::fs_ops::normalize_path(&p),
    };
    resolved.to_string_lossy().to_string()
}

/// Каталог конфигурации по XDG: `$XDG_CONFIG_HOME/grime` или `~/.config/grime`.
fn xdg_config_dir(
    env_get: &dyn Fn(&str) -> Option<String>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(xdg) = env_get("XDG_CONFIG_HOME").filter(|v| !v.trim().is_empty()) {
        return Some(PathBuf::from(xdg).join("grime"));
    }
    home.map(|h| h.join(".config").join("grime"))
}

/// Упорядоченный список кандидатов файла конфигурации.
/// Порядок: GRIME_CONFIG → PROJECT_CONFIG_PATH (устаревший) → XDG → `<exe>/../share/grime/gproj.conf`.
/// Поиск относительно текущей рабочей директории намеренно отсутствует.
pub fn config_candidates(
    env_get: &dyn Fn(&str) -> Option<String>,
    home: Option<&Path>,
    exe: Option<&Path>,
) -> Vec<PathBuf> {
    let mut list = Vec::new();
    for var in ["GRIME_CONFIG", "PROJECT_CONFIG_PATH"] {
        if let Some(v) = env_get(var).filter(|v| !v.trim().is_empty()) {
            list.push(PathBuf::from(expand_path_value(v.trim(), None)));
        }
    }
    if let Some(dir) = xdg_config_dir(env_get, home) {
        list.push(dir.join("gproj.conf"));
    }
    if let Some(parent) = exe.and_then(|e| e.parent()) {
        list.push(parent.join("../share/grime/gproj.conf"));
    }
    list
}

/// Упорядоченный список кандидатов каталогов модулей.
/// Порядок: `override_dir` / GRIME_MODULES → `modules=` из конфига → `<config_dir>/modules`
/// → `<exe>/../share/grime/modules` → `<exe>/modules`.
pub fn module_dir_candidates(
    env_modules: Option<&str>,
    config_modules: Option<PathBuf>,
    config_dir: &Path,
    exe: Option<&Path>,
) -> Vec<PathBuf> {
    let mut list: Vec<PathBuf> = Vec::new();
    let mut push = |p: PathBuf| {
        if !list.contains(&p) {
            list.push(p);
        }
    };
    if let Some(v) = env_modules.filter(|v| !v.trim().is_empty()) {
        push(PathBuf::from(expand_path_value(v.trim(), None)));
    }
    if let Some(p) = config_modules {
        push(p);
    }
    push(config_dir.join("modules"));
    if let Some(parent) = exe.and_then(|e| e.parent()) {
        push(parent.join("../share/grime/modules"));
        push(parent.join("modules"));
    }
    list
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
            let example_path = conf_path.with_extension("conf.example");
            if example_path.exists() {
                config.read_file(&example_path);
            }
        }

        config.ensure_defaults();
        config
    }

    /// Фиксированные умолчания ядра: только `config` и `modules`.
    /// `config` — каталог файла конфигурации (для стандартного расположения это XDG-каталог grime).
    pub fn default_paths(config_file: &Path) -> HashMap<String, String> {
        let cfg_dir = config_file
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .map(crate::fs_ops::normalize_path)
            .or_else(|| {
                xdg_config_dir(&|k| std::env::var(k).ok(), crate::fs_ops::get_cached_home_dir())
            })
            .unwrap_or_else(|| PathBuf::from("."));
        let mut map = HashMap::new();
        map.insert(
            "modules".to_string(),
            cfg_dir.join("modules").to_string_lossy().to_string(),
        );
        map.insert("config".to_string(), cfg_dir.to_string_lossy().to_string());
        map
    }

    /// Дополнение отсутствующих путей `config`/`modules` значениями по умолчанию.
    pub fn ensure_defaults(&mut self) {
        for (key, default_val) in Self::default_paths(&self.config_file) {
            self.paths.entry(key).or_insert(default_val);
        }
    }

    fn discover_config_path() -> PathBuf {
        let env_get = |k: &str| std::env::var(k).ok();
        let exe = std::env::current_exe().ok();
        let candidates = config_candidates(&env_get, crate::fs_ops::get_cached_home_dir(), exe.as_deref());
        // Первый существующий кандидат; иначе — стандартное XDG-расположение (может не существовать)
        let xdg_default = xdg_config_dir(&env_get, crate::fs_ops::get_cached_home_dir())
            .map(|d| d.join("gproj.conf"));
        candidates
            .iter()
            .find(|c| c.exists())
            .cloned()
            .or(xdg_default)
            .unwrap_or_else(|| PathBuf::from("gproj.conf"))
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
                    // Значения, не похожие на путь (fedora-box, 300, auto, claude), остаются как есть
                    self.paths.insert(key, expand_path_value(&val, Some(base_dir)));
                }
            }
        }
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
        self.get_path("config").unwrap_or_else(|| {
            self.config_file
                .parent()
                .map(crate::fs_ops::normalize_path)
                .unwrap_or_else(|| PathBuf::from("."))
        })
    }

    pub fn modules_dir(&self) -> PathBuf {
        self.get_path("modules")
            .unwrap_or_else(|| self.config_dir().join("modules"))
    }

    /// Единый упорядоченный список директорий-кандидатов для поиска Lua-модулей.
    /// Явное переопределение (`override_dir`) полностью заменяет поиск; иначе учитывается GRIME_MODULES.
    pub fn candidate_module_dirs(&self, override_dir: Option<PathBuf>) -> Vec<PathBuf> {
        if let Some(dir) = override_dir {
            return vec![dir];
        }
        let env_modules = std::env::var("GRIME_MODULES").ok();
        let exe = std::env::current_exe().ok();
        let config_modules = self.get_path("modules");
        module_dir_candidates(
            env_modules.as_deref(),
            config_modules,
            &self.config_dir(),
            exe.as_deref(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_conf(name: &str, content: &str) -> (crate::test_support::TempDir, PathBuf) {
        let dir = crate::test_support::TempDir::new(&format!("cfg_{}", name));
        let p = dir.join("gproj.conf");
        fs::write(&p, content).unwrap();
        (dir, p)
    }

    #[test]
    fn test_default_paths_only_core_keys() {
        let defaults = GrimeConfig::default_paths(Path::new("/tmp/x/gproj.conf"));
        assert_eq!(defaults.len(), 2);
        assert_eq!(defaults["config"], "/tmp/x");
        assert_eq!(defaults["modules"], "/tmp/x/modules");
        assert!(!defaults.contains_key("projects"));
    }

    #[test]
    fn test_non_path_values_not_expanded_as_paths() {
        let (_dir, conf) = tmp_conf(
            "nonpath",
            "distrobox_default = fedora-box\ntimeout=300\nmode=auto\nai=claude\nprojects = ~/Work/\nrel = sub/dir\n",
        );
        let cfg = GrimeConfig::load_or_default(Some(&conf));
        assert_eq!(cfg.get("distrobox_default", None), "fedora-box");
        assert_eq!(cfg.get("timeout", None), "300");
        assert_eq!(cfg.get("mode", None), "auto");
        assert_eq!(cfg.get("ai", None), "claude");
        let home = crate::fs_ops::get_cached_home_dir().unwrap();
        assert_eq!(cfg.get("projects", None), home.join("Work").to_string_lossy());
        let base = conf.parent().unwrap();
        assert_eq!(cfg.get("rel", None), base.join("sub/dir").to_string_lossy());
    }

    #[test]
    fn test_looks_like_path() {
        for p in ["/a", "~", "~/x", "$HOME/x", "./a", "../a", "a/b"] {
            assert!(looks_like_path(p), "{}", p);
        }
        for p in ["fedora-box", "300", "auto", "claude", ""] {
            assert!(!looks_like_path(p), "{}", p);
        }
    }

    #[test]
    fn test_no_cwd_search_in_candidates() {
        let env = |k: &str| match k {
            "XDG_CONFIG_HOME" => Some("/xdg".to_string()),
            _ => None,
        };
        let cands = config_candidates(&env, Some(Path::new("/home/u")), Some(Path::new("/opt/g/bin/grime")));
        assert!(cands.iter().all(|c| c.is_absolute()), "{:?}", cands);
        assert_eq!(cands[0], PathBuf::from("/xdg/grime/gproj.conf"));
        assert!(cands.iter().all(|c| !c.starts_with("config")));

        let mods = module_dir_candidates(None, None, Path::new("/xdg/grime"), Some(Path::new("/opt/g/bin/grime")));
        assert!(mods.iter().all(|c| c.is_absolute()), "{:?}", mods);
        assert!(!mods.iter().any(|c| c == Path::new("modules")));
        assert!(!mods.iter().any(|c| c.to_string_lossy().contains("dotfiles")));
        assert_eq!(mods[0], PathBuf::from("/xdg/grime/modules"));
    }

    #[test]
    fn test_env_priority_for_configs_and_modules() {
        let env = |k: &str| match k {
            "GRIME_CONFIG" => Some("/c/new.conf".to_string()),
            "PROJECT_CONFIG_PATH" => Some("/c/old.conf".to_string()),
            _ => None,
        };
        let cands = config_candidates(&env, Some(Path::new("/home/u")), None);
        assert_eq!(cands[0], PathBuf::from("/c/new.conf"));
        assert_eq!(cands[1], PathBuf::from("/c/old.conf"));
        assert_eq!(cands[2], PathBuf::from("/home/u/.config/grime/gproj.conf"));

        let mods = module_dir_candidates(
            Some("/dev/mods"),
            Some(PathBuf::from("/cfg/mods")),
            Path::new("/home/u/.config/grime"),
            None,
        );
        assert_eq!(
            mods,
            vec![
                PathBuf::from("/dev/mods"),
                PathBuf::from("/cfg/mods"),
                PathBuf::from("/home/u/.config/grime/modules"),
            ]
        );
    }

    #[test]
    fn test_override_replaces_search() {
        let cfg = GrimeConfig::load_or_default(Some(Path::new("/nonexistent_grime/gproj.conf")));
        assert_eq!(
            cfg.candidate_module_dirs(Some(PathBuf::from("/x/mods"))),
            vec![PathBuf::from("/x/mods")]
        );
    }
}
