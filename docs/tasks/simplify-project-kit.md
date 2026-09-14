# Simplify: per-project copy-paste kit

## Status
- Slice: review fixes R2 (complete)
- Next: commit — gates green, reviewer passed fixes R1 + R2 minors

## Spec
The repo content must be copy-pasteable into any project adopting the multi-agent
workflow. Drop the "global machine config + symlinks" mode and every reference to
the `agent-workflow` repo itself.

### User decisions (2026-09-14)
- Per-project install, **without setup.sh**: content goes into the project
  (`.claude/`, `.opencode/`, root `AGENTS.md` + one-line `CLAUDE.md`).
- `templates/` deleted completely (ci-gates.yml, gitignore template); no more
  "from agent-workflow" mentions anywhere.
- `githooks/` (this repo's self-gate) kept.
- `statusline-command.sh` kept in the kit (referenced by settings.json).

## Target layout
```
AGENTS.md                  workflow rules (opencode reads the project root natively)
CLAUDE.md                  one line: @AGENTS.md
.claude/
  agents/ (6)
  hooks/shunt.sh           PreToolUse hook (test-shunt.sh = dev)
  settings.json            structural keys only (push-ask permissions, hooks, statusLine)
  statusline-command.sh
.opencode/
  agent/ (7: 6 + build.md) orchestrator build agent
  plugins/shunt.ts
.gates.yml                 self-gate
.github/workflows/ci.yml   mirror of .gates.yml
githooks/                  this repo's self-gate only, not shipped to projects
README.md                  copy-paste install + deps
```

## Deleted
- setup.sh — the repo installs nothing anymore
- templates/ — .gitignore lines now live directly in the kit .gitignore + a
  self-contained AGENTS.md init-hygiene rule
- opencode/{opencode.jsonc, package.json, package-lock.json} — model/
  telemetry config is a user-level global preference (~/.config/opencode), out of kit scope
- opencode/AGENTS.md + claude/AGENTS.md — no more triple copy: the root file is
  canonical, CLAUDE.md imports it via @AGENTS.md

## Hook changes (TDD: test-pre-commit.sh first)
- agents-sync (githooks/pre-commit) now checks CLAUDE.md == `@AGENTS.md`
  (single logical line, no extra lines; missing trailing newline OK) instead of
  3 identical copies; staged deletion blocks.
- shellcheck lists now cover all shipped shell scripts; setup.sh dropped.

## Implementation notes
- `.claude/settings.json`: hook command `bash .claude/hooks/shunt.sh` (relative,
  cwd = project root), statusLine `bash .claude/statusline-command.sh`.
- `.gitignore`: only `.claude/settings.local.json` + `.opencode/settings.local.json`.
- README: reduced deps (Git Bash + jq on Windows for the Claude hook; shellcheck/
  jq/gitleaks dev deps); npm/bun telemetry deps gone with opencode.opencode.jsonc.

## Rounds
- R1 review (7 findings, 3 majors) — fixed by implementer R1.
- R2 review: 1 major (French plan file blocked by accent gate) + minors.

## R2 fixes (orchestrator, direct)
- Plan file translated to plain English (accent-gate compatible).
- Hook CLAUDE.md check: missing trailing newline accepted; error message
  adjusted; tests 17 (no trailing newline passes) + 18 (junk after Newline
  blocks) added, red-green verified (20 passed, 0 failed).
- README: githooks/ tree annotation no longer reads as an adopter instruction;
  duplicate self-gate paragraphs merged.

## Subagent metrics
| Round | agent | tokens | tool_uses | duration |
|-------|-------|--------|-----------|----------|
| 1 restructure | implementer ses_f5fb9db87ffexYkQilMIRvopnA | n/a (not reported) | n/a | n/a |
| 1 gates | gate-keeper ses_f5fb3dfcdffeEBn4JGeoM0q1Es | n/a | n/a | n/a |
| 1 review | reviewer ses_f5fb3cc41ffe0k7QKhGEWtsoyc | n/a | n/a | n/a |
| R1 fixes | implementer ses_f5fb010acffeIuAHdsnqmDE4oD | n/a | n/a | n/a |
| 2 gates | gate-keeper ses_f5faab9a9ffeyQ74WgfQMV8ECH | n/a | n/a | n/a |

Note: tool results did not carry token/tool_uses/duration fields; recorded as n/a.
