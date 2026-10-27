use std::{
    env,
    net::TcpListener,
    path::{Path, PathBuf},
};
fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("init") {
        if args.len() != 5 {
            return Err("usage: keytrail-server init CONFIG DATA_DIR ACCOUNT_ID DEVICE_ID".into());
        }
        keytrail_server::initialize(
            Path::new(&args[1]),
            PathBuf::from(&args[2]),
            "127.0.0.1:8787".into(),
            args[3].clone(),
            args[4].clone(),
        )?;
        println!("Private configuration created with mode 0600. Read credentials locally; never place them in URLs or logs.");
        return Ok(());
    }
    if args.len() != 2 || args[0] != "serve" {
        return Err(
            "usage: keytrail-server serve CONFIG | init CONFIG DATA_DIR ACCOUNT_ID DEVICE_ID"
                .into(),
        );
    }
    let config = keytrail_server::load_config(Path::new(&args[1]))?;
    let bind = config.bind.clone();
    let listener = TcpListener::bind(&bind).map_err(|e| e.to_string())?;
    let service = keytrail_server::Service::open(config)?;
    println!("KeyTrail private replica listening at {bind}; external access requires a private HTTPS reverse proxy.");
    keytrail_server::serve(listener, service)
}
fn main() {
    if let Err(e) = run() {
        eprintln!("KeyTrail server: {e}");
        std::process::exit(1)
    }
}
