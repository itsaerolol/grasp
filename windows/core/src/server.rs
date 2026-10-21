//! LocalSend v2.2 receiver. Mirrors the rules of tools/mock-receiver.mjs, which in turn mirrors
//! localsend/localsend packages/core. Keep the three in lockstep.

use std::{
    collections::HashMap,
    future::Future,
    net::{IpAddr, SocketAddr},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

use anyhow::Result;
use axum::{
    body::{Body, Bytes},
    extract::{ConnectInfo, DefaultBodyLimit, Query, State},
    Extension,
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_server::tls_rustls::{RustlsAcceptor, RustlsConfig};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

use crate::{
    cert::Identity,
    outbox::{OutItem, Outbox},
    pairing::{PairOutcome, PairedDevice, Pairing, PairingWindow},
    tls::{self, PeerCert, PeerCertAcceptor},
    ui::{FileSummary, IncomingRequest, Ui, UiEvent},
};

pub const API: &str = "/api/localsend/v2";
pub const VERSION: &str = "2.2";
/// Grasp-only extension, advertised as `"grasp": N` in /info and /register. 1: code pairing.
/// 2: also the outbox (Windows -> iPhone, the phone pulls; see outbox.rs). 3: also durable pairing
/// (`GET .../pair` = is this phone paired, `POST .../unpair`, removed phones refused; see pairing.rs).
pub const GRASP_API: &str = "/api/grasp/v1";
pub const GRASP_LEVEL: u8 = 3;
/// How long the toast waits for the human. Silence is a rejection, never an acceptance.
/// (The sender's own prepare-upload timeout is 600s; this is deliberately much shorter.)
const DECISION_TIMEOUT: Duration = Duration::from_secs(30);
/// A session with no upload activity for this long no longer blocks new senders.
const SESSION_IDLE: Duration = Duration::from_secs(300);

pub struct Config {
    pub port: u16,
    pub inbox: PathBuf,
    pub alias: String,
    /// Where paired devices (`paired.json`) and the outbox queue (`outbox.json`) are kept.
    pub state: PathBuf,
    /// Skip the Accept prompt for paired devices. Never applies to anyone else.
    pub auto_accept_paired: bool,
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
    /// Grasp for Windows only: 1 = code pairing (`/api/grasp/v1/pair`), 2 = also the outbox. Stock
    /// LocalSend ignores it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    grasp: Option<u8>,
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

#[derive(Deserialize)]
struct IdQuery {
    id: Option<String>,
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
    info: DeviceInfo,
    slot: Mutex<Slot>,
    inbox: Mutex<PathBuf>,
    auto_accept: AtomicBool,
    pairing: Pairing,
    outbox: Outbox,
    /// The last session cancelled (by the sender or on the PC): its later uploads get 410, not 403.
    cancelled: Mutex<Option<String>>,
}

type AppState = Arc<Inner>;

#[derive(Deserialize)]
struct PairReq {
    code: String,
    #[serde(default)]
    info: DeviceInfo,
}

/// What the shell uses to change settings and drive pairing while the server runs.
#[derive(Clone)]
pub struct Handle(Arc<Inner>);

impl Handle {
    pub fn inbox(&self) -> PathBuf {
        self.0.inbox.lock().unwrap().clone()
    }
    pub fn set_inbox(&self, dir: PathBuf) {
        *self.0.inbox.lock().unwrap() = dir;
    }
    pub fn auto_accept_paired(&self) -> bool {
        self.0.auto_accept.load(Ordering::Relaxed)
    }
    pub fn set_auto_accept_paired(&self, on: bool) {
        self.0.auto_accept.store(on, Ordering::Relaxed);
    }
    pub fn start_pairing(&self) -> PairingWindow {
        self.0.pairing.open()
    }
    pub fn start_pairing_with(&self, code: &str, lifetime: Duration) -> PairingWindow {
        self.0.pairing.open_with(code.to_string(), lifetime)
    }
    pub fn cancel_pairing(&self) {
        self.0.pairing.close();
    }
    pub fn pairing(&self) -> Option<PairingWindow> {
        self.0.pairing.current()
    }
    pub fn paired_devices(&self) -> Vec<PairedDevice> {
        self.0.pairing.devices()
    }
    /// The X in the window: forget the phone; the phone notices within seconds and drops the PC too.
    pub fn unpair(&self, fingerprint: &str) {
        unpair_phone(&self.0, fingerprint, false);
    }

    /// Queues files and folders for the paired iPhone to pull. Returns how many files were queued.
    pub fn send_paths(&self, paths: &[PathBuf]) -> usize {
        let added = self.0.outbox.add_paths(paths);
        self.queued(&added);
        added.len()
    }

    /// Queues text (or a link); the phone puts it on its clipboard.
    pub fn send_text(&self, text: &str) -> bool {
        let added: Vec<OutItem> = self.0.outbox.add_text(text).into_iter().collect();
        self.queued(&added);
        !added.is_empty()
    }

    fn queued(&self, added: &[OutItem]) {
        if !added.is_empty() {
            let first = added.first().map(|i| i.label());
            self.0.ui.event(UiEvent::Queued { count: added.len(), waiting: self.0.outbox.len(), first });
        }
    }

    pub fn outbox_len(&self) -> usize {
        self.0.outbox.len()
    }

    /// Clears the queue. A file the phone is downloading right now stops mid-stream.
    pub fn clear_outbox(&self) {
        self.0.outbox.clear();
    }

    /// The X on the receiving toast: ends that transfer and deletes everything it saved.
    pub fn cancel_receive(&self, request_id: &str) {
        if let Some(id) = abort_session(&self.0, None, Some(request_id)) {
            self.0.ui.event(UiEvent::Cancelled { id });
        }
    }
}

pub async fn serve(cfg: Config, identity: Identity, ui: Arc<dyn Ui>) -> Result<()> {
    let (_handle, server) = build(cfg, identity, ui)?;
    server.await
}

/// Builds the receiver. Returns a handle for the shell and the future that runs the server.
pub fn build(
    cfg: Config,
    identity: Identity,
    ui: Arc<dyn Ui>,
) -> Result<(Handle, impl Future<Output = Result<()>> + Send + 'static)> {
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
        grasp: Some(GRASP_LEVEL),
    };
    let port = cfg.port;
    let state: AppState = Arc::new(Inner {
        ui,
        info,
        slot: Mutex::new(Slot::Free),
        inbox: Mutex::new(cfg.inbox),
        auto_accept: AtomicBool::new(cfg.auto_accept_paired),
        pairing: Pairing::load(cfg.state.join("paired.json")),
        outbox: Outbox::load(cfg.state.join("outbox.json")),
        cancelled: Mutex::new(None),
    });
    let handle = Handle(state.clone());

    let app = Router::new()
        .route(&format!("{API}/info"), get(info_handler))
        .route(&format!("{API}/register"), post(register_handler))
        .route(&format!("{API}/prepare-upload"), post(prepare_upload))
        .route(&format!("{API}/upload"), post(upload))
        .route(&format!("{API}/cancel"), post(cancel))
        .route(&format!("{GRASP_API}/pair"), post(pair_handler).get(pair_status))
        .route(&format!("{GRASP_API}/unpair"), post(unpair_handler))
        .route(&format!("{GRASP_API}/outbox"), get(outbox_list))
        .route(&format!("{GRASP_API}/outbox/file"), get(outbox_file))
        .route(&format!("{GRASP_API}/outbox/done"), post(outbox_done))
        .layer(DefaultBodyLimit::disable())
        .with_state(state);

    let tls = RustlsConfig::from_config(Arc::new(tls::server_config(&identity)?));
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let server = async move {
        axum_server::bind(addr)
            .acceptor(PeerCertAcceptor(RustlsAcceptor::new(tls)))
            .serve(app.into_make_service_with_connect_info::<SocketAddr>())
            .await?;
        Ok(())
    };
    Ok((handle, server))
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

/// Code pairing. Needs the phone's client certificate: its fingerprint is what gets remembered.
async fn pair_handler(
    State(s): State<AppState>,
    Extension(PeerCert(fp)): Extension<PeerCert>,
    Json(req): Json<PairReq>,
) -> Response {
    let Some(fp) = fp else {
        return json_error(StatusCode::BAD_REQUEST, "Client certificate required");
    };
    let alias = if req.info.alias.trim().is_empty() { "Unknown device".to_string() } else { req.info.alias.clone() };
    match s.pairing.try_pair(&req.code, &fp, &alias, req.info.device_model.clone()) {
        PairOutcome::Paired(device) => {
            s.ui.event(UiEvent::Paired { device });
            Json(s.info.clone()).into_response()
        }
        PairOutcome::NotOpen => json_error(StatusCode::CONFLICT, "Pairing is not open on the PC"),
        PairOutcome::WrongCode { attempts_left } => (
            StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({ "message": "Wrong code", "attemptsLeft": attempts_left })),
        )
            .into_response(),
        PairOutcome::Locked => json_error(StatusCode::TOO_MANY_REQUESTS, "Too many wrong codes"),
        PairOutcome::AlreadyPaired(_) => (
            StatusCode::CONFLICT,
            Json(serde_json::json!({ "message": "Already paired", "alreadyPaired": true, "alias": s.info.alias })),
        )
            .into_response(),
    }
}

/// Is the phone presenting this cert paired? The phone asks every few seconds and drops the PC when not.
async fn pair_status(State(s): State<AppState>, Extension(PeerCert(fp)): Extension<PeerCert>) -> Response {
    let Some(fp) = fp else {
        return json_error(StatusCode::BAD_REQUEST, "Client certificate required");
    };
    Json(serde_json::json!({ "paired": s.pairing.is_paired(&fp), "alias": s.info.alias })).into_response()
}

/// The phone unpaired this PC: forget it here too.
async fn unpair_handler(State(s): State<AppState>, Extension(PeerCert(fp)): Extension<PeerCert>) -> Response {
    let Some(fp) = fp else {
        return json_error(StatusCode::BAD_REQUEST, "Client certificate required");
    };
    unpair_phone(&s, &fp, true);
    StatusCode::OK.into_response()
}

/// One place for both sides' unpair. With no paired phone left, nothing can collect the outbox, so it's
/// cleared (the toast and menu are told).
fn unpair_phone(s: &Inner, fingerprint: &str, by_phone: bool) {
    let Some(device) = s.pairing.unpair(fingerprint) else { return };
    let outbox_cleared = s.pairing.devices().is_empty() && !s.outbox.is_empty();
    if outbox_cleared {
        s.outbox.clear();
    }
    s.ui.event(UiEvent::Unpaired { device, by_phone, outbox_cleared });
}

/// The outbox is only for a phone paired by code: its client cert fingerprint is the proof.
fn require_paired(s: &AppState, fp: &Option<String>) -> Result<(), Response> {
    match fp {
        Some(fp) if s.pairing.is_paired(fp) => Ok(()),
        Some(_) => Err(json_error(StatusCode::FORBIDDEN, "Not paired: pair this iPhone by code first")),
        None => Err(json_error(StatusCode::FORBIDDEN, "Client certificate required")),
    }
}

fn gone(s: &AppState, item: &OutItem) {
    s.ui.event(UiEvent::Failed {
        id: format!("outbox-{}", item.id()),
        reason: format!("{} wasn't sent to iPhone: it was moved or deleted.", item.label()),
    });
}

/// What's waiting for the phone. Files moved or deleted since they were queued are dropped (and reported).
async fn outbox_list(State(s): State<AppState>, Extension(PeerCert(fp)): Extension<PeerCert>) -> Response {
    if let Err(r) = require_paired(&s, &fp) {
        return r;
    }
    for item in s.outbox.prune_missing() {
        gone(&s, &item);
    }
    let items: Vec<_> = s.outbox.items().iter().map(OutItem::wire).collect();
    Json(serde_json::json!({ "items": items })).into_response()
}

/// Streams one queued file from where it is on disk, in 256 KB chunks. Never buffers the file.
async fn outbox_file(
    State(s): State<AppState>,
    Extension(PeerCert(fp)): Extension<PeerCert>,
    Query(q): Query<IdQuery>,
) -> Response {
    if let Err(r) = require_paired(&s, &fp) {
        return r;
    }
    let Some(id) = q.id else { return json_error(StatusCode::BAD_REQUEST, "Missing id") };
    let Some(item) = s.outbox.get(&id) else {
        return json_error(StatusCode::NOT_FOUND, "Not in the outbox");
    };
    let OutItem::File { path, .. } = &item else {
        return json_error(StatusCode::BAD_REQUEST, "Not a file");
    };
    let opened = match tokio::fs::File::open(path).await {
        Ok(f) => f.metadata().await.map(|m| (f, m.len())),
        Err(e) => Err(e),
    };
    let Ok((file, total)) = opened else {
        s.outbox.remove(&id);
        gone(&s, &item);
        return json_error(StatusCode::NOT_FOUND, "File was moved or deleted");
    };

    let name = item.label();
    let state = s.clone();
    let start = Instant::now() - Duration::from_secs(1);
    let stream = futures_util::stream::unfold(Some((file, 0u64, start)), move |st| {
        let (s, id, name) = (state.clone(), id.clone(), name.clone());
        async move {
            let (mut file, sent, last_emit) = st?;
            // Cancelled on the PC (the queue was cleared): stop mid-file; the phone keeps nothing.
            if !s.outbox.contains(&id) {
                return Some((Err(std::io::Error::other("cancelled on the PC")), None));
            }
            let mut buf = vec![0u8; 256 * 1024];
            match file.read(&mut buf).await {
                Ok(0) => None,
                Ok(n) => {
                    buf.truncate(n);
                    let sent = sent + n as u64;
                    // Same ~15 updates a second as receiving.
                    let last_emit = if last_emit.elapsed() >= Duration::from_millis(65) || sent >= total {
                        s.ui.event(UiEvent::OutboxProgress { id, name, sent, total });
                        Instant::now()
                    } else {
                        last_emit
                    };
                    Some((Ok::<_, std::io::Error>(Bytes::from(buf)), Some((file, sent, last_emit))))
                }
                Err(e) => Some((Err(e), None)),
            }
        }
    });
    Response::builder()
        .header(header::CONTENT_TYPE, "application/octet-stream")
        .header(header::CONTENT_LENGTH, total)
        .body(Body::from_stream(stream))
        .unwrap()
}

/// The phone saved an item: take it off the queue. Unknown ids are fine (a retried request).
async fn outbox_done(
    State(s): State<AppState>,
    Extension(PeerCert(fp)): Extension<PeerCert>,
    Query(q): Query<IdQuery>,
) -> Response {
    if let Err(r) = require_paired(&s, &fp) {
        return r;
    }
    let Some(id) = q.id else { return json_error(StatusCode::BAD_REQUEST, "Missing id") };
    if let Some((item, remaining)) = s.outbox.remove(&id) {
        let text = matches!(item, OutItem::Text { .. });
        s.ui.event(UiEvent::OutboxDelivered { id, name: item.label(), text, remaining });
    }
    StatusCode::OK.into_response()
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
    Extension(PeerCert(fp)): Extension<PeerCert>,
    Json(req): Json<PrepareReq>,
) -> Response {
    let files: Vec<&FileDto> = req.files.values().collect();
    if files.is_empty() {
        return json_error(StatusCode::BAD_REQUEST, "No files provided");
    }
    let from = if req.info.alias.trim().is_empty() { "Unknown device".to_string() } else { req.info.alias.clone() };

    // A phone unpaired on either side can't send until it pairs by code again: no prompt, no toast.
    if fp.as_deref().is_some_and(|f| s.pairing.is_removed(f)) {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({ "message": "Unpaired: pair this iPhone with the PC again", "unpaired": true })),
        )
            .into_response();
    }

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
        paired: fp.as_deref().is_some_and(|fp| s.pairing.is_paired(fp)),
    };

    // Auto-accept only ever applies to a device paired by code (identified by its client cert).
    let accepted = if incoming.paired && s.auto_accept.load(Ordering::Relaxed) {
        s.ui.event(UiEvent::AutoAccepted { request: incoming.clone() });
        true
    } else {
        tokio::time::timeout(DECISION_TIMEOUT, s.ui.decide(&incoming)).await.unwrap_or(false)
    };
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
            return if was_cancelled(&s, &session_id) {
                json_error(StatusCode::GONE, "Cancelled")
            } else {
                json_error(StatusCode::FORBIDDEN, "Invalid token or IP address")
            };
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

    let inbox = s.inbox.lock().unwrap().clone();
    let _ = tokio::fs::create_dir_all(&inbox).await;
    let tmp = inbox.join(format!(".{file_id}.part"));
    let streamed = stream_to_disk(&s, body, &tmp, &request_id).await;
    let actual = match streamed {
        Ok(hash) => hash,
        Err(e) => {
            let _ = tokio::fs::remove_file(&tmp).await;
            if was_cancelled(&s, &session_id) {
                return json_error(StatusCode::GONE, "Cancelled");
            }
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

    let dest = unique_path(&inbox, &name);
    if let Err(e) = tokio::fs::rename(&tmp, &dest).await {
        let _ = tokio::fs::remove_file(&tmp).await;
        s.ui.event(UiEvent::Failed { id: request_id, reason: format!("Couldn't save {name}: {e}") });
        *s.slot.lock().unwrap() = Slot::Free;
        return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Couldn't save file");
    }

    let finished = {
        let mut slot = s.slot.lock().unwrap();
        let Slot::Active(sess) = &mut *slot else {
            // Cancelled while this file was being saved: a cancel leaves nothing behind.
            let _ = std::fs::remove_file(&dest);
            return json_error(StatusCode::GONE, "Cancelled");
        };
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
            dir: inbox.display().to_string(),
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

/// The sender cancelled: end the session and delete everything it saved.
async fn cancel(State(s): State<AppState>, Query(q): Query<CancelQuery>) -> Response {
    if let Some(sid) = q.session_id.as_deref() {
        if let Some(id) = abort_session(&s, Some(sid), None) {
            s.ui.event(UiEvent::Cancelled { id });
        }
    }
    StatusCode::OK.into_response()
}

fn was_cancelled(s: &Inner, session_id: &str) -> bool {
    s.cancelled.lock().unwrap().as_deref() == Some(session_id)
}

/// Ends the active session if it matches, and deletes every file it saved plus any partial ones: a cancel
/// (from the phone or the X on the toast) leaves nothing of the transfer on the PC. The upload still
/// streaming notices on its next chunk, removes its own `.part` file and answers 410. Returns the
/// session's request id (the toast's id).
fn abort_session(s: &Inner, session_id: Option<&str>, request_id: Option<&str>) -> Option<String> {
    let sess = {
        let mut slot = s.slot.lock().unwrap();
        let hit = matches!(&*slot, Slot::Active(sess)
            if session_id.is_none_or(|id| id == sess.id) && request_id.is_none_or(|id| id == sess.request_id));
        if !hit {
            return None;
        }
        let Slot::Active(sess) = std::mem::replace(&mut *slot, Slot::Free) else { return None };
        sess
    };
    *s.cancelled.lock().unwrap() = Some(sess.id.clone());
    let inbox = s.inbox.lock().unwrap().clone();
    for saved in &sess.saved {
        let _ = std::fs::remove_file(saved);
    }
    for file_id in sess.files.keys() {
        let _ = std::fs::remove_file(inbox.join(format!(".{file_id}.part")));
    }
    Some(sess.request_id)
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
