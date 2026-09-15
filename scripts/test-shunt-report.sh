#!/usr/bin/env bash
# Smoke tests for scripts/shunt-report.sh.
#
# Report contract (text):
#   blocked: N
#   by harness:
#     <harness>: <count>
#   by tool:
#     <tool>: <count>
#   by reason:
#     <reason>: <count>
#   top blocked files:
#     <count>x  <path>
#
# shunt.jsonl events are one-shot (no dedup): every line is a distinct
# blocked-call record, filtered only by --since/--session.
#
# Usage:  bash scripts/test-shunt-report.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/shunt-report.sh"

PASS=0
FAIL=0

R=""
cleanup() { [ -n "$R" ] && rm -rf "$R"; }
trap cleanup EXIT

run() { # run [args...] — sink at $R/.usage/shunt.jsonl, sets OUT/RC
  OUT="$(bash "$REPORT" --file "$R/.usage/shunt.jsonl" "$@" 2>&1)"
  RC=$?
}

expect_rc() { # expect_rc <desc> <want>
  if [ "$RC" = "$2" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (want rc=$2, got $RC)  [out: ${OUT:0:140}]"; fi
}
expect_has() {
  if grep -qF -- "$2" <<< "$OUT"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: $1 (missing: $2)  [out: ${OUT:0:200}]"; fi
}
expect_lacks() {
  if grep -qF -- "$2" <<< "$OUT"; then FAIL=$((FAIL + 1)); echo "FAIL: $1 (must not contain: $2)  [out: ${OUT:0:200}]"; else PASS=$((PASS + 1)); fi
}

# --- fixture -------------------------------------------------------------------
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
mkdir -p "$R/.usage"
SINK="$R/.usage/shunt.jsonl"
{
  # E1: claude/s1, read, foo.json, bytes, no command key
  echo '{"ts":"2026-09-12T15:26:19Z","harness":"claude","session":"s1","tool":"read","path":"foo.json","reason":"bytes","bytes":71234,"lines":null,"threshold_bytes":65536,"threshold_lines":350}'
  # E2: claude/s1, bash, bigfile.txt, lines, has command key
  echo '{"ts":"2026-09-12T15:27:00Z","harness":"claude","session":"s1","tool":"bash","path":"bigfile.txt","reason":"lines","bytes":50000,"lines":412,"threshold_bytes":65536,"threshold_lines":350,"command":"cat bigfile.txt"}'
  # E3: opencode/s2, read, foo.json (repeat), bytes, no command key
  echo '{"ts":"2026-09-13T09:00:00Z","harness":"opencode","session":"s2","tool":"read","path":"foo.json","reason":"bytes","bytes":80000,"lines":null,"threshold_bytes":65536,"threshold_lines":350}'
  # E4: opencode/s2, bash, other.txt, bytes, has command key
  echo '{"ts":"2026-09-13T10:00:00Z","harness":"opencode","session":"s2","tool":"bash","path":"other.txt","reason":"bytes","bytes":90000,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"ls other.txt"}'
  # E5: opencode/s3, read, foo.json (repeat again), lines, no command key
  echo '{"ts":"2026-09-13T11:00:00Z","harness":"opencode","session":"s3","tool":"read","path":"foo.json","reason":"lines","bytes":1000,"lines":500,"threshold_bytes":65536,"threshold_lines":350}'
} > "$SINK"

# --- 1. totals + breakdowns over the whole fixture -------------------------------
run
expect_rc "report exits 0" 0
expect_has "total blocked" "blocked: 5"
expect_has "harness claude count" "claude: 2"
expect_has "harness opencode count" "opencode: 3"
expect_has "tool read count" "read: 3"
expect_has "tool bash count" "bash: 2"
expect_has "reason bytes count" "bytes: 3"
expect_has "reason lines count" "lines: 2"
expect_has "top file: foo.json wins with 3" "3x  foo.json"
expect_lacks "no spurious command breakdown category" "command"

# --- 2. --since filters older events (drops the two claude/s1 events) -----------
run --since "2026-09-13T00:00:00Z"
expect_has "blocked count after since filter" "blocked: 3"
expect_lacks "claude excluded by since filter" "claude:"
expect_has "opencode kept by since filter" "opencode: 3"

# --- 3. --session filters to one session -----------------------------------------
run --session s1
expect_has "blocked count for session s1" "blocked: 2"
expect_has "claude kept for session s1" "claude: 2"
expect_lacks "opencode excluded for session s1" "opencode:"

# --- 4. missing/bash+read mixed command key never crashes (already exercised in
#        fixture above via E1..E5's mix of present/absent "command" keys) -------

# --- 5. empty sink (file exists, 0 records) -> rc 0 ------------------------------
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
mkdir -p "$R/.usage" && : > "$R/.usage/shunt.jsonl"
run
expect_rc "empty sink exits 0" 0
expect_has "empty sink reports zero blocked" "blocked: 0"

# --- 6. missing file -> error ------------------------------------------------------
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
run
expect_rc "missing sink exits nonzero" 1

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
