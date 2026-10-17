use std::env;

#[tokio::main]
async fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.first().map(|s| s.as_str()) == Some("--daemon-server") {
        if let Err(e) = grime::daemon::run_daemon(None, None).await {
            eprintln!("[grime-daemon] Ошибка сервера демона: {}", e);
            std::process::exit(1);
        }
        std::process::exit(0);
    }

    let code = grime::client::run_client(&args, None, None).await;
    std::process::exit(code);
}
