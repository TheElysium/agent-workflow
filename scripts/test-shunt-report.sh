#!/usr/bin/env bash
# Smoke tests for scripts/shunt-report.sh.
#
# Report contract (text):
#   records: N
#   allowed: A
#   blocked: B
#   by decision/reason:
#     <decision>/<reason>: <count>
#   by harness:
#     <harness>: <count>
#   by tool:
#     <tool>: <count>
#   top blocked files:
#     <count>x  <path>
#   top allowed commands:
#     <count>x  <command>
#
# shunt.jsonl holds one record per shunt decision (allow AND deny); legacy
# records without a "decision" field count as "deny". Filtering is by
# --since/--session only (no dedup of raw records; only the "top allowed
# commands" section collapses multi-file calls sharing ts+session+command).
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
# E1: legacy deny (no "decision" key) — claude/s1, read, foo.json, bytes
# E2: deny — claude/s1, bash, bigfile.txt, lines, has command
# E3: deny, null path (defensive) — opencode/s2, bash, bytes, has command
# E4: allow/compound, null path — opencode/s2, bash, command "git log | head -n 5"
# E5+E6: allow/targeted, multi-file (same ts+session+command) — opencode/s3, bash
# E7: allow/verb, command with an embedded newline — claude/s4, bash
# E8: allow/compound, same command as E4 but a different call — claude/s5, bash
# E9: deny/lines — opencode/s2, read, foo.json (repeat of E1's path)
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
mkdir -p "$R/.usage"
SINK="$R/.usage/shunt.jsonl"
{
  echo '{"ts":"2026-09-14T08:00:00Z","harness":"claude","session":"s1","tool":"read","path":"foo.json","reason":"bytes","bytes":71234,"lines":null,"threshold_bytes":65536,"threshold_lines":350}'
  echo '{"ts":"2026-09-14T08:05:00Z","harness":"claude","session":"s1","tool":"bash","decision":"deny","path":"bigfile.txt","reason":"lines","bytes":50000,"lines":412,"threshold_bytes":65536,"threshold_lines":350,"command":"cat bigfile.txt"}'
  echo '{"ts":"2026-09-14T08:10:00Z","harness":"opencode","session":"s2","tool":"bash","decision":"deny","path":null,"reason":"bytes","bytes":90000,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"ls -la"}'
  echo '{"ts":"2026-09-14T09:00:00Z","harness":"opencode","session":"s2","tool":"bash","decision":"allow","path":null,"reason":"compound","bytes":null,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"git log | head -n 5"}'
  echo '{"ts":"2026-09-14T09:05:00Z","harness":"opencode","session":"s3","tool":"bash","decision":"allow","path":"file1.txt","reason":"targeted","bytes":null,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"grep foo file1.txt file2.txt"}'
  echo '{"ts":"2026-09-14T09:05:00Z","harness":"opencode","session":"s3","tool":"bash","decision":"allow","path":"file2.txt","reason":"targeted","bytes":null,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"grep foo file1.txt file2.txt"}'
  printf '%s\n' '{"ts":"2026-09-14T09:10:00Z","harness":"claude","session":"s4","tool":"bash","decision":"allow","path":null,"reason":"verb","bytes":null,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"echo hi\necho bye"}'
  echo '{"ts":"2026-09-14T09:15:00Z","harness":"claude","session":"s5","tool":"bash","decision":"allow","path":null,"reason":"compound","bytes":null,"lines":null,"threshold_bytes":65536,"threshold_lines":350,"command":"git log | head -n 5"}'
  echo '{"ts":"2026-09-14T10:00:00Z","harness":"opencode","session":"s2","tool":"read","decision":"deny","path":"foo.json","reason":"lines","bytes":1000,"lines":500,"threshold_bytes":65536,"threshold_lines":350}'
} > "$SINK"

# --- 1. totals + breakdowns over the whole fixture -------------------------------
run
expect_rc "report exits 0" 0
expect_has "total records" "records: 9"
expect_has "total allowed" "allowed: 5"
expect_has "total blocked" "blocked: 4"
expect_has "decision/reason allow/compound" "allow/compound: 2"
expect_has "decision/reason allow/targeted" "allow/targeted: 2"
expect_has "decision/reason allow/verb" "allow/verb: 1"
expect_has "decision/reason deny/bytes (incl. legacy no-decision record)" "deny/bytes: 2"
expect_has "decision/reason deny/lines" "deny/lines: 2"
expect_has "harness claude count" "claude: 4"
expect_has "harness opencode count" "opencode: 5"
expect_has "tool read count" "read: 2"
expect_has "tool bash count" "bash: 7"
expect_has "top blocked files: foo.json wins with 2 (excludes allow + null-path deny)" "2x  foo.json"
expect_has "top blocked files: bigfile.txt" "1x  bigfile.txt"
expect_lacks "top blocked files excludes null path" "x  null"
expect_has "top allowed commands: git log dedup+aggregate across 2 distinct calls" "2x  git log | head -n 5"
expect_has "top allowed commands: multi-file grep call counts once" "1x  grep foo file1.txt file2.txt"
expect_has "top allowed commands: newline command stays on one line" "1x  echo hi\necho bye"
if printf '%s\n' "$OUT" | grep -qx "echo bye"; then
  FAIL=$((FAIL + 1)); echo "FAIL: no raw newline splits the echo command across two output lines"
else
  PASS=$((PASS + 1))
fi

# --- 2. output has no CR (native Windows jq default) -----------------------------
if printf '%s' "$OUT" | grep -q $'\r'; then FAIL=$((FAIL + 1)); echo "FAIL: output must not contain CR"; else PASS=$((PASS + 1)); fi

# --- 3. --since filters older events (drops E1, E2, E3; keeps ts > since) --------
run --since "2026-09-14T08:59:00Z"
expect_has "records after since filter" "records: 6"
expect_has "allowed after since filter" "allowed: 5"
expect_has "blocked after since filter" "blocked: 1"

# --- 4. --session filters to one session -----------------------------------------
run --session s1
expect_has "records for session s1" "records: 2"
expect_has "blocked for session s1" "blocked: 2"
expect_has "allowed for session s1" "allowed: 0"
expect_lacks "opencode excluded for session s1" "opencode:"

# --- 5. empty sink (file exists, 0 records) -> rc 0 ------------------------------
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
mkdir -p "$R/.usage" && : > "$R/.usage/shunt.jsonl"
run
expect_rc "empty sink exits 0" 0
expect_has "empty sink reports zero records" "records: 0"
expect_has "empty sink reports zero allowed" "allowed: 0"
expect_has "empty sink reports zero blocked" "blocked: 0"

# --- 6. missing file -> error ------------------------------------------------------
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
run
expect_rc "missing sink exits nonzero" 1

# --- 7. unknown arg -> error --------------------------------------------------------
R="$(mktemp -d /tmp/shunt-report-test.XXXXXX)"
mkdir -p "$R/.usage" && : > "$R/.usage/shunt.jsonl"
run --bogus
expect_rc "unknown arg exits nonzero" 1

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
