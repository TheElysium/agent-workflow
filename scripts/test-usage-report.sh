#!/usr/bin/env bash
# Smoke tests for scripts/usage-report.sh.
#
# Report contract (text):
#   records: N (deduped from M)
#   primary:  <in> in / <out> out   (cache_read R, cache_write W)
#   subagent: <in> in / <out> out
#   unknown:  <in> in / <out> out
#   by model:
#     <model>: <in> in / <out> out
#
# Duplicates (same harness+session+msg — repeated message.updated events or
# snapshot imports) collapse to the last record per key.
#
# Usage:  bash scripts/test-usage-report.sh
# Exit:   0 if every case passes, 1 otherwise.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/usage-report.sh"

PASS=0
FAIL=0

R=""
cleanup() { [ -n "$R" ] && rm -rf "$R"; }
trap cleanup EXIT

run() { # run [args...] — sink at $R/.usage/usage.jsonl, sets OUT/RC
  OUT="$(bash "$REPORT" --file "$R/.usage/usage.jsonl" "$@" 2>&1)"
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
R="$(mktemp -d /tmp/usage-report-test.XXXXXX)"
mkdir -p "$R/.usage"
SINK="$R/.usage/usage.jsonl"
{
  # msg_a: snapshot 1 then snapshot 2 (dedup -> keep last: in 2 / out 503)
  echo '{"ts":"2026-09-12T15:26:19Z","harness":"claude","session":"s1","msg":"msg_a","role":"primary","model":"claude-sonnet-5","tokens_in":2,"tokens_out":100,"cache_read":33764,"cache_write":15753}'
  echo '{"ts":"2026-09-12T15:26:30Z","harness":"claude","session":"s1","msg":"msg_a","role":"primary","model":"claude-sonnet-5","tokens_in":2,"tokens_out":503,"cache_read":33764,"cache_write":15753}'
  # subagent record
  echo '{"ts":"2026-09-12T15:27:00Z","harness":"claude","session":"s2","msg":"msg_b","role":"subagent","model":"claude-sonnet-5","tokens_in":7,"tokens_out":8,"cache_read":9,"cache_write":10}'
  # opencode record
  echo '{"ts":"2026-09-13T09:00:00Z","harness":"opencode","session":"s3","msg":"m1","role":"primary","model":"opencode-go/glm-5.3-flash","tokens_in":1000,"tokens_out":200,"cache_read":0,"cache_write":0}'
} > "$SINK"

# --- 1. totals after dedup ------------------------------------------------------
run
expect_rc "report exits 0" 0
expect_has "dedup count" "records: 3 (deduped from 4)"
expect_has "primary totals (msg_a last + opencode)" "primary: 1002 in / 703 out"
expect_has "subagent totals" "subagent: 7 in / 8 out"
expect_has "unknown totals" "unknown: 0 in / 0 out"
expect_has "model line: claude" "claude-sonnet-5: 9 in / 511 out"
expect_has "model line: opencode" "opencode-go/glm-5.3-flash: 1000 in / 200 out"

# --- 2. --since filters older records -------------------------------------------
run --since "2026-09-13T00:00:00Z"
expect_has "opencode record kept" "opencode-go/glm-5.3-flash: 1000 in / 200 out"
expect_lacks "claude records filtered out" "claude-sonnet-5"

# --- 3. --session filters to one session ----------------------------------------
run --session s2
expect_has "only s2 totals" "subagent: 7 in / 8 out"
expect_lacks "opencode session excluded" "opencode-go/glm-5.3-flash"

# --- 4. empty sink (file exists, 0 records) -> rc 0 ------------------------------
R="$(mktemp -d /tmp/usage-report-test.XXXXXX)"
mkdir -p "$R/.usage" && : > "$R/.usage/usage.jsonl"
run
expect_rc "empty sink exits 0" 0

# --- 5. missing file -> error ----------------------------------------------------
R="$(mktemp -d /tmp/usage-report-test.XXXXXX)"
run
expect_rc "missing sink exits nonzero" 1

# --- summary -----------------------------------------------------------------
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
