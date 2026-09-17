import type { Plugin } from "@opencode-ai/plugin"
import * as path from "node:path"
import { mkdirSync, statSync } from "node:fs"
import { appendFile as appendFileAsync } from "node:fs/promises"

// Session IDs of subagent runs (child sessions) — their reads always pass.
const DELEGATED_MAX = 4096
const delegated = new Set<string>()

const BLOCKED_BASH = /^(cat|head|tail|less|more|bat|grep|sed|awk|rg|xxd|base64|strings)(?=\s|$)/

function minLines(): number {
  const v = Number(process.env.SHUNT_MIN_LINES)
  return Number.isFinite(v) && v > 0 ? v : 350
}

function maxBytes(): number {
  const v = Number(process.env.SHUNT_MAX_BYTES)
  return Number.isFinite(v) && v > 0 ? v : 65_536
}

// `null` means stat failed (missing/unreadable path); distinct from an
// actual 0-byte file so callers/logging can tell "missing" from "empty".
function byteSize(p: string): number | null {
  try {
    return statSync(p).size
  } catch {
    return null
  }
}

async function lineCount(p: string): Promise<number> {
  try {
    const text = await Bun.file(p).text()
    return text.split("\n").length
  } catch {
    return 0
  }
}

function isTargeted(args: { offset?: unknown; limit?: unknown }): boolean {
  // A targeted read requires BOTH offset and limit. `0` counts as present for
  // both fields; `false` and `""` count as absent (matches shunt.sh jq
  // extraction + [ -n ... ] test). limit alone can equal the default full-read
  // size, and an offset alone reads the unbounded rest of the file — neither
  // is targeted.
  const present = (v: unknown) => v != null && v !== false && v !== ""
  return present(args.offset) && present(args.limit)
}

type Hit = { big: boolean; bytes: number | null; lines: number | null }

async function isOversized(p: string, threshold: number): Promise<Hit> {
  const bytes = byteSize(p)
  // Stat failure (nonexistent/unreadable path): never treat as oversized.
  if (bytes === null) return { big: false, bytes: null, lines: null }
  // Size check first: avoid reading the whole file just to count lines (slow on /mnt/c).
  if (bytes > maxBytes()) return { big: true, bytes, lines: null }
  if (bytes === 0) return { big: false, bytes, lines: null }
  const lines = await lineCount(p)
  return { big: lines > threshold, bytes, lines }
}

// Maps a measured Hit to the (decision, reason) pair logged for it. Decisions
// are unchanged from before this instrumentation — only the labeling is new.
function classify(hit: Hit): { decision: "allow" | "deny"; reason: string } {
  if (hit.bytes === null) return { decision: "allow", reason: "missing" }
  if (hit.big) return { decision: "deny", reason: hit.lines != null ? "lines" : "bytes" }
  return { decision: "allow", reason: "under_threshold" }
}

function redirectMsg(p: string, hit: { bytes: number | null; lines: number | null }, threshold: number): string {
  const why = hit.lines != null
    ? `${hit.lines} lines (threshold: ${threshold})`
    : `${((hit.bytes ?? 0) / 1024).toFixed(0)} KB (threshold: ${maxBytes() / 1024} KB)`
  return [
    `BLOCKED by shunt: "${p}" has ${why}.`,
    `Do NOT read this file directly — delegate I/O instead:`,
    `  - For analysis/questions across files (incl. minified JSON like Grafana dashboards): use the task tool with subagent "bulk-reader" (pass file paths + your question; you only consume the summary).`,
    `  - For boilerplate generation: use the task tool with subagent "code-writer" (pass spec + reference file + target path).`,
    `  - If you must edit a specific section of this file, do a targeted read with BOTH offset and limit (an offset alone reads the unbounded rest of the file) — that is allowed.`,
  ].join("\n")
}

type LogFields = {
  sessionID: string
  tool: "read" | "bash"
  decision: "allow" | "deny"
  reason: string
  path: string | null
  threshold: number
  bytes?: number | null
  lines?: number | null
  command?: string
  offset?: unknown
  limit?: unknown
}

// Single sink writer for every decision (allow and deny). Best-effort: a
// logging failure must never affect the decision already made by the caller.
async function logDecision(sinkPath: string, fields: LogFields): Promise<void> {
  try {
    const rec: Record<string, unknown> = {
      ts: new Date().toISOString(),
      harness: "opencode",
      session: fields.sessionID,
      tool: fields.tool,
      decision: fields.decision,
      reason: fields.reason,
      path: fields.path,
      bytes: fields.bytes ?? null,
      lines: fields.lines ?? null,
      threshold_bytes: maxBytes(),
      threshold_lines: fields.threshold,
    }
    if (fields.tool === "bash") rec.command = fields.command ?? ""
    if (fields.tool === "read") {
      rec.offset = fields.offset ?? null
      rec.limit = fields.limit ?? null
    }
    await appendFileAsync(sinkPath, JSON.stringify(rec) + "\n")
  } catch {
    // instrumentation must never block the redirect behavior
  }
}

function stripQuotes(a: string): string {
  if (a.length < 2) return a
  if ((a.startsWith('"') && a.endsWith('"')) || (a.startsWith("'") && a.endsWith("'"))) {
    return a.slice(1, -1)
  }
  return a
}

function isBoundedSed(args: string[]): boolean {
  let hasN = false
  for (const a of args) {
    if (a === "-n" || a === "--quiet" || a === "--silent") hasN = true
    const stripped = stripQuotes(a)
    // Any '$' in a script means read to EOF — unbounded.
    if (stripped.includes("$")) return false
  }
  if (!hasN) return false
  for (const a of args) {
    const stripped = stripQuotes(a)
    if (/^[0-9]+(,[0-9]+)?p$/.test(stripped)) return true
  }
  return false
}

function isBoundedHeadTail(args: string[]): boolean {
  let expectNum = false
  for (const a of args) {
    if (expectNum) {
      return /^[0-9]+$/.test(a)
    }
    if (a === "-n" || a === "-c") {
      expectNum = true
      continue
    }
    const merged = a.match(/^-(n|c)([0-9]+)$/)
    if (merged) return true
  }
  return false
}

function isBoundedCommand(verb: string, args: string[]): boolean {
  if (verb === "sed") return isBoundedSed(args)
  if (verb === "head" || verb === "tail") return isBoundedHeadTail(args)
  return false
}

export const ShuntPlugin: Plugin = async ({ directory, worktree }) => {
  const sinkDir = path.join(worktree ?? directory ?? ".", ".usage")
  try {
    mkdirSync(sinkDir, { recursive: true })
  } catch {
    // instrumentation must never break the harness init
  }
  const sinkPath = path.join(sinkDir, "shunt.jsonl")

  // Subagent (delegated) calls always allow, but still get one telemetry
  // record each — no measurement is performed for them.
  async function logSubagent(
    sessionID: string,
    tool: "read" | "bash",
    args: unknown,
    threshold: number,
  ): Promise<void> {
    if (tool === "read") {
      const readArgs = args as { filePath?: string; offset?: unknown; limit?: unknown } | undefined
      const p = readArgs?.filePath ? path.resolve(directory, readArgs.filePath) : null
      await logDecision(sinkPath, {
        sessionID, tool: "read", decision: "allow", reason: "subagent", path: p,
        offset: readArgs?.offset, limit: readArgs?.limit, threshold,
      })
      return
    }
    const bashArgs = args as { command?: string } | undefined
    await logDecision(sinkPath, {
      sessionID, tool: "bash", decision: "allow", reason: "subagent", path: null,
      command: bashArgs?.command ?? "", threshold,
    })
  }

  async function handleRead(
    sessionID: string,
    args: { filePath?: string; offset?: unknown; limit?: unknown },
    threshold: number,
  ): Promise<void> {
    if (!args?.filePath) {
      await logDecision(sinkPath, {
        sessionID, tool: "read", decision: "allow", reason: "no_input", path: null,
        offset: args?.offset, limit: args?.limit, threshold,
      })
      return
    }
    const p = path.resolve(directory, args.filePath)
    if (isTargeted(args)) {
      await logDecision(sinkPath, {
        sessionID, tool: "read", decision: "allow", reason: "targeted", path: p,
        offset: args.offset, limit: args.limit, threshold,
      })
      return
    }
    const hit = await isOversized(p, threshold)
    const { decision, reason } = classify(hit)
    await logDecision(sinkPath, {
      sessionID, tool: "read", decision, reason, path: p,
      offset: args.offset, limit: args.limit, bytes: hit.bytes, lines: hit.lines, threshold,
    })
    if (decision === "deny") throw new Error(redirectMsg(p, hit, threshold))
  }

  async function handleBash(
    sessionID: string,
    args: { command?: string },
    threshold: number,
  ): Promise<void> {
    const rawCmd = args?.command ?? ""
    const cmd = rawCmd.trim()
    const allow = (reason: string, path: string | null = null) =>
      logDecision(sinkPath, { sessionID, tool: "bash", decision: "allow", reason, path, command: rawCmd, threshold })

    // Contract for Bash commands:
    //   (a) Compound commands (pipes, redirections, ; & backticks, or newlines)
    //       pass untouched — we do NOT try to parse them.
    //   (b) Verbs outside the whitelist (python, jq, git show, node, perl...)
    //       are never size-checked.
    //   (c) Accepted gap: a piped `sed -n 400,562p | grep` still passes via (a).
    //       A single bounded read (sed -n N,Mp, head -n N, tail -n N, head/tail -c N)
    //       is treated as targeted and skips the size check entirely.
    if (!cmd) return allow("no_input")
    if (/[|>;`&]/.test(cmd) || cmd.includes("\n")) return allow("compound")
    const verbMatch = cmd.match(BLOCKED_BASH)
    if (!verbMatch) return allow("verb")
    const verb = verbMatch[1]
    const cmdArgs = cmd
      .slice(verbMatch[0].length)
      .trim()
      .split(/\s+/)
      .filter(Boolean)

    // Single-command bounded reads are targeted: the explicit window bounds
    // the read, so we skip the size check. Caveat: `head -c N` on a 70 KB
    // single-line file still transfers N bytes of that file; that is accepted
    // because it is explicitly bounded.
    if (isBoundedCommand(verb, cmdArgs)) return allow("bounded")

    const files = cmdArgs.filter((a) => a && !a.startsWith("-"))
    if (files.length === 0) return allow("no_input")

    for (const f of files) {
      const p = path.resolve(directory, f)
      const hit = await isOversized(p, threshold)
      const { decision, reason } = classify(hit)
      await logDecision(sinkPath, {
        sessionID, tool: "bash", decision, reason, path: p, command: rawCmd,
        bytes: hit.bytes, lines: hit.lines, threshold,
      })
      if (decision === "deny") throw new Error(redirectMsg(p, hit, threshold))
    }
  }

  return {
    event: async ({ event }) => {
      const info = (event as { properties?: { info?: { id?: string; parentID?: string } } })
        .properties?.info
      if (info?.id && info.parentID) {
        // Bound the set so long-lived processes don't leak memory.
        if (delegated.size >= DELEGATED_MAX) delegated.clear()
        delegated.add(info.id)
      }
    },

    "tool.execute.before": async (input, output) => {
      const threshold = minLines()

      // Never block subagent reads/bash — they are the worker. Still logged.
      if (delegated.has(input.sessionID)) {
        if (input.tool === "read" || input.tool === "bash") {
          await logSubagent(input.sessionID, input.tool, output.args, threshold)
        }
        return
      }

      if (input.tool === "read") {
        return handleRead(input.sessionID, output.args as { filePath?: string; offset?: unknown; limit?: unknown }, threshold)
      }

      if (input.tool === "bash") {
        return handleBash(input.sessionID, output.args as { command?: string }, threshold)
      }
    },
  }
}
