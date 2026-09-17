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

Orchestrator cost (`session-tools.sh --summary`, whole session file incl. pre-task PR #9 merge; `--cut` had no effect): main 221 turns, 191.5k output, 15.44M cache reads, 16.47M billed volume.

| thread | calls | errors | flags | tools |
|---|---|---|---|---|
| main | 115 | 1 | 14 | Bash 42, Edit 35, Agent 11, Read 9, Grep 8, Write 6, Skill 2, Glob 1, ToolSearch 1 |
| gate-keeper | 47 | 4 | 1 | Bash 34, Read 7 |
| reviewer | 35 | 0 | 4 | Read 16, Bash 11, Grep 3 |
