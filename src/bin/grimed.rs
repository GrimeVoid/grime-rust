#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    grime::daemon::run_daemon(None, None).await
}
