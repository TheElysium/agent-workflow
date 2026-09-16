#!/usr/bin/env bash
# Shunt PreToolUse hook for Claude Code — port of the opencode shunt.ts plugin.
#
# Blocks non-targeted reads of large files by the primary model and redirects
# to delegation (bulk-reader / code-writer subagents). Subagent tool calls are
# never blocked: Claude Code marks them with a top-level agent_id field.
#
# Input : full PreToolUse hook JSON on stdin (hook_event_name, tool_name,
#         tool_input, and agent_id for subagent calls).
# Output: on deny, one JSON object:
#         {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#          "permissionDecision":"deny","permissionDecisionReason":"..."}}
#         On pass: exit 0 with no output (normal permission flow continues).
#
# Env:   SHUNT_MIN_LINES  line threshold   (default 350)
#        SHUNT_MAX_BYTES  byte threshold    (default 65536)
#
# Note: relative paths resolve against the hook process's cwd, which Claude
# Code sets to the project directory (same behavior as shunt.ts).

set -u

input=$(cat)

# --- thresholds -----------------------------------------------------------

min_lines() {
  local v="${SHUNT_MIN_LINES:-350}"
  case "$v" in ''|*[!0-9]*) echo 350; return;; esac
  [ "$v" -gt 0 ] 2>/dev/null && { printf '%s\n' "$v"; return; }
  printf '%s\n' 350
}

max_bytes() {
  local v="${SHUNT_MAX_BYTES:-65536}"
  case "$v" in ''|*[!0-9]*) printf '%s\n' 65536; return;; esac
  [ "$v" -gt 0 ] 2>/dev/null && { printf '%s\n' "$v"; return; }
  printf '%s\n' 65536
}

# Hoisted once: every Read/Bash call pays for these, keep it cheap.
MIN_LINES=$(min_lines)
MAX_BYTES=$(max_bytes)

# Structured fields (+ the human-readable redirect message) for the last
# check_file() block decision, consumed by log_shunt_block()/deny() at the
# call sites. Populated via globals, not a captured return value: capturing
# check_file's stdout with `$(...)` would fork a subshell and any globals it
# sets there would not survive back to the caller. Initialized so `set -u`
# never trips even though check_file() only assigns them on the deny path.
LAST_REASON=""
LAST_BYTES=""
LAST_LINES=""
LAST_MSG=""

# --- path handling --------------------------------------------------------
# The Read tool sends absolute Windows paths with backslashes. Convert for
# the POSIX tools. cygpath exists under Git Bash (Windows); the WSL fallback
# maps C:\foo -> /mnt/c/foo.

unixpath() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$p" 2>/dev/null || printf '%s\n' "$p"
  else
    p=${p//\\//}
    case "$p" in
      [A-Za-z]:*) local drive="${p%%:*}"; printf '/mnt/%s%s\n' "${drive,,}" "${p#?:}";;
      *) printf '%s\n' "$p";;
    esac
  fi
}

# --- size / line checks ---------------------------------------------------

byte_size() { stat -c %s -- "$1" 2>/dev/null || printf '0\n'; }

line_count() { wc -l < "$1" 2>/dev/null || printf '0\n'; }

redirect_reason() { # $1 = path, $2 = why string
  cat <<EOF
BLOCKED by shunt: "$1" has $2.
Do NOT read this file directly — delegate I/O instead:
  - For analysis/questions across files (incl. minified JSON): use the task tool with subagent "bulk-reader" (pass file paths + your question; you only consume the summary).
  - For boilerplate generation: use the task tool with subagent "code-writer" (pass spec + reference file + target path).
  - If you must edit a specific section of this file, do a targeted read with offset/limit — that is allowed.
EOF
}

deny() { # $1 = reason text
  jq -rn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Telemetry sink, mirrors .opencode/plugins/shunt.ts's logShuntBlock: one
# JSONL line per denied call, written BEFORE the deny JSON. Best-effort only
# — a logging failure must never suppress the deny decision.
log_shunt_block() { # log_shunt_block <tool: read|bash> <path> [command]
  local tool="$1" p="$2" cmd="${3-}" line
  if [ "$tool" = "bash" ]; then
    line=$(jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg session "$SESSION" \
      --arg tool "$tool" \
      --arg path "$p" \
      --arg reason "$LAST_REASON" \
      --argjson bytes "$LAST_BYTES" \
      --argjson lines "${LAST_LINES:-null}" \
      --argjson threshold_bytes "$MAX_BYTES" \
      --argjson threshold_lines "$MIN_LINES" \
      --arg command "$cmd" \
      '{ts:$ts,harness:"claude",session:$session,tool:$tool,path:$path,reason:$reason,
        bytes:$bytes,lines:$lines,threshold_bytes:$threshold_bytes,
        threshold_lines:$threshold_lines,command:$command}' 2>/dev/null)
  else
    line=$(jq -cn \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg session "$SESSION" \
      --arg tool "$tool" \
      --arg path "$p" \
      --arg reason "$LAST_REASON" \
      --argjson bytes "$LAST_BYTES" \
      --argjson lines "${LAST_LINES:-null}" \
      --argjson threshold_bytes "$MAX_BYTES" \
      --argjson threshold_lines "$MIN_LINES" \
      '{ts:$ts,harness:"claude",session:$session,tool:$tool,path:$path,reason:$reason,
        bytes:$bytes,lines:$lines,threshold_bytes:$threshold_bytes,
        threshold_lines:$threshold_lines}' 2>/dev/null)
  fi
  [ -n "$line" ] || return 0
  mkdir -p .usage 2>/dev/null || true
  { printf '%s\n' "$line" >> .usage/shunt.jsonl; } 2>/dev/null || true
}

# Oversized check shared by the Read and Bash paths. Prints the redirect
# reason and returns 1 when oversized; returns 0 otherwise.
check_file() { # check_file <path>
  local p up bytes lines
  p=$1
  up=$(unixpath "$p")
  bytes=$(byte_size "$up")
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    LAST_REASON=bytes; LAST_BYTES=$bytes; LAST_LINES=""
    LAST_MSG=$(redirect_reason "$p" "$((bytes / 1024)) KB (threshold: $(( MAX_BYTES / 1024 )) KB)")
    return 1
  fi
  [ "$bytes" -eq 0 ] && return 0
  lines=$(line_count "$up")
  if [ "$lines" -gt "$MIN_LINES" ]; then
    LAST_REASON=lines; LAST_BYTES=$bytes; LAST_LINES=$lines
    LAST_MSG=$(redirect_reason "$p" "$lines lines (threshold: $MIN_LINES)")
    return 1
  fi
  return 0
}

# --- main -----------------------------------------------------------------

# One jq extraction for the routing fields (kept to 2 jq spawns per call).
# NUL-delimited + mapfile: tab/TSV variants break on empty fields (read
# collapses IFS-whitespace runs) and NUL never appears in JSON string content.
mapfile -t -d '' F < <(
  printf '%s' "$input" | jq -j '[.agent_id // "", .tool_name // "", .tool_input.file_path // "", (.tool_input.offset // ""), (.session_id // "")] | join("\u0000")' 2>/dev/null
)
agent=${F[0]-}; tool=${F[1]-}; file=${F[2]-}; offset=${F[3]-}; SESSION=${F[4]-}

# Subagent calls are the workers: their reads always pass.
[ -n "$agent" ] && exit 0

case "$tool" in
  Read)
    [ -n "$file" ] || exit 0
    # limit alone can equal the default full-read size — only a real offset is targeted.
    [ -n "$offset" ] && [ "$offset" != "null" ] && exit 0
    if ! check_file "$file"; then
      log_shunt_block read "$file"
      deny "$LAST_MSG"
    fi
    exit 0
    ;;

  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    [ -n "$cmd" ] || exit 0
    # pipes, redirections, compound commands and multi-line scripts are targeted
    if printf '%s' "$cmd" | grep -q '[|>;$&`]'; then
      exit 0
    fi
    case "$cmd" in *$'\n'*) exit 0;; esac
    printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cat|head|tail|less|more|bat|grep|sed|awk|rg|xxd|base64|strings)([[:space:]]|$)' || exit 0
    read -r _ args <<<"$cmd"           # drop the verb, keep file args (handles leading spaces)
    set -f                             # no globbing: expand nothing, check the literal arg like shunt.ts
    for f in $args; do                 # intentional word splitting
      case "$f" in -*) continue;; esac
      if ! check_file "$f"; then
        log_shunt_block bash "$f" "$cmd"
        deny "$LAST_MSG"
      fi
    done
    exit 0
    ;;
esac

exit 0
