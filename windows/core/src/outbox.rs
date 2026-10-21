//! Windows -> iPhone. An iPhone app can't accept connections in the background, so the PC never pushes:
//! things to send wait here and the phone pulls them over its usual mTLS connection while Grasp is open.
//! `GET /api/grasp/v1/outbox` lists them, `GET .../outbox/file?id=` streams one, `POST .../outbox/done?id=`
//! removes it once the phone has saved it. Only a phone paired by code may pull (see server.rs).
//!
//! Files are sent from where they are, never copied first (a 10 GB video shouldn't need 10 GB more disk).
//! One that has been moved or deleted by the time the phone asks is dropped and reported. The queue
//! survives restarts in `outbox.json`.

use std::{
    path::{Path, PathBuf},
    sync::Mutex,
};

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum OutItem {
    #[serde(rename_all = "camelCase")]
    File {
        id: String,
        /// Where the file is on this PC. Never sent to the phone.
        path: PathBuf,
        /// What the phone saves it as. Folder contents keep their relative path ("Trip/day 2/a.jpg"),
        /// always with `/`, so the phone can recreate the folder.
        file_name: String,
        size: u64,
        file_type: String,
    },
    #[serde(rename_all = "camelCase")]
    Text { id: String, text: String },
}

impl OutItem {
    pub fn id(&self) -> &str {
        match self {
            OutItem::File { id, .. } | OutItem::Text { id, .. } => id,
        }
    }

    /// Short label for the toast: the file name, or the text itself.
    pub fn label(&self) -> String {
        match self {
            OutItem::File { file_name, .. } => file_name.rsplit('/').next().unwrap_or(file_name).to_string(),
            OutItem::Text { text, .. } => text.clone(),
        }
    }

    /// What the phone sees: no local path.
    pub fn wire(&self) -> serde_json::Value {
        match self {
            OutItem::File { id, file_name, size, file_type, .. } => serde_json::json!({
                "kind": "file", "id": id, "fileName": file_name, "size": size, "fileType": file_type,
            }),
            OutItem::Text { id, text } => serde_json::json!({ "kind": "text", "id": id, "text": text }),
        }
    }
}

pub struct Outbox {
    file: PathBuf,
    items: Mutex<Vec<OutItem>>,
}

impl Outbox {
    /// `file` is the JSON queue (created on first add).
    pub fn load(file: PathBuf) -> Self {
        let items = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file, items: Mutex::new(items) }
    }

    /// Queues files and folders (a folder's files, recursively, under the folder's name). Returns what was
    /// added; paths that don't exist, empty folders and hidden/system files add nothing.
    pub fn add_paths(&self, paths: &[PathBuf]) -> Vec<OutItem> {
        let mut added = Vec::new();
        for p in paths {
            if p.is_dir() {
                let root = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "Folder".into());
                walk(p, &root, &mut added);
            } else if let Some(item) = file_item(p, None) {
                added.push(item);
            }
        }
        self.push(added)
    }

    pub fn add_text(&self, text: &str) -> Option<OutItem> {
        if text.trim().is_empty() {
            return None;
        }
        self.push(vec![OutItem::Text { id: new_id(), text: text.to_string() }]).pop()
    }

    fn push(&self, new: Vec<OutItem>) -> Vec<OutItem> {
        if !new.is_empty() {
            let mut items = self.items.lock().unwrap();
            items.extend(new.iter().cloned());
            self.save(&items);
        }
        new
    }

    pub fn items(&self) -> Vec<OutItem> {
        self.items.lock().unwrap().clone()
    }

    pub fn len(&self) -> usize {
        self.items.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Still queued? (The PC can cancel a send mid-stream by clearing the queue.)
    pub fn contains(&self, id: &str) -> bool {
        self.items.lock().unwrap().iter().any(|i| i.id() == id)
    }

    pub fn get(&self, id: &str) -> Option<OutItem> {
        self.items.lock().unwrap().iter().find(|i| i.id() == id).cloned()
    }

    /// Removes an item; returns it and how many are left.
    pub fn remove(&self, id: &str) -> Option<(OutItem, usize)> {
        let mut items = self.items.lock().unwrap();
        let pos = items.iter().position(|i| i.id() == id)?;
        let item = items.remove(pos);
        self.save(&items);
        Some((item, items.len()))
    }

    /// Drops files that no longer exist (moved or deleted since they were queued) and returns them.
    pub fn prune_missing(&self) -> Vec<OutItem> {
        let mut items = self.items.lock().unwrap();
        let (gone, keep): (Vec<_>, Vec<_>) =
            items.drain(..).partition(|i| matches!(i, OutItem::File { path, .. } if !path.is_file()));
        *items = keep;
        if !gone.is_empty() {
            self.save(&items);
        }
        gone
    }

    pub fn clear(&self) {
        let mut items = self.items.lock().unwrap();
        items.clear();
        self.save(&items);
    }

    fn save(&self, items: &[OutItem]) {
        if let Some(dir) = self.file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(items) {
            let _ = std::fs::write(&self.file, json);
        }
    }
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Windows' own clutter and dotfiles never go to the phone.
fn skipped(name: &str) -> bool {
    name.starts_with('.') || name.eq_ignore_ascii_case("desktop.ini") || name.eq_ignore_ascii_case("thumbs.db")
}

fn file_item(path: &Path, relative: Option<String>) -> Option<OutItem> {
    let meta = std::fs::metadata(path).ok().filter(|m| m.is_file())?;
    let name = path.file_name()?.to_string_lossy().into_owned();
    if skipped(&name) {
        return None;
    }
    Some(OutItem::File {
        id: new_id(),
        path: path.to_path_buf(),
        file_type: mime_of(&name).to_string(),
        file_name: relative.unwrap_or(name),
        size: meta.len(),
    })
}

/// Depth-first, sorted by name so a folder arrives in the order Explorer shows it.
fn walk(dir: &Path, prefix: &str, out: &mut Vec<OutItem>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = read.flatten().collect();
    entries.sort_by_key(|e| e.file_name().to_string_lossy().to_lowercase());
    for e in entries {
        let name = e.file_name().to_string_lossy().into_owned();
        if skipped(&name) {
            continue;
        }
        let path = e.path();
        let rel = format!("{prefix}/{name}");
        if path.is_dir() {
            walk(&path, &rel, out);
        } else if let Some(item) = file_item(&path, Some(rel)) {
            out.push(item);
        }
    }
}

/// Enough for the phone to tell photos and videos (which also go to the Photos library) from the rest.
pub fn mime_of(name: &str) -> &'static str {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "tif" | "tiff" => "image/tiff",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "pdf" => "application/pdf",
        "txt" | "log" | "md" => "text/plain",
        "csv" => "text/csv",
        "zip" => "application/zip",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp() -> PathBuf {
        let d = std::env::temp_dir().join(format!("grasp-outbox-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn folders_keep_their_structure_and_skip_clutter() {
        let d = tmp();
        let trip = d.join("Trip");
        std::fs::create_dir_all(trip.join("day 2")).unwrap();
        std::fs::write(trip.join("b.jpg"), b"b").unwrap();
        std::fs::write(trip.join("day 2").join("a.mov"), b"aa").unwrap();
        std::fs::write(trip.join("desktop.ini"), b"x").unwrap();
        std::fs::write(trip.join(".DS_Store"), b"x").unwrap();
        std::fs::write(d.join("note.pdf"), b"pdf").unwrap();

        let o = Outbox::load(d.join("state").join("outbox.json"));
        let added = o.add_paths(&[trip, d.join("note.pdf"), d.join("missing.txt")]);
        let names: Vec<_> = added
            .iter()
            .map(|i| match i {
                OutItem::File { file_name, file_type, size, .. } => format!("{file_name} {file_type} {size}"),
                _ => unreachable!(),
            })
            .collect();
        assert_eq!(names, ["Trip/b.jpg image/jpeg 1", "Trip/day 2/a.mov video/quicktime 2", "note.pdf application/pdf 3"]);
        std::fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn queue_persists_and_items_are_removed_once() {
        let d = tmp();
        std::fs::write(d.join("a.txt"), b"a").unwrap();
        let file = d.join("outbox.json");
        let o = Outbox::load(file.clone());
        o.add_paths(&[d.join("a.txt")]);
        let text = o.add_text("https://whiteframe.cc").unwrap();
        assert!(o.add_text("   ").is_none());

        let again = Outbox::load(file.clone());
        assert_eq!(again.items(), o.items());
        let (removed, left) = again.remove(text.id()).unwrap();
        assert_eq!(removed, text);
        assert_eq!(left, 1);
        assert!(again.remove(text.id()).is_none());
        assert_eq!(Outbox::load(file).len(), 1);
        std::fs::remove_dir_all(d).unwrap();
    }

    #[test]
    fn missing_files_are_pruned_and_wire_never_shows_the_path() {
        let d = tmp();
        std::fs::write(d.join("gone.jpg"), b"x").unwrap();
        std::fs::write(d.join("kept.jpg"), b"x").unwrap();
        let o = Outbox::load(d.join("outbox.json"));
        o.add_paths(&[d.join("gone.jpg"), d.join("kept.jpg")]);
        std::fs::remove_file(d.join("gone.jpg")).unwrap();

        let gone = o.prune_missing();
        assert_eq!(gone.len(), 1);
        assert_eq!(gone[0].label(), "gone.jpg");
        assert_eq!(o.len(), 1);
        let wire = o.items()[0].wire().to_string();
        assert!(wire.contains("\"fileName\":\"kept.jpg\""));
        assert!(!wire.contains(&d.display().to_string().replace('\\', "\\\\")) && !wire.contains("path"));
        std::fs::remove_dir_all(d).unwrap();
    }
}
