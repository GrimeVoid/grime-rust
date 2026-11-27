//! Граф зависимостей модулей (аннотация `--@grime requires:`).
//!
//! Ядро разрешает только то, что может проверить без побочных эффектов:
//! - `module:` — транзитивный порядок разрешения (топологический), циклы и отсутствующие модули;
//! - `bin:` — наличие исполняемого файла в `$PATH` (без порождения процессов, общая с
//!   `grime.process.which` реализация [`crate::process::which_in`]);
//! - `nix:` — только записывается и отдаётся Lua: материализует пакеты модуль `nix`.
//!
//! Если у модуля есть `nix:`-зависимость, отсутствие его `bin:` — лишь предупреждение: бинарь может
//! появиться после входа в окружение Nix.

use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;

use crate::modules::{DepKind, ModuleRegistry};
use crate::process::which_in;

/// Итог анализа зависимостей.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DepReport {
    /// Топологический порядок модулей (зависимости раньше зависящих; корни — в порядке запроса).
    pub order: Vec<String>,
    /// Фатальные проблемы (обязательные зависимости).
    pub errors: Vec<String>,
    /// Предупреждения (необязательные зависимости, `bin:` при наличии `nix:`).
    pub warnings: Vec<String>,
}

impl DepReport {
    pub fn is_ok(&self) -> bool {
        self.errors.is_empty()
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mark {
    InProgress,
    Done,
}

struct Walker<'a> {
    registry: &'a ModuleRegistry,
    path_var: Option<&'a OsStr>,
    check_bins: bool,
    marks: HashMap<String, Mark>,
    stack: Vec<String>,
    report: DepReport,
    seen_issues: HashSet<String>,
}

impl Walker<'_> {
    fn error(&mut self, msg: String) {
        if self.seen_issues.insert(msg.clone()) {
            self.report.errors.push(msg);
        }
    }

    fn warn(&mut self, msg: String) {
        if self.seen_issues.insert(msg.clone()) {
            self.report.warnings.push(msg);
        }
    }

    fn visit(&mut self, name: &str) {
        match self.marks.get(name) {
            Some(Mark::Done) => return,
            Some(Mark::InProgress) => {
                let start = self.stack.iter().position(|n| n == name).unwrap_or(0);
                let mut cycle: Vec<&str> = self.stack[start..].iter().map(String::as_str).collect();
                cycle.push(name);
                self.error(format!("цикл зависимостей: {}", cycle.join(" → ")));
                return;
            }
            None => {}
        }
        let Some(meta) = self.registry.get(name) else {
            return;
        };
        self.marks.insert(name.to_string(), Mark::InProgress);
        self.stack.push(name.to_string());

        let has_nix = meta.requires.iter().any(|d| d.kind == DepKind::Nix);
        for dep in &meta.requires {
            match dep.kind {
                DepKind::Module => match self.registry.get(&dep.name) {
                    Some(found) => self.visit(&found.name),
                    None if dep.optional => {
                        self.warn(format!("модуль '{}': необязательный модуль '{}' не найден", name, dep.name))
                    }
                    None => {
                        let hint = self
                            .registry
                            .resolve(&dep.name)
                            .map(|s| format!(" (возможно, '{}')", s))
                            .unwrap_or_default();
                        self.error(format!(
                            "модуль '{}' требует модуль '{}', которого нет{}",
                            name, dep.name, hint
                        ));
                    }
                },
                DepKind::Bin if self.check_bins && which_in(&dep.name, self.path_var).is_none() => {
                    let msg = format!("модуль '{}' требует программу '{}', её нет в PATH", name, dep.name);
                    if dep.optional || has_nix {
                        self.warn(msg);
                    } else {
                        self.error(msg);
                    }
                }
                _ => {}
            }
        }

        self.stack.pop();
        self.marks.insert(name.to_string(), Mark::Done);
        self.report.order.push(name.to_string());
    }
}

fn analyze(registry: &ModuleRegistry, roots: &[String], path_var: Option<&OsStr>, check_bins: bool) -> DepReport {
    let mut w = Walker {
        registry,
        path_var,
        check_bins,
        marks: HashMap::new(),
        stack: Vec::new(),
        report: DepReport::default(),
        seen_issues: HashSet::new(),
    };
    for root in roots {
        let canonical = registry.get(root).map(|m| m.name).unwrap_or_else(|| root.to_lowercase());
        w.visit(&canonical);
    }
    w.report
}

/// Топологический порядок разрешения модулей `roots` (транзитивно по `module:`).
/// Ошибка — список понятных сообщений (циклы, отсутствующие обязательные модули).
pub fn resolve_order(registry: &ModuleRegistry, roots: &[String]) -> Result<Vec<String>, Vec<String>> {
    let rep = analyze(registry, roots, None, false);
    if rep.errors.is_empty() {
        Ok(rep.order)
    } else {
        Err(rep.errors)
    }
}

/// Pre-flight: полный отчёт по `module:` и `bin:` для модулей шагов конвейера (все проблемы разом).
pub fn preflight(registry: &ModuleRegistry, roots: &[String]) -> DepReport {
    preflight_with_path(registry, roots, std::env::var_os("PATH").as_deref())
}

/// То же с явным `PATH` (для тестов).
pub fn preflight_with_path(registry: &ModuleRegistry, roots: &[String], path_var: Option<&OsStr>) -> DepReport {
    analyze(registry, roots, path_var, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn reg(tag: &str, files: &[(&str, &str)]) -> (ModuleRegistry, crate::test_support::TempDir) {
        let d = crate::test_support::TempDir::new(&format!("deps_{}", tag));
        for (n, body) in files {
            fs::write(d.join(format!("{n}.lua")), body).unwrap();
        }
        (ModuleRegistry::scan(vec![d.to_path_buf()]), d)
    }

    fn roots(r: &[&str]) -> Vec<String> {
        r.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn транзитивный_порядок() {
        let (r, _d) = reg(
            "order",
            &[
                ("a", "--@grime requires: module:b, c\n"),
                ("b", "--@grime requires: module:c\n"),
                ("c", ""),
            ],
        );
        assert_eq!(resolve_order(&r, &roots(&["a"])).unwrap(), vec!["c", "b", "a"]);
    }

    #[test]
    fn цикл_и_отсутствие_с_подсказкой() {
        let (r, _d) = reg(
            "cycle",
            &[
                ("a", "--@grime requires: module:b\n"),
                ("b", "--@grime requires: module:a\n"),
                ("gitx", "--@grime requires: module:gitt, module:nope\n"),
                ("gitt", ""),
            ],
        );
        let e = resolve_order(&r, &roots(&["a"])).unwrap_err();
        assert_eq!(e, vec!["цикл зависимостей: a → b → a"]);
        let (r2, _d2) = reg("miss", &[("x", "--@grime requires: module:gitt, module:nope\n"), ("git", "")]);
        let e = resolve_order(&r2, &roots(&["x"])).unwrap_err();
        assert_eq!(e.len(), 2, "{e:?}");
        assert!(e[0].contains("'gitt'") && e[0].contains("возможно, 'git'"), "{e:?}");
    }

    #[test]
    fn optional_и_bin() {
        let (r, _d) = reg(
            "bin",
            &[
                ("m", "--@grime requires: module:nope?, bin:grime-no-such-bin, bin:grime-opt-bin?\n"),
                ("n", "--@grime requires: nix:gcc, bin:grime-no-such-bin\n"),
            ],
        );
        let path = std::env::join_paths([_d.path()]).unwrap();
        let rep = preflight_with_path(&r, &roots(&["m", "n"]), Some(&path));
        assert_eq!(rep.errors.len(), 1, "{:?}", rep.errors);
        assert!(rep.errors[0].contains("grime-no-such-bin"));
        assert_eq!(rep.warnings.len(), 3, "{:?}", rep.warnings);
        // Найденный бинарь проблем не даёт
        let (r2, _d2) = reg("bin2", &[("m", "--@grime requires: bin:sh\n")]);
        assert!(preflight(&r2, &roots(&["m"])).is_ok());
    }
}
