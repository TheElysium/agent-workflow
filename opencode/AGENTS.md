# Token routing (shunt pattern)

The primary model is expensive. Delegate I/O-heavy work to cheap subagents instead of reading or writing large amounts of content yourself.

## When to delegate

- **bulk-reader** — whenever answering a question requires reading more than one large file (>350 lines or >64 KB, e.g. minified JSON), mapping a module's structure, or tracing call flows. Delegate instead of reading the files yourself; you only consume the summary.
- **bulk-reader for structured data** — Grafana dashboard JSON, exports, big config files: do NOT write Python/bash scripts to parse them, and do NOT read them yourself. Delegate to bulk-reader with a targeted question ("list all panel queries, datasources and variables in these dashboards") — the worker parses the JSON and returns structured bullets.
- **code-writer** — for test files, config scaffolding, type stubs, and anything predictable from existing patterns. Give it a spec, a reference file to match style against, and a target path. It writes directly to disk; you never see the generated code.

## When NOT to delegate

- Targeted reads where you already know the exact section (offset/limit) — just read it.
- Editing existing code based on analysis — delegate for understanding, then make the targeted read and edit yourself.
- Debugging, architectural decisions, subtle bugs (concurrency, safety) — reasoning stays on the primary model.
- Small reads/writes where delegation round-trip overhead exceeds the savings.

# Development workflow

Multi-phase workflow applied to every project. The main session (the `build` agent in opencode) is the default orchestrator. Two operating modes:
- **Interactive**: small tasks, quick fixes, questions — act directly, no delegation ceremony.
- **Orchestrated**: substantial tasks — decompose, delegate, verify, review (parallelizable work, peer review, heavy I/O).

Never add ceremony for micro-tasks.

## Phase 1 — Understand & Spec

- Locate the spec: user message, `docs/`, `*.md` files, or issues.
- Extract: requirements, acceptance criteria, edge cases, explicit out-of-scope.
- Restate the spec in the plan before writing any code (problem, solution, implementation decisions, out of scope). Do not hardcode file paths in the spec or PRD — they go stale fast; keep them at the `file:line` level in delegation prompts only.
- If the spec is ambiguous, incomplete, or missing → interview the user relentlessly, one question at a time, each with your recommended answer, walking the decision tree until shared understanding. If a question can be answered by exploring the codebase, explore instead of asking. Never guess requirements.
- Design check: sketch the modules to build or modify. Favor deep modules (rich functionality behind a small, stable, testable interface) over shallow ones; confirm the module sketch with the user before coding.
- Delegate heavy codebase exploration to `explore` / `bulk-reader`; do not read large files yourself.

**Output format**: the restated spec as short structured prose (Problem / Solution / Decisions / Out of scope); interview questions one at a time, each with the recommended answer.

## Phase 2 — Plan

- Any task with 3+ steps → maintain a tracked todo list, kept up to date in real time.
- Decompose into vertical slices (tracer bullets): each slice cuts through every layer end-to-end (schema, API, UI, tests) and is demoable or verifiable on its own — never a horizontal slice of one layer. Prefer many thin slices over few thick ones.
- Classify each slice: `HITL` (needs a human decision or review) or `AFK` (implementable and mergeable autonomously). Prefer AFK.
- Order slices by dependency (blockers first).
- For non-trivial or architectural changes, propose the approach and get agreement before coding.
- Persist the plan: for tasks spanning multiple sessions, create `docs/tasks/<slug>.md` in the project with the extracted spec, decisions, todo state, and gate status — the orchestrator updates it as work progresses. Sessions read it before resuming.
- Log subagent metrics (tokens / tool_uses / duration) as a line in `docs/tasks/<slug>.md` right when each subagent completes, not only kept in conversation context — conversation compaction erases them, and a plan file is the only durable record for later cost/latency review.

**Output format**: a tracked todo list (todo tool), slices listed with their `HITL`/`AFK` label and their dependency order — no narrative paragraph.

## Phase 3 — Implement

- TDD is mandatory: red-green-refactor. Write the failing test first, minimal implementation, then refactor. No production code without a test that demands it.
- Lint: follow the project's configured linter. If none is configured, apply a strict default for the stack (e.g. `clippy -D warnings`, `ruff --strict`, `eslint` strict) and tell the user.
- Cyclomatic complexity: target ≤ 10 per function (lizard, radon, gocyclo, clippy cognitive complexity). Above the threshold → refactor or explicitly justify.
- Apply the stack's formatter.
- Run SAST tooling when available (cargo clippy/audit, npm audit, semgrep, gitleaks, gosec...). If the tool is not installed, propose installing it — never skip silently.

**Output format**: a summarized diff (files touched + why), never a full code dump in the reply — the code lives in the files.

## Phase 4 — Verify (mandatory gate)

- Gate: lint + typecheck + build + tests + SAST must pass before a task is done.
- Commands come from the project's `.gates.yml` at the repo root (see below). If it is missing, build it with the user before running any gate — never discover-and-hope, never invent.
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
- Missing file → gate-keeper must ask the user for each command and offer to write the file.
- Local enforcement is the default: gates are enforced by `gate-keeper` before a task is done and before commit — no CI needed. Adding the CI layer is optional and only for projects whose CI you control (copy `templates/ci-gates.yml` from agent-workflow as `.github/workflows/ci.yml`, keep it in sync with `.gates.yml`).
- Dispatch `gate-keeper` as its own explicit step after every `implementer` run, even for a slice that looks trivial — never let the `reviewer` or the orchestrator absorb the gate run informally. A dedicated gate-keeper dispatch costs ~15-20k tokens and a minute; a correction found late by the reviewer costs more.
- When a slice is UI/visual work (CSS, layout, positioning) that no automated gate can catch, add an explicit manual-QA todo item (e.g. "run the app, click through X") instead of leaving verification implicit — it must show up as a pending item, not be silently skipped.

**Output format**: a structured pass/fail table per `.gates.yml` command, with no interpretation or rephrasing of the results.

## Phase 5 — Git

- One branch per task: `feat/<scope>`, `fix/<scope>`, `chore/<scope>`.
- Conventional Commits (feat, fix, chore, docs, refactor, test) — short, present tense.
- Committing without asking is allowed (on the task branch).
- Push only when the user explicitly asks for it (a permission prompt will confirm). No force-push, no hook bypass, no secrets in commits.

**Output format**: the commit message in strict Conventional Commits, one summary line followed by short bullets when needed — no recap outside the message itself.

## Multi-agent rules

- Subagents start with a fresh context: every delegation prompt must be self-contained (extracted spec, exact task, `file:line` anchors, stack conventions, acceptance criteria). Never rely on session context.
- Subagent outputs: structured bullets only, no file dumps.
- Launch independent delegations in the same message to parallelize.
- When splitting parallel `implementer` work, balance by estimated workload (e.g. backend + bindings + one UI surface vs. a second UI surface alone can be lopsided), not only by file-ownership independence — an uneven split keeps the critical path as long as the heaviest task even though the work looks parallelized.
- Keep agent definitions stable (favors prompt caching).

### Agent roster

- `implementer` — writes code in strict TDD for a given task. Use for substantial coding work, in parallel when tasks are independent.
- `gate-keeper` — runs verification commands only (lint/typecheck/build/tests/SAST), reports structured pass/fail. Use after implementation.
- `reviewer` — read-only peer review of the diff (correctness, security, complexity, style, TDD compliance). Commit only after APPROVE + green gates.
- `explore`, `bulk-reader` — phase 1 exploration.
- `code-writer` — test scaffolding and repetitive code matching existing patterns.
- Re-review loop: after REQUEST_CHANGES, fix everything, then send the corrected diff back to the same reviewer (resume the session when possible). A commit requires a final APPROVE on the latest diff — an old APPROVE never carries over. Gates stay green between rounds.

Flow for a substantial task: spec → decompose → explore (parallel) → implementer (TDD, parallel) → gate-keeper → reviewer → fix/re-review loop → commit (no push) → next todo.

## Project init hygiene

- At the start of any new project (before the first commit), add `templates/gitignore-claude-local.txt` from agent-workflow to the project's `.gitignore` — `.claude/settings.local.json` / `.opencode/settings.local.json` are machine-local and must never be committed.

## Per-project overrides

To adapt an agent to a stack (e.g. Rust for a Tauri project), place a same-name/id file in the project:
- Claude Code: `.claude/agents/<name>.md`
- opencode: `.opencode/agent/<id>.md` (definitions merge: scalar fields replaced, permission rules appended)

The global definition is the base; the project file only adds stack specifics.
