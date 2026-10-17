use std::collections::HashMap;
use std::path::{Path, PathBuf};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::daemon::{get_socket_path, ClientMessage, DaemonResponse, MAX_IPC_PAYLOAD_SIZE};
use crate::orchestrator::Orchestrator;
use crate::pipeline::parse_pipeline_args;

fn print_global_help(config: &crate::config::GrimeConfig) {
    let modules = crate::pipeline::discover_available_modules(config);
    let mut mod_lines = String::new();
    if modules.is_empty() {
        mod_lines.push_str("          (модули не обнаружены в директориях поиска)\n");
    } else {
        for m in &modules {
            let desc = match m.as_str() {
                "project" => "Жизненный цикл проектов (C++, Rust, Python, Java)",
                "pkg" => "Универсальный мета-менеджер пакетов (pacman, nix, flatpak...)",
                "app" => "Изолированные легковесные приложения",
                "box" => "Оркестрация Distrobox-контейнеров",
                "nix" => "Воспроизводимые Nix-окружения и Flakes",
                "aider" => "AI-ассистент разработчика",
                "cmd" => "Выполнение системных команд и TUI-утилит",
                "host" => "Модуль-рубеж возврата на хост-машину",
                "list" => "Список всех доступных модулей (алиасы: ls, modules)",
                "doctor" => "Диагностика окружения, путей и зависимостей Grime",
                "bus" => "Шина разделяемого состояния (StateBus) и событий",
                "daemon" => "Управление фоновым сервисом-демоном (grime daemon)",
                "git" => "Полноценное управление Git-репозиториями и версионированием",
                "log" => "Централизованный сбор, хранение и фильтрация логов",
                "benchmark" => "Стресс-тестирование, бенчмаркинг конвейеров и замеры задержек",
                "polyglot" => "Полиглотный межъязыковой клей и бенчмарк IPC (Python <-> Grime <-> C)",
                _ => "Модуль расширения Grime",
            };
            mod_lines.push_str(&format!("          \x1b[32m{:<20}\x1b[0m {}\n", m, desc));
        }
    }

    println!(
        "\x1b[1mGrime Next Generation (Grime-RS)\x1b[0m 🦀🌙\n\
        Модульный оркестратор конвейеров, контейнеров и окружений разработчика.\n\n\
        \x1b[1mИспользование:\x1b[0m\n  \
          grime [опции] <модуль> [аргументы] [ : <модуль> [аргументы] ... ]\n\n\
        \x1b[1mРазделители конвейера:\x1b[0m\n  \
          : , -> , |\n  \
          \x1b[33mПодсказка для Fish shell:\x1b[0m Токен '->' парсится шеллом как редирект в файл (>).\n  \
          В Fish shell рекомендуется использовать двоеточие ':' или экранировать '\"->\"'.\n\n\
        \x1b[1mГлобальные флаги:\x1b[0m\n  \
          -f, --force          Игнорировать ошибки шагов конвейера\n  \
          -d, --detach         Запуск открепленной фоновой задачи через встроенный демон\n  \
          -p, --path <путь>    Задать базовую рабочую директорию конвейера\n  \
          -h, --help           Показать эту справку\n  \
          -v, --version        Показать версию программы\n\n\
        \x1b[1mДоступные модули:\x1b[0m\n\
        {}\n\n\
        \x1b[90mДля справки по конкретному модулю: grime <модуль> --help\x1b[0m",
        mod_lines.trim_end()
    );
}

/// Подключение к демону с ленивым авто-спавном:
/// Если сокет отсутствует или подключение возвращает ошибку,
/// автоматически запускает `grime --daemon-server` в фоне как открепленный процесс
/// и ожидает готовности Unix-сокета.
pub async fn connect_or_spawn_daemon() -> Result<UnixStream, std::io::Error> {
    let sock_path = get_socket_path();

    // 1. Попытка подключения к уже работающему демону
    if sock_path.exists() {
        if let Ok(stream) = UnixStream::connect(&sock_path).await {
            return Ok(stream);
        }
        // Сокет существует, но подключение не удалось (демон упал или завершился некорректно)
        let _ = std::fs::remove_file(&sock_path);
    }

    // 2. Авто-спавн grime --daemon-server в фоне как открепленный процесс
    let current_exe = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("grime"));
    let mut cmd = std::process::Command::new(current_exe);
    cmd.arg("--daemon-server")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());

    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        unsafe {
            cmd.pre_exec(|| {
                libc::setsid();
                Ok(())
            });
        }
    }

    cmd.spawn()?;

    // 3. В цикле (до 15 попыток с паузой 25 мс, суммарно ~375 мс) дожидаемся появления и готовности сокета
    for _ in 0..15 {
        tokio::time::sleep(tokio::time::Duration::from_millis(25)).await;
        if sock_path.exists() {
            if let Ok(stream) = UnixStream::connect(&sock_path).await {
                return Ok(stream);
            }
        }
    }

    UnixStream::connect(&sock_path).await
}

pub async fn run_client(raw_args: &[String], modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> i32 {
    let parsed = parse_pipeline_args(raw_args);
    let config = crate::config::GrimeConfig::load_or_default(config_path);

    let normalized = crate::args::normalize_cli_flags(raw_args, crate::args::GLOBAL_GRIME_FLAGS);

    if normalized.iter().any(|a| a == "--version" || a == "-v") && parsed.steps.is_empty() {
        println!("grime {}", env!("CARGO_PKG_VERSION"));
        return 0;
    }

    if normalized.iter().any(|a| a == "--help" || a == "-h") && parsed.steps.is_empty() {
        print_global_help(&config);
        return 0;
    }

    if parsed.steps.is_empty() {
        print_global_help(&config);
        return 0;
    }

    // 1. Если указан флаг --detach / -d: передаем задачу супервизору демона через Unix-сокет
    if parsed.detach {
        let mut stream = match connect_or_spawn_daemon().await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[Grime] Ошибка подключения к демону (авто-запуск не удался): {}", e);
                return 1;
            }
        };

        let cwd = std::env::current_dir()
            .unwrap_or_else(|_| PathBuf::from("."))
            .to_string_lossy()
            .to_string();

        let mut env = HashMap::new();
        for (k, v) in std::env::vars() {
            env.insert(k, v);
        }

        let msg = ClientMessage::Run {
            cwd,
            args: raw_args.to_vec(),
            env,
            detach: true,
        };

        if let Ok(bytes) = rmp_serde::to_vec_named(&msg) {
            let len = (bytes.len() as u32).to_be_bytes();
            if stream.write_all(&len).await.is_ok() && stream.write_all(&bytes).await.is_ok() {
                let mut len_buf = [0u8; 4];
                if stream.read_exact(&mut len_buf).await.is_ok() {
                    let resp_len = u32::from_be_bytes(len_buf) as usize;
                    if resp_len > MAX_IPC_PAYLOAD_SIZE {
                        eprintln!(
                            "[Grime Security] Ошибка: размер ответа демона превышает максимально допустимый лимит ({} > {})",
                            resp_len, MAX_IPC_PAYLOAD_SIZE
                        );
                        return 1;
                    }
                    let mut resp_buf = vec![0u8; resp_len];
                    if stream.read_exact(&mut resp_buf).await.is_ok() {
                        if let Ok(resp) = rmp_serde::from_slice::<DaemonResponse>(&resp_buf) {
                            if let Some(ref res) = resp.result {
                                println!("{}", res);
                            }
                            if let Some(ref err) = resp.error {
                                eprintln!("[Grime] {}", err);
                            }
                            return resp.exit_code;
                        }
                    }
                }
            }
        }

        eprintln!("[Grime] Ошибка: Не удалось передать задачу демону или получить ответ.");
        return 1;
    }

    // 2. Client-First Architecture:
    // Интерактивные TUI-приложения (Neovim, fzf, диалоговый режим Aider) и стандартный конвейер
    // исполняются локально в процессе CLI-клиента с прямым доступом к нативным потокам (stdin/stdout/stderr)
    // и сигналам терминала.
    let orchestrator = match Orchestrator::new(modules_dir, config_path) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("[Grime] Ошибка инициализации оркестратора: {}", e);
            return 1;
        }
    };

    let _ctrl_c = crate::cancellation::spawn_ctrl_c_watcher(orchestrator.canceller().clone());

    match orchestrator.run_pipeline(&parsed).await {
        Ok(Some(result)) => {
            if !result.is_empty() {
                println!("{}", result);
            }
            0
        }
        Ok(None) => 0,
        Err(err) => {
            eprintln!("[Grime] Конвейер остановлен из-за ошибки: {}", err);
            1
        }
    }
}
