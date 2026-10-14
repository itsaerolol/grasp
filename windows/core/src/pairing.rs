//! Code pairing. The PC shows a 3-digit code for a short window; the phone sends it to
//! `POST /api/grasp/v1/pair` over TLS with its client certificate. On a match the phone's cert
//! fingerprint is remembered as paired. Paired devices are the only ones auto-accept applies to.

use std::{
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};

pub const CODE_LIFETIME: Duration = Duration::from_secs(120);
/// Wrong guesses allowed before the window closes. 1000 codes / 5 tries = a 0.5% chance per window.
pub const MAX_ATTEMPTS: u32 = 5;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PairedDevice {
    pub fingerprint: String,
    pub alias: String,
    pub device_model: Option<String>,
    /// Unix seconds.
    pub paired_at: u64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingWindow {
    pub code: String,
    pub seconds_left: u64,
}

#[derive(Debug, PartialEq)]
pub enum PairOutcome {
    Paired(PairedDevice),
    /// No window open (or it expired).
    NotOpen,
    WrongCode { attempts_left: u32 },
    /// Too many wrong codes: the window is now closed.
    Locked,
}

struct Window {
    code: String,
    expires: Instant,
    attempts: u32,
}

pub struct Pairing {
    file: PathBuf,
    window: Mutex<Option<Window>>,
    paired: Mutex<Vec<PairedDevice>>,
}

impl Pairing {
    /// `file` is the JSON list of paired devices (created on first pair).
    pub fn load(file: PathBuf) -> Self {
        let paired = std::fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        Self { file, window: Mutex::new(None), paired: Mutex::new(paired) }
    }

    /// Opens (or restarts) the pairing window with a fresh random code.
    pub fn open(&self) -> PairingWindow {
        let n = u16::from_le_bytes(uuid::Uuid::new_v4().as_bytes()[..2].try_into().unwrap()) % 1000;
        self.open_with(format!("{n:03}"), CODE_LIFETIME)
    }

    pub fn open_with(&self, code: String, lifetime: Duration) -> PairingWindow {
        *self.window.lock().unwrap() = Some(Window { code: code.clone(), expires: Instant::now() + lifetime, attempts: 0 });
        PairingWindow { code, seconds_left: lifetime.as_secs() }
    }

    pub fn close(&self) {
        *self.window.lock().unwrap() = None;
    }

    pub fn current(&self) -> Option<PairingWindow> {
        let mut w = self.window.lock().unwrap();
        match &*w {
            Some(win) if win.expires > Instant::now() => Some(PairingWindow {
                code: win.code.clone(),
                seconds_left: win.expires.saturating_duration_since(Instant::now()).as_secs(),
            }),
            Some(_) => {
                *w = None;
                None
            }
            None => None,
        }
    }

    pub fn try_pair(&self, code: &str, fingerprint: &str, alias: &str, device_model: Option<String>) -> PairOutcome {
        let mut w = self.window.lock().unwrap();
        let Some(win) = w.as_mut().filter(|win| win.expires > Instant::now()) else {
            *w = None;
            return PairOutcome::NotOpen;
        };
        if code.trim() != win.code {
            win.attempts += 1;
            if win.attempts >= MAX_ATTEMPTS {
                *w = None;
                return PairOutcome::Locked;
            }
            return PairOutcome::WrongCode { attempts_left: MAX_ATTEMPTS - win.attempts };
        }
        *w = None;
        drop(w);

        let device = PairedDevice {
            fingerprint: fingerprint.to_string(),
            alias: alias.to_string(),
            device_model,
            paired_at: SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        };
        let mut list = self.paired.lock().unwrap();
        list.retain(|d| d.fingerprint != device.fingerprint);
        list.push(device.clone());
        self.save(&list);
        PairOutcome::Paired(device)
    }

    pub fn is_paired(&self, fingerprint: &str) -> bool {
        self.paired.lock().unwrap().iter().any(|d| d.fingerprint == fingerprint)
    }

    pub fn devices(&self) -> Vec<PairedDevice> {
        self.paired.lock().unwrap().clone()
    }

    pub fn unpair(&self, fingerprint: &str) {
        let mut list = self.paired.lock().unwrap();
        list.retain(|d| d.fingerprint != fingerprint);
        self.save(&list);
    }

    fn save(&self, list: &[PairedDevice]) {
        if let Some(dir) = self.file.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(list) {
            let _ = std::fs::write(&self.file, json);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (Pairing, PathBuf) {
        let dir = std::env::temp_dir().join(format!("grasp-pair-{}", uuid::Uuid::new_v4()));
        let file = dir.join("paired.json");
        (Pairing::load(file), dir)
    }

    #[test]
    fn codes_are_three_digits() {
        let (p, _) = fresh();
        for _ in 0..200 {
            let w = p.open();
            assert_eq!(w.code.len(), 3);
            assert!(w.code.chars().all(|c| c.is_ascii_digit()));
        }
    }

    #[test]
    fn right_code_pairs_once_and_persists() {
        let (p, dir) = fresh();
        p.open_with("042".into(), CODE_LIFETIME);
        assert!(matches!(p.try_pair("042", "FP1", "Grasp iPhone", Some("iPhone".into())), PairOutcome::Paired(_)));
        assert!(p.is_paired("FP1"));
        // The window closes after a successful pair: the same code can't be reused.
        assert_eq!(p.try_pair("042", "FP2", "x", None), PairOutcome::NotOpen);
        // Survives a restart.
        let again = Pairing::load(dir.join("paired.json"));
        assert!(again.is_paired("FP1"));
        again.unpair("FP1");
        assert!(!Pairing::load(dir.join("paired.json")).is_paired("FP1"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn wrong_codes_lock_the_window() {
        let (p, _) = fresh();
        p.open_with("123".into(), CODE_LIFETIME);
        for left in (1..MAX_ATTEMPTS).rev() {
            assert_eq!(p.try_pair("999", "FP", "x", None), PairOutcome::WrongCode { attempts_left: left });
        }
        assert_eq!(p.try_pair("999", "FP", "x", None), PairOutcome::Locked);
        assert_eq!(p.try_pair("123", "FP", "x", None), PairOutcome::NotOpen, "locked means closed, even for the right code");
        assert!(!p.is_paired("FP"));
    }

    #[test]
    fn expired_window_refuses() {
        let (p, _) = fresh();
        p.open_with("555".into(), Duration::from_millis(1));
        std::thread::sleep(Duration::from_millis(5));
        assert_eq!(p.try_pair("555", "FP", "x", None), PairOutcome::NotOpen);
        assert!(p.current().is_none());
    }

    #[test]
    fn no_window_no_pairing() {
        let (p, _) = fresh();
        assert_eq!(p.try_pair("000", "FP", "x", None), PairOutcome::NotOpen);
    }
}
