# agent-workflow

Versioned configuration of the multi-agent development workflow for **opencode** and **Claude Code**.

## Structure

```
opencode/                    ← ~/.config/opencode/ (WSL symlinks)
├── AGENTS.md                Global rules: 5-phase workflow + shunt pattern + multi-agent rules
├── opencode.jsonc           Config: primary model, telemetry plugin
├── package.json(+lock)      Plugin deps (npm install in ~/.config/opencode)
├── agent/                   Agents (build fork = orchestrator, implementer, reviewer,
│                            gate-keeper, explore, bulk-reader, code-writer)
└── plugins/shunt.ts         Shunt plugin

claude/                      ← /mnt/c/Users/lukas/.claude/ (NTFS junction + hardlinks)
├── CLAUDE.md                Global rules (mirror of AGENTS.md, orchestration in the main loop)
├── settings.json            git push ask permission, hooks, enabled plugins
├── statusline-command.sh    Statusline (referenced by settings.json, hardlinked into .claude/)
├── hooks/shunt.sh           Shunt hook (PreToolUse: blocks oversized non-targeted reads)
│                            + hooks/test-shunt.sh (test harness, 20 cases)
└── agents/                  implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer

setup.sh                     creates/verifies the links (all, or opencode/claude separately)
```

## No sync step: live configs point into the repo

- **opencode**: `~/.config/opencode/{AGENTS.md,opencode.jsonc,package*.json,agent,plugins}` are WSL symlinks into this repo.
- **Claude Code**: `.claude/CLAUDE.md` and `.claude/settings.json` are NTFS **hardlinks**, `.claude/agents` is a **junction**, `.claude/hooks/shunt.sh` is a hardlink — visible from both Windows and WSL.

Consequence: **the repo IS the live config**. Edit here, the tool sees it immediately (at the next session start for agents).

```bash
./setup.sh --check    # verify every link resolves
./setup.sh            # (re)create all links — idempotent, repairs what broke
./setup.sh opencode   # limit to opencode links (same for claude)
```

Known caveat: a tool that rewrites a hardlinked file via temp-file+rename save breaks the link (the file becomes an autonomous copy). If `--check` is green but an edit does not propagate, compare with `git diff`, then re-run `./setup.sh claude`.

## Workflow (summary)

spec → decomposition → explore/bulk-reader (parallel) → implementer (TDD) → gate-keeper (lint/typecheck/build/tests/SAST) → reviewer (peer review) → commit → push only on explicit request.

Details: see `opencode/AGENTS.md` (source of truth).

## Fresh-machine setup

1. `./setup.sh` (creates the links)
2. opencode deps: `cd ~/.config/opencode && npm install` (node_modules is not versioned)
3. Telemetry CLI: install bun (`~/.local/bin/bun`) + wrapper `~/.local/bin/octm` pointing to `~/.config/opencode/node_modules/opencode-telemetry/bin/cli.js`
4. Pricing patch: add `opencode/mimo-v2.5-free` (and variants) to `node_modules/opencode-telemetry/src/pricing.json` (free = 0) — ephemeral patch, redo after `npm update`
5. Agents/opencode.jsonc reload at the next session; Claude Code re-reads `CLAUDE.md`/`settings.json` at launch

## Cross-tool sync notes

- `opencode/AGENTS.md` and `claude/CLAUDE.md` are copies maintained in parallel. Any edit to one must be carried into the other (the repo keeps them side by side).
- **Shunt parity**: opencode enforces it via the `shunt.ts` plugin, Claude Code via the `shunt.sh` hook (same thresholds, 350 lines / 65536 bytes; tuned on either side with `SHUNT_MIN_LINES` / `SHUNT_MAX_BYTES`). Boundary detail: a file with exactly 350 lines passes on the Claude side (`wc -l`), while shunt.ts counts the trailing newline as a line and blocks it. Claude Code flags subagent calls with a top-level `agent_id`, which replaces the plugin's delegated-session tracking. Test the hook with `bash claude/hooks/test-shunt.sh` (exercises the WSL path fallback; the Git Bash/cygpath branch is exercised in production).
- Accepted divergences: `hidden`/`temperature` agent fields are opencode only; detailed permissions (Task, bash patterns) opencode only; `git push` ask = permission rule on the Claude Code side, `permission` field on the opencode side.
- `claude/settings.json` is versioned without secrets (credentials live in `.credentials.json`, never committed).
