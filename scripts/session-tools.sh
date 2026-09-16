#!/usr/bin/env bash
# Extract a per-tool-call TSV log from Claude Code session transcripts.
#
# Port of opencycling's .usage/session-tools.jq, extended to merge a main
# transcript with its subagent transcripts and emit per-thread summary tables.
#
# Usage: scripts/session-tools.sh <session.jsonl> [--thread <label>] \
#                                  [--cut <YYYY-MM-DDTHH:MM:SSZ>] \
#                                  [--subagents <dir>] [--summary]
#   --cut        keep assistant records strictly before this instant
#                (second precision: both sides truncated to YYYY-MM-DDTHH:MM:SS)
#   --subagents  merge <dir>/agent-*.jsonl; thread label = agentType from the
#                sibling .meta.json, else the file stem
# Exit:  0 on success, 1 on bad usage / missing transcript.
#
# jq runs with -b: native Windows jq otherwise emits CRLF (no-op elsewhere).

set -euo pipefail

TRANSCRIPT=""
THREAD="main"
CUT=""
SUBAGENTS=""
SUMMARY=0

usage() {
  echo "usage: session-tools.sh <session.jsonl> [--thread <label>] [--cut <ISO-8601-Z>] [--subagents <dir>] [--summary]" >&2
}

die_usage() {
  echo "session-tools.sh: $1" >&2
  usage
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --thread|--cut|--subagents)
      [ $# -ge 2 ] || die_usage "$1 requires a value"
      case "$1" in
        --thread)    THREAD="$2";;
        --cut)       CUT="$2";;
        --subagents) SUBAGENTS="$2";;
      esac
      shift 2;;
    --summary)  SUMMARY=1; shift;;
    -h|--help)  usage; exit 0;;
    -*)         die_usage "unknown option '$1'";;
    *)
      [ -z "$TRANSCRIPT" ] || die_usage "unexpected argument '$1'"
      TRANSCRIPT="$1"; shift;;
  esac
done

[ -n "$TRANSCRIPT" ] || die_usage "missing transcript argument"

if [ ! -f "$TRANSCRIPT" ]; then
  echo "session-tools.sh: transcript not found: $TRANSCRIPT" >&2
  exit 1
fi

TMP="$(mktemp /tmp/session-tools.XXXXXX.jsonl)"
trap 'rm -f "$TMP"' EXIT

# Tag every record with its thread label and drop assistant records at/after --cut.
# User records are kept so tool_results of pre-cut calls still resolve.
append_records() {
  local file="$1" label="$2"
  # shellcheck disable=SC2016
  jq -b -c --arg thread "$label" --arg cut "$CUT" '
    select(.type != "assistant" or $cut == "" or ((.timestamp // "")[0:19] < $cut[0:19]))
    | . + {_thread: $thread}' "$file"
}

append_records "$TRANSCRIPT" "$THREAD" >> "$TMP"

if [ -n "$SUBAGENTS" ]; then
  if [ -d "$SUBAGENTS" ]; then
    shopt -s nullglob
    for agent in "$SUBAGENTS"/agent-*.jsonl; do
      label="$(basename "$agent" .jsonl)"
      meta="${agent%.jsonl}.meta.json"
      if [ -f "$meta" ]; then
        mlabel="$(jq -b -r '.agentType // empty' "$meta" 2>/dev/null || true)"
        [ -n "$mlabel" ] && label="$mlabel"
      fi
      append_records "$agent" "$label" >> "$TMP"
    done
    shopt -u nullglob
  else
    echo "session-tools.sh: subagents dir not found, skipped: $SUBAGENTS" >&2
  fi
fi

# Shared definitions: tool calls, tool_result lookup, ERROR/FLAG status.
# shellcheck disable=SC2016
JQ_DEFS='
def txt: if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join(" ")) else tostring end;
def flat: gsub("[\t\n\r]+"; " ");
def failre: "BLOCKED|shunt|error TS|Error:|FAIL|failed|non-zero|[Ee]xit code [1-9]";
def calls: [ .[] | select(.type == "assistant") | . as $r | .message.content? | select(type == "array") | .[]
    | select(.type == "tool_use") | {id, ts: $r.timestamp, thread: $r._thread, name, input} ]
  | unique_by([.thread, .id]);
def results: [ .[] | select(.type == "user") | .message.content? | select(type == "array") | .[]
    | select(.type == "tool_result")
    | {key: .tool_use_id, value: {err: (.is_error // false), text: (.content | txt)}} ] | from_entries;
def outcome($res): ($res[.id] // {err: false, text: ""});
def status($res): outcome($res) as $o
  | if $o.err then "ERROR" elif ($o.text | test(failre)) then "FLAG" else "" end;
'

# shellcheck disable=SC2016
JQ_LOG='
def summ($n; $i):
  if $n == "Bash" or $n == "PowerShell" then ($i.command // "")
  elif $n == "Read" then ($i.file_path // "") + (if ($i.offset != null or $i.limit != null) then " [offset=\($i.offset // "-") limit=\($i.limit // "-")]" else "" end)
  elif $n == "Edit" or $n == "Write" then ($i.file_path // "")
  elif $n == "Grep" then "pattern=\($i.pattern // "") path=\($i.path // "") glob=\($i.glob // "")"
  elif $n == "Glob" then "pattern=\($i.pattern // "") path=\($i.path // "")"
  elif $n == "Agent" then "\($i.subagent_type // "") | \($i.description // "")"
  elif $n == "AskUserQuestion" then ($i.questions | map(.header) | join(", "))
  elif $n == "ToolSearch" then ($i.query // "")
  else ($i | tostring) end;
results as $res
| calls | sort_by(.ts) | .[]
| status($res) as $st
| [ .thread, (.ts // "")[11:19], .name, (summ(.name; .input) | flat | .[0:240]), $st,
    (if $st != "" then (outcome($res).text | flat | .[0:200]) else "" end) ]
| @tsv
'

LOG="$(jq -b -s -r "$JQ_DEFS $JQ_LOG" "$TMP")"

if [ "$SUMMARY" -eq 0 ]; then
  [ -n "$LOG" ] && printf '%s\n' "$LOG"
  exit 0
fi

# shellcheck disable=SC2016
JQ_TOOLCOUNTS='
calls | group_by([.thread, .name]) | .[]
| [.[0].thread, .[0].name, length] | @tsv
'

# One row per thread: call/error/flag counts + token usage summed over assistant records.
# shellcheck disable=SC2016
JQ_TOTALS='
results as $res
| (calls | group_by(.thread)
    | map({key: .[0].thread, value: {calls: length,
        errors: map(select(status($res) == "ERROR")) | length,
        flags: map(select(status($res) == "FLAG")) | length}})
    | from_entries) as $c
| [ .[] | select(.type == "assistant") ] | group_by(._thread)
| map({key: .[0]._thread, value: {
    turns: length,
    input: map(.message.usage.input_tokens // 0) | add,
    output: map(.message.usage.output_tokens // 0) | add,
    cwrite: map(.message.usage.cache_creation_input_tokens // 0) | add,
    cread: map(.message.usage.cache_read_input_tokens // 0) | add}})
| from_entries as $u
| ($u | keys) | .[]
| . as $t
| ($c[$t] // {calls: 0, errors: 0, flags: 0}) as $ct
| $u[$t] as $ut
| [$t, $ct.calls, $ct.errors, $ct.flags, $ut.turns, $ut.input, $ut.output, $ut.cwrite, $ut.cread,
   ($ut.input + $ut.output + $ut.cwrite + $ut.cread)]
| @tsv
'

TOOLCOUNTS="$(jq -b -s -r "$JQ_DEFS $JQ_TOOLCOUNTS" "$TMP")"
TOTALS="$(jq -b -s -r "$JQ_DEFS $JQ_TOTALS" "$TMP")"

if [ -n "$LOG" ]; then
  printf '%s\n' "$LOG"
  [ -n "$TOOLCOUNTS$TOTALS" ] && printf '\n'
fi

if [ -n "$TOOLCOUNTS" ]; then
  printf '%s\t%s\t%s\n' thread tool count
  printf '%s\n' "$TOOLCOUNTS"
fi

if [ -n "$TOTALS" ]; then
  [ -n "$TOOLCOUNTS" ] && printf '\n'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' thread calls errors flags assistant_turns input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens billed_volume
  printf '%s\n' "$TOTALS"
fi
