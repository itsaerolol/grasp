use async_trait::async_trait;

use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileSummary {
    pub name: String,
    pub size: u64,
    pub mime: String,
}

/// A sender asking permission to push files. The shell shows Accept / Reject.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IncomingRequest {
    pub id: String,
    pub from: String,
    pub device_model: Option<String>,
    pub files: Vec<FileSummary>,
    pub total: u64,
    /// Set when the "file" is really a text message / link. It still needs Accept: nothing from
    /// the network may touch the clipboard or open a browser without a human saying yes.
    pub message: Option<String>,
    /// The sender presented the client certificate of a device paired by code.
    pub paired: bool,
}

/// Everything the shell needs to draw after the Accept / Reject decision.
#[derive(Clone, Debug, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum UiEvent {
    /// A paired device's transfer was accepted without a prompt (auto-accept is on). The shell shows
    /// it as receiving straight away; a message still arrives as `Message` next.
    #[serde(rename_all = "camelCase")]
    AutoAccepted { request: IncomingRequest },
    /// A phone entered the right code.
    #[serde(rename_all = "camelCase")]
    Paired { device: crate::pairing::PairedDevice },
    /// A phone was unpaired: on the PC (`by_phone` false) or by the phone itself (true).
    #[serde(rename_all = "camelCase")]
    Unpaired { device: crate::pairing::PairedDevice, by_phone: bool, outbox_cleared: bool },
    /// A LocalSend "message" the user has just ACCEPTED. The shell may now act on `text`.
    #[serde(rename_all = "camelCase")]
    Message { id: String, from: String, text: String },
    #[serde(rename_all = "camelCase")]
    Progress { id: String, received: u64, total: u64 },
    #[serde(rename_all = "camelCase")]
    Done { id: String, count: usize, dir: String, first_file: Option<String> },
    /// The sender cancelled or vanished. Dismiss the toast for `id`.
    #[serde(rename_all = "camelCase")]
    Cancelled { id: String },
    #[serde(rename_all = "camelCase")]
    Failed { id: String, reason: String },
    /// Windows -> iPhone: `count` things were just queued for the phone to pull; `waiting` is the whole
    /// queue now. `first` names the first new one for the toast.
    #[serde(rename_all = "camelCase")]
    Queued { count: usize, waiting: usize, first: Option<String> },
    /// The phone is downloading a queued file.
    #[serde(rename_all = "camelCase")]
    OutboxProgress { id: String, name: String, sent: u64, total: u64 },
    /// The phone saved a queued item and took it off the queue. `remaining` are still waiting.
    #[serde(rename_all = "camelCase")]
    OutboxDelivered { id: String, name: String, text: bool, remaining: usize },
}

#[async_trait]
pub trait Ui: Send + Sync + 'static {
    /// Resolves when the user taps Accept (true) or Reject (false). The core drops the future
    /// if the sender disconnects first, so implementations must tolerate cancellation.
    async fn decide(&self, req: &IncomingRequest) -> bool;
    fn event(&self, ev: UiEvent);
}
