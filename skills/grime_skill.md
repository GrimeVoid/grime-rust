# Grime Orchestration System: Skill Guide for AI Agents

You are operating inside an execution system orchestrated by **Grime** — a modular command-line pipeline and project lifecycle manager.
Grime handles infrastructure, build systems, tooling environments, and modular pipelines.

---

## 1. Modular Pipelines & Prompt Chaining

Grime organizes execution as linear pipelines of modules separated by `:`:
```bash
grime project python init my_app path : aider -m "Implement core data models"
```

### Multi-Agent Pipeline Interaction:
1. **Intermediate Agents (`ctx.has_next_step`)**:
   When you are called as a preparatory or intermediate step in a Grime pipeline (e.g. an architect or planner agent before an implementation agent), Grime expects you to formulate a structured master-prompt for the next agent.
   Wrap your instructions inside the tag:
   ```markdown
   <next_agent_prompt>
   [Your precise requirements, architecture specification, or prompt for the next agent]
   </next_agent_prompt>
   ```
   Grime will automatically extract the content inside `<next_agent_prompt>` and pass it directly as the input context to the next agent in the pipeline.

2. **Terminal / Standalone Agents (`ctx.is_last_step`)**:
   When you are called alone or as the final step in a pipeline (e.g. answering a user question or writing code directly), provide a clean, direct, and well-structured answer without `<next_agent_prompt>` tags.

3. **No Direct OS Shell Injection**:
   Do NOT attempt to execute arbitrary OS commands by printing fake terminal commands. The Grime orchestrator controls all pipeline stages, builds, tests, and module executions directly.

### Pipeline Environment Wrapping & Tail Delegation:
Grime поддерживает динамическое переключение среды исполнения прямо в процессе конвейера с помощью модулей окружения (`box` и `nix`) и рубежа возврата на хост (`host`):

1. **Концепция оборачивания сред (Environment Wrapping)**:
   Когда шаг модуля среды (`box [имя_контейнера]` или `nix [--pure]`) встречается в конвейере без автономных команд управления (таких как `list`, `create`, `flake`, `gc`):
   Оркестратор переходит в режим **Tail Delegation** — собирает все последующие шаги вплоть до разделителя `host` (или до конца конвейера) и формирует из них подконвейер.

2. **Гарантированный проброс Grime (PATH Guarantees)**:
   При выполнении подконвейера в Distrobox или Nix DevShell Grime гарантирует проброс путей пользователя:
   `export PATH="$PATH:$HOME/.local/bin"; cd '<target_dir>' && grime <подконвейер>`
   Подконвейер выполняется внутри изолированного окружения с подключением TTY-терминала (`ctx.run_interactive`).

3. **Рубеж возврата на хост (`host`, `exit-env`, `unhost`, `host-env`)**:
   Специальный разделитель конвейера, завершающий делегирование в окружение и возвращающий дальнейшее выполнение оставшихся шагов обратно на хост-систему:
   ```bash
   # Создание на хосте -> сборка и тесты в fedora-box -> запуск на хосте:
   grime project cpp my_app path : box fedora-box : project build : cmd pytest : host : project run

   # Сборка внутри чистого Nix DevShell без возврата (до конца конвейера):
   grime project cpp my_app path : nix : project build : project run
   ```

---

## 2. Standard Built-in Grime Modules

### A. `project` (Project Lifecycle Management)
Supports C++, Python, Java, and Rust.
- **Initialize project**:
  ```bash
  grime project cpp init <Name> [path]
  grime project python init <Name> [path]
  grime project java init <Name> [path]
  grime project rust init <Name> [path]
  ```
- **Build project**:
  ```bash
  grime project build [Name] [path]
  ```
- **Run project** (auto-checks `mtime` and rebuilds if code changed):
  ```bash
  grime project run [Name]
  ```
- **Delete project** (aliases: delete, rm, del, remove, d):
  ```bash
  grime project delete <Name>
  grime project rm <Name>
  grime project delete /path/to/project
  ```
- **Clear project** (resets to initial clean state with fresh git):
  ```bash
  grime project clear <Name>
  ```
- **Query project path / language root (supports exact, prefix, substring & fuzzy matching)**:
  ```bash
  grime project <Name>
  grime project python <PrefixOrName>
  grime project python
  ```

### B. `cmd` / `exec` (Universal Command Runner)
Runs arbitrary commands and tools (`git`, `pytest`, `make`, `cargo`, `nvim`) in the context of the active pipeline directory:
```bash
grime project MyGame path : cmd git status : cmd pytest
```

### C. `aider` (AI Agent Invocation)
- **Standalone Mode**: Starts in `--no-git` mode outside any repository.
- **Project Mode**: When invoked with a project path, launches inside the project repository with access to git and source files.
- **Prompt Chaining**: Automatically chains prompts and specifications between sequential `aider` steps.

### D. `pkg` (Package Management, Environment Inspection & Nix Environments)
Управление пакетами, инспекция установленного софта и работа с изолированными Nix-окружениями с полной независимостью от порядка аргументов (Token Classifier).
- **Инспекция установленного софта (list / ls / l / show)**:
  Определяет нативную систему через `/etc/os-release` и выводит только явно установленные пользователем пакеты (отсекая системные зависимости):
  ```bash
  grime pkg list                  # инспекция по всем доступным менеджерам (pacman, flatpak, nix, distrobox и др.)
  grime pkg pacman ls             # только pacman
  grime pkg flatpak               # только flatpak
  grime pkg nix ls                # профиль nix
  grime pkg -a                    # полный вывод всех пакетов включая системные зависимости
  ```
- **Защищенная установка (install / i / add)**:
  Требует ОБЯЗАТЕЛЬНОГО явного указания пакетного менеджера (Grime запрещает угадывать менеджер для безопасности ОС):
  ```bash
  grime pkg pacman install htop
  grime pkg flatpak install com.obsproject.Studio
  grime pkg nix install ripgrep
  grime pkg distrobox install clang
  ```
- **Одноразовый запуск через Nix (run / r / try)**:
  Запуск любой утилиты в изолированном окружении без установки в профиль:
  ```bash
  grime pkg nix run hello
  grime pkg run cmake --version
  ```
- **Генерация окружения разработки (init / shell / sh / new)**:
  Создает `shell.nix` в контексте проекта (автоматически определяя стек или принимая список пакетов):
  ```bash
  grime pkg nix init              # автоопределение (CMake -> cmake, gcc, ninja; Python -> python3; Rust -> cargo, rustc)
  grime pkg nix init cmake gcc zlib
  ```
- **Прозрачность конвейера (Pipeline Passthrough)**:
  Возвращает директорию проекта в конвейер Grime:
  ```bash
  grime project my_app path : pkg nix init : pkg nix run ninja : project run
  ```

### E. `nix` (Reproducible Development Environments, Flakes & System Maintenance)
Полноценное управление воспроизводимыми изолированными средами разработки на базе `flake.nix` и `shell.nix`, обслуживание системы Nix (GC, Optimise), динамическое делегирование определения зависимостей языковым адаптерам, умная установка пакетов Flakes в профиль, независимость от порядка аргументов (Token Classifier), защита от дубликатов пакетов и сквозная прозрачность конвейера:
- **Динамические языковые адаптеры (`modules/languages/`)**:
  Модуль опрашивает адаптеры проекта для формирования оптимального окружения:
  * **C++** (`cpp.py`): `CMakeLists.txt` -> `["cmake", "gcc", "ninja", "pkg-config"]`; `Makefile` -> `["gnumake", "gcc"]`; одиночный `main.cpp` -> `["gcc"]`.
  * **Python** (`python.py`): `pyproject.toml` -> `["python3", "uv"]`; `requirements.txt` -> `["python3", "pip"]`; чистый скрипт -> `["python3"]`.
  * **Java** (`java.py`): `pom.xml` -> `["jdk", "maven"]`; `build.gradle` -> `["jdk", "gradle"]`; одиночный `Main.java` -> `["jdk"]`.
  * **Rust** (`rust.py`): `Cargo.toml` / `src/main.rs` -> `["cargo", "rustc", "rust-analyzer"]`.
  * **Fallback**: при отсутствии совпадений -> `["bashInteractive"]`.
- **Генерация современного Flake-окружения (flake / f / flake init)**:
  Создает современный `flake.nix` со стандартным `devShells.<system>.default = pkgs.mkShell { ... }` на базе `github:nixos/nixpkgs/nixpkgs-unstable`, автоматически опрашивая языковые адаптеры или принимая явный список пакетов:
  ```bash
  grime nix flake init                  # автоопределение через языковые модули
  grime nix flake init cmake gcc ninja  # создание с явным набором зависимостей
  grime nix flake init -f               # принудительная перезапись существующего flake.nix
  ```
- **Инициализация классического shell.nix (init / create / new / make)**:
  Создает стандартизированный `shell.nix` с автоопределением стека или явным списком пакетов. Защищен от случайной перезаписи (требует `-f` / `--force`):
  ```bash
  grime nix init                        # автоопределение через языковые адаптеры
  grime nix init cmake gcc ninja -f     # перезапись с явно указанным списком пакетов
  ```
- **Интерактивный вход в окружение (enter / shell / sh)**:
  * При наличии `flake.nix`: автоматически запускает современный `nix develop` (с поддержкой `--pure` / `--ignore-env`).
  * При наличии `shell.nix`: запускает классический `nix-shell` (с поддержкой `--pure`).
  ```bash
  grime nix enter                       # вход в nix develop (для Flake) или nix-shell
  grime nix enter --pure                # изолированный вход с очисткой окружения
  ```
- **Универсальный запуск команд, скриптов и модулей в Nix DevShell (run / exec / do / run-in / e)**:
  * Если в проекте есть `flake.nix`: выполняет команду внутри `nix develop -c bash -c "<команда>"`.
  * Если есть `shell.nix`: выполняет команду внутри `nix-shell --run "<команда>"`.
  * Требует явного указания команды или модуля для запуска (при отсутствии аргументов выдает ошибку с подсказкой).
  * С аргументами модулей Grime (например, `project build`, `project run` или `cmd git status`): автоматически оборачивает в `grime <аргументы>` и запускает внутри окружения.
  * С произвольной shell-командой, цепочкой или скриптом (например, `./build.sh`, `make`, `pytest`, `cargo test`, `cmake -B build && ninja -C build`): исполняет напрямую внутри шелла.
  * Прозрачно передает путь проекта дальше в конвейер (Pipeline Passthrough):
  ```bash
  grime project cpp my_app path : nix flake init : nix run project build # сквозной цикл: обнаружение -> flake.nix -> сборка в Nix
  grime nix run project build run                                         # вызов модулей Grime в DevShell
  grime nix run cargo test                                                # запуск произвольной shell-команды
  grime nix exec ./build.sh                                               # выполнение скрипта сборки в окружении
  grime nix run --pure -- pytest                                          # запуск в абсолютно изолированном шелле
  ```
- **Добавление пакетов в окружение проекта (add / append / in)**:
  Безопасно парсит существующий блок `buildInputs = with pkgs; [ ... ];` во `flake.nix` или `shell.nix` и дописывает новые пакеты без дубликатов:
  ```bash
  grime nix add ripgrep fzf
  grime nix add requests uv
  ```
- **Удаление пакетов из окружения проекта (rm / remove / del / delete)**:
  Аккуратно удаляет указанные пакеты из блока `buildInputs` во `flake.nix` или `shell.nix`:
  ```bash
  grime nix rm gcc cmake
  ```
- **Умная установка пакетов в профиль пользователя Nix (install / i / profile-install / get)**:
  Устанавливает пакет(ы) в глобальный пользовательский профиль Nix (`~/.nix-profile`).
  * Для обычных имен пакетов (например, `ripgrep`): добавляет префикс `nixpkgs#ripgrep`.
  * Для Flake URI (например, `github:nix-community/nixvim`, `git+https://...`, `path:/...`, `.#pkg`): передает URI напрямую в `nix profile install <flake_uri>`.
  * При установке обычных пакетов имеет fallback на `nix-env -iA nixpkgs.<пакет>`:
  ```bash
  grime nix install ripgrep fzf
  grime nix install github:nix-community/nixvim
  grime nix i lazygit
  grime nix profile-install bat eza
  ```
- **Удаление пакетов из профиля пользователя Nix (uninstall / un / remove-profile / rm-profile / erase)**:
  Удаляет пакет(ы) из глобального пользовательского профиля Nix. Пытается использовать `nix profile remove <пакет>` с автоматическим fallback на `nix-env -e <пакет>`:
  ```bash
  grime nix uninstall ripgrep
  grime nix un fzf
  grime nix rm-profile lazygit
  ```
- **Обслуживание и сборка мусора (gc / clean / cleanup / garbage-collect)**:
  Очищает неиспользуемые пути в хранилище Nix и удаляет старые поколения профилей через `nix-collect-garbage -d` (или `nix store gc`). Поддерживает дополнительные аргументы (например, `--older-than 14d`):
  ```bash
  grime nix gc                          # удаление старых поколений и сборка мусора
  grime nix gc --older-than 14d         # удаление поколений старше 14 дней
  grime nix clean                       # алиас для быстрой очистки
  ```
- **Оптимизация и дедупликация хранилища (optimise / optimize / opt / dedup)**:
  Заменяет идентичные файлы в хранилище Nix жесткими ссылками (hard links), существенно экономя место на диске (`nix store optimise` с fallback на `nix-store --optimise`):
  ```bash
  grime nix optimise                    # дедупликация Nix store
  grime nix opt                         # краткий алиас
  ```
- **Разграничение областей действия**:
  * `flake` / `init` / `add` / `rm` — работают строго локально с файлами окружения проекта (`flake.nix` / `shell.nix`).
  * `install` / `uninstall` — управляют постоянным профилем пользователя Nix (`~/.nix-profile`).
  * `gc` / `optimise` — обслуживают глобальное хранилище `/nix/store` и историю поколений.
- **Валидация и проверка окружения (check / test / validate)**:
  Быстрая проверка синтаксиса через `nix-instantiate` и тестовое инстанцирование окружения (`nix develop -c true` / `nix-shell --run true`):
  ```bash
  grime nix check
  ```
- **Интеграция с конвейером Grime и AI-агентами (Aider Prompt Chaining)**:
  * Модуль принимает путь к проекту или извлекает пакеты из тегов `<nix_packages>пакеты...</nix_packages>` (включая блок внутри `<next_agent_prompt>`), переданных предыдущим агентом:
    ```bash
    grime project python init my_service path : aider -m "Спроектируй API и укажи зависимости в <nix_packages>fastapi uvicorn httpx</nix_packages>" : nix flake init : nix run pytest
    ```
  * Каждая операция возвращает путь к проекту (`ctx.module_return(str(target_dir))`), обеспечивая бесшовные сквозные конвейеры.

### F. `box` (Distrobox Container Orchestration, Multi-container Management & Tooling Environments)
Управление контейнерами Distrobox, выполнение команд, изолированных сборок и интерактивных сессий в контексте проектов Grime с полной независимостью от порядка аргументов (Token Classifier), мультиконтейнерностью и сквозной прозрачностью конвейера (Pipeline Passthrough):
- **Инспекция контейнеров (list / ls / status / ps)**:
  Парсит `distrobox list --no-color` и выводит аккуратную цветовую таблицу со статусом (Running/Stopped), образами и отметкой контейнера по умолчанию:
  ```bash
  grime box                        # действие по умолчанию (список всех контейнеров)
  grime box list
  grime box fedora-box             # просмотр статуса конкретного контейнера
  ```
- **Умное определение целевого контейнера (Мультиконтейнерность)**:
  * Если контейнер указан явно (`grime box fedora-box ...`) — используется он.
  * Если не указан — проверяется ключ `distrobox_default` из `config/gproj.conf`, затем первый запущенный ("up"/"running"), затем первый доступный контейнер.
  * Если контейнеров нет — выдает понятную ошибку и предлагает `grime box create <имя>`.
- **Интерактивный вход в терминал контейнера (enter / shell / sh)**:
  Переходит в каталог целевого проекта (`target_dir`) и подключает реальный TTY-терминал к контейнеру:
  ```bash
  grime box enter                  # вход в дефолтный контейнер
  grime box fedora-box enter       # вход в fedora-box
  grime project cpp my_app path : box enter  # вход в контейнер прямо в директории проекта
  ```
- **Запуск команд и проектов внутри контейнера (run / runner / exec / wrap / do)**:
  Выполняет команду внутри контейнера в контексте `target_dir`: `distrobox enter <box> -- bash -c "cd '<dir>' && <cmd>"`.
  * Без аргументов: по умолчанию запускает `grime project run` внутри контейнера.
  * С модулями Grime (`project build run`, `pkg list`): запускает `grime <аргументы>` внутри контейнера.
  * С shell-командами (`make -j8`, `cargo build`, `pytest`, `gcc`): выполняет указанную команду.
  * Поддержка разделителя `--` для передачи сложных флагов (`grime box run -- make -j8`).
  * Возвращает путь проекта дальше в конвейер (`ctx.module_return(str(target_dir))`):
  ```bash
  grime box run make               # запуск make в дефолтном контейнере
  grime box fedora-box run make -j8
  grime box run project build run  # запуск Grime внутри контейнера
  grime project cpp my_app path : box fedora-box run make : project run
  ```
- **Экспорт утилит и приложений на хост (export / exp)**:
  Экспортирует бинарники или GUI-приложения из контейнера в систему через `distrobox-export`:
  ```bash
  grime box export bin /usr/bin/htop                 # экспорт бинарника в ~/.local/bin
  grime box export bin /usr/bin/mytool --name custom # с кастомным именем
  grime box export app code                          # экспорт desktop-приложения
  grime box export delete bin htop                   # удаление экспортированного бинарника
  grime box export list                              # просмотр всех экспортов контейнера
  ```
- **Создание нового контейнера (create / new / init)**:
  Интерактивная инициализация контейнера через `distrobox create`:
  ```bash
  grime box create fedora-box
  grime box create ubuntu-box --image ubuntu:22.04
  ```
- **Остановка и удаление (stop / rm / delete / remove)**:
  ```bash
  grime box stop fedora-box
  grime box rm fedora-box
  ```

### G. `host` (Host Environment Return Marker)
Специальный модуль-рубеж конвейера, завершающий делегирование в изолированные среды (Distrobox, Nix DevShell) и возвращающий контекст выполнения на хост:
- **Алиасы**: `host`, `exit-env`, `unhost`, `host-env`.
- **Поведение**:
  * Служит точкой отсечения подконвейера в механизме Tail Delegation.
  * Передает текущий рабочий каталог `target_dir` и входные данные конвейера дальше хостовым шагам.
  * Безопасен для одиночного вызова (возвращает `ctx.pipeline_input` или текущий путь).
  ```bash
  grime project cpp my_app path : box fedora-box : project build : host : project run
  ```



