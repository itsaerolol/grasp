#!/usr/bin/env bash
# Proves the sender flow against the mock receiver. Run from repo root: bash tools/test-e2e.sh
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d); PORT=53399; PASS=0; FAIL=0
cleanup() { kill "${MOCK:-}" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

start_mock() { node tools/mock-receiver.mjs --port $PORT --inbox "$T/inbox" "$@" > "$T/mock.log" 2>&1 & MOCK=$!; sleep 1.2; }
stop_mock() { kill "$MOCK" 2>/dev/null || true; wait "$MOCK" 2>/dev/null || true; }
check() { if eval "$2"; then echo "PASS  $1"; PASS=$((PASS+1)); else echo "FAIL  $1"; FAIL=$((FAIL+1)); cat "$T/mock.log"; fi; }
send() { node tools/ls-send.mjs --host 127.0.0.1 --port $PORT "$@" > "$T/send.log" 2>&1; }

head -c 3000000 /dev/urandom > "$T/photo.jpg"; echo "hello grasp" > "$T/note.pdf"

start_mock --auto-accept
FP=$(grep -o 'fingerprint [0-9A-F]\{64\}' "$T/mock.log" | awk '{print $2}')
check "files upload with mTLS + sha256" "send '$T/photo.jpg' '$T/note.pdf' && cmp -s '$T/photo.jpg' '$T/inbox/photo.jpg' && cmp -s '$T/note.pdf' '$T/inbox/note.pdf'"
check "text message -> 204, no upload" "send --text 'https://whiteframe.cc' && grep -q '204' '$T/send.log' && grep -q 'MESSAGE.*whiteframe' '$T/mock.log'"
check "pinned fingerprint accepted" "send --pin-fp $FP --info"
check "wrong pinned fingerprint refused" "! send --pin-fp $(printf 'A%.0s' {1..64}) --info"
check "no client cert refused (mandatory mTLS)" "! send --no-client-cert --info"
stop_mock

start_mock --reject
check "manual reject -> 403 surfaced" "! send '$T/photo.jpg' && grep -q 'Rejected' '$T/send.log'"
stop_mock

start_mock --auto-accept --pin 4321
check "pin required -> 401 surfaced" "! send --text hi && grep -q 'PIN' '$T/send.log'"
check "pin accepted" "send --pin 4321 --text hi"
stop_mock

# LocalSend 1.17.0 (Flutter build, verified on the real Windows PC) does not request a client cert.
# Grasp must still work when the server never asks for one.
start_mock --auto-accept --optional-client-cert
check "optional client cert (LocalSend 1.17): send without cert works" "send --no-client-cert --text hi && grep -q '204' '$T/send.log'"
stop_mock

# Grasp for Windows code pairing, as the mock implements it (same rules as windows/core/src/pairing.rs).
start_mock --auto-accept --optional-client-cert --pair-code 427   # Grasp for Windows: client cert optional
check "info advertises code pairing" "send --info && grep -q 'code pairing: supported' '$T/send.log'"
check "wrong code refused with attempts left" "! send --pair 111 && grep -q 'Wrong code (4 left)' '$T/send.log'"
check "pairing needs a client cert" "! send --no-client-cert --pair 427 && grep -q 'Client certificate required' '$T/send.log'"
check "right code pairs" "send --pair 427 && grep -q 'paired with Mock PC' '$T/send.log'"
check "code is single-use" "! send --pair 427 && grep -q 'not open' '$T/send.log'"
stop_mock

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
