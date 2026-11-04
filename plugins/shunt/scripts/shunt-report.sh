#!/usr/bin/env bash
set -euo pipefail
export MSYS2_ARG_CONV_EXCL='*'

FILE=".usage/shunt.jsonl"
SINCE=""
SESSION=""

while [ $# -gt 0 ]; do
  case "$1" in
    --file|--since|--session)
      [ $# -ge 2 ] || { echo "shunt-report.sh: $1 requires a value" >&2; exit 1; }
      case "$1" in
        --file) FILE="$2";;
        --since) SINCE="$2";;
        --session) SESSION="$2";;
      esac
      shift 2;;
    *) echo "shunt-report.sh: unknown arg '$1'" >&2; exit 1;;
  esac
done

[ -f "$FILE" ] || { echo "shunt-report.sh: no sink: $FILE" >&2; exit 1; }

parse_err=$(jq -b . <"$FILE" 2>&1 >/dev/null || true)
if [ -n "$parse_err" ]; then
  echo "shunt-report.sh: invalid json in $FILE: $parse_err" >&2
  exit 5
fi

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
' <"$FILE"
