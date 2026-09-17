# Shunt decision log (allow + deny)

Status: archived 2026-09-17. Branch `feat/shunt-decision-log`, single commit, not pushed.

## Outcome

- `shunt.sh` + `shunt.ts`: one `.usage/shunt.jsonl` record per Read/Bash decision, allow and deny, subagent calls included.
- Schema: `ts`, `harness`, `session`, `tool`, `decision` (allow|deny), `reason`, `path`, `command` (bash only), `offset`/`limit` (read only), `bytes`, `lines`, `threshold_bytes`, `threshold_lines`.
- Reasons — deny: `bytes`|`lines`; allow: `subagent`|`no_input`|`targeted`|`compound`|`verb`|`bounded`|`under_threshold`|`missing`.
- `shunt-report.sh`: records/allowed/blocked totals, decision/reason, harness, tool, top blocked files, top allowed commands (deduped per call). Legacy records without `decision` = deny.

## Decisions

- Subagent calls logged, no measurement.
- Multi-file bash: one record per file arg; stops at the first deny.
- No kill switch, no rotation (README documents purge).
- `missing` distinguishes stat failure from a 0-byte file.
- A grep pattern arg is a file candidate -> `missing` record (pre-existing arg parsing).

## Follow-ups

- ts trims the bash command before checks, sh does not: whitespace-only or edge-newline commands get different reasons (pre-existing).

## Lessons

- Git Bash lacks shellcheck/bun/gitleaks and fails test-pre-commit + test-review-checklist on HEAD; WSL has every gate tool -> run gate-keeper in WSL from the start.
- Implementers tried installing missing tools unprompted (choco failed, pip shellcheck-py succeeded): state "do not install tools" in delegation prompts.
- SendMessage disabled: delta re-reviews need a fresh self-contained reviewer.
- After `/clear`, the session transcript is the newest `~/.claude/projects/<proj>/*.jsonl`, not the id in the task temp dir; `session-tools.sh --cut` keeps records before the instant (no "since").

## Report

Subagents:

- spec-critic | 33516 | 10 | 108s | 0 | 0 | 0 | NEEDS_CLARIFICATION (4 questions resolved with user)
- implementer S3 | 56447 | 32 | 475s | 0 | 0 | 0 | done, 34/34 green
- implementer S2 | 110363 | 34 | 775s | 0 | 0 | 0 | done; node harness 35/35 (bun absent in Git Bash)
- implementer S1 | 47365 | 69 | 1458s | 0 | 0 | 0 | done, 82/82 green
- gate-keeper (Git Bash) | 24788 | 20 | 240s | 0 | 0 | 1 | RED — env (pre-existing test failures, gitleaks missing)
- reviewer | 107825 | 15 | 382s | 0 | 1 | 0 | APPROVE (minor: handleBash complexity, trim parity)
- reviewer (delta isBoundedCommand) | 21141 | 4 | 39s | 0 | 2 | 0 | APPROVE
- gate-keeper (WSL) | 17231 | 13 | 132s | 0 | 0 | 1 | RED — SC2028 test-shunt-report.sh:73
- gate-keeper (WSL) | 16584 | 13 | 122s | 0 | 0 | 0 | GREEN (all keys, no skips)

Orchestrator cost (`session-tools.sh --summary`, session 7e1907d4): main 106 turns, 91.7k output, 8.36M cache reads, 8.64M billed volume.

| thread | calls | errors | flags | tools |
|---|---|---|---|---|
| main | 56 | 2 | 4 | Bash 20, Edit 12, Agent 9, AskUserQuestion 4, Grep 4, Read 3, Write 2, Skill 1, SendMessage 1 |
| implementer (x3) | 135 | 13 | 5 | Bash 87, Read 21, Edit 19, Write 4, Grep 1 |
| gate-keeper (x3) | 46 | 1 | 1 | Bash 36, Read 7 |
| reviewer (x2) | 19 | 0 | 2 | Read 10, Bash 7 |
| spec-critic | 10 | 0 | 0 | Grep 5, Read 4 |
