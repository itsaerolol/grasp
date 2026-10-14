# Grasp

iPhone share sheet → Windows PC, AirDrop-style, in two apps that speak the LocalSend v2.2 protocol:

- **Grasp (iOS):** a share extension. Pair once, then sharing is instant.
- **Grasp for Windows (`desktop/`):** a tray-only receiver with no window. A chime plays and a toast slides in at the top right with **Accept** and **Reject**; Accept turns the same toast into a progress bar, then a check. Nothing is ever accepted automatically.

It speaks LocalSend's protocol, so stock LocalSend desktop still works as a fallback receiver.

## Flow

```
Share sheet ──tap PC (suggestion row) or Grasp icon──▶ GraspShare extension
  1. Normalize items: HEIC→JPG, URL/text→message, files copied to tmp
  2. Resolve PC: GET /info at its stored IP (pinned cert); no automatic network sweep
  3. POST /prepare-upload ──▶ chime + toast on the PC: Accept / Reject ──▶ tokens (or 204 for text)
  4. POST /upload per file, streamed from disk, sha256 verified by the PC
  5. Donate INSendMessageIntent ▸ PC stays in the share sheet's top row
```

On the PC, an accepted text message is copied to the clipboard, and opened in the browser if it is a single `http(s)` link. Rejecting, or not answering for 30 seconds, delivers nothing.

## Locked v1 decisions

| Area | Decision |
|---|---|
| PC | Windows 11, Grasp for Windows (`desktop/`), LocalSend-compatible, encryption ON |
| Payload | Photos/screenshots, files/docs, text/links (no video focus) |
| Targets | One default PC, zero-tap send |
| Lifetime | Sheet stays open with progress; no background transfer |
| Photos | Always HEIC→JPG (q 0.9, EXIF kept) |
| Text | LocalSend message; after Accept, copied to the clipboard and opened if it is one `http(s)` link |
| Accept | Manual accept on the PC for everything, never automatic; unanswered for 30s = reject |
| PC app | Tray + toast only, no window, no settings; always dark; top right of the primary monitor |
| Network | LAN only; pair by tap-only /24 scan or IP address; sends use the stored IP (no multicast entitlement) |
| Distribution | Personal, TestFlight. Bundle `com.itsaerolol.grasp`, iOS 18+ |

## Protocol findings (LocalSend source, Oct 2026, verified on the real PC)

- **mTLS is mandatory in LocalSend 1.18.2 (Rust core), but NOT in 1.17.0 (Flutter).** `packages/core/src/http/server/mod.rs`: client cert required unless web share is on. Any valid self-signed cert is accepted. Verified on this PC against both versions:

  | | 1.17.0+58 | 1.18.2+64 |
  |---|---|---|
  | Protocol | 2.1 (accepted our `version: "2.2"`) | 2.2 |
  | No client cert | works, even plain `curl` | rejected with a TLS "certificate required" alert |
  | Text message | popup, 204 held until you click Copy/Close | accepted, 204 |
  | Files | accepted, SHA-256 matched | accepted, SHA-256 matched |

  Grasp always presents its cert when asked, so it works against both. Grasp (iOS) generates an RSA-2048 self-signed cert on first launch (`ClientIdentity.swift`), stored in the App Group keychain so the extension can use it. Grasp for Windows never requests a client cert.
- **`info.fingerprint` (1.17.0):** the `/info` body fingerprint equals the TLS cert fingerprint. Identity still comes from the TLS cert, which is right for both versions.
- **Upgrading LocalSend keeps its identity:** the server cert fingerprint did not change from 1.17.0 to 1.18.2, so a pairing survives an upgrade.
- **Fingerprint** = uppercase hex SHA-256 of cert DER (`crypto/cert.rs`). On `/register`, the claimed `fingerprint` must equal the presented client cert or the registration is ignored.
- **Single session slot**: concurrent prepare-upload → 409. Upload must come from the same IP that prepared, with the per-file token (403 otherwise).
- **sha256** compared case-insensitively; mismatch → 422.
- **Text message** = exactly one `text/plain` file with `preview` set. Returns 204 with no upload. Stock LocalSend shows a popup; Grasp for Windows asks Accept first, then copies it.
- `prepare-upload` blocks until the PC user decides, so the sender's request timeout is 600s. Grasp for Windows decides within 30s (silence is a reject → 403).

## Layout

```
project.yml                  XcodeGen spec (app + share extension, App Group, packages)
Shared/                      Compiled into both targets
  LSModels.swift             DTOs + error mapping (401/403/409/422/429)
  ClientIdentity.swift       mTLS identity: keychain RSA key + swift-certificates self-signed cert
  LSSessionDelegate.swift    Server pin / TOFU + client cert challenge + upload progress
  LSClient.swift             register / info / prepare-upload / upload (streamed) / cancel
  Discovery.swift            /24 HTTP scan, resolve pinned PC after DHCP changes
  Payload.swift              NSItemProvider → files/text, HEIC→JPG
  ShareDonation.swift        INSendMessageIntent donation (top-row suggestion)
  SendEngine.swift           One share = one session; drives extension UI state
  PeerStore.swift            Paired PC in App Group defaults
App/                         Pairing UI: scan, pair, test message, unpair
ShareExtension/              ShareViewController + status sheet
desktop/                     Grasp for Windows (Cargo workspace)
  core/                      grasp-core: the LocalSend receiver (axum + rustls), no UI; `Ui` trait is the seam
    src/bin/headless.rs      Same receiver without the toast, for tests
  src-tauri/                 Tauri shell: tray icon, toast window, chime (synthesized), Accept/Reject plumbing
  ui/index.html              The toast: the whole UI in one file
  scripts/make-icons.mjs     Generates the placeholder icons (no dependencies)
tools/
  mock-receiver.mjs          Mock LocalSend receiver enforcing core's rules (mTLS, 409, 403, 422, 204)
  ls-send.mjs                Reference sender, same flow as SendEngine; works against the real PC
  test-e2e.sh                9 protocol tests against the mock (all passing)
  test-e2e-desktop.sh        10 protocol tests against the Rust receiver (all passing)
```

## Run

```bash
# Prove protocol against the mock (Node 18+, openssl)
bash tools/test-e2e.sh

# Prove it against the real PC BEFORE touching Xcode
node tools/ls-send.mjs --host <PC-IP> --info
node tools/ls-send.mjs --host <PC-IP> some.jpg
node tools/ls-send.mjs --host <PC-IP> --text "hello"

# Test and build Grasp for Windows (Rust, Node, MSVC build tools, WebView2)
bash tools/test-e2e-desktop.sh
cd desktop && cargo test --workspace
cd desktop && npm install && npx tauri build --debug --no-bundle   # target/debug/grasp-desktop.exe
GRASP_PORT=53318 desktop/target/debug/grasp-desktop.exe              # beside stock LocalSend, which owns 53317

# Generate and build the iOS project (macOS)
brew install xcodegen
DEVELOPMENT_TEAM=<TEAMID> xcodegen generate
open Grasp.xcodeproj
```

## PC setup

Grasp for Windows (once there is an installer; today it runs from `desktop/target`):

1. Quit stock LocalSend first: both listen on TCP 53317, and Grasp shows a "Port 53317 is busy" toast if it can't bind.
2. Run Grasp. It lives in the tray (Open Downloads, Launch at login, Quit). Files save to Downloads.
3. Windows Firewall: allow Grasp on **Private** networks (TCP 53317), and set your Wi-Fi profile to Private (Settings → Network & internet → Wi-Fi → your network → Private). Windows asks the first time it listens.

Fallback with stock LocalSend: `winget install LocalSend.LocalSend`, Encryption ON, Quick Save OFF, and make sure its inbound firewall rules cover the Private profile (its installer may only add Public).

## Not in v1

Background transfers, video-sized payloads, multi-PC picker, Tailscale/off-LAN, multicast discovery, App Store polish. For Grasp for Windows: an installer build and autostart have not been exercised yet, and there is no settings UI by design.
