# Token routing (shunt pattern)

The primary model is expensive. Delegate I/O-heavy work to cheap subagents instead of reading or writing large amounts of content yourself.

## When to delegate

- **bulk-reader** — whenever answering a question requires reading more than one large file (>350 lines or >64 KB, e.g. minified JSON, Grafana dashboard JSON, big config files), mapping a module's structure, or tracing call flows. Delegate with a targeted question; you only consume the summary. Never write Python/bash scripts to parse structured data.
- **code-writer** — test files, config scaffolding, type stubs, anything predictable from existing patterns. Give it a spec, a reference file to match style against, and a target path. It writes directly to disk.

## When NOT to delegate

- Targeted reads where you already know the exact section (offset/limit) — just read it.
- Editing existing code based on analysis — delegate for understanding, then make the targeted read and edit yourself.
- Debugging, architectural decisions, subtle bugs (concurrency, safety) — reasoning stays on the primary model.
- Small reads/writes where delegation round-trip overhead exceeds the savings.

# Development workflow

Multi-phase workflow applied to every project. The main session (the `build` agent in opencode) is the default orchestrator. Two operating modes:
- **Interactive**: small tasks, quick fixes, questions — act directly, no delegation ceremony.
- **Orchestrated**: substantial tasks — decompose, delegate, verify, review (parallelizable work, peer review, heavy I/O).

## Phase 1 — Understand & Spec

- Locate the spec: user message, `docs/`, `*.md` files, or issues.
- Extract: requirements, acceptance criteria, edge cases, explicit out-of-scope.
- Restate the spec in the plan before writing any code (problem, solution, implementation decisions, out of scope). Do not hardcode file paths in the spec or PRD — keep them at the `file:line` level in delegation prompts only.
- If the spec is ambiguous, incomplete, or missing → interview the user, one question at a time, each with your recommended answer. If a question can be answered by exploring the codebase, explore instead of asking. Never guess requirements.
- Design check: sketch the modules to build or modify. Favor deep modules (rich functionality behind a small, stable, testable interface); confirm the sketch with the user before coding.
- Delegate heavy codebase exploration to `explore` / `bulk-reader`. Give `explore` a question, not a territory: "where is X computed today, and is there more than one implementation?" beats "map the X module".

**Output format**: the restated spec as short structured prose (Problem / Solution / Decisions / Out of scope); interview questions one at a time, each with the recommended answer.

## Phase 2 — Plan

- Any task with 3+ steps → maintain a tracked todo list, kept up to date in real time.
- Decompose into vertical slices (tracer bullets): each slice cuts through every layer end-to-end and is demoable or verifiable on its own. Prefer many thin slices over few thick ones.
- Classify each slice: `HITL` (needs a human decision or review) or `AFK` (implementable and mergeable autonomously). Prefer AFK.
- HITL slices: split so every pure decision or mapping lives in a unit-tested module; only the irreducibly manual part (actor wiring, hardware-in-the-loop) sits outside TDD. Write the manual QA script (exact click path, expected state, expected state after undo/delete) before implementing, not after.
- Order slices by dependency (blockers first).
- For non-trivial or architectural changes, propose the approach and get agreement before coding.
- Persist the plan: for tasks spanning multiple sessions, create `docs/tasks/<slug>.md` with the extracted spec, decisions, todo state, and gate status. Sessions read it before resuming. The status header (current slice, commit, next step) is updated in the same commit as the slice it describes — never as a follow-up edit.
- Log subagent metrics (tokens / tool_uses / duration) as a line in `docs/tasks/<slug>.md` at each subagent's completion — every subagent, every round, gate-keeper and re-review included. Conversation compaction erases them; the plan file is the only durable record.

**Output format**: a tracked todo list (todo tool), slices with `HITL`/`AFK` labels and dependency order — no narrative paragraph.

## Phase 3 — Implement

- TDD is mandatory: red-green-refactor. No production code without a test that demands it.
- Lint: follow the project's configured linter; if none, apply a strict default for the stack (e.g. `clippy -D warnings`, `ruff --strict`, `eslint` strict) and tell the user.
- Cyclomatic complexity: target ≤ 10 per function. Above the threshold → refactor or explicitly justify.
- Apply the stack's formatter.
- Run SAST when available; if the tool is missing, propose installing it (never skip silently — see Phase 4).

**Output format**: a summarized diff (files touched + why), never a full code dump in the reply — the code lives in the files.

## Phase 4 — Verify (mandatory gate)

- Gate: lint + typecheck + build + tests + SAST must pass before a task is done.
- Commands come from the project's `.gates.yml` at the repo root (see below). If it is missing, creating it with the user is the first action of the session — before implementation, not at the first gate run. Never run gates from a command list hand-copied into prompts.
- SAST is non-skippable: at minimum `gitleaks` (secrets) plus the stack's audit tool. A gate-keeper run that skipped SAST is a failed gate.
- A task with a failing gate is never "done".

### `.gates.yml` convention

At the repo root of every project:

```yaml
stack: rust                      # free-form: rust | go | node | python | tauri...
lint: cargo clippy -- -D warnings
typecheck: cargo check
build: cargo build
test: cargo test
sast: cargo audit && gitleaks detect
format: cargo fmt --check        # optional
```

- `gate-keeper` reads it verbatim, runs each key, and reports a structured pass/fail per command (never interprets results).
- Accepted gaps are recorded in `.gates.yml` itself, as a dated comment on the affected key (`# gitleaks not installed — gap accepted 2026-09-14`). A RED on a non-skippable step is surfaced and decided the first time it appears; a workaround repeated across two slices is fixed or recorded as an accepted gap — never carried as a habit.
- Local enforcement is the default: gates run before a task is done and before commit — no CI needed. CI is optional, only for projects whose CI you control (copy `templates/ci-gates.yml` from agent-workflow as `.github/workflows/ci.yml`, keep it in sync with `.gates.yml`).
- Dispatch `gate-keeper` as its own explicit step after every `implementer` run, even for a slice that looks trivial — never let the `reviewer` or the orchestrator absorb the gate run informally.
- UI/visual work that no automated gate can catch → an explicit manual-QA todo item (e.g. "run the app, click through X"), never implicit. An open manual-QA item on a surface blocks starting the next slice that builds on that same surface.

**Output format**: a structured pass/fail table per `.gates.yml` command, with no interpretation or rephrasing.

## Phase 5 — Git

- One branch per task: `feat/<scope>`, `fix/<scope>`, `chore/<scope>`.
- Conventional Commits (feat, fix, chore, docs, refactor, test) — short, present tense.
- Committing without asking is allowed (on the task branch).
- Push only when the user explicitly asks (a permission prompt will confirm). No force-push, no hook bypass, no secrets in commits.

**Output format**: the commit message in strict Conventional Commits, one summary line plus short bullets when needed.

## Multi-agent rules

- Subagents start with a fresh context: every delegation prompt must be self-contained (extracted spec, exact task, `file:line` anchors, stack conventions, acceptance criteria). Never rely on session context.
- Subagent outputs: structured bullets only, no file dumps.
- Launch independent delegations in the same message to parallelize. `gate-keeper` and `reviewer` are both read-only on the same tree — dispatch them in parallel after implementation.
- When splitting parallel `implementer` work, balance by estimated workload, not only file ownership — an uneven split keeps the critical path as long as the heaviest task.
- Keep agent definitions stable (favors prompt caching).

### Agent roster

- `implementer` — substantial coding in strict TDD; parallelize on independent tasks.
- `gate-keeper` — verification commands only; after every implementation.
- `reviewer` — read-only peer review of the diff; its distinctive catch is cross-layer inconsistency no gate can catch. Commit only after APPROVE + green gates.
- `explore`, `bulk-reader` — phase 1 exploration.
- `code-writer` — test scaffolding and repetitive code matching existing patterns.
- Re-review loop: after REQUEST_CHANGES, fix everything, then send the corrected diff back to the same reviewer (resume the session when possible). A commit requires a final APPROVE on the latest diff — an old APPROVE never carries over; gates stay green between rounds. Review fixes go through TDD too: edit the test first, watch it fail, then change the implementation.

Flow for a substantial task: spec → decompose → explore (parallel) → implementer (TDD, parallel) → gate-keeper → reviewer → fix/re-review loop → commit (no push) → next todo.

## Project init hygiene

- At the start of any new project (before the first commit), add `templates/gitignore-claude-local.txt` from agent-workflow to the project's `.gitignore` — `.claude/settings.local.json` / `.opencode/settings.local.json` are machine-local and must never be committed.

## Writing rules

One rule = imperative + minimal example. No origin stories, no justifying narratives — the why lives in the retrospective, not here.
