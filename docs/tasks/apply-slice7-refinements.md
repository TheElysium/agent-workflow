# Apply slice-7 refinements

Status: Lot A in progress. Source: opencycling `docs/tasks/slice-7-workflow-report.md` §6 (verified against raw TSVs on 2026-09-16). 3/16 refinements were already applied (anchors chain, review-checklist, gitleaks); 13 remain.

## Spec

Problem: without the refinements, slice-7 frictions repeat on the next UI slice (throwaway design round, missed re-gate, silent gate deviation, unbounded shunt bypasses).

Solution: 3 sequential batches on branch `chore/apply-slice7-refinements`.

## Decisions (fixed after spec-critic round — 15 questions resolved)

Batch A — doc (SKILL.md, gate-keeper.md, reviewer.md, spec-critic.md): A1 visual target + spec-critic trigger; A2 UI order (reviewer after screenshot iterations; amend parallel rule ~:100; one round per iteration, fix/re-review loop still governs); A3 design-iteration routing by size; A4 re-gate in Phase 5 Git; A5 gate-keeper Bash-only + never-narrow (no variant/subset, e.g. no `| head`, no `--lib`); A6 reviewer no gate re-runs, Read not sed/cat; A7 delta-scoped re-review when prompt certifies resume unavailable + confined fix, reviewer escalates to full if delta touches tested behavior; A8 orchestrator Edit/Write only, shell edits for one-line mechanical changes only; A9 batch each log update into ONE write; A10 no blocking TaskOutput — hand-back arrives as message, end the turn; A11 reports include orchestrator cost + per-thread tool usage sections.

Batch B — shunt (shunt.sh + test-shunt.sh + shunt.ts + shunt.test.ts), TDD, tests flipped first:
- B1 Read passes only with offset AND limit both non-empty (offset=0 counts; limit=0 counts as "0" — noted in comment). Tests flipped: test-shunt.sh:92 pass→deny.
- B2 single-command bounded reads pass before size check: `sed -n 'A,Bp'` numeric-only (quotes/spaces optional, multiple file args, per-file window), `head -n N`, `head -c N`, `tail -n N`. Deny: `$`-anchored ranges (`sed -n '100,$p'`), `tail -n +N`, sed without `-n`, plain head/tail (implicit bound). `$` removed from the compound-exemption char class so `$`-ranges no longer slip through. Bounded pass skips byte/line size check (fat-single-line caveat documented).
- B3 compound exemption + uncovered verbs (python/jq/git show) documented as contract in hook comments and tests. Accepted: piped `sed -n 400,562p | grep` still passes (exemption stays).

Batch C — `scripts/session-tools.sh` + `test-session-tools.sh`, registered in .gates.yml (lint + test). CLI: `session-tools.sh <session.jsonl> [--thread label] [--cut ts] [--subagents dir]`; JSONL slurped to array before jq; outputs per-thread tool counts, TSV command log, ERROR/FLAG statuses (regex from opencycling jq), per-subagent token usage from `subagents/*.jsonl`. Fixtures: sanitized real lines from `~/.claude/projects/C--Users-lukas-Documents-Projets-opencycling/4b6f560a-db03-4293-85e7-58e3f474ffce{,.jsonl,/subagents/agent-a34d390284502049a.jsonl}`.

Out of scope: opencycling repo, push, new agents, sast/CI changes.

## Subagent log

(append one line per subagent completion)
