# Telemetry integrity

## Problem

1. `.usage/shunt.jsonl` holds spliced lines: 6 of 987. `scripts/shunt-report.sh` aborted
   on the first one (`jq: parse error: Invalid literal at line 530, column 1029`), so one
   bad line cost the whole report.
2. Root cause: bash's `printf` builtin writes through stdio, whose buffer is 1024 bytes
   under MSYS. A record above that leaves as several `write()` calls and a concurrent hook
   process splices itself into the gap. Every observed splice sits at byte offset exactly
   1024 (`grep -bo '{"ts":"20'` returns `0:` and `1024:`).
3. Records are only oversized because of `command`: with that field removed, the p99 is
   417 bytes and the max 425 (n=871). 49 of 975 records exceed 1024 bytes; the largest is
   15693. `flock` does not exist in Git Bash, and forking an external writer costs 22.8 ms
   per append versus 0.8 ms for the builtin.
4. No way to switch telemetry off.

## Solution

- Cap the logged `command` (`...[truncated]`) so the encoded record stays under 1000
  bytes and leaves in one `write()`. Every other field is bounded (max 425), so the cap
  is the whole guarantee and concurrency stops mattering. Two caps, because the stdio
  boundary is in bytes and JSON is not: 500 characters first (free for ASCII, and the
  only cost paid by normal commands), then a shrink loop until `utf8bytelength` of the
  encoded record fits. A 500-character cap alone still produced 3224-byte records.
- Readers keep well-formed objects only (`fromjson? | select(type == "object")`) and print
  `skipped: N` unconditionally, including `skipped: 0`.
- Two independent opt-outs: `SHUNT_TELEMETRY` (decisions) and `USAGE_TELEMETRY` (tokens),
  each accepting `0`/`false`/`off`, checked before any `mkdir` so opting out leaves no
  `.usage/` behind and changes no shunt decision.

## Out of scope

Dropped as over-engineering once the size distribution was measured: `mkdir`-based locking
with stale-lock stealing, salvaging records embedded in a spliced line, a `--strict` flag,
and the `usage.meta` high-water-mark race. The cap removes the cause; the rest guarded a
failure mode that can no longer occur.

## Constraints

- Git Bash has no `flock`; hooks never run under WSL, so a WSL-only tool is not an option.
- Forks are expensive on Windows (~28x the builtin) and the hook runs on every Read/Bash.
- Both harnesses (`.claude/` bash, `.opencode/` TypeScript) must stay at parity.

## Evidence

| claim | proof |
|---|---|
| cap keeps records atomic | 8 processes x 12 records of 9 KB through the real hook: 96/96 lines, 0 corrupt, max 723 bytes |
| char cap alone was not enough | through the real hook: control chars 3224 bytes, accents 1224 -> byte-aware fit: 926 / 974 / 724 (ascii) / 228 (short) |
| byte bound holds per codepoint class | `shunt.test.ts` asserts <= 1024 for U+0001, U+00E9, U+1F916; reviewer reproduced `"..." x600 -> 1714` before the fix |
| skipped never goes negative | red `skipped: -1` on a sink with no trailing newline -> green `records: 2`, `skipped: 0` (both reports) |
| cap applied | `test-shunt.sh` red 9215 bytes -> green 723; `shunt.test.ts` red 9220 -> green |
| readers tolerate splices | `test-shunt-report.sh` red `parse error ... column 1029` -> green, `skipped: 6` |
| readers count silently-lost lines | `skipped: 0` asserted on a clean sink in both report tests |
| opt-outs leave no trace | red: sink created for all 3 spellings -> green: no `.usage/`, deny unchanged |
| live sink recovered | `shunt-report.sh` on the real corrupt sink: `records: 987 ... skipped: 6` |

## Progress

- [x] Root cause established (byte-offset forensics, reproduction, latency benchmark)
- [x] Cap + tolerant readers + both opt-outs, bash and TypeScript
- [x] Tests red then green in both harnesses
- [x] README telemetry section
- [x] Gates green (lint/test/sast) after the byte-aware rework
- [x] Review: APPROVE (1 non-blocking nit: no adversarial-unicode test on the bash side)
- [ ] Follow-up: port the control/accent/astral cap tests to test-shunt.sh

## Subagent metrics

| subagent | tokens | tool_uses | duration | retries | review_iterations | gate_failures | outcome |
|---|---|---|---|---|---|---|---|
| bulk-reader | 67200 | 23 | 104s | 0 | - | - | delivered |
| spec-critic | 44483 | 16 | 230s | 0 | - | - | NEEDS_CLARIFICATION, 12 questions |
| implementer x2 | - | - | - | 1 | - | - | failed (session rate limit), work done inline |
| reviewer | - | - | - | 1 | - | - | failed (session rate limit) |
| reviewer (re-run) | - | - | - | 0 | 2 | 0 | REQUEST_CHANGES then APPROVE |
