# Build Grasp v1 MVP

You are building **Grasp**, a personal iOS app whose share extension sends photos, files, and text from the iPhone share sheet to a Windows 11 PC, as close to AirDrop as possible. The PC runs the stock **LocalSend** desktop app as the receiver; Grasp speaks the LocalSend v2.2 protocol. You are running in Claude Code on my Mac with Xcode installed. My iPhone is available over USB/Wi-Fi for device testing.

The repo is already scaffolded (this folder). Read `README.md` first, then every file in `Shared/`, `App/`, `ShareExtension/`, and `tools/`. The scaffold was written without a Swift compiler, so expect compile errors. The architecture and protocol logic are deliberate; fix compile issues without redesigning.

## Locked decisions (do not change, do not add alternatives)

- Receiver: LocalSend desktop on Windows 11, encryption ON, **manual accept** on the PC. No Quick Save, no PIN by default (PIN support stays in code).
- Payloads: photos/screenshots, files/docs, text/links. Video is not a focus.
- One default PC, zero-tap send. No device picker in the extension.
- Share sheet stays open with progress until done. **No background URLSession.**
- Photos always converted HEIC→JPG.
- A single text/link share is sent as a LocalSend text message (popup on PC).
- LAN only. Discovery = HTTP /24 scan + last-known IP. **No multicast entitlement, no Bonjour, no Tailscale.**
- Bundle IDs `com.itsaerolol.grasp` and `com.itsaerolol.grasp.share`; App Group `group.com.itsaerolol.grasp` (also the keychain access group). iOS 18 minimum. Personal TestFlight, not App Store.

If something here seems wrong, stop and tell me instead of substituting your own option.

## Critical protocol facts (verified in localsend/localsend source, Oct 2026)

1. **mTLS is mandatory.** The LocalSend server requires a client certificate unless web share is enabled (`packages/core/src/http/server/mod.rs`, `mandatory_client_auth`). It accepts any self-signed cert whose signature verifies. Grasp creates an RSA-2048 self-signed identity on first app launch (`ClientIdentity.swift`) and presents it in `LSSessionDelegate`.
2. Fingerprint = uppercase hex SHA-256 of cert DER. Our `info.fingerprint` must equal our client cert fingerprint or `/register` is ignored.
3. Server cert is self-signed: pin by fingerprint after first pairing (TOFU during scan).
4. One session at a time (409). Uploads must come from the same IP as prepare-upload, with per-file tokens. sha256 mismatch → 422.
5. Text message = exactly one `text/plain` file with `preview` = text → 204, no upload.
6. `prepare-upload` blocks until the human clicks Accept, so its request timeout is 600s.

## Phases (finish each, verify, then move on)

### Phase 0: Prove the protocol against the real PC (no Xcode)
- `bash tools/test-e2e.sh` must pass 8/8.
- Ask me for the PC's IP, then run `node tools/ls-send.mjs --host <IP> --info`, then a file send and `--text "hi"`. I'll click Accept on the PC.
- **Gate:** confirm the real Windows build behaves like the mock: mTLS required (`--no-client-cert` fails), accept flow works, files land. If the real build differs from the findings above, report the difference and update `tools/` and the Swift code to match reality before continuing.

### Phase 1: Project compiles
- `brew install xcodegen` if missing. Ask me for my Team ID. `DEVELOPMENT_TEAM=<id> xcodegen generate`.
- Build both targets with `xcodebuild` for iOS Simulator until clean, zero warnings that indicate real bugs.
- Expected fix areas: swift-certificates API (`Certificate` init, `Certificate.Extensions` builder, `DER.Serializer`), `_RSA.Signing.PrivateKey(derRepresentation:)` from SecKey PKCS#1 export, Swift concurrency annotations.
- Keep `project.yml` the source of truth; never hand-edit the generated `.xcodeproj`.

### Phase 2: Identity + pairing work in the Simulator
- The Simulator shares the Mac's network, so run `node tools/mock-receiver.mjs --auto-accept` on the Mac and use the Manual IP field with the Mac's LAN IP (127.0.0.1 also works in the Simulator).
- Verify: identity created once and reloaded on relaunch; scan or manual add finds the mock; mock log shows the **client cert fingerprint** matching the one the app displays; "Send test message" logs a MESSAGE on the mock.
- If the mock logs "no client certificate": debug the keychain identity lookup (`kSecClassIdentity` + label + access group) and the client-cert challenge path. If the TLS handshake fails with the RSA key, test whether iOS signs TLS 1.3 CertificateVerify with RSA-PSS for keychain RSA identities; fall back to a P-256 key only after confirming LocalSend's verifier accepts ECDSA certs (check `verify_cert_from_der` in `packages/core/src/crypto/cert.rs`).

### Phase 3: Share extension end-to-end in the Simulator
- From Photos (add sample HEIC images to the Simulator), Files, and Safari, share to Grasp against the mock.
- Verify: HEIC arrives as `.jpg` and opens; multiple photos in one share become one session; a Safari URL arrives as a MESSAGE; text+file mix sends text as `Note.txt`; Cancel calls `/cancel`; errors show readable messages (stop the mock to test unreachable; use `--reject` to test decline).
- Add unit tests (a `GraspTests` target in `project.yml`) for: `Fingerprint.of`, `PayloadBuilder.convertIfHEIC`, `SendEngine.describe` message-vs-files logic, `LSError.from(status:)`.

### Phase 4: Real device + real PC
- Install on my iPhone. Pair with the real PC, send photos, a PDF from Files, and a Safari link. I click Accept on the PC.
- Verify the PC appears in the share sheet's **top suggestion row** after a send (INSendMessageIntent donation), and that tapping it there sends to that PC (`extensionContext.intent` path).
- Verify the extension never exceeds its memory limit on a 50-photo share (Xcode memory gauge). Files must stream from disk; never load a whole file into memory.
- Change the PC's IP (renew DHCP or ask me) and confirm `Discovery.resolve` finds it again by fingerprint.

### Phase 5: Ship to TestFlight
- Archive and upload to TestFlight (I have an active Apple Developer account). App icon: simple placeholder generated in code or a solid-color asset. Ask before creating the App Store Connect record.

## Rules

- Keep `tools/mock-receiver.mjs` in lockstep with real LocalSend behavior; it is the regression harness.
- Every user-visible failure gets a one-line, actionable message (see `LSError`).
- Don't add features outside this prompt. Out of scope: background transfers, video optimization, multi-PC picker, Tailscale, multicast, a custom Windows receiver, App Store polish.
- Commit after each phase with a clear message. At the end, give me: what works, what was verified on device, any divergence from the findings above, and the TestFlight build number.
