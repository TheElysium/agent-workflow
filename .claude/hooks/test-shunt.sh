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

# a second small file, for multi-file bash allow-record ordering checks
{ for i in $(seq 1 5); do echo "other $i"; done; } > "$TDIR/small2.txt"

# zero-byte file (bytes 0 / lines null edge case)
: > "$TDIR/empty.txt"

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

expect "Read big file with offset alone is now denied" deny \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"offset\":10}")"

expect "Read big file with offset and limit is targeted" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"offset\":10,\"limit\":20}")"

expect "Read big file with offset=0 and limit is targeted" pass \
  "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"offset\":0,\"limit\":20}")"

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

expect "Bash grep big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"grep foo $TDIR/big.txt\"}")"

expect "Bash sed big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"sed p $TDIR/big.txt\"}")"

expect "Bash awk big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"awk $TDIR/big.txt\"}")"

expect "Bash rg big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"rg foo $TDIR/big.txt\"}")"

expect "Bash xxd big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"xxd $TDIR/big.txt\"}")"

expect "Bash base64 big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"base64 $TDIR/big.txt\"}")"

expect "Bash strings big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"strings $TDIR/big.txt\"}")"

# Bounded single-command reads skip the size check entirely.
expect "Bash sed -n 244,260p big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"sed -n 244,260p $TDIR/big.txt\"}")"

expect "Bash sed -n quoted 244,260p big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"sed -n '244,260p' $TDIR/big.txt\"}")"

expect "Bash head -n 20 big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"head -n 20 $TDIR/big.txt\"}")"

expect "Bash head -c 500 big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"head -c 500 $TDIR/big.txt\"}")"

expect "Bash tail -n 20 big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"tail -n 20 $TDIR/big.txt\"}")"

expect "Bash head -n 200 fat single-line file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"head -n 200 $TDIR/fat.json\"}")"

# Tricky commands are built with jq to avoid nested quote/escape hell in shell.
SED_UNBOUNDED=$(jq -nc --arg cmd "sed -n '100,\$p' $TDIR/big.txt" '{command:$cmd}')
TAIL_PLUS=$(jq -nc --arg cmd "tail -n +100 $TDIR/big.txt" '{command:$cmd}')
SED_NO_N=$(jq -nc --arg cmd "sed '244,260p' $TDIR/big.txt" '{command:$cmd}')
SED_COMPOUND=$(jq -nc --arg cmd "sed -n '100,\$p' $TDIR/big.txt; echo ok" '{command:$cmd}')
PY_READ=$(jq -nc --arg cmd "python3 -c 'print(open(\"x\").read())' $TDIR/big.txt" '{command:$cmd}')
SED_MISMATCH=$(jq -nc --arg cmd "sed -n '\"244,260p' $TDIR/big.txt" '{command:$cmd}')
HEAD_N_PLUS=$(jq -nc --arg cmd "head -n +20 $TDIR/big.txt" '{command:$cmd}')
TAIL_C_PLUS=$(jq -nc --arg cmd "tail -c +100 $TDIR/big.txt" '{command:$cmd}')
SED_SPACE_RANGE=$(jq -nc --arg cmd "sed -n '244, 260p' $TDIR/big.txt" '{command:$cmd}')
SED_NE_SCRIPT=$(jq -nc --arg cmd "sed -ne '100p' $TDIR/big.txt" '{command:$cmd}')

# shellcheck disable=SC2016
expect 'Bash sed -n 100,$p big file is denied' deny \
  "$(mkinput Bash "$SED_UNBOUNDED")"

expect "Bash tail -n +100 big file is denied" deny \
  "$(mkinput Bash "$TAIL_PLUS")"

expect "Bash sed without -n big file is denied" deny \
  "$(mkinput Bash "$SED_NO_N")"

# Compound-command / whitelist contract: pass untouched, never parsed.
expect "Bash cat big file && echo ok is compound" pass \
  "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt && echo ok\"}")"

# shellcheck disable=SC2016
expect 'Bash sed -n 100,$p; echo ok is compound (accepted gap)' pass \
  "$(mkinput Bash "$SED_COMPOUND")"

expect "Bash python3 read of big file passes (uncovered verb)" pass \
  "$(mkinput Bash "$PY_READ")"

# Edge-case pins for bounded-read detectors.
expect 'Bash sed -n mismatched quotes 244,260p big file is denied' deny \
  "$(mkinput Bash "$SED_MISMATCH")"

expect "Bash head -n +20 big file is denied" deny \
  "$(mkinput Bash "$HEAD_N_PLUS")"

expect "Bash tail -c +100 big file is denied" deny \
  "$(mkinput Bash "$TAIL_C_PLUS")"

expect "Bash sed -n '244, 260p' big file is denied" deny \
  "$(mkinput Bash "$SED_SPACE_RANGE")"

expect "Bash head -n0 big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"head -n0 $TDIR/big.txt\"}")"

expect "Bash head -n 0 big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"head -n 0 $TDIR/big.txt\"}")"

expect "Bash sed -n 1p big file is targeted" pass \
  "$(mkinput Bash "{\"command\":\"sed -n 1p $TDIR/big.txt\"}")"

expect "Bash sed -ne '100p' big file is denied (script not window)" deny \
  "$(mkinput Bash "$SED_NE_SCRIPT")"

# Multi-line commands and verb-boundary checks pass untouched.
expect "Bash multi-line cat big file && echo ok passes" pass \
  "$(mkinput Bash "$(jq -nc --arg c "cat $TDIR/big.txt"$'\n'"echo ok" '{command:$c}')")"

expect "Bash head-file big file passes (verb boundary)" pass \
  "$(mkinput Bash "{\"command\":\"head-file $TDIR/big.txt\"}")"

expect "Bash grep small file passes" pass \
  "$(mkinput Bash "{\"command\":\"grep line $TDIR/small.txt\"}")"

expect "Bash sed small file passes" pass \
  "$(mkinput Bash "{\"command\":\"sed p $TDIR/small.txt\"}")"

expect "Bash grep with flag big file is denied" deny \
  "$(mkinput Bash "{\"command\":\"grep -c foo $TDIR/big.txt\"}")"

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
# Every Read/Bash decision (allow AND deny) appends one JSONL line to
# .usage/shunt.jsonl (relative to cwd, so isolated to $TDIR here — never the
# repo's real sink).

SINK="$TDIR/.usage/shunt.jsonl"

sink_run() { # sink_run <input-json>: clears the sink, runs the hook once.
  rm -f "$SINK"
  (cd "$TDIR" && printf '%s' "$1" | bash "$HOOK" >/dev/null 2>&1)
}

sink_last() { [ -f "$SINK" ] && tail -n1 "$SINK" || printf '%s' ''; }
sink_count() { [ -f "$SINK" ] && wc -l < "$SINK" || printf '0'; }

assert_jq() { # assert_jq <desc> <json> <jq-filter> [jq-arg-flags...]
  local desc="$1" json="$2" filter="$3"; shift 3
  if [ -n "$json" ] && jq -e "$@" "$filter" >/dev/null 2>&1 <<< "$json"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $desc  [line: ${json:0:220}]"
  fi
}

# --- Read: deny records now carry decision:"deny" ---------------------------

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")"
# shellcheck disable=SC2016
assert_jq "shunt.jsonl Read/lines deny record" "$(sink_last)" \
  '.harness == "claude" and .tool == "read" and .decision == "deny" and
   .reason == "lines" and .lines == 400 and .path == $p and
   (has("command") | not) and has("offset") and has("limit") and
   .offset == null and .limit == null' --arg p "$TDIR/big.txt"

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/fat.json\"}")"
assert_jq "shunt.jsonl Read/bytes deny record" "$(sink_last)" \
  '.decision == "deny" and .reason == "bytes" and .lines == null'

# --- Bash: deny record carries decision:"deny" + exact command --------------

sink_run "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt\"}")"
# shellcheck disable=SC2016
assert_jq "shunt.jsonl Bash cat deny record" "$(sink_last)" \
  '.tool == "bash" and .decision == "deny" and .command == $c and
   .path == $p and (has("offset") | not) and (has("limit") | not)' \
  --arg c "cat $TDIR/big.txt" --arg p "$TDIR/big.txt"

# --- allow reasons: Read ------------------------------------------------

sink_run "$(mkinput Read "{}")"
assert_jq "Read no_input (no file_path)" "$(sink_last)" \
  '.tool == "read" and .decision == "allow" and .reason == "no_input" and
   .path == null and has("offset") and has("limit") and (has("command") | not)'

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"offset\":10,\"limit\":20}")"
# shellcheck disable=SC2016
assert_jq "Read targeted (offset+limit)" "$(sink_last)" \
  '.decision == "allow" and .reason == "targeted" and .bytes == null and
   .lines == null and .offset == 10 and .limit == 20 and .path == $p' \
  --arg p "$TDIR/big.txt"

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\",\"offset\":0,\"limit\":20}")"
assert_jq "Read targeted offset=0 keeps number type" "$(sink_last)" \
  '.offset == 0 and (.offset | type) == "number" and .limit == 20'

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")"
assert_jq "Read under_threshold" "$(sink_last)" \
  '.decision == "allow" and .reason == "under_threshold" and .bytes > 0 and
   .lines == 10 and .offset == null and .limit == null'

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/empty.txt\"}")"
assert_jq "Read zero-byte file: bytes 0, lines null, under_threshold" "$(sink_last)" \
  '.decision == "allow" and .reason == "under_threshold" and .bytes == 0 and .lines == null'

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/does-not-exist.txt\"}")"
# shellcheck disable=SC2016
assert_jq "Read missing (stat fails)" "$(sink_last)" \
  '.decision == "allow" and .reason == "missing" and .bytes == null and
   .lines == null and .path == $p' --arg p "$TDIR/does-not-exist.txt"

sink_run "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}" '{"agent_id":"ag1"}')"
# shellcheck disable=SC2016
assert_jq "Read subagent keeps the real path (per-file decision)" "$(sink_last)" \
  '.tool == "read" and .decision == "allow" and .reason == "subagent" and
   .path == $p' --arg p "$TDIR/big.txt"

# --- allow reasons: Bash -------------------------------------------------

sink_run "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt\"}" '{"agent_id":"ag2"}')"
# shellcheck disable=SC2016
assert_jq "Bash subagent: whole-command decision, path null" "$(sink_last)" \
  '.tool == "bash" and .decision == "allow" and .reason == "subagent" and
   .path == null and .command == $c' --arg c "cat $TDIR/big.txt"

sink_run "$(mkinput Bash '{"command":""}')"
assert_jq "Bash no_input: empty command" "$(sink_last)" \
  '.decision == "allow" and .reason == "no_input" and .path == null and .command == ""'

sink_run "$(mkinput Bash "{\"command\":\"cat -n\"}")"
assert_jq "Bash no_input: whitelisted verb, zero non-flag args" "$(sink_last)" \
  '.decision == "allow" and .reason == "no_input" and .path == null and .command == "cat -n"'

sink_run "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt && echo ok\"}")"
assert_jq "Bash compound" "$(sink_last)" \
  '.decision == "allow" and .reason == "compound" and .path == null'

sink_run "$(mkinput Bash "{\"command\":\"ls -la $TDIR\"}")"
assert_jq "Bash verb not whitelisted" "$(sink_last)" \
  '.decision == "allow" and .reason == "verb" and .path == null'

sink_run "$(mkinput Bash "{\"command\":\"sed -n 244,260p $TDIR/big.txt\"}")"
assert_jq "Bash bounded sed" "$(sink_last)" \
  '.decision == "allow" and .reason == "bounded" and .path == null'

# Multi-file bash: one allow record per non-flag arg, in order.
sink_run "$(mkinput Bash "{\"command\":\"cat $TDIR/small.txt $TDIR/small2.txt\"}")"
N=$(sink_count)
if [ "$N" = 2 ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "FAIL: multi-file allow should log 2 records, got $N"
fi
# shellcheck disable=SC2016
assert_jq "multi-file allow: first record" "$(sed -n '1p' "$SINK" 2>/dev/null)" \
  '.decision == "allow" and .reason == "under_threshold" and .path == $p' --arg p "$TDIR/small.txt"
# shellcheck disable=SC2016
assert_jq "multi-file allow: second record" "$(sink_last)" \
  '.decision == "allow" and .reason == "under_threshold" and .path == $p' --arg p "$TDIR/small2.txt"

# Multi-file bash: allow-then-deny stops at the first oversized file (the
# grep pattern arg "foo" is itself a "missing" allow record — expected).
sink_run "$(mkinput Bash "{\"command\":\"grep foo $TDIR/big.txt\"}")"
N=$(sink_count)
if [ "$N" = 2 ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "FAIL: grep foo big.txt should log 2 records (allow, deny), got $N"
fi
assert_jq "allow-then-deny: pattern arg is allow/missing" "$(sed -n '1p' "$SINK" 2>/dev/null)" \
  '.decision == "allow" and .reason == "missing" and .path == "foo" and .tool == "bash"'
assert_jq "allow-then-deny: file arg is the deny record" "$(sink_last)" \
  '.decision == "deny" and .reason == "lines" and .tool == "bash"'

# --- no CR bytes ever reach the sink (native Windows jq text-mode risk) -----

rm -f "$SINK"
(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" | bash "$HOOK" >/dev/null 2>&1)
(cd "$TDIR" && printf '%s' "$(mkinput Bash "{\"command\":\"cat $TDIR/big.txt\"}")" | bash "$HOOK" >/dev/null 2>&1)
if [ -f "$SINK" ]; then
  content=$(cat "$SINK")
  case "$content" in
    *$'\r'*) FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl contains CR bytes" ;;
    *) PASS=$((PASS + 1)) ;;
  esac
else
  FAIL=$((FAIL + 1)); echo "FAIL: shunt.jsonl missing for CR check"
fi

# Unwritable sink (best-effort logging): a regular file named ".usage" makes
# `mkdir -p .usage` and the telemetry append both fail (ENOTDIR). Neither the
# deny decision nor the (silent) allow decision may be affected.
rm -rf "$TDIR/.usage"
: > "$TDIR/.usage"
ERR_OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")" | bash "$HOOK" 2>&1 1>/dev/null)
OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/big.txt\"}")" | bash "$HOOK" 2>/dev/null)
if [ -z "$ERR_OUT" ] && grep -q "BLOCKED by shunt" <<< "$OUT"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: unwritable .usage sink leaks stderr or breaks deny  [stderr: ${ERR_OUT:0:140}] [out: ${OUT:0:140}]"
fi

ALLOW_ERR=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" | bash "$HOOK" 2>&1 1>/dev/null)
ALLOW_OUT=$(cd "$TDIR" && printf '%s' "$(mkinput Read "{\"file_path\":\"$TDIR/small.txt\"}")" | bash "$HOOK" 2>/dev/null)
if [ -z "$ALLOW_ERR" ] && [ -z "$ALLOW_OUT" ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1)); echo "FAIL: unwritable .usage sink breaks allow decision/output  [stderr: ${ALLOW_ERR:0:140}] [out: ${ALLOW_OUT:0:140}]"
fi
rm -f "$TDIR/.usage"

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
