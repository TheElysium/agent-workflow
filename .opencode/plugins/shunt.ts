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

function byteSize(p: string): number {
  try {
    return statSync(p).size
  } catch {
    return 0
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

async function isOversized(p: string, threshold: number): Promise<{ big: boolean; bytes: number; lines: number | null }> {
  const bytes = byteSize(p)
  // Size check first: avoid reading the whole file just to count lines (slow on /mnt/c).
  if (bytes > maxBytes()) return { big: true, bytes, lines: null }
  if (bytes === 0) return { big: false, bytes, lines: null }
  const lines = await lineCount(p)
  return { big: lines > threshold, bytes, lines }
}

function redirectMsg(p: string, hit: { bytes: number; lines: number | null }, threshold: number): string {
  const why = hit.lines != null
    ? `${hit.lines} lines (threshold: ${threshold})`
    : `${(hit.bytes / 1024).toFixed(0)} KB (threshold: ${maxBytes() / 1024} KB)`
  return [
    `BLOCKED by shunt: "${p}" has ${why}.`,
    `Do NOT read this file directly — delegate I/O instead:`,
    `  - For analysis/questions across files (incl. minified JSON like Grafana dashboards): use the task tool with subagent "bulk-reader" (pass file paths + your question; you only consume the summary).`,
    `  - For boilerplate generation: use the task tool with subagent "code-writer" (pass spec + reference file + target path).`,
    `  - If you must edit a specific section of this file, do a targeted read with BOTH offset and limit (an offset alone reads the unbounded rest of the file) — that is allowed.`,
  ].join("\n")
}

async function logShuntBlock(
  sinkPath: string,
  fields: {
    sessionID: string
    tool: "read" | "bash"
    p: string
    hit: { bytes: number; lines: number | null }
    threshold: number
    command?: string
  },
): Promise<void> {
  try {
    const rec: Record<string, unknown> = {
      ts: new Date().toISOString(),
      harness: "opencode",
      session: fields.sessionID,
      tool: fields.tool,
      path: fields.p,
      reason: fields.hit.lines != null ? "lines" : "bytes",
      bytes: fields.hit.bytes,
      lines: fields.hit.lines,
      threshold_bytes: maxBytes(),
      threshold_lines: fields.threshold,
    }
    if (fields.tool === "bash") rec.command = fields.command
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

export const ShuntPlugin: Plugin = async ({ directory, worktree }) => {
  const sinkDir = path.join(worktree ?? directory ?? ".", ".usage")
  try {
    mkdirSync(sinkDir, { recursive: true })
  } catch {
    // instrumentation must never break the harness init
  }
  const sinkPath = path.join(sinkDir, "shunt.jsonl")
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
      // Never block subagent reads — they are the worker.
      if (delegated.has(input.sessionID)) return

      const threshold = minLines()

      if (input.tool === "read") {
        const args = output.args as { filePath?: string; offset?: unknown; limit?: unknown }
        if (!args?.filePath || isTargeted(args)) return
        const p = path.resolve(directory, args.filePath)
        const hit = await isOversized(p, threshold)
        if (hit.big) {
          await logShuntBlock(sinkPath, { sessionID: input.sessionID, tool: "read", p, hit, threshold })
          throw new Error(redirectMsg(p, hit, threshold))
        }
        return
      }

      if (input.tool === "bash") {
        const args = output.args as { command?: string }
        const cmd = args?.command?.trim() ?? ""
        // Contract for Bash commands:
        //   (a) Compound commands (pipes, redirections, ; & backticks, or newlines)
        //       pass untouched — we do NOT try to parse them.
        //   (b) Verbs outside the whitelist (python, jq, git show, node, perl...)
        //       are never size-checked.
        //   (c) Accepted gap: a piped `sed -n 400,562p | grep` still passes via (a).
        //       A single bounded read (sed -n N,Mp, head -n N, tail -n N, head/tail -c N)
        //       is treated as targeted and skips the size check entirely.
        if (!cmd || /[|>;`&]/.test(cmd) || cmd.includes("\n")) return
        const verbMatch = cmd.match(BLOCKED_BASH)
        if (!verbMatch) return
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
        if (verb === "sed" && isBoundedSed(cmdArgs)) return
        if ((verb === "head" || verb === "tail") && isBoundedHeadTail(cmdArgs)) return

        const files = cmdArgs.filter((a) => a && !a.startsWith("-"))
        for (const f of files) {
          const p = path.resolve(directory, f)
          const hit = await isOversized(p, threshold)
          if (hit.big) {
            await logShuntBlock(sinkPath, { sessionID: input.sessionID, tool: "bash", p, hit, threshold, command: cmd })
            throw new Error(redirectMsg(p, hit, threshold))
          }
        }
        return
      }
    },
  }
}
