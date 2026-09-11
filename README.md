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

claude/                      ← /mnt/c/Users/<win-user>/.claude/ (NTFS junction + hardlinks)
├── CLAUDE.md                Global rules (mirror of AGENTS.md, orchestration in the main loop)
├── settings.json            git push ask permission, hooks, enabled plugins
├── statusline-command.sh    Statusline (referenced by settings.json, hardlinked into .claude/)
├── hooks/shunt.sh           Shunt hook (PreToolUse: blocks oversized non-targeted reads)
│                            + hooks/test-shunt.sh (test harness, 20 cases)
└── agents/                  implementer, reviewer, gate-keeper, explore, bulk-reader, code-writer

githooks/pre-commit           self-gate of this repo (shellcheck, secrets, accents, JSON)
githooks/test-pre-commit.sh   smoke tests for the pre-commit gate
templates/ci-gates.yml        GitHub Actions template, copied into projects (mirrors .gates.yml)

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

### Enforceable gates

- Every project carries a `.gates.yml` at its root (format documented in `opencode/AGENTS.md`, Phase 4): the single source of lint/typecheck/build/test/sast commands. `gate-keeper` runs it verbatim; a missing file is built with the user, never discovered by guesswork.
- SAST is non-skippable (gitleaks + the stack's audit tool). A gate run without SAST is a red gate.
- CI: `templates/ci-gates.yml` is copied into projects as `.github/workflows/ci.yml` and kept in sync with `.gates.yml`.
- Task state: long tasks persist their spec, decisions, todo and gate status in `docs/tasks/<slug>.md` (updated by the orchestrator; sessions read it before resuming).
- This repo self-enforces: `githooks/pre-commit` (installed by `setup.sh` via `core.hooksPath`) runs shellcheck, a secrets scan, an English/no-accents check, and JSON validation on every commit.

## Dependencies

| Tool | Needed by | Notes |
|------|-----------|-------|
| Git for Windows (Git Bash) | Claude Code hooks | Hooks run via Git Bash; `bash.exe` at `C:\Windows\system32` is WSL bash, not Git Bash |
| `jq` (Windows) | `claude/hooks/shunt.sh` | `winget install jqlang.jq` — Git Bash inherits the Windows PATH. Without it the hook fails open silently (no blocking) |
| Node.js + npm | opencode plugins | `cd ~/.config/opencode && npm install` |
| `bun` | opencode telemetry only | Optional if the telemetry plugin is removed |
| `jq` + `shellcheck` (Linux, `~/.local/bin`) | dev only: test harness, linting | Optional; harness uses the WSL path fallback |

## Fresh-machine setup

Target: Windows host + WSL (NTFS junctions/hardlinks require both). Steps:

1. **Edit the machine-specific paths first** (see below), then `./setup.sh` (creates the links)
2. Install the dependencies above (jq via WinGet is the only non-optional one for Claude Code)
3. opencode deps: `cd ~/.config/opencode && npm install` (node_modules is not versioned)
4. Telemetry CLI: install bun (`~/.local/bin/bun`) + wrapper `~/.local/bin/octm` pointing to `~/.config/opencode/node_modules/opencode-telemetry/bin/cli.js`
5. Pricing patch: add `opencode/mimo-v2.5-free` (and variants) to `node_modules/opencode-telemetry/src/pricing.json` (free = 0) — ephemeral patch, redo after `npm update`
6. Agents/opencode.jsonc reload at the next session; Claude Code re-reads `CLAUDE.md`/`settings.json` (including hooks) at launch

### Machine-specific paths

None hardcoded: `settings.json` uses `~` (Git Bash resolves it to the Windows home), and `setup.sh` auto-detects the Windows username via `cmd.exe`. Override points:

- `CLAUDE_CONFIG_DIR` env var — replaces the auto-detected live `.claude` dir in `setup.sh`
- `SHUNT_TEST_TMP` env var — replaces the fixture temp dir in `claude/hooks/test-shunt.sh` (dev only)
- `CMD` env var — non-standard `cmd.exe` location in `setup.sh`

Everything else (agents, rules, hook logic, thresholds) is machine-agnostic.

## Cross-tool sync notes

- `opencode/AGENTS.md` and `claude/CLAUDE.md` are copies maintained in parallel. Any edit to one must be carried into the other (the repo keeps them side by side).
- **Shunt parity**: opencode enforces it via the `shunt.ts` plugin, Claude Code via the `shunt.sh` hook (same thresholds, 350 lines / 65536 bytes; tuned on either side with `SHUNT_MIN_LINES` / `SHUNT_MAX_BYTES`). Boundary detail: a file with exactly 350 lines passes on the Claude side (`wc -l`), while shunt.ts counts the trailing newline as a line and blocks it. Claude Code flags subagent calls with a top-level `agent_id`, which replaces the plugin's delegated-session tracking. Test the hook with `bash claude/hooks/test-shunt.sh` (exercises the WSL path fallback; the Git Bash/cygpath branch is exercised in production).
- Accepted divergences: `hidden`/`temperature` agent fields are opencode only; detailed permissions (Task, bash patterns) opencode only; `git push` ask = permission rule on the Claude Code side, `permission` field on the opencode side.
- `claude/settings.json` is versioned without secrets (credentials live in `.credentials.json`, never committed).
