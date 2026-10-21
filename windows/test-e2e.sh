#!/usr/bin/env bash
# Proves Grasp for Windows' receiver (windows/core, headless build) against the reference sender.
# Run from anywhere: bash windows/test-e2e.sh
# Differences from test-e2e.sh (mock): our receiver does not request a client cert, so there is
# no "no cert refused" case, and it has no PIN support.
set -euo pipefail
cd "$(dirname "$0")"
T=$(mktemp -d); PORT=53398; PASS=0; FAIL=0
cleanup() { kill "${RECV:-}" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

cargo build --quiet --manifest-path Cargo.toml -p grasp-core --bin grasp-headless
BIN=target/debug/grasp-headless
[ -f "$BIN.exe" ] && BIN="$BIN.exe"

start_recv() { "$BIN" --port $PORT --inbox "$T/inbox" --state "$T/state" "$@" > "$T/recv.log" 2>&1 & RECV=$!; sleep 1.2; }
stop_recv() { kill "$RECV" 2>/dev/null || true; wait "$RECV" 2>/dev/null || true; }
check() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); cat "$T/recv.log"; fi; }
send() { node ../ios/tools/ls-send.mjs --host 127.0.0.1 --port $PORT "$@" > "$T/send.log" 2>&1; }

head -c 3000000 /dev/urandom > "$T/photo.jpg"; echo "hello grasp" > "$T/note.pdf"

start_recv --auto-accept
FP=$(grep -o 'fingerprint [0-9A-F]\{64\}' "$T/recv.log" | awk '{print $2}')
check "files upload + sha256 verified" "send '$T/photo.jpg' '$T/note.pdf' && cmp -s '$T/photo.jpg' '$T/inbox/photo.jpg' && cmp -s '$T/note.pdf' '$T/inbox/note.pdf'"
check "same name again -> saved as 'photo (2).jpg', original untouched" "send '$T/photo.jpg' && cmp -s '$T/photo.jpg' '$T/inbox/photo (2).jpg' && cmp -s '$T/photo.jpg' '$T/inbox/photo.jpg'"
check "text message -> 204, no upload" "send --text 'https://whiteframe.cc' && grep -q '204' '$T/send.log' && grep -q 'MESSAGE.*whiteframe' '$T/recv.log'"
check "pinned fingerprint accepted" "send --pin-fp $FP --info"
check "wrong pinned fingerprint refused" "! send --pin-fp $(printf 'A%.0s' {1..64}) --info"
check "client cert optional (works without one)" "send --no-client-cert --text hi"
check "no leftover .part files" "! ls -a '$T/inbox' | grep -q '\.part$'"
check "cert fingerprint is stable across restarts" "stop_recv; start_recv --auto-accept; grep -q \"fingerprint $FP\" '$T/recv.log'"
stop_recv

start_recv --reject
check "reject -> 403 surfaced" "! send '$T/photo.jpg' && grep -q 'Rejected' '$T/send.log'"
check "rejected text message is refused and never delivered" "! send --text 'sneaky link' && grep -q 'Rejected' '$T/send.log' && ! grep -q 'MESSAGE' '$T/recv.log'"
stop_recv

# Code pairing + auto-accept for paired devices only. Unpaired senders are rejected (--reject), so
# anything that gets through below got through because it is paired.
rm -rf "$T/state" "$T/inbox"
start_recv --reject --auto-accept-paired --pair-code 427
FP=$(grep -o 'fingerprint [0-9A-F]\{64\}' "$T/recv.log" | awk '{print $2}')
check "info advertises code pairing" "send --info && grep -q 'code pairing: supported' '$T/send.log'"
check "auto-accept does not apply to an unpaired sender" "! send '$T/photo.jpg' && grep -q 'Rejected' '$T/send.log'"
check "wrong code refused with attempts left" "! send --pair 111 && grep -q 'Wrong code (4 left)' '$T/send.log'"
check "pairing needs a client cert" "! send --no-client-cert --pair 427 && grep -q 'Client certificate required' '$T/send.log'"
check "right code pairs" "send --pair 427 && grep -q 'paired with' '$T/send.log' && grep -q 'PAIRED Grasp CLI' '$T/recv.log'"
check "code is single-use" "! send --pair 427 && grep -q 'not open' '$T/send.log'"
check "paired sender is auto-accepted" "send '$T/photo.jpg' && grep -q 'AUTO-ACCEPTED' '$T/recv.log' && cmp -s '$T/photo.jpg' '$T/inbox/photo.jpg'"
check "paired text message is auto-accepted" "send --text 'https://whiteframe.cc' && grep -q 'MESSAGE.*whiteframe' '$T/recv.log'"
check "same sender without its cert is not trusted" "! send --no-client-cert --text hi && grep -q 'Rejected' '$T/send.log'"
check "pairing survives a restart" "stop_recv; start_recv --reject --auto-accept-paired; send --text again && grep -q 'AUTO-ACCEPTED' '$T/recv.log'"
stop_recv

# Windows -> iPhone: the outbox. The phone (ls-send --fetch, same steps as the iPhone app) pulls; only the
# phone paired above may. A folder keeps its structure; a file deleted before the pull is skipped and reported.
mkdir -p "$T/out/Trip/day 2"
head -c 2000000 /dev/urandom > "$T/out/Trip/day 2/clip.mov"; echo b > "$T/out/Trip/b.jpg"; echo x > "$T/out/Trip/desktop.ini"
echo gone > "$T/out/gone.pdf"
start_recv --reject --send "$T/out/Trip" --send "$T/out/gone.pdf" --send "$T/photo.jpg" --send-text 'https://whiteframe.cc'
rm "$T/out/gone.pdf"
check "info advertises the outbox" "send --info && grep -q 'outbox (PC -> iPhone): supported' '$T/send.log'"
check "queued 4 files + 1 text (desktop.ini skipped)" "grep -q 'QUEUED 4 (4 waiting)' '$T/recv.log' && grep -q 'QUEUED 1 (5 waiting)' '$T/recv.log'"
check "outbox needs a client cert" "! send --no-client-cert --fetch '$T/got' && grep -q 'Client certificate required' '$T/send.log'"
check "another phone (unpaired cert) can't pull" "! send --cert '$T/other-phone' --fetch '$T/got' && grep -q 'Not paired' '$T/send.log'"
check "paired phone pulls folder, files and text" "send --fetch '$T/got' && grep -q 'TEXT: https://whiteframe.cc' '$T/send.log' && cmp -s '$T/photo.jpg' '$T/got/photo.jpg'"
check "folder structure kept" "cmp -s '$T/out/Trip/day 2/clip.mov' '$T/got/Trip/day 2/clip.mov' && cmp -s '$T/out/Trip/b.jpg' '$T/got/Trip/b.jpg' && [ ! -e '$T/got/Trip/desktop.ini' ]"
check "deleted file is skipped and reported" "[ ! -e '$T/got/gone.pdf' ] && grep -q 'gone.pdf wasn.t sent to iPhone' '$T/recv.log'"
check "delivered items leave the queue" "grep -q 'DELIVERED https://whiteframe.cc (0 left)' '$T/recv.log' && send --fetch '$T/got2' && grep -q 'nothing waiting' '$T/send.log'"
check "queue survives a restart" "stop_recv; start_recv --reject --send-text later; stop_recv; start_recv --reject; send --fetch '$T/got3' && grep -q 'TEXT: later' '$T/send.log'"
stop_recv

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
