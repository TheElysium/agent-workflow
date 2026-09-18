# setup-workflow

Status: Phase 1 (spec) - branch `feat/setup-workflow` - no commit yet.

## Problem

1. `README.md` is unclear: no workflow diagram, no rationale, ambiguous install.
2. The documented per-project install omits `scripts/`, while the deployed kit
   references `scripts/review-checklist.sh` (dev-workflow skill + opencode
   reviewer agent), `scripts/usage-report.sh`, `scripts/session-tools.sh` and
   `scripts/run-gates.sh` (CI). Every installed project has dead script paths.
3. `.opencode/package.json`, `package-lock.json` and `node_modules/` are
   gitignored, so a copy from a clone ships plugins with no manifest and no
   `@opencode-ai/plugin` dependency. No README step covers this.
4. Install always deploys both harnesses; Claude Code alone is often enough.
5. No automated setup path.

## Solution (agreed with the user)

- `scripts/setup-workflow.sh`: idempotent installer.
  `--mode project --target <path>` and `--mode global`;
  `--harness claude|opencode|both`; gates skeleton or preserve existing;
  `--dry-run`. Copies runtime scripts only (never `test-*.sh`).
  Non-destructive on an existing `AGENTS.md` / `CLAUDE.md` / `settings.json`.
- `scripts/test-setup-workflow.sh`: TDD proof, wired into `.gates.yml`.
- `.claude/skills/setup-workflow/SKILL.md`: thin skill, interviews then calls
  the script, then verifies.
- `README.md` rewrite: Mermaid diagram, concise rationale, unambiguous install.

## Out of scope

Shunt logic, agent definitions, dev-workflow phases, symlink global install,
packaging/publishing.

## Decisions (post spec-critic)

- Target `AGENTS.md`: kit rules to `.claude/agent-workflow/AGENTS.md`, one `@` import
  line appended. Never rewrite user content.
- Manifest `.claude/agent-workflow.install.json` (kit commit + sha256/file) + `--uninstall`:
  makes re-runs safe and lets already-broken installs be repaired.
- `--verify` in scope. `--ci`, `--pre-commit`, `--install-deps` deferred; installer stays
  network-free.
- Global mode Claude-only; `--harness opencode|both` + `--mode global` errors.
- `.gates.yml` skeleton: `sast` real, every unfillable gate a hard red.
- Excluded from every copy: `settings.local.json`, `.usage/`, `node_modules/`, `*.bak.*`,
  `*.stackdump`, `scripts/test-*.sh`, `*.test.ts`.
- Tests hermetic via `--global-dir`; never touch the real `$HOME/.claude`.

## Progress

- [x] `.claude/skills/setup-workflow/SKILL.md`
- [x] `README.md` (193 lines / 8.8 KB, was 148 / 11.4 KB)
- [x] `.gates.yml` wired for setup-workflow
- [x] `scripts/setup-workflow.sh` + `scripts/test-setup-workflow.sh` (161 assertions)
- [x] gate-keeper: lint/test/sast all green
- [x] reviewer: REQUEST_CHANGES -> 2 data-loss bugs fixed, re-verified

## Subagent metrics

| subagent | tokens | tool_uses | duration | retries | review_iterations | gate_failures | outcome |
|---|---|---|---|---|---|---|---|
| bulk-reader | 43487 | 18 | 107s | 0 | - | - | delivered |
| spec-critic | 43981 | 14 | 199s | 0 | - | - | NEEDS_CLARIFICATION, 12 questions |
| implementer | 71599 | 47 | 1350s | 0 | - | - | delivered, 1 assumption flagged |
| gate-keeper | 14282 | 5 | 113s | 0 | - | 0 | ALL_GREEN |
| reviewer | 67759 | 19 | 220s | 0 | 1 | - | REQUEST_CHANGES (1 blocker, 1 major, 1 minor) |

## Review fixes (TDD, test first)

| finding | fix |
|---|---|
| `--uninstall` deleted a pre-existing `settings.json` wholesale, losing personal keys | manifest entries carry `kind` (`create`/`merge`, sticky across re-runs); `merge` entries go through `unmerge_settings_json`, which strips only the kit's hooks/`statusLine` and deletes the file solely if nothing is left |
| `ensure_gitignore_lines` concatenated onto a last line with no trailing newline | append a newline first when the file's last byte is not one |
| two test sections both numbered 13 | renumbered 14; new sections 15 (uninstall unmerge) and 16 (gitignore newline) |

Found by me before review, same pass: `render_settings_json` hard-coded project-relative
hook paths (dead paths in a global install, and a duplicate entry on re-run over a
hand-made `~/.claude`), `install_settings_json` copied the kit's project-shaped file into
a fresh global install, `SCOPE` was unset outside `--verify`/`--uninstall`.
