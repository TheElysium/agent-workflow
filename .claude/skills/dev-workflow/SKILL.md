---
name: dev-workflow
description: Multi-phase development workflow (spec, plan, implement, verify gates, git, multi-agent orchestration) for T1/T2 tasks — substantial features, refactors, or anything touching architecture, auth, DB, or a public API surface. Use when a task is routed T1 or T2 per AGENTS.md task-routing criteria, or when the user asks to "follow the workflow" / "orchestrate this".
---

Multi-phase workflow. The main session is the default orchestrator. Files named below without a path (`gates.md`, `ui.md`, `metrics.md`) sit in the same directory as the SKILL.md file you are reading now (the repo copy, even when reached through the global shim's redirect); read one only when its trigger applies.

## Phase 1 — Understand & Spec

- `git status` before any edit. Uncommitted work belongs to a prior task: land it or ask the user first. A `docs/tasks/<slug>.md` status header that doesn't match the tree = prior session ended without its commit.
- Locate the spec (user message, `docs/`, `*.md` files, issues); extract requirements, acceptance criteria, edge cases, out of scope.
- Non-trivial spec (T1 with new behavior, T2, architectural impact) → `spec-critic` before planning. `NEEDS_CLARIFICATION` → interview the user with its questions.
- Restate the spec (Problem / Solution / Decisions / Out of scope) before any code. File paths stay out of the spec and PRD; `file:line` anchors go in delegation prompts only.
- Ambiguous or missing spec → interview the user, one question at a time, each with your recommended answer. Explore the codebase instead of asking when it holds the answer. Never guess requirements.
- Design check: sketch the modules to build or modify, favoring deep modules (rich behavior behind a small, stable, testable interface); confirm with the user before coding.
- UI slice (new component, template/CSS/markup change) → follow `ui.md`.
- Heavy exploration → `explore` / `bulk-reader`, given a question, not a territory: "where is X computed, and is there more than one implementation?" beats "map the X module".

## Phase 2 — Plan

- 3+ steps → tracked todo list, updated in real time: slices labeled `HITL` (needs a human decision or review) or `AFK` (autonomous; preferred), ordered blockers first. No narrative.
- Vertical slices (tracer bullets): each cuts through every layer and is verifiable on its own. Many thin slices over few thick ones.
- HITL slices: every pure decision or mapping lives in a unit-tested module; only the irreducibly manual part (actor wiring, hardware-in-the-loop) sits outside TDD. Write its manual QA script (click path, expected state, state after undo/delete) before implementing.
- Non-trivial or architectural change → agree on the approach before coding.
- Multi-session task → `docs/tasks/<slug>.md` with spec, decisions, todo state, gate status. Its status header (current slice, commit, next step) is updated in the commit of the slice it describes, never as a follow-up edit.
- Task closure → compress the plan file to its durable outcome (final spec, decisions, lessons) and mark it archived. Never grow a journal.
- Read `metrics.md` once per session, then log each subagent completion per it.

## Phase 3 — Implement

- Evidence-first: no significant change without proof matching the change type:

| Change type | Required proof |
|---|---|
| Business logic, API, parsing, algorithms, services | TDD: red → green → refactor |
| Mechanical refactor, config, migrations, code deletion | Existing suite green + typecheck (behavior unchanged) |
| Pure UI / visual work | Manual-QA script (written before implementing) |
| Prototype / throwaway | Proof form declared explicitly in the spec |
| Review fixes | Edit the test first, watch it fail, then fix (TDD again) |

- Every `implementer` brief names its proof form from the table; a brief without one is an orchestrator defect.
- The orchestrator edits code with Edit/Write. Shell edits (`sed -i`, `awk`, Python splices) only for one-line mechanical changes (rename, single-token substitution); never route around the shunt hook.
- Report a summarized diff (files touched + why), never a code dump.

## Phase 4 — Verify (mandatory gate)

- Two gates, both required before "done": **engineering** (lint, typecheck, build, tests, SAST) run by `gate-keeper`; **intent** (acceptance criteria, edge cases, no out-of-scope change) carried by `reviewer`, whose prompt always includes the spec.
- Gate commands come only from `.gates.yml` at the repo root, never from a list copied into a prompt. Missing file → create it with the user per `gates.md`, before any implementation.
- SAST is non-skippable: a gate-keeper run without it is a failed gate.
- Dispatch `gate-keeper` as its own step after every `implementer` run, even a trivial one; the reviewer or orchestrator never absorbs it.
- A RED on a non-skippable step is decided the first time it appears. A workaround seen in two slices is fixed or recorded as an accepted gap per `gates.md`.
- Relay the gate-keeper table as is, no rephrasing.

## Phase 5 — Git

- One branch per task: `feat/<scope>`, `fix/<scope>`, `chore/<scope>`. Conventional Commits (feat, fix, chore, docs, refactor, test), short, present tense; bullets only when needed.
- Committing without asking is allowed on the task branch.
- Re-run `gate-keeper` after any reviewer-driven fix, before commit. An orchestrator-side check is not a gate.
- Slice end = checkpoint: commit + updated status header. Next slice in a new session: Read the header (`limit: 5`) + `git log --oneline -5`, then only the plan sections it needs (`offset`/`limit`), never the whole file. Long session (e.g. after a compaction) → recommend `/clear` before the next slice.
- Push only when the user explicitly asks. No force-push, no hook bypass, no secrets in commits.

## Multi-agent rules

- Every delegation prompt is self-contained: extracted spec, exact task, `file:line` anchors, stack conventions, acceptance criteria, known environment constraints (toolchain gaps, OS quirks, host-dependent test hazards). Never rely on session context.
- After dispatching, end the turn; never poll with blocking `TaskOutput`.
- Launch independent delegations in one message; `gate-keeper` and `reviewer` run in parallel after implementation.
- Split parallel `implementer` work by estimated workload, not only file ownership.
- Parallel hypothesis testing (2–3 `implementer` designs on throwaway branches): only for irreversible architectural decisions on HITL slices.
- Keep agent definitions stable (favors prompt caching).

### Review

- Every reviewer prompt includes `scripts/review-checklist.sh` output plus the spec. Checklist > ~10 files → parallel `reviewer` shards, one sub-checklist each; a single REQUEST_CHANGES blocks. LLM review never enters `.gates.yml`.
- T2 slice → escalate the reviewer one model tier (per-invocation `model` override), every shard included.
- Commit only after APPROVE + green gates.
- After REQUEST_CHANGES: any undisputed blocker/major, or undisputed findings across 2+ files → fresh `implementer` with them verbatim and proof form "Review fixes", the orchestrator keeping only the verdict and disputed findings; otherwise the orchestrator fixes (e.g. 2 nits in one file). Rebut each disputed finding in one line in the next round; the reviewer rules. Send the corrected diff back to the same reviewer (resume the session when possible).

Flow: spec → decompose → explore (parallel) → implementer (TDD, parallel) → gate-keeper → reviewer → fix/re-review loop → commit (no push) → next todo.
