# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repo layout

`ios/` is the iPhone app (run `xcodegen`/`xcodebuild` from inside it; `ios/tools/` is the protocol harness). `windows/` is Grasp for Windows (Cargo workspace; `windows/test-e2e.sh`). Docs stay at the root. GitHub: `itsaerolol/grasp` (public).

## What this is

Grasp is two apps that speak the LocalSend v2.2 protocol: a personal iOS app whose share extension sends photos, files, and text from the iPhone share sheet, and **Grasp for Windows** (`windows/`), a tray-only receiver that replaces the stock LocalSend desktop app. It also works the other way (owner decision, Oct 2026): Grasp for Windows queues files, folders and text in an **outbox**, and the iPhone app pulls them while it's open, because an iPhone app can't accept connections in the background. `README.md` has the flow diagram and protocol findings; `AGENT_PROMPT.md` is the original phased build brief (Phase 0 protocol proof → Phase 5 TestFlight). The brief listed a custom Windows receiver as out of scope; the owner has since reversed that, so the brief's "Out of scope" line no longer applies to `windows/`. Everything else in the brief still binds.

**Status.**
- **Windows receiver:** built and working. Code pairing, auto-accept, the tray menu and auto-reveal in Explorer were added from the Mac (Oct 2026): the core is tested there (`windows/test-e2e.sh` 20/20) and the shell compiles, but the tray menu, Explorer reveal and folder picker have not run on Windows yet. The Rust core passes 10/10 protocol tests, and the toast UI was checked by the owner on screen (look, chime, Accept, progress bar, check, link auto-open). It has only run as a debug build on a test port; there is no installer, nothing has run on 53317, and Launch at login is untested.
- **iOS app:** builds, signs and runs on the owner's iPhone 16 Pro Max (iOS 27.0.1, Xcode 26.3). Verified on device against Grasp for Windows: pairing by IP, test message, photos (HEIC→JPG), PDF from Files, Safari link, share-sheet suggestion row, a 50-photo share. Code pairing, videos and no item limit are verified in the Simulator against the mock only. Folder → .zip and the any-item share rule are only type-checked from Windows (WSL) so far.
- **Windows → iPhone (branch `windows-to-iphone`, Oct 2026):** the core outbox and its endpoints are covered by `windows/test-e2e.sh` (29/29) and the mock suite (17/17). The shell side (Send to entry, tray Send files/clipboard, drag-detect drop zone, toast cards) compiles and its unit tests pass but has not run on screen. The iPhone side (Inbox, From PC section, Photos saving, settings toggle) builds with xtool and its tests type-check, but has not run on a device or Simulator.
- **Real LocalSend:** verified against the real desktop app on this PC. 1.18.2 (the Rust core) speaks protocol 2.2 and requires a client cert. 1.17.0 (Flutter) speaks 2.1 and does not. Grasp works with both; see README "Protocol findings".

## Commands

Protocol tools (Node 18+, `openssl` on PATH, no npm install; work on any OS, use Git Bash on Windows):

```bash
bash ios/tools/test-e2e.sh                                  # 17 protocol tests against the mock, port 53399
node ios/tools/mock-receiver.mjs --auto-accept              # mock PC on 53317; also --reject, --pin 1234, --port, --inbox, --optional-client-cert
node ios/tools/ls-send.mjs --host <IP> --info               # print PC alias + cert fingerprint
node ios/tools/ls-send.mjs --host <IP> a.jpg b.pdf          # file send
node ios/tools/ls-send.mjs --host <IP> --text "hello"       # text message (expects 204)
```

`test-e2e.sh` has no per-test filter. To run one scenario, start the mock with the matching flags in one shell and run the corresponding `ls-send.mjs` line from the script in another. `ls-send.mjs` also takes `--pin-fp <FP>`, `--pin <PIN>`, `--no-client-cert`.

Grasp for Windows (`windows/`; Rust 1.96, MSVC build tools, Node and WebView2 are all present on the owner's PC):

```bash
bash windows/test-e2e.sh                          # 29 protocol tests against the Rust core's headless build, port 53398
cd windows && cargo test --workspace                    # unit tests: filename sanitising, no-overwrite, link-safety rule, chime WAV
cd windows && npm install && node scripts/make-icons.mjs   # one-time: Tauri CLI + generated icons (src-tauri/icons is output)
cd windows && npx tauri build --debug --no-bundle       # builds target/debug/grasp-desktop.exe (use `npx tauri build` for the NSIS installer)
GRASP_PORT=53318 windows/target/debug/grasp-desktop.exe   # run it beside the real LocalSend, which owns 53317
```

Always set `GRASP_PORT` while developing: the app and stock LocalSend can't both bind 53317, and a busy port shows up as a toast. The Tauri CLI must do the build: plain `cargo build` produces an exe that can't load `ui/`. `target/debug/grasp-headless` is the same receiver without the toast, for scripts: `--auto-accept`, `--reject`, or no flag to answer y/N on stdin.

Compile-checking the Swift from Windows (no Mac): xtool plus the iOS SDK extracted from an Xcode `.xip` live in WSL (`~/.swiftpm/swift-sdks/darwin.artifactbundle`, Swift 6.4.1 via swiftly). `~/scratch/GraspCheck` is a throwaway SwiftPM package that symlinks `App/`, `Shared/`, `ShareExtension/` from the repo, and `~/scratch/GraspCheck/clean-build.sh` type-checks them for `arm64-apple-ios`. This only type-checks. `~/scratch/GraspXT/build.sh` goes further: it copies `ios/` into an xtool project and runs `xtool dev build` unsigned, producing `Grasp.app` with `PlugIns/GraspShare.appex`, which proves compile + link + bundle layout. It has to pass `-u _OBJC_CLASS_$__TtC10GraspShare19ShareViewController` to the linker, because xtool links an appex with entry point `_NSExtensionMain` and nothing references the principal class, so otherwise the linker strips the whole extension down to ~49KB. The "Can't find free space of LoadCommands for CodeSignature" signing error is fixed by `-headerpad 0x10000 -headerpad_max_install_names` (0x1000 is too small for ~30 dylibs); with that, both binaries carry the App Group in their ad-hoc signatures. Not yet tried: a real signed install (`xtool dev run`), which needs `xtool auth login` and the iPhone passed into WSL (usbipd-win + usbmuxd). xtool issue 131 (signer applies only the main app's entitlements to nested bundles) may still drop the extension's App Group on a real signing, so check that first. xtool also has no TestFlight upload, so a Mac is still needed for the signed build, Simulator and TestFlight.

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

**The app sets up, the extension sends.** The app (`App/PairingView.swift`) creates the mTLS identity, pairs one PC, sends a test message, and holds the Settings screen (`App/SettingsView.swift`). All day-to-day sending happens in the extension, which has no compose UI: `ShareViewController` hands the item providers to `SendEngine` in `viewDidLoad` and only shows status. The two processes share state through the App Group `group.com.itsaerolol.grasp`, which is used both as the `UserDefaults` suite (`PeerStore`, and `SendSettings`, which the extension loads at the start of every share) and as the keychain access group (`ClientIdentity`). The extension calls `ClientIdentity.load()`, never `loadOrCreate()`, so a missing identity surfaces as "Open the Grasp app once".

**Identity is a cert fingerprint, in both directions.** A fingerprint is the uppercase hex SHA-256 of a cert's DER.
- Ours: LocalSend requires a client certificate. `ClientIdentity` makes an RSA-2048 keychain key plus a self-signed cert, and `info.fingerprint` in every request must equal that cert's fingerprint or `/register` is ignored.
- The PC's: `Peer.id` is the server's TLS cert fingerprint. `Peer.host` is only the last known address. The `fingerprint` field in the PC's JSON body is an internal token and is not used for identity.

**One `LSClient` per host, two trust modes.** `LSSessionDelegate` answers both TLS challenges. With `expectedFingerprint: nil` it accepts any server cert and records what it saw (trust on first use, used by `Discovery.probe` during scan and pairing). With a fingerprint it pins and cancels the handshake on mismatch, which `LSClient.mapTransport` turns into `LSError.fingerprintMismatch`.

**Discovery has no multicast, and never sweeps on its own.** `Discovery.scan` POSTs `/register` to every host in the phone's own /24 (or its real subnet if smaller, e.g. a hotspot /28), 16 concurrent, 1.5s each, derived from `en0` and its netmask. It runs only when the user taps Scan in the app. `Discovery.resolve` is what every send goes through: one pinned `GET /info` at the stored host, no rescan; failure is `LSError.pcNotAnswering` ("re-add it if its IP changed"). Reason (verified on the owner's WPA2-Enterprise network, Oct 2026): a /20 sweep at 128 concurrent got the phone kicked off the Wi-Fi every time, and an automatic sweep from a share would do the same. Pairing by IP (Manual IP sheet) is the normal path on such networks.

**One share is one session.** `SendEngine.run`: `PayloadBuilder.build` (copy each attachment into a per-share work dir, `processPhoto` per the settings: HEIC/HEIF and still WebP→JPG, GPS removal, date naming; folders → one `<name>.zip` via `NSFileCoordinator` `.forUploading` or their files flattened, directory packages always zipped; an item Files gives only as a file URL → the item it points at; URLs and plain text → `.text`, anything else → whatever file it offers) → `Discovery.resolve` → `prepareUpload` → sequential `upload` per accepted file → `ShareDonation.donate`. `SendEngine.Phase` is the only thing `ShareStatusView` renders. `SendEngine.describe` holds the message-vs-files rule: exactly one text item becomes a LocalSend message (unless the "Send as Message" setting is off, then it is `Note.txt`) (one `text/plain` file with `preview` set, PC returns 204, nothing is uploaded); text mixed with files is sent as `Note.txt`.

**Share sheet top row.** `ShareDonation` donates an `INSendMessageIntent` whose `conversationIdentifier` is the peer id. The extension declares `IntentsSupported` in `project.yml` and reads `extensionContext.intent` to learn which PC was tapped (nil means the Grasp icon, so the default peer is used).

**Windows → iPhone (the outbox).** The PC never connects to the phone. Grasp for Windows keeps a queue (`windows/core/src/outbox.rs`, persisted as `pairing/outbox.json`) and the app pulls it over the paired PC's pinned mTLS connection: `GET /api/grasp/v1/outbox` lists items (`{kind:"file", id, fileName, size, fileType}` or `{kind:"text", id, text}`, never a local path), `GET .../outbox/file?id=` streams one file from where it sits on disk, `POST .../outbox/done?id=` removes it after the phone saved it. Only a phone paired by code may pull (its client cert fingerprint, else 403); `grasp: 2` in `/info` advertises it. Files are queued by path, not copied; a file moved or deleted before the pull is dropped and reported. A folder's files keep their path under the folder name (`Trip/day 2/a.jpg`) and the phone recreates the folders. On the phone, `App/Inbox.swift` polls every 8s while the app is in the foreground (`PairingView` `.task`), downloads with `LSClient.downloadOutboxFile` (URLSession temp file, progress from `task.progress`), saves under Documents (Files › On My iPhone › Grasp; `InboxPaths.destination` cleans each path component and never overwrites), adds photos/videos to the Photos library when `saveMediaToPhotos` is on, puts text on the clipboard, then marks the item done. 403 shows "pair again with the code", 404 means stock LocalSend.

**`ios/tools/` is the regression harness.** `mock-receiver.mjs` enforces the real server's rules (mandatory mTLS, single session slot, same-IP + token uploads, sha256 check, message → 204) and `ls-send.mjs` mirrors `SendEngine` step for step. The message rule, status-code mapping, fingerprint format and the outbox (endpoints, item shape, path cleaning, paired-only rule) each exist in four places (Swift, sender script, mock, and the Rust receiver in `windows/core/src/server.rs` / `outbox.rs`) and must change together. `ls-send.mjs --fetch DIR` pulls the outbox exactly like `Inbox.pull`, `--cert DIR` acts as a different phone, and the mock and `grasp-headless` take `--send PATH` / `--send-text TEXT`. If the real LocalSend build behaves differently from the mock, update the mock and the Swift code to match reality. Both scripts cache their generated certs in gitignored `ios/tools/.client-cert/` and `ios/tools/.mock-server-cert/`, so their fingerprints are stable across runs.

### Grasp for Windows (`windows/`)

A Cargo workspace of two crates, split so the protocol can be tested without any UI.

- **`core/` (`grasp-core`)** is the whole LocalSend receiver: axum over rustls (ring provider, ECDSA cert from rcgen), no Tauri dependency. The only seam is the `Ui` trait in `ui.rs`: `decide(&IncomingRequest) -> bool` blocks `prepare-upload` until a human answers, and `event(UiEvent)` reports `Message`, `Progress`, `Done`, `Cancelled`, `Failed`. `server.rs` holds the session state machine (`Free` / `Pending` while the toast is up / `Active` with per-file tokens); `PendingGuard` frees the slot and dismisses the toast if the phone disconnects mid-prompt. The cert is generated once in the app data dir and reused, because the phone pins its fingerprint. `tls.rs` asks for (doesn't require) a client cert and attaches its fingerprint to every request (`PeerCert`); `pairing.rs` holds the code window and the paired list; `outbox.rs` the queue for the phone. `grasp_core::build` returns a `Handle` the shell uses for pairing, save folder, auto-accept and `send_paths` / `send_text` / `clear_outbox`. `UiEvent` also reports `Queued`, `OutboxProgress` and `OutboxDelivered`.
- **`src-tauri/` (`grasp-desktop`)** is the shell: a tray icon, one hidden-by-default toast window, and `TauriUi`, which implements `Ui`. `decide` plays the chime and emits an `incoming` event to the page, then awaits a oneshot that the `respond` command completes. `chime.rs` synthesizes the two-note bell as a WAV in memory and plays it through winmm. There is no audio asset to ship. `send.rs` is the Windows → iPhone shell: it writes `%APPDATA%\Microsoft\Windows\SendTo\iPhone (Grasp).lnk` (exe + `--send`) on every start, takes `--send <paths>` from its own launch or, through the single-instance plugin, from a second one, and implements Send files…/Send clipboard (copied files, else an image saved as PNG under app data `clipboard/`, else text). `dragwatch.rs` polls ~12×/s for "primary button held + a visible `SysDragImage` window" (the shell's drag image, present only during a real drag) and tells the toast `drag-start`/`drag-end`; the toast window's own `DragDrop` events deliver the paths.
- **`ui/index.html`** is the entire toast (plain HTML/CSS/JS, no bundler, `withGlobalTauri`). It is a small state machine: `incoming` → `receiving` → `done`, plus `copied` (an accepted message) and `failed`; for sending, `dropzone` (dashed area, only while dragging and only with a code-paired phone) → `queued` ("Waiting for iPhone", Cancel) → `outgoing` (progress) → `sent`. The page reports its measured height through `toast_resize` so the transparent window never covers more than the card.

**Rules that must not be loosened (the owner was explicit):**
- **Auto-accept only for a phone paired by code** (owner decision, Oct 2026; off by default, a toggle in the tray menu). Pairing: the tray menu shows a 3-digit code for 2 minutes, the phone POSTs it to `/api/grasp/v1/pair` with its client cert, 5 wrong codes close the window, paired cert fingerprints persist in `pairing/paired.json`. The receiver asks for (doesn't require) a client cert and verifies the handshake signature, so the fingerprint is proof of the key. Anyone else, or the same phone without its cert, still needs a tap on Accept. `windows/test-e2e.sh` proves this.
- A prompt nobody answers is a rejection after 30s (`DECISION_TIMEOUT`), never an acceptance.
- A cancel leaves nothing of that transfer on the receiver (owner decision, Oct 2026). iPhone → PC: the share sheet's Cancel (which waits up to 3s for `/cancel` before closing) or the X beside the toast's progress bar (`Handle::cancel_receive`) runs `abort_session`, which deletes every file the session saved plus its `.part` files; later uploads of that session get 410 (`LSError.cancelledOnPC`). PC → iPhone: the X clears the outbox, the file stream stops at its next chunk, and the phone, finding the item gone from the queue, deletes everything it saved in that pull (`InboxPaths.remove`). Photos are added to the library only after a pull completes, so a cancel leaves no copy there either.
- After a transfer, Explorer opens on the folder with the first file selected (`/select,` as one raw argument). The received file itself is never opened.
- After an accepted (or auto-accepted, owner's choice) message, the shell copies it to the clipboard and opens it only if `as_openable_url` says it is exactly one `http`/`https` link with no whitespace. `file:`, `javascript:`, `ms-msdt:`, UNC paths and multi-line text must never open. The URL is passed to `rundll32` as a single argv entry, never through a shell.
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

- Receiver is **Grasp for Windows** (`windows/`), speaking the LocalSend v2.2 protocol (plus the Grasp-only `/api/grasp/v1/pair` and `/api/grasp/v1/outbox*`) so the iPhone code and the harness stay valid. It replaces the stock LocalSend desktop app, which stays a supported fallback (the phone pairs with it by trust on first use, no code). Accept on every transfer except from a code-paired phone with auto-accept on. PIN support stays in the Swift code but the Windows app has none.
- Grasp for Windows is tray icon + toast + the Grasp window (`ui/menu.html`, label `menu`, same always-dark style). Owner decision, Oct 2026: it is a normal window, not a popup: dark native title bar (`"theme": "Dark"`), taskbar button while open, centred on first open, not resizable, height follows its content; the tray icon brings it to the front and its close button only hides it to the tray (Grasp keeps receiving until Quit). The window holds exactly: PC name/IP and status, paired iPhones (unpair), Pair iPhone (code), Send files…, Send clipboard, what's waiting for the iPhone (with Clear), auto-accept from paired iPhone, save folder, open folder, launch at login, quit. Settings live in `settings.json` in app data. Don't add more configuration.
- One default PC, zero-tap send, no device picker in the extension. (`PeerStore` keeps an array internally so multi-PC is a later UI change.)
- The share sheet stays open with progress until done. No background `URLSession`.
- Photos arrive as JPG by default: HEIC/HEIF and still WebP are converted (quality 0.9, EXIF kept). Animated WebP is left as is (a JPG would keep one frame). Owner decision, Oct 2026: the iPhone app has a Settings screen (`SendSettings`) with exactly these options, all defaulting to the old behaviour: photo format JPG/original, JPG quality 50–100%, remove location (photos only; a photo that can't be rewritten fails the share rather than leak GPS), name photos by date taken, send a single link/text as a message or as Note.txt, send folders as one .zip or as separate files. Settings live on the phone only; the Windows menu is unchanged.
- LAN only: stored IP for every send, plus a tap-only /24 HTTP scan and Manual IP for pairing (owner-approved change, Oct 2026: no automatic sweeps, they get the phone kicked off managed Wi-Fi). No multicast entitlement, no Bonjour, no Tailscale.
- Bundle IDs `com.itsaerolol.grasp` and `com.itsaerolol.grasp.share`, iOS 18 minimum, personal TestFlight distribution.
- Videos are sent as-is (no transcoding) and there is no item-count limit: the extension's activation rule is a SUBQUERY predicate, because the dictionary form caps counts. Provider temp files are moved, not copied, so a large video doesn't need twice its size free.
- The share sheet offers Grasp for any item (activation rule matches `public.item`). Folders are zipped on the phone and arrive as one `<name>.zip` by default (owner decision, Oct 2026; Settings can send their files instead), read in place where the provider allows so the folder isn't copied first. The PC side needs no change.
- Windows → iPhone is pull-only (owner decision, Oct 2026): the PC queues, the phone collects while Grasp is open, only a code-paired phone may collect. Ways in on the PC: Explorer Send to, tray Send files…/Send clipboard, and the drop zone that opens on the toast whenever files are dragged. On the phone everything lands in Files › On My iPhone › Grasp, photos/videos also in Photos (a setting, on by default), text on the clipboard.
- Out of scope: background transfers, video optimization, multi-PC picker, Tailscale/off-LAN, multicast discovery, App Store polish. (A custom Windows receiver was out of scope in the original brief and is now in scope.)
