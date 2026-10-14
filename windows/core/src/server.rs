//! LocalSend v2.2 receiver. Mirrors the rules of tools/mock-receiver.mjs, which in turn mirrors
//! localsend/localsend packages/core. Keep the three in lockstep.

use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::Result;
use axum::{
    body::Body,
    extract::{ConnectInfo, DefaultBodyLimit, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_server::tls_rustls::RustlsConfig;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;

use crate::{
    cert::Identity,
    ui::{FileSummary, IncomingRequest, Ui, UiEvent},
};

pub const API: &str = "/api/localsend/v2";
pub const VERSION: &str = "2.2";
/// How long the toast waits for the human. Silence is a rejection, never an acceptance.
/// (The sender's own prepare-upload timeout is 600s; this is deliberately much shorter.)
const DECISION_TIMEOUT: Duration = Duration::from_secs(30);
/// A session with no upload activity for this long no longer blocks new senders.
const SESSION_IDLE: Duration = Duration::from_secs(300);

pub struct Config {
    pub port: u16,
    pub inbox: PathBuf,
    pub alias: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
struct DeviceInfo {
    #[serde(default)]
    alias: String,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    device_model: Option<String>,
    #[serde(default)]
    device_type: Option<String>,
    #[serde(default)]
    fingerprint: Option<String>,
    #[serde(default)]
    port: Option<u16>,
    #[serde(default)]
    protocol: Option<String>,
    #[serde(default)]
    download: Option<bool>,
}

#[derive(Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
struct FileDto {
    id: String,
    file_name: String,
    size: u64,
    #[serde(default)]
    file_type: String,
    #[serde(default)]
    sha256: Option<String>,
    #[serde(default)]
    preview: Option<String>,
}

#[derive(Deserialize)]
struct PrepareReq {
    #[serde(default)]
    info: DeviceInfo,
    files: HashMap<String, FileDto>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PrepareRes {
    session_id: String,
    files: HashMap<String, String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct UploadQuery {
    session_id: Option<String>,
    file_id: Option<String>,
    token: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CancelQuery {
    session_id: Option<String>,
}

struct FileEntry {
    name: String,
    sha256: Option<String>,
    token: String,
    done: bool,
}

struct Session {
    id: String,
    request_id: String,
    ip: IpAddr,
    files: HashMap<String, FileEntry>,
    total: u64,
    received: u64,
    saved: Vec<PathBuf>,
    last_activity: Instant,
}

enum Slot {
    Free,
    /// prepare-upload is waiting for the human. Blocks other senders (409).
    Pending(Instant),
    Active(Session),
}

struct Inner {
    ui: Arc<dyn Ui>,
    cfg: Config,
    info: DeviceInfo,
    slot: Mutex<Slot>,
}

type AppState = Arc<Inner>;

pub async fn serve(cfg: Config, identity: Identity, ui: Arc<dyn Ui>) -> Result<()> {
    // rustls needs exactly one crypto provider installed process-wide. Ignore "already installed".
    let _ = rustls::crypto::ring::default_provider().install_default();
    std::fs::create_dir_all(&cfg.inbox)?;

    let info = DeviceInfo {
        alias: cfg.alias.clone(),
        version: Some(VERSION.into()),
        device_model: Some("Windows".into()),
        device_type: Some("desktop".into()),
        // LocalSend 1.17 reports the TLS cert fingerprint here, so do the same.
        fingerprint: Some(identity.fingerprint.clone()),
        port: Some(cfg.port),
        protocol: Some("https".into()),
        download: Some(false),
    };
    let port = cfg.port;
    let state: AppState = Arc::new(Inner { ui, cfg, info, slot: Mutex::new(Slot::Free) });

    let app = Router::new()
        .route(&format!("{API}/info"), get(info_handler))
        .route(&format!("{API}/register"), post(register_handler))
        .route(&format!("{API}/prepare-upload"), post(prepare_upload))
        .route(&format!("{API}/upload"), post(upload))
        .route(&format!("{API}/cancel"), post(cancel))
        .layer(DefaultBodyLimit::disable())
        .with_state(state);

    let tls = RustlsConfig::from_pem(identity.cert_pem.into_bytes(), identity.key_pem.into_bytes()).await?;
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    axum_server::bind_rustls(addr, tls)
        .serve(app.into_make_service_with_connect_info::<SocketAddr>())
        .await?;
    Ok(())
}

fn json_error(status: StatusCode, message: &str) -> Response {
    (status, Json(serde_json::json!({ "message": message }))).into_response()
}

async fn info_handler(State(s): State<AppState>) -> Json<DeviceInfo> {
    Json(s.info.clone())
}

/// Discovery handshake. We answer everyone; nothing is stored until a transfer is accepted.
async fn register_handler(State(s): State<AppState>, Json(_peer): Json<DeviceInfo>) -> Json<DeviceInfo> {
    Json(s.info.clone())
}

/// Clears the slot (and dismisses the toast) if prepare-upload is dropped before it finishes,
/// e.g. the phone gave up while the toast was still on screen.
struct PendingGuard {
    state: AppState,
    request_id: String,
    armed: bool,
}

impl Drop for PendingGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let mut slot = self.state.slot.lock().unwrap();
        if matches!(*slot, Slot::Pending(_)) {
            *slot = Slot::Free;
        }
        drop(slot);
        self.state.ui.event(UiEvent::Cancelled { id: self.request_id.clone() });
    }
}

async fn prepare_upload(
    State(s): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Json(req): Json<PrepareReq>,
) -> Response {
    let files: Vec<&FileDto> = req.files.values().collect();
    if files.is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "No files provided");
    }
    let from = if req.info.alias.trim().is_empty() { "Unknown device".to_string() } else { req.info.alias.clone() };

    // A text message is exactly one text/plain file carrying its content in `preview`.
    // It goes through the same Accept gate as files; only the outcome differs (204, no upload).
    let message: Option<String> = if files.len() == 1 && files[0].file_type == "text/plain" {
        files[0].preview.clone()
    } else {
        None
    };

    {
        let mut slot = s.slot.lock().unwrap();
        let busy = match &*slot {
            Slot::Free => false,
            Slot::Pending(since) => since.elapsed() < DECISION_TIMEOUT + Duration::from_secs(30),
            Slot::Active(sess) => sess.last_activity.elapsed() < SESSION_IDLE,
        };
        if busy {
            return json_error(StatusCode::CONFLICT, "Blocked by another session");
        }
        *slot = Slot::Pending(Instant::now());
    }

    let request_id = uuid::Uuid::new_v4().to_string();
    let mut guard = PendingGuard { state: s.clone(), request_id: request_id.clone(), armed: true };

    let mut summaries: Vec<FileSummary> = files
        .iter()
        .map(|f| FileSummary { name: safe_file_name(&f.file_name), size: f.size, mime: f.file_type.clone() })
        .collect();
    summaries.sort_by(|a, b| a.name.cmp(&b.name));
    let total: u64 = files.iter().map(|f| f.size).sum();
    let incoming = IncomingRequest {
        id: request_id.clone(),
        from,
        device_model: req.info.device_model.clone(),
        files: summaries,
        total,
        message: message.clone(),
    };

    let accepted = tokio::time::timeout(DECISION_TIMEOUT, s.ui.decide(&incoming)).await.unwrap_or(false);
    if !accepted {
        *s.slot.lock().unwrap() = Slot::Free;
        guard.armed = false;
        // Also covers the decision timeout: the shell must take the toast down either way.
        s.ui.event(UiEvent::Cancelled { id: incoming.id.clone() });
        return json_error(StatusCode::FORBIDDEN, "Rejected");
    }

    if let Some(text) = message {
        *s.slot.lock().unwrap() = Slot::Free;
        guard.armed = false;
        s.ui.event(UiEvent::Message { id: incoming.id.clone(), from: incoming.from.clone(), text });
        return StatusCode::NO_CONTENT.into_response();
    }

    let mut tokens = HashMap::new();
    let mut entries = HashMap::new();
    for f in req.files.values() {
        let token = uuid::Uuid::new_v4().to_string();
        tokens.insert(f.id.clone(), token.clone());
        entries.insert(
            f.id.clone(),
            FileEntry { name: safe_file_name(&f.file_name), sha256: f.sha256.clone(), token, done: false },
        );
    }
    let session_id = uuid::Uuid::new_v4().to_string();
    *s.slot.lock().unwrap() = Slot::Active(Session {
        id: session_id.clone(),
        request_id,
        ip: addr.ip(),
        files: entries,
        total,
        received: 0,
        saved: Vec::new(),
        last_activity: Instant::now(),
    });
    guard.armed = false;
    Json(PrepareRes { session_id, files: tokens }).into_response()
}

async fn upload(
    State(s): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    Query(q): Query<UploadQuery>,
    body: Body,
) -> Response {
    let (Some(session_id), Some(file_id), Some(token)) = (q.session_id, q.file_id, q.token) else {
        return json_error(StatusCode::BAD_REQUEST, "Missing parameters");
    };

    // Validate and grab what we need without holding the lock across awaits.
    let (name, expected_sha, request_id) = {
        let mut slot = s.slot.lock().unwrap();
        let Slot::Active(sess) = &mut *slot else {
            return json_error(StatusCode::FORBIDDEN, "Invalid token or IP address");
        };
        let ok = sess.id == session_id
            && sess.ip == addr.ip()
            && sess.files.get(&file_id).is_some_and(|f| f.token == token);
        if !ok {
            return json_error(StatusCode::FORBIDDEN, "Invalid token or IP address");
        }
        sess.last_activity = Instant::now();
        let f = &sess.files[&file_id];
        (f.name.clone(), f.sha256.clone(), sess.request_id.clone())
    };

    let tmp = s.cfg.inbox.join(format!(".{file_id}.part"));
    let streamed = stream_to_disk(&s, body, &tmp, &request_id).await;
    let actual = match streamed {
        Ok(hash) => hash,
        Err(e) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            s.ui.event(UiEvent::Failed { id: request_id, reason: format!("Transfer interrupted: {e}") });
            *s.slot.lock().unwrap() = Slot::Free;
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Upload failed");
        }
    };

    if let Some(expected) = expected_sha {
        if !expected.eq_ignore_ascii_case(&actual) {
            let _ = tokio::fs::remove_file(&tmp).await;
            return json_error(StatusCode::UNPROCESSABLE_ENTITY, "Checksum mismatch");
        }
    }

    let dest = unique_path(&s.cfg.inbox, &name);
    if let Err(e) = tokio::fs::rename(&tmp, &dest).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        s.ui.event(UiEvent::Failed { id: request_id, reason: format!("Couldn't save {name}: {e}") });
        *s.slot.lock().unwrap() = Slot::Free;
        return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Couldn't save file");
    }

    let finished = {
        let mut slot = s.slot.lock().unwrap();
        let Slot::Active(sess) = &mut *slot else { return StatusCode::OK.into_response() };
        if let Some(f) = sess.files.get_mut(&file_id) {
            f.done = true;
        }
        sess.saved.push(dest);
        sess.last_activity = Instant::now();
        if sess.files.values().all(|f| f.done) {
            let done = (sess.request_id.clone(), sess.saved.clone());
            *slot = Slot::Free;
            Some(done)
        } else {
            None
        }
    };
    if let Some((id, saved)) = finished {
        s.ui.event(UiEvent::Done {
            id,
            count: saved.len(),
            dir: s.cfg.inbox.display().to_string(),
            first_file: saved.first().map(|p| p.display().to_string()),
        });
    }
    StatusCode::OK.into_response()
}

/// Streams the request body to `tmp` and returns the lowercase hex SHA-256. Never buffers a file.
async fn stream_to_disk(s: &AppState, body: Body, tmp: &Path, request_id: &str) -> Result<String> {
    let mut file = tokio::fs::File::create(tmp).await?;
    let mut hasher = Sha256::new();
    let mut stream = body.into_data_stream();
    let mut last_emit = Instant::now() - Duration::from_secs(1);

    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        hasher.update(&chunk);
        file.write_all(&chunk).await?;

        let (received, total) = {
            let mut slot = s.slot.lock().unwrap();
            let Slot::Active(sess) = &mut *slot else { anyhow::bail!("session ended") };
            sess.received += chunk.len() as u64;
            sess.last_activity = Instant::now();
            (sess.received, sess.total)
        };
        // ~15 updates a second is plenty for a progress bar and keeps the UI thread calm.
        if last_emit.elapsed() >= Duration::from_millis(65) {
            last_emit = Instant::now();
            s.ui.event(UiEvent::Progress { id: request_id.to_string(), received, total });
        }
    }
    file.flush().await?;
    // Final tick so the bar always lands on the true value before the Done event.
    let (received, total) = match &*s.slot.lock().unwrap() {
        Slot::Active(sess) => (sess.received, sess.total),
        _ => (0, 0),
    };
    s.ui.event(UiEvent::Progress { id: request_id.to_string(), received, total });
    Ok(hex::encode(hasher.finalize()))
}

async fn cancel(State(s): State<AppState>, Query(q): Query<CancelQuery>) -> Response {
    let cancelled = {
        let mut slot = s.slot.lock().unwrap();
        match &*slot {
            Slot::Active(sess) if q.session_id.as_deref() == Some(sess.id.as_str()) => {
                let id = sess.request_id.clone();
                *slot = Slot::Free;
                Some(id)
            }
            _ => None,
        }
    };
    if let Some(id) = cancelled {
        s.ui.event(UiEvent::Cancelled { id });
    }
    StatusCode::OK.into_response()
}

/// Sender-controlled names must never escape the inbox: keep the last path component only and
/// replace characters Windows forbids.
pub fn safe_file_name(raw: &str) -> String {
    let base = raw.rsplit(['/', '\\']).next().unwrap_or("");
    let cleaned: String = base
        .chars()
        .map(|c| if matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*') || c.is_control() { '_' } else { c })
        .collect();
    let cleaned = cleaned.trim_matches(|c: char| c == '.' || c == ' ').to_string();
    if cleaned.is_empty() {
        "file".to_string()
    } else {
        cleaned
    }
}

/// `photo.jpg`, then `photo (2).jpg`, `photo (3).jpg`... Never overwrites.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let first = dir.join(name);
    if !first.exists() {
        return first;
    }
    let p = Path::new(name);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or(name);
    let ext = p.extension().and_then(|s| s.to_str());
    (2u32..)
        .map(|n| match ext {
            Some(e) => dir.join(format!("{stem} ({n}).{e}")),
            None => dir.join(format!("{stem} ({n})")),
        })
        .find(|c| !c.exists())
        .unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_names_cannot_escape_the_inbox() {
        assert_eq!(safe_file_name("../../Windows/evil.exe"), "evil.exe");
        assert_eq!(safe_file_name("C:\\Users\\x\\a.txt"), "a.txt");
        assert_eq!(safe_file_name("a:b?c*.jpg"), "a_b_c_.jpg");
        assert_eq!(safe_file_name(".."), "file");
        assert_eq!(safe_file_name("  "), "file");
        assert_eq!(safe_file_name("IMG_0001.JPG"), "IMG_0001.JPG");
    }

    #[test]
    fn unique_path_never_overwrites() {
        let dir = std::env::temp_dir().join(format!("grasp-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        assert_eq!(unique_path(&dir, "a.jpg"), dir.join("a.jpg"));
        std::fs::write(dir.join("a.jpg"), b"x").unwrap();
        assert_eq!(unique_path(&dir, "a.jpg"), dir.join("a (2).jpg"));
        std::fs::write(dir.join("a (2).jpg"), b"x").unwrap();
        assert_eq!(unique_path(&dir, "a.jpg"), dir.join("a (3).jpg"));
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
