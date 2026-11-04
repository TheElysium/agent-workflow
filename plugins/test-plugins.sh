#!/usr/bin/env bash
set -uo pipefail
export MSYS2_ARG_CONV_EXCL='*'

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$HERE")"
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"

PASS=0
FAIL=0

check() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "FAIL: $1 (want: ${3:0:200} | got: ${2:0:200})"
  fi
}

markdown_files() {
  find "$1" -name '*.md' -type f -print0 | LC_ALL=C sort -z
}

run_awk() {
  local root="$1" program="$2" files=()
  mapfile -d '' files < <(markdown_files "$root")
  [ "${#files[@]}" -gt 0 ] || return 0
  awk -v root="$root/" "$program" "${files[@]}"
}

AWK_PRELUDE='
function rel() { return substr(FILENAME, length(root) + 1) }
function skill_or_agent(r) { return r ~ /^skills\/[^\/]+\/SKILL\.md$/ || r ~ /^agents\/[^\/]+\.md$/ }
{ sub(/\r$/, "") }
'

find_cwd_relative_script_calls() {
  run_awk "$1" "$AWK_PRELUDE"'
  {
    line = $0
    gsub(/[$][{]CLAUDE_PLUGIN_ROOT[}]\/scripts\//, "@/", line)
    if (line ~ /(^|[^A-Za-z0-9_])scripts\/[A-Za-z0-9_-]+\.(ps1|sh)([^A-Za-z0-9_]|$)/) print rel() ":" FNR
  }'
}

find_misplaced_plugin_variable() {
  run_awk "$1" "$AWK_PRELUDE"'
  !skill_or_agent(rel()) && /[$][{]CLAUDE_PLUGIN_ROOT[}]/ { print rel() ":" FNR }'
}

find_unquoted_plugin_variable() {
  run_awk "$1" "$AWK_PRELUDE"'
  skill_or_agent(rel()) && /(^|[^"`])[$][{]CLAUDE_PLUGIN_ROOT[}]\// { print rel() ":" FNR }'
}

find_agent_name_mismatch() {
  run_awk "$1" "$AWK_PRELUDE"'
  function flush() {
    if (current != "" && declared != base) print current
  }
  FNR == 1 {
    flush()
    current = ""; declared = ""; seen = 0
    if (rel() ~ /^agents\/[^\/]+\.md$/) {
      current = rel(); base = current
      sub(/^agents\//, "", base); sub(/\.md$/, "", base)
    }
  }
  current != "" && !seen && /^name:[ \t]*[^ \t]/ {
    seen = 1; declared = $0
    sub(/^name:[ \t]*/, "", declared); sub(/[ \t]+$/, "", declared)
  }
  END { flush() }'
}

jq_text() { jq -b -r "$1" 2>/dev/null; }

check_marketplace() {
  local owner names
  owner="$(jq_text '.owner.name // empty' < "$MARKETPLACE")"
  check "marketplace has an owner name" "$([ -n "$owner" ] && echo yes)" "yes"
  names="$(jq_text '[.plugins[].name] | join(",")' < "$MARKETPLACE")"
  check "marketplace lists agent-workflow and shunt" "$names" "agent-workflow,shunt"
}

expected_events() {
  case "$1" in
    agent-workflow) echo "SessionEnd";;
    shunt) echo "PreToolUse";;
  esac
}

expected_matchers() {
  case "$1" in
    shunt) echo "Read|Bash";;
    *) echo "";;
  esac
}

check_manifest() {
  local name="$1" dir="$2" manifest_name same
  local manifest="$dir/.claude-plugin/plugin.json"
  manifest_name="$(jq_text '.name // empty' < "$manifest")"
  check "$name: plugin.json is named after the marketplace entry" "$manifest_name" "$name"
  same="$(jq -b -s -r --arg n "$name" '(.[0].plugins[] | select(.name == $n) | .description) == .[1].description' < <(cat "$MARKETPLACE" "$manifest") 2>/dev/null)"
  check "$name: plugin.json description matches the marketplace entry" "$same" "true"
}

check_hooks() {
  local name="$1" dir="$2" commands=() cmd rel_path events matchers hooks
  hooks="$dir/hooks/hooks.json"
  mapfile -t commands < <(jq_text '.hooks[][].hooks[].command' < "$hooks")
  check "$name: declares at least one hook command" "$([ "${#commands[@]}" -gt 0 ] && echo yes)" "yes"
  events="$(jq_text '.hooks | keys_unsorted | join(",")' < "$hooks")"
  check "$name: declares exactly the expected hook events" "$events" "$(expected_events "$name")"
  matchers="$(jq_text '[.hooks[][].matcher // empty] | join(",")' < "$hooks")"
  check "$name: declares the expected matchers" "$matchers" "$(expected_matchers "$name")"
  for cmd in "${commands[@]}"; do
    if [[ "$cmd" =~ ^bash\ \"\$\{CLAUDE_PLUGIN_ROOT\}/(hooks/[A-Za-z0-9_-]+\.sh)\"$ ]]; then
      rel_path="${BASH_REMATCH[1]}"
      check "$name: hook script exists: $rel_path" "$([ -f "$dir/$rel_path" ] && echo yes)" "yes"
    else
      check "$name: hook command has the form bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/<x>.sh\"" "$cmd" "bash \"\${CLAUDE_PLUGIN_ROOT}/hooks/<x>.sh\""
    fi
  done
}

report_offenders() {
  local desc="$1" offenders="$2"
  check "$desc" "${offenders//$'\n'/, }" ""
}

check_markdown() {
  local name="$1" dir="$2" size=0 skill
  skill="$dir/skills/dev-workflow/SKILL.md"
  report_offenders "$name: no cwd-relative scripts/*.(ps1|sh) call" "$(find_cwd_relative_script_calls "$dir")"
  report_offenders "$name: plugin root variable only in SKILL.md and agents" "$(find_misplaced_plugin_variable "$dir")"
  report_offenders "$name: plugin root paths quoted or backticked" "$(find_unquoted_plugin_variable "$dir")"
  report_offenders "$name: agent name matches file name" "$(find_agent_name_mismatch "$dir")"
  if [ "$name" = "agent-workflow" ]; then
    check "$name: dev-workflow SKILL.md exists" "$([ -f "$skill" ] && echo yes)" "yes"
  fi
  if [ -f "$skill" ]; then
    size="$(wc -c < "$skill" | tr -d ' ')"
    check "$name: dev-workflow SKILL.md at most 9000 bytes ($size)" "$([ "$size" -le 9000 ] && echo yes)" "yes"
  fi
}

check_guards() {
  fx="$(mktemp -d "${TMPDIR:-/tmp}/test-plugins.XXXXXX")"
  trap 'rm -rf "$fx"' EXIT
  mkdir -p "$fx/skills/x" "$fx/skills/dev-workflow" "$fx/agents"
  cat > "$fx/skills/x/SKILL.md" <<'EOF'
ok
run `pwsh scripts/gates.ps1`
run "${CLAUDE_PLUGIN_ROOT}/scripts/gates.ps1"
pwsh ${CLAUDE_PLUGIN_ROOT}/scripts/a.ps1
pwsh "${CLAUDE_PLUGIN_ROOT}/scripts/a.ps1"
pwsh `${CLAUDE_PLUGIN_ROOT}/scripts/a.ps1`
EOF
  cat > "$fx/skills/dev-workflow/gates.md" <<'FIXTURE'
x
"${CLAUDE_PLUGIN_ROOT}/a"
FIXTURE
  cat > "$fx/agents/a.md" <<'FIXTURE'
---
name: a
---
"${CLAUDE_PLUGIN_ROOT}/a"
FIXTURE
  printf '%s\n' '---' 'name: c' '---' > "$fx/agents/b.md"
  printf '%s\n' '---' 'model: x' '---' > "$fx/agents/d.md"
  check "guard: cwd-relative script call flagged, prefixed one accepted" "$(find_cwd_relative_script_calls "$fx")" "skills/x/SKILL.md:2"
  check "guard: misplaced variable flagged, agent use accepted" "$(find_misplaced_plugin_variable "$fx")" "skills/dev-workflow/gates.md:2"
  check "guard: unquoted path flagged, quoted and backticked accepted" "$(find_unquoted_plugin_variable "$fx")" "skills/x/SKILL.md:4"
  check "guard: wrong or missing agent name flagged, right one accepted" "$(find_agent_name_mismatch "$fx")" $'agents/b.md\nagents/d.md'
  rm -rf "$fx"
}

check_marketplace
check_guards

while IFS=$'\t' read -r name source; do
  dir="$REPO_ROOT/${source#./}"
  check "$name: source directory holds a plugin.json" "$([ -f "$dir/.claude-plugin/plugin.json" ] && echo yes)" "yes"
  [ -f "$dir/.claude-plugin/plugin.json" ] || continue
  check_manifest "$name" "$dir"
  check_hooks "$name" "$dir"
  check_markdown "$name" "$dir"
done < <(jq_text '.plugins[] | [.name, .source] | @tsv' < "$MARKETPLACE")

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
