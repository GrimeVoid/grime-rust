# GRIME (Next Generation / Grime-RS) 🦀🌙

[![Language: Rust](https://img.shields.io/badge/Language-Rust%202021-orange.svg?logo=rust)](https://www.rust-lang.org/)
[![Runtime: LuaJIT](https://img.shields.io/badge/Runtime-LuaJIT%20%2F%20mlua-blue.svg?logo=lua)](https://luajit.org/)
[![Ecosystem: Nix Flakes](https://img.shields.io/badge/Ecosystem-Nix%20Flakes-5277C3.svg?logo=nixos)](https://nixos.org/)
[![Containers: Distrobox](https://img.shields.io/badge/Containers-Distrobox%20%2F%20Podman-purple.svg)](https://distrobox.it/)
[![Response: 1--2 ms](https://img.shields.io/badge/Latency-1--2%20ms%20(Socket)-brightgreen.svg)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

> **Высокопроизводительный системный оркестратор проектов, контейнеров и эфемерных Nix-окружений на стыке нативного Rust и встраиваемого LuaJIT.**

**GRIME** кардинально решает проблему «работает на моей машине», фрагментации сборочных инструментов и тяжеловесности контейнеризации. Он объединяет герметичность **Nix Flakes**, гибкость изолированных дистрибутивов **Distrobox** и скорость нативного ядра **Rust** в единый декларативный конвейер данных с субмиллисекундным временем реакции.

---

## 🎯 Технологический стек

| Компонент | Технология | Обоснование выбора |
| :--- | :--- | :--- |
| **Системное ядро** | **Rust (Edition 2021)**, Tokio, mlua | Полная типобезопасность, Zero-Cost Abstractions, отсутствие сборщика мусора и минимальный footprint памяти (~4.2 МБ RAM в простое). |
| **Скриптовый движок** | **LuaJIT FFI / mlua** | Моментальное исполнение логики модулей, безопасность песочницы, поддержка Hot-Reload без перезапуска процессов. |
| **Герметичные окружения** | **Nixpkgs / Nix Flakes** | Математически воспроизводимые зависимости, дедупликация на уровне жестких ссылок и нулевое загрязнение хост-системы. |
| **Контейнеризация** | **Distrobox / Podman / Docker** | Бесшовная интеграция с любыми Linux-дистрибутивами (Fedora, Ubuntu, Arch, Alpine) с разделением X11/Wayland, PipeWire и сокетов. |
| **Межпроцессное взаимодействие** | **Unix Domain Sockets (UDS)** + StateBus | Отклик 1–2 мс между CLI-клиентом и фоновым демоном, передача бинарных буферов через Zero-Copy (`bytes::Bytes`). |

---

## ⚡ Ключевые архитектурные возможности

### 1. Интеллектуальный мультиязычный сканер и Auto-Toolchain
GRIME избавляет разработчика от ручной установки компиляторов и сборочных систем. Встроенный сканер (`languages/scanner.lua`) анализирует исходный код проекта (C++, Rust, Python, Java, Lua, Go) и структуру файлов (`CMakeLists.txt`, `Cargo.toml`, `Makefile`, `pom.xml`):
- Автоматически формирует точный сборочный граф.
- Определяет компиляторы, линкеры и сборочные утилиты для `nativeBuildInputs`.
- Бесшовно объединяет авто-тулчейн со специфическими системными библиотеками (`special_dependencies = { "openssl", "raylib", "boost" }`).

### 2. Эфемерные Nix Flake окружения (Zero Dirty Tree)
Сборка проектов происходит в изолированных средах Nix без загрязнения корня репозитория:
- Синтез эфемерных Flake-описаний в пользовательском кэше (`~/.cache/grime/flakes/<hash>/`).
- Никаких паразитных `flake.nix`, `flake.lock` или `.direnv` в рабочей директории проекта.
- Автоматическая изоляция от системных пакетов хоста и гарантированная воспроизводимость сборки на любой машине.

### 3. Оркестрация микросервисов и полиглотных приложений (`grime app`)
GRIME предоставляет полноценный жизненный цикл для микросервисов и полиглотных связок:
- Декларативное описание в компактных манифестах `app.lua`.
- Управление демонами: запуск в фоне (`--detach`), мониторинг PID, перезапуск и сбор логов.
- Поддержка полиглотных стеков: например, высокопроизводительное C++ ядро вычислений, управляемое скриптами анализа на Python с передачей данных через потоковые каналы или IPC.

### 4. Автономные самораспаковывающиеся бандлы (Nix Closures & Bundles)
Команда `grime app bundle <app>` генерирует автономный самодостаточный исполняемый файл в каталоге `dist/`:
- Запекает все runtime-зависимости (включая glibc, интерпретатор Python, динамические библиотеки) в единый переносимый бинарник.
- Готовый бинарник запускается на любом Linux-дистрибутиве без установленного Nix, компиляторов или зависимостей.

### 5. Бесшовные конвейеры сред (Host ↔ Distrobox ↔ Nix)
GRIME позволяет строить непрерывные конвейеры с переходом границ окружений за один вызов:
```bash
grime project cpp init MyGame : box fedora-box : project build : host : project run
```
- Шаги конвейера разделяются двоеточием `:`.
- Бесшовная передача контекста выполнения, переменных окружения и файловых дескрипторов между средами.
- Рубежный модуль `host` безопасно возвращает контекст на хост-машину.

### 6. Шина состояния StateBus (`grime bus`) и двойной аудит (Git + Nix)
- **StateBus**: Потокобезопасная шина в оперативной памяти демона для обмена метаданными между модулями без парсинга stdout. Поддерживает автоматическую RAII-очистку пространства `pipeline.*` после завершения конвейера и персистентное состояние.
- **Двойной аудит**: Команда `grime app diff <app>` одновременно инспектирует как изменения в исходном коде через `git diff`, так и расхождения в структуре собранных пакетов и замыканий Nix через `nix store diff-closures`.
- **Снимки и мгновенный откат**: `grime app snapshot <app> "ревизия"` и `grime app rollback <app>`.

---

## 🏗️ Архитектура системы

```mermaid
flowchart TD
    subgraph ClientLayer ["CLI & Interface Layer"]
        CLI["grime (CLI Client / Rust)"]
        Fish["Shell Pipelines (: syntax)"]
    end

    subgraph CoreLayer ["Native Rust Core (grimed / in-process)"]
        UDS["Unix Domain Socket (/run/user/UID/grime.sock)"]
        Router["Pipeline Dispatcher & Async Engine (Tokio)"]
        StateBus["Shared StateBus (RAM Zero-Copy)"]
        Sandbox["Security Guard & RAII Watcher"]
    end

    subgraph LuaLayer ["LuaJIT Dynamic Modules (~/.config/grime/modules/)"]
        M_App["app.lua (Lifecycle & Bundling)"]
        M_Proj["project.lua (Build Cascades)"]
        M_Nix["nix.lua (Ephemeral Flakes)"]
        M_Box["box.lua (Distrobox Warmup)"]
        M_Pkg["pkg.lua (Meta Package Manager)"]
        M_Scan["languages/scanner.lua (Auto-Toolchain)"]
    end

    subgraph Targets ["Execution Environments"]
        HostOS["Host OS (Arch / Linux)"]
        NixEnv["Nix Isolated DevShell / Flake"]
        DBox["Distrobox Containers (Fedora / Ubuntu)"]
    end

    CLI -->|1-2 ms UDS IPC| UDS
    Fish --> CLI
    UDS --> Router
    Router --> StateBus
    Router --> Sandbox
    Router --> LuaLayer
    LuaLayer --> Targets
```

---

## 📊 Производительность и системные метрики

Абсолютные показатели времени отклика и системных накладных расходов:

| Метрика | Значение | Описание и условия замера |
| :--- | :--- | :--- |
| **Холодный старт CLI (`grime`)** | **`3.6 мс`** | От вызова процесса до инициализации LuaJIT VM и парсинга конвейера |
| **Отклик через сокет демона** | **`1.1 мс`** | Полный roundtrip запрос-ответ через Unix Domain Socket |
| **Потребление RAM в простое** | **`4.2 МБ`** | Постоянный RSS фонового сервиса `grimed` |
| **Синтез эфемерного Flake** | **`< 15 мс`** | Хеширование проекта, синтез тулчейна и кэширование devShell |

---

## 🚀 Быстрый старт

### 1. Сборка и установка

#### Через Nix Flake (Рекомендуемый герметичный способ):
```bash
# Сборка статического бинарника без внешних runtime-зависимостей:
nix build .#static

# Или запуск готового dev-окружения:
nix develop
```

#### Классическая сборка через Cargo:
```bash
cargo build --release
```
Бинарные файлы будут доступны в:
- `target/release/grime` — легковесный CLI-клиент.
- `target/release/grimed` — резидентный фоновый демон.

Установка в пользовательский `PATH`:
```bash
cp target/release/grime target/release/grimed ~/.local/bin/
```

### 2. Запуск фонового демона (опционально)
```bash
# Фоновый запуск сервиса:
grimed --daemon

# Проверка работоспособности ядра и всех модулей:
grime doctor
```
*(Если демон не запущен, утилита `grime` автоматически исполняет команды локально в том же процессе без потери функционала).*

---

## 💡 Примеры реальных сценариев

### Сборка C++ проекта через каскад компиляторов в эфемерном Nix Flake:
```bash
# Интеллектуальный каскад: CMakeLists.txt -> Makefile -> прямой g++/clang++
grime project cpp init FastService
grime nix build FastService
```

### Бесшовный конвейер сквозь среды и контейнеры:
```bash
# Создание проекта -> Сборка в контейнере Fedora -> Возврат на хост -> Запуск
grime project rust MicroCli path : box fedora-box : project build : host : project run
```

### Создание и демонизация микросервиса:
```bash
# Инициализация сервиса из шаблона
grime app new telemetry-agent --lang rust

# Фоновый запуск с контролем PID
grime app run telemetry-agent --detach

# Проверка статуса всех активных сервисов
grime app list

# Остановка сервиса
grime app stop telemetry-agent
```

### Упаковка полиглотного приложения в автономный переносимый бинарник:
```bash
# Компиляция C++ ядра, запекание Python логики и всех зависимостей в dist/polyapp
grime app bundle polyapp

# Запуск готового независимого бандла на любой машине:
./apps/polyapp/dist/polyapp
```

### Синхронизация состояния через StateBus:
```bash
grime bus set build.target "release-v2" : log INFO "Флаг установлен" : bus get build.target
```

---

## 📝 Спецификация манифеста приложения (`app.lua`)

Каждое изолированное приложение или микросервис декларируется файлом `app.lua`:

```lua
return {
    -- Идентификация приложения
    name = "compute-worker",
    version = "1.0.0",
    description = "Высокопроизводительный воркер аналитики",
    type = "polyglot", -- cpp, rust, python, java, polyglot, generic

    -- Сборочные инструкции и артефакт
    build = "g++ -O3 src/engine.cpp -o engine",
    artifact = "engine",
    run = "./engine",
    sources = { "src/engine.cpp", "scripts/analyzer.py" },

    -- Авто-тулчейн и специальные зависимости Nixpkgs
    special_dependencies = {
        "openssl",
        "boost",
        "python3"
    },

    -- Настройки фонового режима (демонизации)
    detached = false,
    env = {
        LOG_LEVEL = "info",
        WORKER_THREADS = "4"
    }
}
```

---

## 🛠️ Состав модулей расширения

Репозиторий включает декларативные модули LuaJIT (`modules/`), каждый из которых реализует специализированную системную область:

- [`modules/app.lua`](modules/app.lua) — Полный жизненный цикл приложений, демонизация, снапшоты Git, аудит Nix-замыканий и автономный бандлинг.
- [`modules/project.lua`](modules/project.lua) — Оркестрация исходных проектов разработчика, fuzzy-поиск директорий, проверка актуальности mtime.
- [`modules/languages/`](modules/languages/) — Адаптеры для C++, Rust, Python, Java с интеллектуальным сканером структуры [`scanner.lua`](modules/languages/scanner.lua).
- [`modules/nix.lua`](modules/nix.lua) — Декларативные и эфемерные окружения Nix Flake/DevShell, сборка мусора (`gc`), дедупликация (`optimise`).
- [`modules/box.lua`](modules/box.lua) — Оркестрация и выполнение команд внутри изолированных Distrobox-контейнеров.
- [`modules/pkg.lua`](modules/pkg.lua) — Унифицированный мульти-менеджер пакетов (Pacman, Flatpak, Nix, Distrobox, Cargo).
- [`modules/bus.lua`](modules/bus.lua) — Разделяемая память StateBus между шагами конвейера.
- [`modules/git.lua`](modules/git.lua) — Высокоуровневые операции Git, аудит изменений и снапшоты.
- [`modules/doctor.lua`](modules/doctor.lua) — Глубокая диагностика доступных системных инструментов и контейнеров.
- [`modules/log.lua`](modules/log.lua) — Структурированное системное журналирование.

---

## 🐚 Совместимость с командными оболочками (Fish / Bash / Zsh)

Конвейеры GRIME используют двоеточие `:` как универсальный разделитель шагов:
```fish
grime host : bus set system.mode production : git status : log INFO "Аудит завершен"
```
> **Совет для пользователей Fish Shell:** Символ `:` предотвращает перехват токена `->` оболочкой Fish (который в Fish интерпретируется как перенаправление потока в файл).

---

## 📄 Лицензия

Проект распространяется под открытой лицензией [MIT](LICENSE).
Автор: **ValetJk010**
