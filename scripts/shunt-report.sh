#!/usr/bin/env bash
# Aggregate the shunt-decision JSONL sink written by the adapters
# (.opencode/plugins/shunt.ts and .claude/hooks/shunt.sh).
#
# One record per Read/Bash shunt decision (allow AND deny), fields:
#   ts, harness (claude|opencode), session, tool (read|bash),
#   decision (allow|deny — legacy records with no "decision" key count as
#   deny), reason (deny: bytes|lines; allow: subagent|no_input|targeted|
#   compound|verb|bounded|under_threshold|missing), path (string or null),
#   command (bash records only), offset/limit (read records only),
#   bytes/lines, threshold_bytes, threshold_lines.
# A multi-file bash command produces one record per file arg, sharing the
# same ts/session/command.
#
# shunt.jsonl events are one-shot (no repeated/streaming records for the
# same event) — every line is a distinct decision record, so unlike
# usage-report.sh there is no dedup step for the raw counts. The "top
# allowed commands" section is the one exception: it collapses records that
# share ts+session+command (i.e. the file args of one multi-file call) back
# into a single call before counting.
#
# Usage: scripts/shunt-report.sh [--file .usage/shunt.jsonl]
#                                [--since <ts>] [--session <id>]
# Exit:  0 on success, 1 on bad usage / missing sink.
#
# jq runs with -b: native Windows jq otherwise emits CRLF (no-op elsewhere).

set -euo pipefail

FILE=".usage/shunt.jsonl"
SINCE=""
SESSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file) FILE="$2"; shift 2;;
    --since) SINCE="$2"; shift 2;;
    --session) SESSION="$2"; shift 2;;
    *) echo "shunt-report.sh: unknown arg '$1'" >&2; exit 1;;
  esac
done

[ -f "$FILE" ] || {
  echo "shunt-report.sh: no sink: $FILE (telemetry off via SHUNT_TELEMETRY?)" >&2
  exit 1
}

# jq -s aborts on the first unparsable line, which used to cost the whole
# report for one spliced record. Keep only well-formed objects and count what
# was dropped, so data loss stays visible instead of becoming silent.
CLEAN="$(mktemp)"
trap 'rm -f "$CLEAN"' EXIT
# awk, not wc -l: wc counts newlines, so a sink whose last append was cut short
# before its newline is undercounted while jq -R still reads that line, which
# made "skipped" go negative.
TOTAL="$(awk 'END{print NR}' "$FILE")"
jq -b -R -c 'fromjson? | select(type == "object")' "$FILE" > "$CLEAN" 2>/dev/null || true
KEPT="$(awk 'END{print NR}' "$CLEAN")"

jq -b -s -r --arg since "$SINCE" --arg sess "$SESSION" '
  def breakdown(f): group_by(f) | map("  \(.[0]|f): \(length)") | .[];
  map(select(.ts > $since and ($sess == "" or .session == $sess)))
  | map(. + {decision: (.decision // "deny")}) as $recs
  | ($recs | map(select(.decision == "allow"))) as $allow
  | ($recs | map(select(.decision == "deny"))) as $deny
  | "records: \($recs | length)",
    "allowed: \($allow | length)",
    "blocked: \($deny | length)",
    "by decision/reason:",
    ($recs | breakdown(.decision + "/" + .reason)),
    "by harness:",
    ($recs | breakdown(.harness)),
    "by tool:",
    ($recs | breakdown(.tool)),
    "top blocked files:",
    ($deny
      | map(select(.path != null))
      | group_by(.path)
      | map({path: .[0].path, count: length})
      | sort_by(-.count)
      | .[0:10]
      | map("  \(.count)x  \(.path)")
      | .[]),
    "top allowed commands:",
    ($allow
      | map(select(.command != null))
      | group_by([.ts, .session, .command])
      | map(.[0])
      | group_by(.command)
      | map({command: .[0].command, count: length})
      | sort_by(-.count)
      | .[0:10]
      | map("  \(.count)x  \(.command | gsub("\n"; "\\n"))")
      | .[])
' "$CLEAN"

# Printed unconditionally, including "skipped: 0": a counter that only shows up
# on failure would turn a loud abort into silent data loss.
echo "skipped: $((TOTAL - KEPT))"
