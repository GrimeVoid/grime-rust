use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::net::UnixStream;

use crate::daemon::{
    get_socket_path, read_ipc_frame_async, write_ipc_frame_async, ClientMessage, DaemonResponse,
    IpcFrameError, MAX_IPC_PAYLOAD_SIZE,
};
use crate::orchestrator::Orchestrator;
use crate::pipeline::{has_preamble_flag, parse_pipeline_args};

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
          : , |\n  \
          \x1b[33mРазделители флагов:\x1b[0m -- или // (передача флагов напрямую подкоманде без перехвата ядром).\n\n\
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
/// и ожидает готовности Unix-сокета (очисткой устаревшего сокета занимается сам стартующий демон).
pub async fn connect_or_spawn_daemon() -> Result<UnixStream, std::io::Error> {
    let sock_path = get_socket_path();

    // 1. Попытка подключения к уже работающему демону
    if sock_path.exists() {
        if let Ok(stream) = UnixStream::connect(&sock_path).await {
            return Ok(stream);
        }
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

    let mut child = cmd.spawn()?;

    // 3. В цикле (до 15 попыток с паузой 25 мс, суммарно ~375 мс) дожидаемся появления и готовности сокета
    for _ in 0..15 {
        tokio::time::sleep(Duration::from_millis(25)).await;
        if sock_path.exists() {
            if let Ok(stream) = UnixStream::connect(&sock_path).await {
                let _ = child.try_wait();
                return Ok(stream);
            }
        }
        if let Ok(Some(status)) = child.try_wait() {
            // Если демон уже был запущен параллельным процессом или завершился с ошибкой,
            // пробуем подключиться к сокету ещё раз, прежде чем возвращать ошибку
            if sock_path.exists() {
                if let Ok(stream) = UnixStream::connect(&sock_path).await {
                    return Ok(stream);
                }
            }
            return Err(std::io::Error::other(format!(
                "Процесс демона завершился при запуске со статусом: {}",
                status
            )));
        }
    }

    let _ = child.try_wait();
    UnixStream::connect(&sock_path).await
}

pub async fn run_client(raw_args: &[String], modules_dir: Option<PathBuf>, config_path: Option<&Path>) -> i32 {
    let parsed = parse_pipeline_args(raw_args);

    if has_preamble_flag(raw_args, &["--version", "-v"]) && parsed.steps.is_empty() {
        println!("grime {}", env!("CARGO_PKG_VERSION"));
        return 0;
    }

    if (has_preamble_flag(raw_args, &["--help", "-h"]) && parsed.steps.is_empty())
        || parsed.steps.is_empty()
    {
        let config = crate::config::GrimeConfig::load_or_default(config_path);
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

        if write_ipc_frame_async(&mut stream, &msg).await.is_ok() {
            match read_ipc_frame_async::<_, DaemonResponse>(
                &mut stream,
                Duration::from_secs(10),
                Duration::from_secs(30),
            )
            .await
            {
                Ok(resp) => {
                    if let Some(ref res) = resp.result {
                        println!("{}", res);
                    }
                    if let Some(ref err) = resp.error {
                        eprintln!("[Grime] {}", err);
                    }
                    return resp.exit_code;
                }
                Err(IpcFrameError::PayloadTooLarge(resp_len)) => {
                    eprintln!(
                        "[Grime Security] Ошибка: размер ответа демона превышает максимально допустимый лимит ({} > {})",
                        resp_len, MAX_IPC_PAYLOAD_SIZE
                    );
                    return 1;
                }
                Err(_) => {}
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

    match orchestrator.run_pipeline(&parsed) {
        Ok(Some(result)) => {
            if !result.is_empty() {
                println!("{}", result);
            }
            0
        }
        Ok(None) => 0,
        Err(_err) => {
            // Сообщение об ошибке уже выведено ядром (Orchestrator) в едином формате [Grime Error]
            1
        }
    }
}
