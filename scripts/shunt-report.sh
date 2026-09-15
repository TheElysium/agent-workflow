#!/usr/bin/env bash
# Aggregate the shunt-denial JSONL sink written by the adapters
# (.opencode/plugins/shunt.ts and .claude/hooks/shunt.sh).
#
# shunt.jsonl events are one-shot (no repeated/streaming records for the
# same event) — every line is a distinct blocked-call record, so unlike
# usage-report.sh there is no dedup step.
#
# Usage: scripts/shunt-report.sh [--file .usage/shunt.jsonl]
#                                [--since <ts>] [--session <id>]
# Exit:  0 on success, 1 on bad usage / missing sink.

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

[ -f "$FILE" ] || { echo "shunt-report.sh: no sink: $FILE" >&2; exit 1; }

jq -s -r --arg since "$SINCE" --arg sess "$SESSION" '
  def breakdown(f): group_by(f) | map("  \(.[0]|f): \(length)") | .[];
  map(select(.ts > $since and ($sess == "" or .session == $sess))) as $recs
  | "blocked: \($recs | length)",
    "by harness:",
    ($recs | breakdown(.harness)),
    "by tool:",
    ($recs | breakdown(.tool)),
    "by reason:",
    ($recs | breakdown(.reason)),
    "top blocked files:",
    ($recs
      | group_by(.path)
      | map({path: .[0].path, count: length})
      | sort_by(-.count)
      | .[0:10]
      | map("  \(.count)x  \(.path)")
      | .[])
' "$FILE"
