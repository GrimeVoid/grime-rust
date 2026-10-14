use std::env;

#[tokio::main]
async fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let code = grime::client::run_client(&args, None, None).await;
    std::process::exit(code);
}
