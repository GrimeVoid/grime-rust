use std::env;

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    // Демон — долгоживущий многопоточный сервер; клиент — короткий процесс, которому
    // хватает current_thread runtime (без пула воркеров и cgroup-пробы числа CPU).
    let is_daemon = args.first().map(|s| s.as_str()) == Some("--daemon-server");
    let mut builder = if is_daemon {
        tokio::runtime::Builder::new_multi_thread()
    } else {
        tokio::runtime::Builder::new_current_thread()
    };
    let runtime = match builder.enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("[Grime] Не удалось создать runtime: {}", e);
            std::process::exit(1);
        }
    };

    if is_daemon {
        if let Err(e) = runtime.block_on(grime::daemon::run_daemon(None, None)) {
            eprintln!("[grime-daemon] Ошибка сервера демона: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

    // Клиент ведёт себя как классическая утилита: при закрытом читателе (`grime list | head`)
    // тихо завершается по SIGPIPE, а не паникует в println!. Rust по умолчанию ставит SIG_IGN,
    // поэтому восстанавливаем SIG_DFL. Демон (ветка выше) сохраняет SIG_IGN: запись в
    // оборванный сокет должна возвращать io::Error (EPIPE), а не убивать процесс.
    // Побочно дочерние процессы шагов наследуют штатный SIGPIPE, а не игнорирование.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }

    // Подметание эфемерных каталогов процессов, убитых без очистки (kill -9, потеря питания)
    grime::ephemeral::sweep_default();

    let code = runtime.block_on(grime::client::run_client(&args, None, None));
    // Не ждём завершения blocking-потоков при выходе процесса
    runtime.shutdown_background();
    std::process::exit(code);
}
