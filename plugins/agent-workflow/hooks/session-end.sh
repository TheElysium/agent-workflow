#!/usr/bin/env bash
# Claude Code SessionEnd hook: import token usage into .usage/usage.jsonl via
# ../scripts/usage-import-claude.sh. cwd is the project worktree. Overrides:
# USAGE_IMPORT_CMD (script path), CLAUDE_PROJECTS_DIR. Never fails, never
# prints: instrumentation must not surface errors to the harness.

set -u
export MSYS2_ARG_CONV_EXCL='*'

project_slug() {
  local worktree="$PWD" probe=$'\303\251' candidate LC_ALL
  for candidate in C.UTF-8 en_US.UTF-8; do
    LC_ALL="$candidate"
    [ "${#probe}" -eq 1 ] && break
  done
  case "$(uname -s)" in
    MINGW*|MSYS*) worktree="$(pwd -W)";;
  esac
  printf '%s' "${worktree//[^A-Za-z0-9]/-}"
}

run_import() {
  local import_cmd="${USAGE_IMPORT_CMD:-}"
  if [ -z "$import_cmd" ]; then
    import_cmd="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/usage-import-claude.sh"
  fi
  local projects="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
  [ -d "$projects" ] && [ -f "$import_cmd" ] || return 0
  local slug
  slug="$(project_slug)"
  [ -d "$projects/$slug" ] || return 0
  bash "$import_cmd" --dir "$projects" --project "$slug" --out "$PWD/.usage/usage.jsonl" >/dev/null 2>&1 || true
}

run_import || true
exit 0
