# Agent effort/model tuning + implementer gate alignment

Status: done, committed on `chore/agent-effort-tuning`, not pushed. APPROVE + green gate (lint, test 57/0, sast). Next step: compress this file to its durable outcome at closure (`SKILL.md:31`), or work the follow-ups below.

## Spec

Three defects in the agent roster config:

1. `spec-critic` and `reviewer` run on sonnet with no `effort` key — pure-judgment, one-shot, small-output agents with no heavy I/O to absorb.
2. `implementer.md` discovers verification commands from package.json/Cargo.toml/Makefile while `.gates.yml` is the declared single source (`SKILL.md:63`). In this repo the instruction is inapplicable: `lint` is a hand-maintained 19-file list and `test` a 9-script `&&` chain — neither is derivable from package.json, and there is no Makefile.
3. The proof form was optional in the delegation brief, so the implementer classified its own change type.

## Decisions

- `effort` is static (no per-call override on the Agent tool); `model` is overridable per invocation. Hence: floor in the file, escalation at dispatch.
- `spec-critic` → opus + `effort: high`. Smallest input (a spec, not a codebase), earliest leverage, adversarial task.
- `reviewer` → `effort: high`, sonnet floor, opus override on T2 slices, every shard when split.
- `implementer` keeps sonnet and gets no effort key: it writes both the tests and the code they validate, so a weakened implementer produces a weakened suite that `gate-keeper` still passes green. The gate cannot structurally catch it.
- No `effort` on the haiku agents (`bulk-reader`, `explore`, `code-writer`, `gate-keeper`): `claude-haiku-4-5` is in the effort-support exclusion list of the Claude Code binary (2.1.276) — it would be a silent no-op.
- `.gates.yml` absent in a target project: the implementer keeps its discovery fallback. Its purpose in reading the file is to not diverge from the standard that will judge it — no file, nothing to diverge from. `gate-keeper`'s strict UNKNOWN does not transfer: that agent only reports gate state, the implementer must execute tests to run red-green.
- Implementer runs `lint`/`typecheck`/`test` only; `build` and `sast` stay in the formal gate-keeper pass.
- Brief without a proof form: auto-classification kept, but announced (`proof form not specified in brief — inferred <form>`) so the brief defect surfaces instead of staying silent.
- Proof form made mandatory as a Phase 3 bullet, not in `SKILL.md:103` — that line is the generic rule for *all* delegations and would impose the field on explore/reviewer/gate-keeper briefs.
- No justification text written into SKILL.md or the agent files (repo writing rule: the why lives in the retrospective).
- Defects 2 and 3 mirrored to `.opencode/agent/implementer.md` — same commit, per repo convention. The effort/model changes are NOT mirrored: opencode tunes with `temperature` and its own model strings, so the Claude-side `effort` key joins `hidden`/`temperature` as an accepted divergence, recorded in the README "Cross-tool sync notes" registry (the durable home — this task file is compressed at closure). Picking opencode model tiers is a separate decision, not taken here.
- `SKILL.md` is shared (opencode discovers `.claude/skills/*/SKILL.md` natively), so the reviewer-escalation rule is worded harness-neutral ("one model tier"), not "opus".
- SAST removed from `implementer.md` rather than kept alongside the new "`sast` belongs to the gate-keeper pass" line: `gate-keeper` is dispatched after every implementer run (`SKILL.md:84`), so an implementer-side SAST run is pure duplication.

## Evidence

Config/instruction change, no executable code → existing suite green (Phase 3 table, mechanical row).

Effort support verified statically against the binary (2.1.276), not measured at runtime:
- `effort` is in the agent-file frontmatter key allowlist and validated (`Agent file <x> has invalid effort '<v>'. Valid options: low, medium, high, xhigh, max — or an integer`).
- The effort-support exclusion list contains `claude-3-*`, `claude-opus-4-0`, `claude-opus-4-1`, `claude-sonnet-4-0`, `claude-sonnet-4-5`, `claude-haiku-4-5` — opus-5 and sonnet-5 are not in it.
- Not proven: that the parsed value reaches the subagent's API request. Would need request-level observation.

## Subagent log

`subagent | tokens | tool_uses | duration | retries | review_iterations | gate_failures | outcome`

- `spec-critic` | 46581 | 10 | 220s | 0 | 0 | 0 | NEEDS_CLARIFICATION (5 questions; 2 resolved by the orchestrator, 1 dissolved by re-examining the premise, 2 answered by the user)
- `gate-keeper` | 13977 | 5 | 97s | 0 | 0 | 0 | GREEN (lint, test, sast)
- `reviewer` (opus) | 36352 | 13 | 135s | 0 | 1 | 0 | REQUEST_CHANGES — 3 major: opencode mirror not updated, absent-`.gates.yml`-key substitution risk after the "never invent" guard was narrowed, SAST self-contradiction inside implementer.md
- `gate-keeper` | 13867 | 5 | 102s | 0 | 0 | 0 | GREEN (lint, test, sast) — after the review fixes
- `reviewer` (opus, fresh session, delta-scoped) | 33659 | 9 | 110s | 0 | 2 | 0 | APPROVE — 3 major verified fixed, 1 minor (README divergence registry) + 4 nits
- `gate-keeper` | 13436 | 5 | 98s | 0 | 0 | 0 | GREEN (lint, test 57/0, sast) — after the README minor fix

## Follow-ups

- Measure whether the opus reviewer is cost-negative per mergeable change: compare `review_iterations` on the next T2 tasks against the lines already logged. Out of scope here.
- `SKILL.md:55` still carries "Run SAST when available" in Phase 3 while SAST is now gate-keeper-only for the implementer. It reads as phase-level guidance cross-referencing Phase 4, not an implementer instruction, so it was left alone — worth re-reading on the next SKILL.md pass.
- A proof-form component with no matching `.gates.yml` key (here: `typecheck` on the mechanical row) silently degrades the proof. No rule requires the implementer to flag it. Candidate addition: "a proof-form component with no key is reported absent".
- `SKILL.md:119` assumes a per-invocation `model` override; the opencode side documents none (README "Cross-tool sync notes"). Probably inert there — confirm on the next opencode run.
- The SAST-removal rationale (gate-keeper runs after every implementer run → duplication) would apply verbatim to `lint`, which the implementer still runs locally. The real distinction — red-green needs the tests executed, lint findings are fixed in place — is not written down anywhere.
