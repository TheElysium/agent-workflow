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

line_count() { wc -l < "$1" 2>/dev/null || printf '0\n'; }

redirect_reason() { # $1 = path, $2 = why string
  cat <<EOF
BLOCKED by shunt: "$1" has $2.
Do NOT read this file directly — delegate I/O instead:
  - For analysis/questions across files (incl. minified JSON): use the task tool with subagent "bulk-reader" (pass file paths + your question; you only consume the summary).
  - For boilerplate generation: use the task tool with subagent "code-writer" (pass spec + reference file + target path).
  - If you must edit a specific section of this file, do a targeted read with BOTH offset and limit (an offset alone reads the unbounded rest of the file) — that is allowed.
EOF
}

deny() { # $1 = reason text
  jq -rn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

# Telemetry sink, mirrors .opencode/plugins/shunt.ts's logShuntBlock: one
# JSONL line per Read/Bash decision (allow AND deny), written BEFORE any deny
# JSON. Best-effort only — a logging failure must never change the decision,
# stdout, or exit code.
#
# jq on this host may be the native Windows build, which text-mode-translates
# \n to \r\n on stdout unless run with -b; since $(...) only strips the
# trailing \n, an untranslated line would leave a stray \r in the sink.
#
# offset/limit (Read) and command (Bash) are pulled straight from the raw
# hook input on stdin so they keep their exact JSON type/value — no
# re-quoting through shell args. The two fields are mutually exclusive by
# design (Read records never carry command; Bash records never carry
# offset/limit).
log_event() { # log_event <tool:read|bash> <decision:allow|deny> <reason> <path|""> <bytes|""> <lines|"">
  local tool="$1" decision="$2" reason="$3" p="$4" bytes="$5" lines="$6" line
  line=$(printf '%s' "$input" | jq -b -c \
    --arg tool "$tool" \
    --arg decision "$decision" \
    --arg reason "$reason" \
    --arg path "$p" \
    --argjson bytes "${bytes:-null}" \
    --argjson lines "${lines:-null}" \
    --argjson threshold_bytes "$MAX_BYTES" \
    --argjson threshold_lines "$MIN_LINES" \
    '{
      ts: (now | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")),
      harness: "claude",
      session: (.session_id // null),
      tool: $tool,
      decision: $decision,
      reason: $reason,
      path: (if $path == "" then null else $path end),
      bytes: $bytes,
      lines: $lines,
      threshold_bytes: $threshold_bytes,
      threshold_lines: $threshold_lines
    } + (
      if $tool == "bash"
      then {command: (.tool_input.command // "")}
      else {offset: (.tool_input.offset // null), limit: (.tool_input.limit // null)}
      end
    )' 2>/dev/null)
  [ -n "$line" ] || return 0
  mkdir -p .usage 2>/dev/null || true
  { printf '%s\n' "$line" >> .usage/shunt.jsonl; } 2>/dev/null || true
}

# Oversized check shared by the Read and Bash paths. Always sets LAST_REASON/
# LAST_BYTES/LAST_LINES (consumed by log_event at the call sites); LAST_MSG is
# only set — and only meaningful — on the deny path (return 1).
check_file() { # check_file <path>
  local p up bytes lines stat_out
  p=$1
  up=$(unixpath "$p")
  if ! stat_out=$(stat -c %s -- "$up" 2>/dev/null); then
    LAST_REASON=missing; LAST_BYTES=""; LAST_LINES=""
    return 0
  fi
  bytes=$stat_out
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    LAST_REASON=bytes; LAST_BYTES=$bytes; LAST_LINES=""
    LAST_MSG=$(redirect_reason "$p" "$((bytes / 1024)) KB (threshold: $(( MAX_BYTES / 1024 )) KB)")
    return 1
  fi
  if [ "$bytes" -eq 0 ]; then
    LAST_REASON=under_threshold; LAST_BYTES=0; LAST_LINES=""
    return 0
  fi
  lines=$(line_count "$up")
  if [ "$lines" -gt "$MIN_LINES" ]; then
    LAST_REASON=lines; LAST_BYTES=$bytes; LAST_LINES=$lines
    LAST_MSG=$(redirect_reason "$p" "$lines lines (threshold: $MIN_LINES)")
    return 1
  fi
  LAST_REASON=under_threshold; LAST_BYTES=$bytes; LAST_LINES=$lines
  return 0
}

# --- bounded-read detectors (Bash path) -----------------------------------

# Strip one layer of surrounding single or double quotes from an argument.
# `sed -n '244,260p' file` reaches us as args `-n '244,260p' file`; word
# splitting already removed the quotes, but this is defensive.
# Only strip a matched pair (same opening and closing quote) to match shunt.ts.
strip_quotes() {
  local a="$1"
  if [ "${#a}" -ge 2 ]; then
    case "$a" in
      '"'*) [ "${a: -1}" = '"' ] && a="${a#\"}"; a="${a%\"}" ;;
      "'"*) [ "${a: -1}" = "'" ] && a="${a#\'}"; a="${a%\'}" ;;
    esac
  fi
  printf '%s\n' "$a"
}

# sed is bounded only when:
#   - it has -n (or --quiet/--silent), AND
#   - one non-flag arg matches ^[0-9]+(,[0-9]+)?p$.
# It is explicitly unbounded (fall through to size check) when:
#   - no -n is present (whole file is printed), OR
#   - any script arg contains '$' (e.g. '100,$p' reads to EOF).
is_bounded_sed() {
  local args_in="$1" has_n=0 arg stripped
  # shellcheck disable=SC2086
  for arg in $args_in; do
    case "$arg" in
      -n|--quiet|--silent) has_n=1 ;;
    esac
    stripped=$(strip_quotes "$arg")
    case "$stripped" in
      *'$'*) return 1 ;;
    esac
  done
  [ "$has_n" -eq 1 ] || return 1
  # shellcheck disable=SC2086
  for arg in $args_in; do
    stripped=$(strip_quotes "$arg")
    [[ "$stripped" =~ ^[0-9]+(,[0-9]+)?p$ ]] && return 0
  done
  return 1
}

# head/tail are bounded only with an explicit numeric bound:
#   -n N / -c N (N numeric, no '+' prefix), or -nN / -cN.
# Plain `head file`/`tail file` (implicit 10 lines) and legacy `-N` (e.g.
# `head -20`) are intentionally denied. `tail -n +100` (start-at-N to EOF)
# is unbounded and denied.
is_bounded_head_tail() {
  local args_in="$1" arg next=0 val
  # shellcheck disable=SC2086
  for arg in $args_in; do
    if [ "$next" -eq 1 ]; then
      [[ "$arg" =~ ^[0-9]+$ ]] && return 0
      return 1
    fi
    case "$arg" in
      -n|-c) next=1 ;;
      -n[0-9]*|-c[0-9]*)
        val="${arg#-?}"
        [[ "$val" =~ ^[0-9]+$ ]] && return 0
        return 1
        ;;
    esac
  done
  return 1
}

# --- main -----------------------------------------------------------------

# One jq extraction for the routing fields (kept to 2 jq spawns per call).
# NUL-delimited + mapfile: tab/TSV variants break on empty fields (read
# collapses IFS-whitespace runs) and NUL never appears in JSON string content.
mapfile -t -d '' F < <(
  printf '%s' "$input" | jq -j '[.agent_id // "", .tool_name // "", .tool_input.file_path // "", (.tool_input.offset // ""), (.tool_input.limit // "")] | join("\u0000")' 2>/dev/null
)
agent=${F[0]-}; tool=${F[1]-}; file=${F[2]-}; offset=${F[3]-}; limit=${F[4]-}

# Subagent calls are the workers: their reads always pass. Read is a
# per-file decision, so its record keeps the real path; Bash is a
# whole-command decision, so its record has no single path.
if [ -n "$agent" ]; then
  case "$tool" in
    Read) log_event read allow subagent "$file" "" "" ;;
    Bash) log_event bash allow subagent "" "" "" ;;
  esac
  exit 0
fi

case "$tool" in
  Read)
    if [ -z "$file" ]; then
      log_event read allow no_input "" "" ""
      exit 0
    fi
    # A targeted read requires BOTH offset and limit. "0" is a present value
    # for both fields (jq prints it as "0", which is non-empty and != "null").
    # limit alone can equal the default full-read size, and offset alone reads
    # the unbounded rest of the file — neither is targeted.
    if [ -n "$offset" ] && [ "$offset" != "null" ] && [ -n "$limit" ] && [ "$limit" != "null" ]; then
      log_event read allow targeted "$file" "" ""
      exit 0
    fi
    if check_file "$file"; then
      log_event read allow "$LAST_REASON" "$file" "$LAST_BYTES" "$LAST_LINES"
      exit 0
    fi
    log_event read deny "$LAST_REASON" "$file" "$LAST_BYTES" "$LAST_LINES"
    deny "$LAST_MSG"
    ;;

  Bash)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    if [ -z "$cmd" ]; then
      log_event bash allow no_input "" "" ""
      exit 0
    fi
    # Contract for Bash commands:
    #   (a) Compound commands (pipes, redirections, ; & backticks, or newlines)
    #       pass untouched — we do NOT try to parse them.
    #   (b) Verbs outside the whitelist (python, jq, git show, node, perl...)
    #       are never size-checked.
    #   (c) Accepted gap: a piped `sed -n 400,562p | grep` still passes via (a).
    #       A single bounded read (sed -n N,Mp, head -n N, tail -n N, head/tail -c N)
    #       is treated as targeted and skips the size check entirely.
    # pipes, redirections, compound commands and multi-line scripts are targeted
    if printf '%s' "$cmd" | grep -q '[|>;`&]'; then
      log_event bash allow compound "" "" ""
      exit 0
    fi
    case "$cmd" in
      *$'\n'*)
        log_event bash allow compound "" "" ""
        exit 0
        ;;
    esac
    if ! printf '%s' "$cmd" | grep -qE '^[[:space:]]*(cat|head|tail|less|more|bat|grep|sed|awk|rg|xxd|base64|strings)([[:space:]]|$)'; then
      log_event bash allow verb "" "" ""
      exit 0
    fi
    set -f                             # no globbing during parsing; intentional word splitting below
    read -r verb args <<<"$cmd"        # drop leading spaces; keep verb + file args

    # Single-command bounded reads are targeted: the explicit window bounds the
    # read, so we skip the size check. Caveat: `head -c N` on a 70 KB single-line
    # file still transfers N bytes of that file; that is accepted because it is
    # explicitly bounded.
    case "$verb" in
      sed)
        if is_bounded_sed "$args"; then
          log_event bash allow bounded "" "" ""
          exit 0
        fi
        ;;
      head|tail)
        if is_bounded_head_tail "$args"; then
          log_event bash allow bounded "" "" ""
          exit 0
        fi
        ;;
    esac

    file_count=0
    # shellcheck disable=SC2086
    for f in $args; do                 # intentional word splitting
      case "$f" in -*) continue;; esac
      file_count=$((file_count + 1))
      if check_file "$f"; then
        log_event bash allow "$LAST_REASON" "$f" "$LAST_BYTES" "$LAST_LINES"
      else
        log_event bash deny "$LAST_REASON" "$f" "$LAST_BYTES" "$LAST_LINES"
        deny "$LAST_MSG"
      fi
    done
    [ "$file_count" -eq 0 ] && log_event bash allow no_input "" "" ""
    exit 0
    ;;
esac

exit 0
