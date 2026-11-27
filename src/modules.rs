//! Реестр Lua-модулей Grime.
//!
//! Ядро не знает имён модулей, их алиасов, описаний и путей по умолчанию: всё это
//! объявляется самими модулями аннотациями в шапке `.lua`-файла (Lua при чтении не исполняется):
//!
//! ```text
//! --@grime description: Список модулей
//! --@grime alias: ls, modules
//! --@grime boundary: true          -- модуль-рубеж смены среды (шаг, поглощающий подконвейер)
//! --@grime wraps: pipeline         -- модуль экспортирует хук wrap_pipeline(args, rest_argv)
//! --@grime chain: passthrough      -- `:` перед неизвестным модулем остаётся аргументом шага
//! --@grime default: true          -- модуль по умолчанию для legacy-формы `grime --args ...`
//! --@grime requires: module:git, bin:gcc, nix:gcc, module:ai?   -- зависимости (аннотация повторяема;
//!                                  -- без префикса = module; `?` в конце имени = необязательная)
//! --@grime path.projects: ~/Projects
//! ```

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use serde::{Deserialize, Serialize};

use crate::cache;
use crate::config::{expand_path_value, GrimeConfig};

/// Порог схожести для нечёткого разрешения имён модулей.
pub const MODULE_FUZZY_THRESHOLD: f64 = 0.75;

/// Вид зависимости модуля (аннотация `requires:`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DepKind {
    /// Другой Lua-модуль Grime (`module:git`).
    Module,
    /// Исполняемый файл в `$PATH` (`bin:gcc`).
    Bin,
    /// Nix-пакет (`nix:gcc`): ядро лишь отдаёт его Lua, материализует модуль `nix`.
    Nix,
}

impl DepKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DepKind::Module => "module",
            DepKind::Bin => "bin",
            DepKind::Nix => "nix",
        }
    }
}

/// Одна зависимость модуля.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dep {
    pub kind: DepKind,
    pub name: String,
    /// Необязательная зависимость (`?` в конце имени): её отсутствие — лишь предупреждение.
    pub optional: bool,
}

/// Разбирает значение аннотации `requires:` (элементы через запятую). Имена модулей — в нижнем регистре.
pub fn parse_requires(value: &str) -> Vec<Dep> {
    value
        .split(',')
        .filter_map(|item| {
            let item = item.trim();
            let (kind, rest) = match item.split_once(':') {
                Some(("module", r)) => (DepKind::Module, r),
                Some(("bin", r)) => (DepKind::Bin, r),
                Some(("nix", r)) => (DepKind::Nix, r),
                _ => (DepKind::Module, item),
            };
            let rest = rest.trim();
            let (name, optional) = match rest.strip_suffix('?') {
                Some(n) => (n.trim(), true),
                None => (rest, false),
            };
            if name.is_empty() {
                return None;
            }
            let name = if kind == DepKind::Module { name.to_lowercase() } else { name.to_string() };
            Some(Dep { kind, name, optional })
        })
        .collect()
}

/// Метаданные модуля, прочитанные из аннотаций `--@grime`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModuleMeta {
    pub name: String,
    pub path: PathBuf,
    pub description: String,
    pub aliases: Vec<String>,
    pub boundary: bool,
    pub wraps: Option<String>,
    pub chain: Option<String>,
    /// Модуль по умолчанию для legacy-формы `grime --args ...` без имени модуля.
    pub default: bool,
    /// Значения по умолчанию именованных путей (`path.<имя>`), уже раскрытые (`~`, `$HOME`).
    pub paths: BTreeMap<String, String>,
    /// Зависимости из аннотаций `requires:` (в порядке объявления).
    pub requires: Vec<Dep>,
}

fn parse_bool(v: &str) -> bool {
    matches!(v.trim().to_lowercase().as_str(), "true" | "yes" | "1" | "on")
}

impl ModuleMeta {
    /// Разбирает шапку исходника: строки `--@grime key: value` до первой строки,
    /// не являющейся комментарием/пустой. Блочные комментарии `--[[ ... ]]` пропускаются.
    pub fn from_source(name: &str, path: &Path, source: &str) -> Self {
        let mut meta = ModuleMeta {
            name: name.to_string(),
            path: path.to_path_buf(),
            ..Default::default()
        };
        let mut in_block = false;

        for raw in source.lines() {
            let line = raw.trim();
            if in_block {
                if line.contains("]]") {
                    in_block = false;
                }
                continue;
            }
            if line.is_empty() || line.starts_with("#!") {
                continue;
            }
            let Some(comment) = line.strip_prefix("--") else {
                break;
            };
            if comment.starts_with("[[") || comment.starts_with("[=[") {
                in_block = !line.contains("]]");
                continue;
            }
            let Some(rest) = comment.strip_prefix("@grime ") else {
                continue;
            };
            let Some((key, value)) = rest.split_once(':') else {
                continue;
            };
            let (key, value) = (key.trim(), value.trim());
            match key {
                "description" => {
                    if meta.description.is_empty() {
                        meta.description = value.to_string();
                    }
                }
                "alias" => {
                    for a in value.split(',').map(|a| a.trim().to_lowercase()) {
                        if !a.is_empty() && !meta.aliases.contains(&a) {
                            meta.aliases.push(a);
                        }
                    }
                }
                "requires" => {
                    for d in parse_requires(value) {
                        if !meta.requires.contains(&d) {
                            meta.requires.push(d);
                        }
                    }
                }
                "boundary" => meta.boundary = parse_bool(value),
                "default" => meta.default = parse_bool(value),
                "wraps" if !value.is_empty() => meta.wraps = Some(value.to_lowercase()),
                "chain" if !value.is_empty() => meta.chain = Some(value.to_lowercase()),
                k if k.starts_with("path.") && k.len() > 5 && !value.is_empty() => {
                    meta.paths
                        .insert(k[5..].to_string(), expand_path_value(value, None));
                }
                _ => {}
            }
        }
        meta
    }

    /// Читает файл модуля и разбирает его аннотации.
    pub fn from_file(name: &str, path: &Path) -> Option<Self> {
        let source = fs::read_to_string(path).ok()?;
        Some(Self::from_source(name, path, &source))
    }

    /// Имеет ли модуль хук `wrap_pipeline`.
    pub fn wraps_pipeline(&self) -> bool {
        self.wraps.as_deref() == Some("pipeline")
    }

    /// Оставляет ли модуль `:` перед неизвестным модулем аргументом своего шага.
    pub fn chain_passthrough(&self) -> bool {
        self.chain.as_deref() == Some("passthrough")
    }

    fn matches_name(&self, lower: &str) -> bool {
        self.name.to_lowercase() == lower
    }
}

/// Версия формата индекса модулей на диске (меняется при изменении структуры `ModuleMeta`/`IndexFile`).
const INDEX_VERSION: u32 = 2;

/// Запись индекса: победивший модуль + отпечаток его файла (mtime/size) для валидации без чтения.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct IndexEntry {
    mtime_ns: i64,
    size: u64,
    meta: ModuleMeta,
}

/// Индекс модулей на диске (msgpack). Валидируется по версии grime, `$HOME` (от него зависит
/// раскрытие `path.*`), списку каталогов, их mtime и отпечаткам файлов.
#[derive(Debug, Default, Serialize, Deserialize)]
struct IndexFile {
    version: u32,
    grime: String,
    home: String,
    dirs: Vec<PathBuf>,
    dir_mtimes: Vec<Option<i64>>,
    entries: Vec<IndexEntry>,
}

fn current_home() -> String {
    crate::fs_ops::get_cached_home_dir()
        .map(|h| h.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn dir_mtime_ns(dir: &Path) -> Option<i64> {
    fs::metadata(dir).ok().map(|m| cache::mtime_ns(&m))
}

/// Путь индекса по умолчанию: `<кэш>/grime/modules.idx`.
pub fn default_index_path() -> Option<PathBuf> {
    cache::grime_cache_dir().map(|d| d.join("modules.idx"))
}

fn load_index(path: &Path) -> Option<IndexFile> {
    let bytes = cache::read_private(path)?;
    let idx: IndexFile = rmp_serde::from_slice(&bytes).ok()?;
    (idx.version == INDEX_VERSION && idx.grime == env!("CARGO_PKG_VERSION") && idx.home == current_home())
        .then_some(idx)
}

fn store_index(path: &Path, idx: &IndexFile) {
    if let Ok(bytes) = rmp_serde::to_vec(idx) {
        // Ошибка записи кэша не критична: следующий запуск просто пересоберёт индекс
        let _ = cache::write_private_atomic(path, &bytes);
    }
}

/// Снимок модулей: победившие записи (первый каталог выигрывает) по имени файла.
type Snapshot = Vec<IndexEntry>;

/// Полный скан каталогов; файлы с совпавшим отпечатком в `known` не перечитываются.
fn scan_dirs(dirs: &[PathBuf], known: &[IndexEntry]) -> Snapshot {
    let mut found: BTreeMap<String, IndexEntry> = BTreeMap::new();
    for dir in dirs {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("lua") {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            if found.contains_key(stem) {
                continue;
            }
            // d_type без stat; симлинки (и неизвестный тип) уточняем через is_file()
            let is_file = match entry.file_type() {
                Ok(t) if t.is_file() => true,
                Ok(t) if t.is_dir() => false,
                _ => path.is_file(),
            };
            if !is_file {
                continue;
            }
            let Ok(md) = fs::metadata(&path) else {
                continue;
            };
            let (mtime_ns, size) = (cache::mtime_ns(&md), md.len());
            let reused = known
                .iter()
                .find(|e| e.meta.path == path && e.mtime_ns == mtime_ns && e.size == size);
            let item = match reused {
                Some(e) => e.clone(),
                None => match ModuleMeta::from_file(stem, &path) {
                    Some(meta) => IndexEntry { mtime_ns, size, meta },
                    None => continue,
                },
            };
            found.insert(stem.to_string(), item);
        }
    }
    found.into_values().collect()
}

/// Строит снимок: по индексу (stat каталогов и файлов без чтения содержимого), при несовпадении
/// перечитывает только изменившиеся файлы либо пересканирует каталоги. Индекс обновляется при изменениях.
///
/// `force` отключает быстрый путь «mtime каталогов не изменился»: mtime имеет грубую гранулярность
/// (тик ядра, единицы мс), и файл, созданный в тот же тик, что и снимок, иначе остался бы невидимым.
fn build_snapshot(dirs: &[PathBuf], index_path: Option<&Path>, force: bool) -> (Snapshot, Vec<Option<i64>>) {
    let dir_mtimes: Vec<Option<i64>> = dirs.iter().map(|d| dir_mtime_ns(d)).collect();
    let Some(index_path) = index_path else {
        return (scan_dirs(dirs, &[]), dir_mtimes);
    };
    let loaded = load_index(index_path);

    let mut known: Vec<IndexEntry> = Vec::new();
    if let Some(idx) = loaded {
        if !force && idx.dirs == dirs && idx.dir_mtimes == dir_mtimes {
            // Каталоги не менялись: проверяем отпечатки файлов, перечитываем только изменившиеся
            let mut changed = false;
            let mut entries = Vec::with_capacity(idx.entries.len());
            let mut ok = true;
            for e in idx.entries {
                match fs::metadata(&e.meta.path) {
                    Ok(md) if cache::mtime_ns(&md) == e.mtime_ns && md.len() == e.size => entries.push(e),
                    Ok(md) => match ModuleMeta::from_file(&e.meta.name, &e.meta.path) {
                        Some(meta) => {
                            changed = true;
                            entries.push(IndexEntry {
                                mtime_ns: cache::mtime_ns(&md),
                                size: md.len(),
                                meta,
                            });
                        }
                        None => ok = false,
                    },
                    Err(_) => ok = false,
                }
                if !ok {
                    break;
                }
            }
            if ok {
                if changed {
                    store_index(
                        index_path,
                        &IndexFile {
                            version: INDEX_VERSION,
                            grime: env!("CARGO_PKG_VERSION").to_string(),
                            home: current_home(),
                            dirs: dirs.to_vec(),
                            dir_mtimes: dir_mtimes.clone(),
                            entries: entries.clone(),
                        },
                    );
                }
                return (entries, dir_mtimes);
            }
            // Файл исчез/нечитаем при неизменном mtime каталога (редко): полный пересбор
        } else {
            known = idx.entries;
        }
    }

    let entries = scan_dirs(dirs, &known);
    store_index(
        index_path,
        &IndexFile {
            version: INDEX_VERSION,
            grime: env!("CARGO_PKG_VERSION").to_string(),
            home: current_home(),
            dirs: dirs.to_vec(),
            dir_mtimes: dir_mtimes.clone(),
            entries: entries.clone(),
        },
    );
    (entries, dir_mtimes)
}

/// Реестр модулей: единый снимок каталогов на запуск (первый каталог с модулем побеждает).
/// Снимок не обновляется сам; актуализация — явно через [`ModuleRegistry::invalidate`]
/// (демон вызывает её при hot-reload).
pub struct ModuleRegistry {
    dirs: Vec<PathBuf>,
    index_path: Option<PathBuf>,
    modules: RwLock<Vec<ModuleMeta>>,
    /// mtime каталогов на момент построения снимка (для `refresh_if_changed`).
    dir_mtimes: Mutex<Vec<Option<i64>>>,
}

impl std::fmt::Debug for ModuleRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ModuleRegistry").field("dirs", &self.dirs).finish()
    }
}

impl ModuleRegistry {
    /// Сканирует каталоги модулей (в порядке приоритета) без дискового индекса.
    pub fn scan(dirs: Vec<PathBuf>) -> Self {
        Self::scan_with_index(dirs, None)
    }

    /// То же, но со снимком, ускоренным дисковым индексом (`None` — индекс не используется).
    pub fn scan_with_index(dirs: Vec<PathBuf>, index_path: Option<PathBuf>) -> Self {
        let (entries, dir_mtimes) = build_snapshot(&dirs, index_path.as_deref(), false);
        Self {
            dirs,
            index_path,
            modules: RwLock::new(entries.into_iter().map(|e| e.meta).collect()),
            dir_mtimes: Mutex::new(dir_mtimes),
        }
    }

    /// Реестр по конфигурации. Дисковый индекс используется только для стандартных каталогов
    /// (явный `override_dir` — тесты и встраивание — индекс не трогает).
    pub fn for_config(config: &GrimeConfig, override_dir: Option<PathBuf>) -> Self {
        let index = if override_dir.is_none() { default_index_path() } else { None };
        Self::scan_with_index(config.candidate_module_dirs(override_dir), index)
    }

    /// Работает ли реестр со стандартными каталогами и дисковым кэшем (индекс модулей, байткод).
    /// Для явных каталогов (тесты, встраивание) диск не используется.
    pub fn uses_disk_cache(&self) -> bool {
        self.index_path.is_some()
    }

    /// Каталоги поиска в порядке приоритета.
    pub fn dirs(&self) -> &[PathBuf] {
        &self.dirs
    }

    /// Пересобирает снимок (через индекс: перечитываются только изменившиеся файлы).
    pub fn invalidate(&self) {
        self.rebuild(false);
    }

    /// Принудительный пересбор: каталоги перечитываются всегда, даже если их mtime не изменился.
    pub fn invalidate_force(&self) {
        self.rebuild(true);
    }

    fn rebuild(&self, force: bool) {
        let (entries, dir_mtimes) = build_snapshot(&self.dirs, self.index_path.as_deref(), force);
        *self.modules.write().unwrap_or_else(|e| e.into_inner()) = entries.into_iter().map(|e| e.meta).collect();
        *self.dir_mtimes.lock().unwrap_or_else(|e| e.into_inner()) = dir_mtimes;
    }

    /// Пересобирает снимок, только если изменился mtime какого-либо каталога (один `stat` на каталог).
    /// Вызывается на редком пути «модуль не найден», чтобы подхватить файлы, появившиеся после старта.
    /// Возвращает `true`, если снимок был обновлён.
    pub fn refresh_if_changed(&self) -> bool {
        let now: Vec<Option<i64>> = self.dirs.iter().map(|d| dir_mtime_ns(d)).collect();
        if *self.dir_mtimes.lock().unwrap_or_else(|e| e.into_inner()) == now {
            return false;
        }
        self.invalidate();
        true
    }

    fn with_snapshot<R>(&self, f: impl FnOnce(&[ModuleMeta]) -> R) -> R {
        f(&self.modules.read().unwrap_or_else(|e| e.into_inner()))
    }

    /// Все модули (отсортированы по имени).
    pub fn list(&self) -> Vec<ModuleMeta> {
        self.with_snapshot(|mods| mods.to_vec())
    }

    /// Как [`get`](Self::get), но при промахе один раз принудительно перечитывает каталоги
    /// и повторяет поиск (модуль мог появиться после построения снимка, раньше hot-reload демона).
    pub fn get_fresh(&self, name: &str) -> Option<ModuleMeta> {
        if let Some(meta) = self.get(name) {
            return Some(meta);
        }
        let lower = name.trim();
        if lower.is_empty() || lower.starts_with('-') {
            return None;
        }
        self.invalidate_force();
        self.get(name)
    }

    /// Модуль по точному имени или алиасу (без нечёткого поиска).
    pub fn get(&self, name: &str) -> Option<ModuleMeta> {
        let lower = name.trim().to_lowercase();
        if lower.is_empty() || lower.starts_with('-') {
            return None;
        }
        self.with_snapshot(|mods| {
            mods.iter()
                .find(|m| m.matches_name(&lower))
                .or_else(|| mods.iter().find(|m| m.aliases.contains(&lower)))
                .cloned()
        })
    }

    /// Каноническое имя: точное имя → алиас → нечёткое совпадение (порог 0.75) → `None`.
    pub fn resolve(&self, name: &str) -> Option<String> {
        if let Some(m) = self.get_fresh(name) {
            return Some(m.name);
        }
        self.resolve_fuzzy(name)
    }

    /// Нечёткое совпадение имени (без обновления снимка).
    pub fn resolve_fuzzy(&self, name: &str) -> Option<String> {
        let lower = name.trim().to_lowercase();
        if lower.is_empty() || lower.starts_with('-') {
            return None;
        }
        self.with_snapshot(|mods| {
            let names: Vec<&str> = mods.iter().map(|m| m.name.as_str()).collect();
            crate::args::fuzzy_match_entity(&lower, &names, MODULE_FUZZY_THRESHOLD)
                .map(|s| s.to_string())
        })
    }

    /// Каноническое имя для шага конвейера: разрешённое имя либо исходное имя в нижнем регистре.
    pub fn canonical_name(&self, name: &str) -> String {
        self.resolve(name).unwrap_or_else(|| name.to_lowercase())
    }

    /// Каноническое имя модуля по умолчанию (`--@grime default: true`): первый по имени среди помеченных.
    pub fn default_module(&self) -> Option<String> {
        self.with_snapshot(|mods| mods.iter().find(|m| m.default).map(|m| m.name.clone()))
    }

    /// Известен ли токен как имя или алиас модуля (без нечёткого поиска).
    pub fn is_known(&self, name: &str) -> bool {
        self.get(name).is_some()
    }

    /// Является ли модуль рубежом смены среды.
    pub fn is_boundary(&self, name: &str) -> bool {
        self.get(name).is_some_and(|m| m.boundary)
    }

    /// Значение по умолчанию именованного пути из аннотаций `path.<имя>` (по порядку имён модулей).
    pub fn annotation_path(&self, key: &str) -> Option<String> {
        self.with_snapshot(|mods| mods.iter().find_map(|m| m.paths.get(key).cloned()))
    }

    /// Все именованные пути из аннотаций (первый модуль по имени побеждает).
    pub fn annotation_paths(&self) -> HashMap<String, String> {
        self.with_snapshot(|mods| {
            let mut map = HashMap::new();
            for m in mods {
                for (k, v) in &m.paths {
                    map.entry(k.clone()).or_insert_with(|| v.clone());
                }
            }
            map
        })
    }
}

/// Единый резолвер именованных путей: конфиг → аннотации `path.*` модулей.
#[derive(Clone)]
pub struct PathResolver {
    config: Arc<GrimeConfig>,
    registry: Arc<ModuleRegistry>,
}

fn is_unset(val: &str) -> bool {
    val.is_empty() || val.eq_ignore_ascii_case("auto")
}

impl PathResolver {
    pub fn new(config: Arc<GrimeConfig>, registry: Arc<ModuleRegistry>) -> Self {
        Self { config, registry }
    }

    /// Значение именованного пути: сначала конфиг, затем аннотация модуля.
    pub fn get(&self, name: &str) -> Option<String> {
        self.config
            .paths
            .get(name)
            .filter(|v| !is_unset(v))
            .cloned()
            .or_else(|| self.registry.annotation_path(name))
    }

    /// Все именованные пути (аннотации, поверх них значения из конфига).
    pub fn all(&self) -> HashMap<String, String> {
        let mut map = self.registry.annotation_paths();
        for (k, v) in &self.config.paths {
            if !is_unset(v) || !map.contains_key(k) {
                map.insert(k.clone(), v.clone());
            }
        }
        map
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> crate::test_support::TempDir {
        crate::test_support::TempDir::new(&format!("modreg_{}", tag))
    }

    #[test]
    fn test_annotation_parser() {
        let src = "#!/usr/bin/env lua\n\
            -- обычный комментарий\n\
            --@grime description: Список модулей\n\
            --@grime alias: ls, Modules\n\
            --@grime alias: lst\n\
            --@grime boundary: true\n\
            --@grime wraps: pipeline\n\
            --@grime chain: passthrough\n\
            --@grime path.projects: /srv/p/\n\
            --@grime path.empty:\n\
            \n\
            local x = 1\n\
            --@grime description: после кода не читается\n";
        let m = ModuleMeta::from_source("list", Path::new("/m/list.lua"), src);
        assert_eq!(m.description, "Список модулей");
        assert_eq!(m.aliases, vec!["ls", "modules", "lst"]);
        assert!(m.boundary && m.wraps_pipeline() && m.chain_passthrough());
        assert_eq!(m.paths.get("projects").map(String::as_str), Some("/srv/p"));
        assert!(!m.paths.contains_key("empty"));
    }

    #[test]
    fn test_default_annotation_and_registry() {
        let m = ModuleMeta::from_source("x", Path::new("x.lua"), "--@grime default: true\n");
        assert!(m.default);
        let m = ModuleMeta::from_source("x", Path::new("x.lua"), "--@grime default: no\n");
        assert!(!m.default);

        let d = temp_dir("default");
        fs::write(d.join("zeta.lua"), "--@grime default: true\n").unwrap();
        fs::write(d.join("beta.lua"), "--@grime default: true\n").unwrap();
        fs::write(d.join("alpha.lua"), "").unwrap();
        assert_eq!(ModuleRegistry::scan(vec![d.to_path_buf()]).default_module().as_deref(), Some("beta"));

        let d = temp_dir("nodefault");
        fs::write(d.join("alpha.lua"), "").unwrap();
        assert_eq!(ModuleRegistry::scan(vec![d.to_path_buf()]).default_module(), None);
    }

    #[test]
    fn test_annotation_parser_stops_at_code_and_skips_block_comment() {
        let src = "--[[ блок\n--@grime description: скрыто\n]]\n--@grime alias: a\nreturn {}\n--@grime alias: b\n";
        let m = ModuleMeta::from_source("x", Path::new("x.lua"), src);
        assert!(m.description.is_empty());
        assert_eq!(m.aliases, vec!["a"]);
    }

    #[test]
    fn test_path_annotation_expands_home() {
        let m = ModuleMeta::from_source("p", Path::new("p.lua"), "--@grime path.projects: ~/Projects\n");
        let home = crate::fs_ops::get_cached_home_dir().unwrap();
        assert_eq!(m.paths["projects"], home.join("Projects").to_string_lossy());
    }

    #[test]
    fn test_registry_resolve_priority_and_cache() {
        let d1 = temp_dir("a");
        let d2 = temp_dir("b");
        fs::write(d1.join("project.lua"), "--@grime alias: proj\n--@grime path.projects: /p1\n").unwrap();
        fs::write(d1.join("host.lua"), "--@grime alias: exit-env, unhost\n--@grime boundary: true\n").unwrap();
        fs::write(d2.join("project.lua"), "--@grime alias: other\n").unwrap();
        fs::write(d2.join("doctor.lua"), "--@grime description: d\n").unwrap();
        fs::create_dir_all(d1.join("languages")).unwrap();
        fs::write(d1.join("languages").join("base.lua"), "return {}").unwrap();

        let reg = ModuleRegistry::scan(vec![d1.to_path_buf(), d2.to_path_buf()]);
        let names: Vec<_> = reg.list().into_iter().map(|m| m.name).collect();
        assert_eq!(names, vec!["doctor", "host", "project"]);

        assert_eq!(reg.resolve("PROJ").as_deref(), Some("project"));
        assert_eq!(reg.resolve("unhost").as_deref(), Some("host"));
        assert_eq!(reg.resolve("doctr").as_deref(), Some("doctor"));
        assert_eq!(reg.resolve("zzzzzz"), None);
        assert_eq!(reg.canonical_name("Zzzzzz"), "zzzzzz");
        assert!(reg.get("other").is_none(), "алиас из затенённого каталога не виден");
        assert!(reg.is_boundary("exit-env") && !reg.is_boundary("project"));
        assert!(reg.is_known("proj") && !reg.is_known("doctr"));
        assert_eq!(reg.annotation_path("projects").as_deref(), Some("/p1"));

        // Инвалидация по mtime каталога: новый файл подхватывается без пересоздания
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(d1.join("newmod.lua"), "--@grime alias: nm\n").unwrap();
        reg.invalidate();
        assert_eq!(reg.resolve("nm").as_deref(), Some("newmod"));
    }

    #[test]
    fn test_get_fresh_sees_new_file_without_pause_even_with_index() {
        let d = temp_dir("fresh");
        let cache = temp_dir("freshcache");
        let idx = cache.join("grime").join("modules.idx");
        fs::write(d.join("seed.lua"), "return {}").unwrap();
        let reg = ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx));
        for i in 0..50 {
            let name = format!("fresh{i}");
            fs::write(d.join(format!("{name}.lua")), "return {}").unwrap();
            assert_eq!(reg.resolve(&name).as_deref(), Some(name.as_str()), "итерация {i}");
        }
        assert!(reg.get_fresh("absent_zzz").is_none());
    }

    #[test]
    fn test_disk_index_reuse_update_and_corruption() {
        let d = temp_dir("idx");
        let cache = temp_dir("idxcache");
        let idx = cache.join("grime").join("modules.idx");
        fs::write(d.join("a.lua"), "--@grime alias: aa\n").unwrap();
        fs::write(d.join("b.lua"), "--@grime description: b1\n").unwrap();

        let reg = ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx.clone()));
        assert!(idx.exists() && reg.uses_disk_cache());
        assert_eq!(std::os::unix::fs::MetadataExt::mode(&fs::metadata(&idx).unwrap()) & 0o777, 0o600);
        assert_eq!(reg.resolve("aa").as_deref(), Some("a"));

        // Второй запуск: данные берутся из индекса (подмена содержимого с тем же mtime/size не видна)
        let reg2 = ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx.clone()));
        assert_eq!(reg2.get("b").unwrap().description, "b1");

        // Изменение файла (размер другой): перечитывается только он
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(d.join("b.lua"), "--@grime description: b2-longer\n").unwrap();
        let reg3 = ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx.clone()));
        assert_eq!(reg3.get("b").unwrap().description, "b2-longer");

        // Новый файл меняет mtime каталога: полный пересбор; снимок не обновляется сам
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(d.join("c.lua"), "--@grime alias: cc\n").unwrap();
        assert!(reg3.get("cc").is_none(), "снимок единый на запуск");
        reg3.invalidate();
        assert_eq!(reg3.resolve("cc").as_deref(), Some("c"));
        assert_eq!(ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx.clone())).list().len(), 3);

        // Удалённый файл
        fs::remove_file(d.join("a.lua")).unwrap();
        let reg4 = ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx.clone()));
        assert!(reg4.get("a").is_none());

        // Повреждённый индекс — тихий пересбор
        fs::write(&idx, b"garbage").unwrap();
        fs::set_permissions(&idx, std::os::unix::fs::PermissionsExt::from_mode(0o600)).unwrap();
        let reg5 = ModuleRegistry::scan_with_index(vec![d.to_path_buf()], Some(idx.clone()));
        assert_eq!(reg5.list().len(), 2);
        assert!(load_index(&idx).is_some(), "индекс переписан корректно");
    }

    #[test]
    fn test_path_resolver_config_overrides_annotation() {
        let d = temp_dir("pr");
        fs::write(d.join("a.lua"), "--@grime path.projects: /ann/p\n--@grime path.apps: /ann/a\n").unwrap();
        let reg = Arc::new(ModuleRegistry::scan(vec![d.to_path_buf()]));
        let mut cfg = GrimeConfig {
            paths: HashMap::new(),
            config_file: PathBuf::from("/tmp/x/gproj.conf"),
        };
        cfg.paths.insert("projects".into(), "/cfg/p".into());
        cfg.paths.insert("apps".into(), "auto".into());
        let r = PathResolver::new(Arc::new(cfg), reg);
        assert_eq!(r.get("projects").as_deref(), Some("/cfg/p"));
        assert_eq!(r.get("apps").as_deref(), Some("/ann/a"));
        assert_eq!(r.get("nothing"), None);
        assert_eq!(r.all()["apps"], "/ann/a");
    }
}
