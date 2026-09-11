#!/usr/bin/env bash
# Links the live tool configs INTO this repo, so there is no sync step:
# edit a repo file, the tool reads it live. Run once per machine, or to
# repair a link (re-running the same command is idempotent).
#
#   ./setup.sh                    # link everything
#   ./setup.sh opencode           # opencode links only
#   ./setup.sh claude             # claude links only (also repairs them)
#   ./setup.sh [--check] [opencode|claude]
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OC="$HOME/.config/opencode"
OC_REPO="$REPO/opencode"
CL="${CLAUDE_CONFIG_DIR:-/mnt/c/Users/lukas/.claude}"   # live Claude Code config (NTFS)
CMD="${CMD:-/mnt/c/Windows/System32/cmd.exe}"
# Windows-side relative paths for mklink (resolved from C:\Users\lukas)
REL_OC="Documents\\Projets\\agent-workflow\\opencode"
REL_CL="Documents\\Projets\\agent-workflow\\claude"

link_opencode() {
  for f in AGENTS.md opencode.jsonc package.json package-lock.json; do
    ln -sfn "$OC_REPO/$f" "$OC/$f"
  done
  for d in agent plugins; do
    rm -rf "$OC/$d"
    ln -sfn "$OC_REPO/$d" "$OC/$d"
  done
  echo "opencode: $OC/* -> $OC_REPO (WSL symlinks)"
}

link_claude() {
  # junction (dir) + hardlinks (files) — no admin needed, same NTFS volume
  rm -rf "$CL/agents"
  "$CMD" /c "mklink /J .claude\\agents $REL_CL\\agents" >/dev/null
  for f in CLAUDE.md settings.json; do
    rm -f "$CL/$f"
    "$CMD" /c "mklink /H .claude\\$f $REL_CL\\$f" >/dev/null
  done
  echo "claude: $CL/{CLAUDE.md,settings.json,agents} -> $REPO/claude (junction + hardlinks)"
}

check_opencode() {
  for p in "$OC/AGENTS.md" "$OC/agent" "$OC/plugins" "$OC/opencode.jsonc" "$OC/package.json" "$OC/package-lock.json"; do
    [ -e "$p" ] || { echo "BROKEN: $p"; exit 1; }
  done
  echo "opencode: links resolve"
}

check_claude() {
  for p in "$CL/CLAUDE.md" "$CL/settings.json" "$CL/agents/implementer.md"; do
    [ -e "$p" ] || { echo "BROKEN: $p"; exit 1; }
  done
  echo "claude: links resolve"
}

TOOL="all"
ACTION="create"
for arg in "$@"; do
  case "$arg" in
    opencode | claude) TOOL="$arg" ;;
    all)               TOOL="all" ;;
    --check)           ACTION="check" ;;
    *) echo "usage: setup.sh [--check] [opencode|claude]"; exit 1 ;;
  esac
done

run() { # run <op> <tool>
  case "$1" in
    link)  [ "$2" = opencode ] && link_opencode || link_claude ;;
    check) [ "$2" = opencode ] && check_opencode || check_claude ;;
  esac
}

for t in opencode claude; do
  if [ "$TOOL" = all ] || [ "$TOOL" = "$t" ]; then run "$ACTION" "$t"; fi
done
