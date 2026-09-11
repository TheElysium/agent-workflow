#!/usr/bin/env bash
# Links the live tool configs INTO this repo, so there is no sync step:
# edit a repo file, the tool reads it live. Run once per machine, or to
# repair a link (e.g. if a tool rewrote a hardlinked file).
#
#   ./setup.sh          create/repair all links
#   ./setup.sh --check  verify every link resolves
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

check() {
  for p in "$OC/AGENTS.md" "$OC/agent" "$OC/plugins" "$OC/opencode.jsonc"; do
    [ -e "$p" ] || { echo "BROKEN: $p"; exit 1; }
  done
  for p in "$CL/CLAUDE.md" "$CL/settings.json" "$CL/agents/implementer.md"; do
    [ -e "$p" ] || { echo "BROKEN: $p"; exit 1; }
  done
  echo "all links resolve"
}


case "${1:-}" in
  "" | setup) link_opencode; link_claude ;;
  --repair)   link_claude ;;  # hardlinks are the fragile part (tool rewrites)
  --check)    check ;;
  *) echo "usage: setup.sh [--check|--repair]"; exit 1 ;;
esac
