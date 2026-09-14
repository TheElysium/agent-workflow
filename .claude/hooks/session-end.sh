#!/usr/bin/env bash
# Claude Code SessionEnd hook: import token usage into the harness-neutral
# sink (.usage/usage.jsonl) via scripts/usage-import-claude.sh.
#
# cwd is the project worktree. The Claude Code project slug is derived from
# the current directory: on WSL Windows drives (wslpath transform,
# C:\... -> C--Users-...), otherwise POSIX (slashes to dashes). Imports run
# for whichever candidate slug exists under the projects storage.
#
# IMPORT_CMD is a single script path (default: the repo's import script);
# an override must be a path too — arguments are not supported. The hook
# never fails: SessionEnd instrumentation must not surface errors to the
# harness. Configure via .claude/settings.json:
#   "SessionEnd": [{ "hooks": [{ "type": "command",
#     "command": "bash .claude/hooks/session-end.sh", "timeout": 10 }] }]

set -u

WORKTREE="$PWD"

IMPORT_CMD="${USAGE_IMPORT_CMD:-}"
if [ -z "$IMPORT_CMD" ]; then
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  IMPORT_CMD="$ROOT/scripts/usage-import-claude.sh"
fi

PROJECTS="${CLAUDE_PROJECTS_DIR:-}"
if [ -z "$PROJECTS" ]; then
  for candidate in "$HOME/.claude/projects" /mnt/[a-z]/Users/*/.claude/projects; do
    if [ -d "$candidate" ]; then
      PROJECTS="$candidate"
      break
    fi
  done
fi
[ -n "$PROJECTS" ] || exit 0

slugs=()
if [[ "$WORKTREE" == /mnt/[a-z]/* ]] && command -v wslpath >/dev/null 2>&1; then
  win="$(wslpath -w "$WORKTREE")"
  slugs+=("$(printf '%s' "$win" | sed 's/:/-/; s/\\/-/g')")
fi
slugs+=("$(printf '%s' "$WORKTREE" | tr '/' '-')")

for slug in "${slugs[@]}"; do
  [ -d "$PROJECTS/$slug" ] || continue
  bash "$IMPORT_CMD" --dir "$PROJECTS" --project "$slug" --out "$WORKTREE/.usage/usage.jsonl" || true
done

exit 0
