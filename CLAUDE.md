# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo layout

`ios/` is the iPhone app (run `xcodegen`/`xcodebuild` from inside it; `ios/tools/` is the protocol harness). `windows/` is Grasp for Windows (Cargo workspace; `windows/test-e2e.sh`). Docs stay at the root. GitHub: `itsaerolol/grasp` (public).

## What this is

Grasp is two apps that speak the LocalSend v2.2 protocol: a personal iOS app whose share extension sends photos, files, and text from the iPhone share sheet, and **Grasp for Windows** (`windows/`), a tray-only receiver that replaces the stock LocalSend desktop app. `README.md` has the flow diagram and protocol findings; `AGENT_PROMPT.md` is the original phased build brief (Phase 0 protocol proof → Phase 5 TestFlight). The brief listed a custom Windows receiver as out of scope; the owner has since reversed that, so the brief's "Out of scope" line no longer applies to `windows/`. Everything else in the brief still binds.

**Status.**
- **Windows receiver:** built and working. The Rust core passes 10/10 protocol tests, and the toast UI was checked by the owner on screen (look, chime, Accept, progress bar, check, link auto-open). It has only run as a debug build on a test port; there is no installer, nothing has run on 53317, and Launch at login is untested.
- **iOS app:** the Swift code was scaffolded without a compiler. It has since been compiled (type-checked, `arm64-apple-ios18.0`, iOS 27.1 SDK, zero errors or warnings) using xtool's Linux build in WSL, and the few real errors were fixed. It has never been linked into a signed app, run in a Simulator, or run on a device, so runtime behaviour (keychain identity lookup, TLS client-cert challenge, the share extension itself) is unverified. Fix problems without redesigning: the architecture and protocol logic are deliberate.
- **Real LocalSend:** verified against the real desktop app on this PC. 1.18.2 (the Rust core) speaks protocol 2.2 and requires a client cert. 1.17.0 (Flutter) speaks 2.1 and does not. Grasp works with both; see README "Protocol findings".

## Commands

Protocol tools (Node 18+, `openssl` on PATH, no npm install; work on any OS, use Git Bash on Windows):

```bash
bash ios/tools/test-e2e.sh                                  # 9 protocol tests against the mock, port 53399
node ios/tools/mock-receiver.mjs --auto-accept              # mock PC on 53317; also --reject, --pin 1234, --port, --inbox, --optional-client-cert
node ios/tools/ls-send.mjs --host <IP> --info               # print PC alias + cert fingerprint
node ios/tools/ls-send.mjs --host <IP> a.jpg b.pdf          # file send
node ios/tools/ls-send.mjs --host <IP> --text "hello"       # text message (expects 204)
```

`test-e2e.sh` has no per-test filter. To run one scenario, start the mock with the matching flags in one shell and run the corresponding `ls-send.mjs` line from the script in another. `ls-send.mjs` also takes `--pin-fp <FP>`, `--pin <PIN>`, `--no-client-cert`.

Grasp for Windows (`windows/`; Rust 1.96, MSVC build tools, Node and WebView2 are all present on the owner's PC):

```bash
bash windows/test-e2e.sh                          # 10 protocol tests against the Rust core's headless build, port 53398
cd windows && cargo test --workspace                    # unit tests: filename sanitising, no-overwrite, link-safety rule, chime WAV
cd windows && npm install && node scripts/make-icons.mjs   # one-time: Tauri CLI + generated icons (src-tauri/icons is output)
cd windows && npx tauri build --debug --no-bundle       # builds target/debug/grasp-desktop.exe (use `npx tauri build` for the NSIS installer)
GRASP_PORT=53318 windows/target/debug/grasp-desktop.exe   # run it beside the real LocalSend, which owns 53317
```

Always set `GRASP_PORT` while developing: the app and stock LocalSend can't both bind 53317, and a busy port shows up as a toast. The Tauri CLI must do the build: plain `cargo build` produces an exe that can't load `ui/`. `target/debug/grasp-headless` is the same receiver without the toast, for scripts: `--auto-accept`, `--reject`, or no flag to answer y/N on stdin.

Compile-checking the Swift from Windows (no Mac): xtool plus the iOS SDK extracted from an Xcode `.xip` live in WSL (`~/.swiftpm/swift-sdks/darwin.artifactbundle`, Swift 6.4.1 via swiftly). `~/scratch/GraspCheck` is a throwaway SwiftPM package that symlinks `App/`, `Shared/`, `ShareExtension/` from the repo, and `~/scratch/GraspCheck/clean-build.sh` type-checks them for `arm64-apple-ios`. This only type-checks. xtool can't produce a usable build of the share extension: its signer applies only the main app's entitlements to nested bundles (xtool issue 131), so the extension would lose its App Group, and signing with entitlements failed with a load-command error on this toolchain. xtool also has no TestFlight upload, so a Mac is still needed for the signed build, Simulator and TestFlight.

Gotchas for running this from Windows: `wsl.exe` swallows `$variables` and quotes in inline commands, so put anything non-trivial in a script file and run that. Git Bash rewrites `/mnt/c/...` arguments, so call `wsl.exe` from PowerShell when passing such paths.

iOS project (macOS + Xcode only; none of this runs on Windows):

```bash
brew install xcodegen
DEVELOPMENT_TEAM=<TEAMID> xcodegen generate
xcodebuild -project Grasp.xcodeproj -scheme Grasp -destination 'generic/platform=iOS Simulator' build
```

`project.yml` is the source of truth. `Grasp.xcodeproj`, `App/Info.plist`, `ShareExtension/Info.plist`, and both `.entitlements` files are XcodeGen output: change `project.yml` and regenerate, never hand-edit them. `GraspTests` (unit tests, compiles `Shared/` directly) runs with `xcodebuild test -project Grasp.xcodeproj -scheme GraspTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`. Regenerate with `DEVELOPMENT_TEAM` set or device signing fails.

## Architecture

Two targets, `Grasp` (app) and `GraspShare` (share extension), each compile `Shared/` directly as sources. There is no shared framework, so anything in `Shared/` must be extension-safe.

**The app sets up, the extension sends.** The app (`App/PairingView.swift`) creates the mTLS identity, pairs one PC, and sends a test message. All day-to-day sending happens in the extension, which has no compose UI: `ShareViewController` hands the item providers to `SendEngine` in `viewDidLoad` and only shows status. The two processes share state through the App Group `group.com.itsaerolol.grasp`, which is used both as the `UserDefaults` suite (`PeerStore`) and as the keychain access group (`ClientIdentity`). The extension calls `ClientIdentity.load()`, never `loadOrCreate()`, so a missing identity surfaces as "Open the Grasp app once".

**Identity is a cert fingerprint, in both directions.** A fingerprint is the uppercase hex SHA-256 of a cert's DER.
- Ours: LocalSend requires a client certificate. `ClientIdentity` makes an RSA-2048 keychain key plus a self-signed cert, and `info.fingerprint` in every request must equal that cert's fingerprint or `/register` is ignored.
- The PC's: `Peer.id` is the server's TLS cert fingerprint. `Peer.host` is only the last known address. The `fingerprint` field in the PC's JSON body is an internal token and is not used for identity.

**One `LSClient` per host, two trust modes.** `LSSessionDelegate` answers both TLS challenges. With `expectedFingerprint: nil` it accepts any server cert and records what it saw (trust on first use, used by `Discovery.probe` during scan and pairing). With a fingerprint it pins and cancels the handshake on mismatch, which `LSClient.mapTransport` turns into `LSError.fingerprintMismatch`.

**Discovery has no multicast, and never sweeps on its own.** `Discovery.scan` POSTs `/register` to every host in the phone's own /24 (or its real subnet if smaller, e.g. a hotspot /28), 16 concurrent, 1.5s each, derived from `en0` and its netmask. It runs only when the user taps Scan in the app. `Discovery.resolve` is what every send goes through: one pinned `GET /info` at the stored host, no rescan; failure is `LSError.pcNotAnswering` ("re-add it if its IP changed"). Reason (verified on the owner's WPA2-Enterprise network, Oct 2026): a /20 sweep at 128 concurrent got the phone kicked off the Wi-Fi every time, and an automatic sweep from a share would do the same. Pairing by IP (Manual IP sheet) is the normal path on such networks.

**One share is one session.** `SendEngine.run`: `PayloadBuilder.build` (copy each attachment into a per-share work dir, HEIC/HEIF→JPG, URLs and plain text → `.text`) → `Discovery.resolve` → `prepareUpload` → sequential `upload` per accepted file → `ShareDonation.donate`. `SendEngine.Phase` is the only thing `ShareStatusView` renders. `SendEngine.describe` holds the message-vs-files rule: exactly one text item becomes a LocalSend message (one `text/plain` file with `preview` set, PC returns 204, nothing is uploaded); text mixed with files is sent as `Note.txt`.

**Share sheet top row.** `ShareDonation` donates an `INSendMessageIntent` whose `conversationIdentifier` is the peer id. The extension declares `IntentsSupported` in `project.yml` and reads `extensionContext.intent` to learn which PC was tapped (nil means the Grasp icon, so the default peer is used).

**`ios/tools/` is the regression harness.** `mock-receiver.mjs` enforces the real server's rules (mandatory mTLS, single session slot, same-IP + token uploads, sha256 check, message → 204) and `ls-send.mjs` mirrors `SendEngine` step for step. The message rule, status-code mapping, and fingerprint format each exist in four places (Swift, sender script, mock, and the Rust receiver in `windows/core/src/server.rs`) and must change together. If the real LocalSend build behaves differently from the mock, update the mock and the Swift code to match reality. Both scripts cache their generated certs in gitignored `ios/tools/.client-cert/` and `ios/tools/.mock-server-cert/`, so their fingerprints are stable across runs.

### Grasp for Windows (`windows/`)

A Cargo workspace of two crates, split so the protocol can be tested without any UI.

- **`core/` (`grasp-core`)** is the whole LocalSend receiver: axum over rustls (ring provider, ECDSA cert from rcgen), no Tauri dependency. The only seam is the `Ui` trait in `ui.rs`: `decide(&IncomingRequest) -> bool` blocks `prepare-upload` until a human answers, and `event(UiEvent)` reports `Message`, `Progress`, `Done`, `Cancelled`, `Failed`. `server.rs` holds the session state machine (`Free` / `Pending` while the toast is up / `Active` with per-file tokens); `PendingGuard` frees the slot and dismisses the toast if the phone disconnects mid-prompt. The cert is generated once in the app data dir and reused, because the phone pins its fingerprint. The receiver never requests a client cert (like 1.17.0), so there is no mTLS check.
- **`src-tauri/` (`grasp-desktop`)** is the shell: a tray icon, one hidden-by-default toast window, and `TauriUi`, which implements `Ui`. `decide` plays the chime and emits an `incoming` event to the page, then awaits a oneshot that the `respond` command completes. `chime.rs` synthesizes the two-note bell as a WAV in memory and plays it through winmm. There is no audio asset to ship.
- **`ui/index.html`** is the entire toast (plain HTML/CSS/JS, no bundler, `withGlobalTauri`). It is a small state machine: `incoming` → `receiving` → `done`, plus `copied` (an accepted message) and `failed`. The page reports its measured height through `toast_resize` so the transparent window never covers more than the card.

**Rules that must not be loosened (the owner was explicit):**
- **No auto-accept, ever.** Nothing from the network may touch the disk, the clipboard, or the browser without a tap on Accept. Text messages and links go through the same Accept gate as files. `--auto-accept` exists only in the headless test binary.
- A prompt nobody answers is a rejection after 30s (`DECISION_TIMEOUT`), never an acceptance.
- After an accepted message, the shell copies it to the clipboard and opens it only if `as_openable_url` says it is exactly one `http`/`https` link with no whitespace. `file:`, `javascript:`, `ms-msdt:`, UNC paths and multi-line text must never open. The URL is passed to `rundll32` as a single argv entry, never through a shell.
- Sender-supplied file names are reduced to their last path component and stripped of Windows-forbidden characters (`safe_file_name`), and existing files are never overwritten (`photo (2).jpg`).

**Toast design (decided with the owner):** always dark regardless of the Windows theme, a near-opaque rounded card (no blur-behind: that would square the corners and lose the shadow), blue Accept and a muted-red Reject, a progress bar with "x of y MB" left and the percent right, a green check that slides away after ~4s (click opens the file in Explorer), the sender labelled "iPhone", and always the primary monitor's top-right corner. Constraints that bit during development:
- The card's CSS shadow must fit inside the transparent margin (`.stage` padding) or the window edge slices it into a visible dark rectangle. `WIDTH` in `toast.rs` (card 360 + 2×22) must match `.stage` in `index.html`, and `BLEED_X` pulls the window slightly off-screen so the visible card sits ~16px from the screen edge.
- The check animation uses `pathLength="1"` so the dash always spans the whole path. A fixed dash length silently stops short if the path is edited.
- The window is `focusable: false`, so it never steals keystrokes, and it is hidden rather than closed between toasts.

## Constraints that shape the code

- Share extensions are killed near 120MB. Files are hashed in 1MB chunks and uploaded with `uploadTask(fromFile:)`; never read a whole file into memory.
- `prepare-upload` blocks until a human clicks Accept on the PC, so that request alone has a 600s timeout. Other requests use the short connect timeout passed to `LSClient`. (Grasp for Windows answers within 30s; stock LocalSend 1.17.0 can hold a text-message reply until the popup is closed.)
- The receiver holds one session at a time (409 if busy) and requires uploads from the same IP that called `prepare-upload`.
- User-visible failures are one-line and actionable. Add new ones as `LSError` cases with an `errorDescription`, and map HTTP statuses in `LSError.from(status:)`.

## Locked decisions

Do not change these or add alternatives. If one seems wrong, stop and ask.

- Receiver is **Grasp for Windows** (`windows/`), speaking the LocalSend v2.2 protocol so the iPhone code and the harness stay valid. It replaces the stock LocalSend desktop app, which stays a supported fallback. Manual accept on every transfer, no Quick Save, never auto-accept. PIN support stays in the Swift code but the Windows app has none.
- Grasp for Windows is deliberately minimal: tray icon and toast only, no window, no settings (the one exception is a "Launch at login" tray toggle, off by default). Prefer simplicity over customizability on both apps; don't add configuration.
- One default PC, zero-tap send, no device picker in the extension. (`PeerStore` keeps an array internally so multi-PC is a later UI change.)
- The share sheet stays open with progress until done. No background `URLSession`.
- Photos are always converted HEIC→JPG (quality 0.9, EXIF kept).
- LAN only: stored IP for every send, plus a tap-only /24 HTTP scan and Manual IP for pairing (owner-approved change, Oct 2026: no automatic sweeps, they get the phone kicked off managed Wi-Fi). No multicast entitlement, no Bonjour, no Tailscale.
- Bundle IDs `com.itsaerolol.grasp` and `com.itsaerolol.grasp.share`, iOS 18 minimum, personal TestFlight distribution.
- Out of scope: background transfers, video optimization, multi-PC picker, Tailscale/off-LAN, multicast discovery, App Store polish. (A custom Windows receiver was out of scope in the original brief and is now in scope.)
