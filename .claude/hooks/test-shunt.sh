#!/usr/bin/env bash
# Test harness for the shunt PreToolUse hook (.claude/hooks/shunt.sh).
# Mirrors the behavior contract of the opencode shunt.ts plugin.
#
# Usage:  bash test-shunt.sh
# Exit:   0 if every case passes, 1 otherwise.
#
# Runs the hook exactly like Claude Code does: JSON PreToolUse input on
# stdin; the hook's deny decision is read from stdout JSON.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/shunt.sh"

PASS=0
FAIL=0

# --- fixtures -------------------------------------------------------------
# Fixtures live on the Windows drive so that wslpath -w yields real C:\...
# paths, exactly like the Read tool sends them in production. The base dir
# is auto-detected from the mounted Windows drive (first profile with a
# writable Temp); SHUNT_TEST_TMP overrides.

TDIR=""
if [ -n "${SHUNT_TEST_TMP:-}" ]; then
  TDIR="$(mktemp -d "$SHUNT_TEST_TMP/shunt-test.XXXXXX")"
else
  for d in /mnt/[a-z]/Users/*/AppData/Local/Temp; do
    if TDIR="$(mktemp -d "$d/shunt-test.XXXXXX" 2>/dev/null)"; then break; fi
  done
  TDIR="${TDIR:-$(mktemp -d /tmp/shunt-test.XXXXXX)}"
fi
TDIR_BASE="${TDIR%/*}"
trap 'rm -rf "$TDIR"' EXIT

# 400 lines, small bytes (line-threshold trigger)
{ for i in $(seq 1 400); do echo "line $i of the big file"; done; } > "$TDIR/big.txt"

# 10 lines (under any default threshold)
{ for i in $(seq 1 10); do echo "line $i"; done; } > "$TDIR/small.txt"

# ~70 KB in a single line (byte-threshold trigger, few lines)
head -c 70000 /dev/zero | tr '\0' 'x' > "$TDIR/fat.json"

# Windows-style path for the big file (hook must handle backslashes).
# Only meaningful when fixtures sit on a mounted Windows drive; under /tmp,
# wslpath -w would yield a UNC path, so the backslash cases are skipped.
ON_WIN_DRIVE=0
if [[ "$TDIR_BASE" == /mnt/* ]]; then
  ON_WIN_DRIVE=1
  WSL_BIG="$(wslpath -w "$TDIR/big.txt")"   # C:\...\big.txt
fi

# --- helpers --------------------------------------------------------------

mkinput() { # mkinput <tool_name> <tool_input-json> [top-level-extra-json]
  local base
  base=$(jq -nc --arg tool "$1" --argjson ti "$2" \
    '{session_id:"s1",hook_event_name:"PreToolUse",tool_name:$tool,tool_input:$ti}')
  if [ $# -ge 3 ]; then jq -nc --argjson b "$base" --argjson x "$3" '$b + $x'; else printf '%s' "$base"; fi
}

expect() { # expect <desc> <want: pass|deny> <input-json> [ENVVAR value]...
  local desc="$1" want="$2" in="$3"; shift 3
  local env_extra=() out verdict
  while [ $# -ge 2 ]; do env_extra+=("$1=$2"); shift 2; done
  # cd into TDIR: any deny now also writes .usage/shunt.jsonl (telemetry),
  # relative to cwd — keep it inside the isolated fixture dir, never the repo.
  out=$(cd "$TDIR" && printf '%s' "$in" | env "${env_extra[@]}" bash "$HOOK" 2>/dev/null)
  if jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 <<< "$out"; then
    verdict=deny
  else
    verdict=pass
  fi
  if [ "$verdict" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL: $desc (want $want, got $verdict)  [out: ${out:0:140}]"
  fi
}

# --- Read tool ------------------------------------------------------------

expect "Read small file passes" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")"

expect "Read big file (400 lines) is denied" deny \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")"

expect "Read big file with offset is targeted" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"offset\":10}")"

expect "Read big file with limit only still denied (no offset)" deny \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"limit\":50}")"

expect "Read 70KB single-line file is denied by bytes" deny \
  "$(mkinput Read "{\"file_path\":\"$TDIR/fat.json\"}")"

expect "Read big file passes with top-level agent_id (subagent)" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}" '{"agent_id":"ag1","agent_type":"bulk-reader"}')"

expect "Read missing file passes" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/does-not-exist.txt\"}")"

if [ "$ON_WIN_DRIVE" = 1 ]; then
  expect "Read via Windows backslash path is denied" deny \
    "$(mkinput Read "{\"file_path\":\"${WSL_BIG//\\/\\\\}\"}")"
fi

# env-tuned thresholds
expect "SHUNT_MIN_LINES=5 denies 10-line file at lower bar" deny \
  "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" SHUNT_MIN_LINES 5

expect "SHUNT_MAX_BYTES=10 denies small file" deny \
  "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" SHUNT_MAX_BYTES 10

expect "SHUNT_MIN_LINES invalid falls back to default (small passes)" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" SHUNT_MIN_LINES 0

# --- Bash tool ------------------------------------------------------------

expect "Bash cat big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt\"}")"

expect "Bash cat small file passes" pass \
  "$(mkinput Bash "{\"command\":\"cat $TDIR/small.txt\"}")"

expect "Bash piped cat big file passes (targeted)" pass \
  "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt | head -20\"}")"

expect "Bash head big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"head $TDIR/big.txt\"}")"

expect "Bash cat with flag passes" pass \
  "$(mkinput Bash "{\"command\":\"cat -n $TDIR/small.txt\"}")"

expect "Bash ls passes (not a blocked verb)" pass \
  "$(mkinput Bash "{\"command\":\"ls -la $TDIR\"}")"

expect "Bash compound command passes" pass \
  "$(mkinput Bash "{\"command\":\"cat $TDIR/small.txt > /dev/null && echo ok\"}")"

expect "Bash bat big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"bat $TDIR/big.txt\"}")"

if [ "$ON_WIN_DRIVE" = 1 ]; then
  expect "Bash cat Windows backslash path is denied" deny \
    "$(mkinput Bash "{\"command\":\"cat ${WSL_BIG//\\/\\\\}\"}")"
fi

expect "Bash tail big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"tail $TDIR/big.txt\"}")"

expect "Bash subagent call passes (top-level agent_id)" pass \
  "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt\"}" '{"agent_id":"ag2"}')"

expect "Bash multi-line compound passes" pass \
  "$(mkinput Bash "$(jq -nc --arg c "cd $TDIR"$'\n'"cat big.txt" '{command:$c}')")"

# Glob args must be checked literally (set -f), like shunt.ts: the glob
# expansion would drag in the 70 KB fat.json, which ts would not even stat.
GLOB_OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Bash '{"command":"cat *.json"}')" | bash "$HOOK" 2>/dev/null)
if [ -z "$GLOB_OUT" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: Bash glob arg checked literally (got: ${GLOB_OUT:0:120})"
fi

# The deny reason is the point of the shunt: it must redirect to delegation.
REASON_OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")" | bash "$HOOK" 2>/dev/null)
if grep -q "BLOCKED by shunt" <<< "$REASON_OUT" && grep -q "bulk-reader" <<< "$REASON_OUT"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: deny reason lacks shunt guidance  [out: ${REASON_OUT:0:140}]"
fi

# --- shunt.jsonl telemetry --------------------------------------------------
# Every denied call appends one JSONL line to .usage/shunt.jsonl (relative to
# cwd, so isolated to $TDIR here — never the repo's real sink).

SINK="$TDIR/.usage/shunt.jsonl"

# Line-threshold deny: reason "lines", lines count, no "command" key (Read).
rm -f "$SINK"
(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")" | bash "$HOOK" >/dev/null 2>&1)
if [ -f "$SINK" ]; then
  LAST=$(tail -n1 "$SINK")
  if jq -e --arg p "$TDIR/big.txt" '
      .harness == "claude" and .tool == "read" and .reason == "lines" and
      .lines == 400 and .path == $p and (has("command") | not)
    ' >/dev/null 2>&1 <<< "$LAST"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl Read/lines record malformed  [line: ${LAST:0:200}]"
  fi
else
  FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl not created after denied Read"
fi

# Byte-threshold deny: reason "bytes".
rm -f "$SINK"
(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/fat.json\"}")" | bash "$HOOK" >/dev/null 2>&1)
LAST=$(tail -n1 "$SINK" 2>/dev/null)
if jq -e '.reason == "bytes"' >/dev/null 2>&1 <<< "$LAST"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl bytes reason missing  [line: ${LAST:0:200}]"
fi

# Bash cat deny: tool "bash" and "command" carries the raw invocation.
rm -f "$SINK"
(cd "$TDIR" && printf '%s' "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt\"}")" | bash "$HOOK" >/dev/null 2>&1)
LAST=$(tail -n1 "$SINK" 2>/dev/null)
if jq -e --arg c "cat $TDIR/big.txt" '.tool == "bash" and (.command // "" | contains($c))' >/dev/null 2>&1 <<< "$LAST"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl bash record missing/incorrect command  [line: ${LAST:0:200}]"
fi

# A passing call (small file) must not append anything.
rm -f "$SINK"
(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" | bash "$HOOK" >/dev/null 2>&1)
if [ -f "$SINK" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl created on a passing Read"
else
  PASS=$((PASS + 1))
fi

# A subagent call (top-level agent_id) must not append, even on a big file.
rm -f "$SINK"
(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}" '{"agent_id":"ag1"}')" | bash "$HOOK" >/dev/null 2>&1)
if [ -f "$SINK" ]; then
  FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl created on a subagent call"
else
  PASS=$((PASS + 1))
fi

# Unwritable sink (best-effort logging): a regular file named ".usage" makes
# `mkdir -p .usage` and the telemetry append both fail (ENOTDIR). The deny
# decision must still be emitted correctly, with no stray error on stderr.
rm -rf "$TDIR/.usage"
: > "$TDIR/.usage"
ERR_OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")" | bash "$HOOK" 2>&1 1>/dev/null)
OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")" | bash "$HOOK" 2>/dev/null)
if [ -z "$ERR_OUT" ] && grep -q "BLOCKED by shunt" <<< "$OUT"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: unwritable .usage sink leaks stderr or breaks deny  [stderr: ${ERR_OUT:0:140}] [out: ${OUT:0:140}]"
fi
rm -f "$TDIR/.usage"

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
