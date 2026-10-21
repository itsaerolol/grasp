//! Headless receiver for the protocol tests: same server as the app, no toast.
//! Usage: grasp-headless [--port 53318] [--inbox DIR] [--state DIR] [--auto-accept | --reject]
//!        [--pair-code 123] (open a pairing window with this code)  [--auto-accept-paired]
//!        [--send PATH]... (queue files/folders for the paired iPhone)  [--send-text TEXT]
//! Without a decision flag it asks on stdin ("Accept? [y/N]"), like tools/mock-receiver.mjs.

use std::{path::PathBuf, sync::Arc, time::Duration};

use async_trait::async_trait;
use grasp_core::{build, cert, Config, IncomingRequest, Ui, UiEvent};
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
        println!("prepare-upload from {}{}: {}", req.from, if req.paired { " (paired)" } else { "" }, list.join(", "));
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
            UiEvent::AutoAccepted { request } => println!("AUTO-ACCEPTED from paired {}", request.from),
            UiEvent::Paired { device } => println!("PAIRED {} {}", device.alias, device.fingerprint),
            UiEvent::Unpaired { device, by_phone, .. } => {
                println!("UNPAIRED {} {}", device.alias, if by_phone { "by the phone" } else { "on the PC" })
            }
            UiEvent::Queued { count, waiting, .. } => println!("QUEUED {count} ({waiting} waiting)"),
            UiEvent::OutboxProgress { .. } => {}
            UiEvent::OutboxDelivered { name, remaining, .. } => println!("DELIVERED {name} ({remaining} left)"),
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
    let cfg = Config {
        port,
        inbox,
        alias: "Grasp PC (headless)".into(),
        state,
        auto_accept_paired: flag("--auto-accept-paired"),
    };
    let (handle, server) = build(cfg, identity, Arc::new(HeadlessUi(mode)))?;
    if args.iter().any(|a| a == "--pair-code") {
        let w = handle.start_pairing_with(&opt("--pair-code", "000"), Duration::from_secs(3600));
        println!("pairing open, code {}", w.code);
    }
    let values = |n: &str| -> Vec<String> {
        args.windows(2).filter(|w| w[0] == n).map(|w| w[1].clone()).collect()
    };
    let paths: Vec<PathBuf> = values("--send").into_iter().map(PathBuf::from).collect();
    if !paths.is_empty() {
        handle.send_paths(&paths);
    }
    for text in values("--send-text") {
        handle.send_text(&text);
    }
    server.await
}
