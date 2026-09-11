#!/usr/bin/env bash
# Sync agent-workflow configs between this repo and the live tool locations.
#
# Usage:
#   ./sync.sh           deploy  : repo → live configs (opencode + Claude Code)
#   ./sync.sh --pull    harvest : live configs → repo (then review `git diff` and commit)
#
# The repo is the source of truth for normal edits; use --pull only when a
# tool (or an agent) edited a live config directly.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENCODE_SRC="$REPO/opencode"
CLAUDE_SRC="$REPO/claude"

# Live locations (override with env vars if needed)
OPENCODE_LIVE="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
CLAUDE_LIVE="${CLAUDE_CONFIG_DIR:-/mnt/c/Users/lukas/.claude}"

deploy() {
  cp -v "$OPENCODE_SRC/AGENTS.md"       "$OPENCODE_LIVE/AGENTS.md"
  cp -v "$OPENCODE_SRC/opencode.jsonc"  "$OPENCODE_LIVE/opencode.jsonc"
  cp -v "$OPENCODE_SRC/package.json"    "$OPENCODE_LIVE/package.json"
  mkdir -p "$OPENCODE_LIVE/agent" "$OPENCODE_LIVE/plugins"
  cp -v "$OPENCODE_SRC"/agent/*.md      "$OPENCODE_LIVE/agent/"
  cp -v "$OPENCODE_SRC"/plugins/*.ts    "$OPENCODE_LIVE/plugins/"

  cp -v "$CLAUDE_SRC/CLAUDE.md"     "$CLAUDE_LIVE/CLAUDE.md"
  cp -v "$CLAUDE_SRC/settings.json" "$CLAUDE_LIVE/settings.json"
  mkdir -p "$CLAUDE_LIVE/agents"
  cp -v "$CLAUDE_SRC"/agents/*.md   "$CLAUDE_LIVE/agents/"

  echo "Deployed. If opencode/package.json changed, run: (cd $OPENCODE_LIVE && npm install)"
  echo "Note: node_modules is never deployed — reinstall deps there if needed."
}

pull() {
  cp -v "$OPENCODE_LIVE/AGENTS.md"      "$OPENCODE_SRC/AGENTS.md"
  cp -v "$OPENCODE_LIVE/opencode.jsonc" "$OPENCODE_SRC/opencode.jsonc"
  cp -v "$OPENCODE_LIVE/package.json"   "$OPENCODE_SRC/package.json"
  cp -v "$OPENCODE_LIVE"/agent/*.md     "$OPENCODE_SRC/agent/"
  cp -v "$OPENCODE_LIVE"/plugins/*.ts   "$OPENCODE_SRC/plugins/"

  cp -v "$CLAUDE_LIVE/CLAUDE.md"     "$CLAUDE_SRC/CLAUDE.md"
  cp -v "$CLAUDE_LIVE/settings.json" "$CLAUDE_SRC/settings.json"
  cp -v "$CLAUDE_LIVE"/agents/*.md   "$CLAUDE_SRC/agents/"

  echo "Harvested. Review 'git diff' and commit to keep the trace."
}

case "${1:-}" in
  "" | deploy)   deploy ;;
  --pull | pull) pull ;;
  *) echo "usage: sync.sh [--pull]"; exit 1 ;;
esac
