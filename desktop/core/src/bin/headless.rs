//! Headless receiver for the protocol tests: same server as the app, no toast.
//! Usage: grasp-headless [--port 53318] [--inbox DIR] [--state DIR] [--auto-accept | --reject]
//! Without a decision flag it asks on stdin ("Accept? [y/N]"), like tools/mock-receiver.mjs.

use std::{path::PathBuf, sync::Arc};

use async_trait::async_trait;
use grasp_core::{cert, serve, Config, IncomingRequest, Ui, UiEvent};
use tokio::io::{AsyncBufReadExt, BufReader};

enum Mode {
    Accept,
    Reject,
    Ask,
}

struct HeadlessUi(Mode);

#[async_trait]
impl Ui for HeadlessUi {
    async fn decide(&self, req: &IncomingRequest) -> bool {
        let list: Vec<String> = req.files.iter().map(|f| format!("{} {}B {}", f.name, f.size, f.mime)).collect();
        println!("prepare-upload from {}: {}", req.from, list.join(", "));
        match self.0 {
            Mode::Accept => true,
            Mode::Reject => false,
            Mode::Ask => {
                print!("Accept? [y/N] ");
                let mut line = String::new();
                let _ = BufReader::new(tokio::io::stdin()).read_line(&mut line).await;
                line.trim().to_lowercase().starts_with('y')
            }
        }
    }

    fn event(&self, ev: UiEvent) {
        match ev {
            UiEvent::Message { from, text, .. } => println!("MESSAGE from {from}: \"{text}\""),
            UiEvent::Progress { .. } => {}
            UiEvent::Done { count, dir, .. } => println!("session complete: {count} file(s) in {dir}"),
            UiEvent::Cancelled { .. } => println!("cancelled by sender"),
            UiEvent::Failed { reason, .. } => println!("FAILED {reason}"),
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |n: &str| args.iter().any(|a| a == n);
    let opt = |n: &str, d: &str| {
        args.iter().position(|a| a == n).and_then(|i| args.get(i + 1)).cloned().unwrap_or_else(|| d.to_string())
    };
    let port: u16 = opt("--port", "53318").parse()?;
    let inbox = PathBuf::from(opt("--inbox", "./headless-inbox"));
    let state = PathBuf::from(opt("--state", "./headless-state"));
    let mode = if flag("--auto-accept") {
        Mode::Accept
    } else if flag("--reject") {
        Mode::Reject
    } else {
        Mode::Ask
    };

    let identity = cert::load_or_create(&state)?;
    println!("Grasp headless receiver on https://0.0.0.0:{port}");
    println!("server cert fingerprint {}", identity.fingerprint);
    serve(Config { port, inbox, alias: "Grasp PC (headless)".into() }, identity, Arc::new(HeadlessUi(mode))).await
}
