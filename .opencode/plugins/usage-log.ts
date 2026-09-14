// Usage-log adapter: appends one JSONL line per assistant message to
// .usage/usage.jsonl — the harness-neutral sink consumed by
// scripts/usage-report.sh (schema documented in AGENTS.md).
//
// Payload source: opencode SDK types (EventMessageUpdated →
// properties.info: AssistantMessage). Subagent sessions are attributed
// via Session.parentID (result cached per sessionID).
//
// Append-only: repeated message.updated events for the same message id are
// tolerated; scripts/usage-report.sh deduplicates at read time.

import type { Plugin } from "@opencode-ai/plugin"
import { appendFile as appendFileAsync } from "node:fs/promises"
import { mkdirSync } from "node:fs"
import { join } from "node:path"

export const UsageLog: Plugin = async ({ client, worktree }) => {
  const sinkDir = join(worktree ?? ".", ".usage")
  try {
    mkdirSync(sinkDir, { recursive: true })
  } catch {
    // instrumentation must never break the harness init
  }
  const sinkPath = join(sinkDir, "usage.jsonl")

  const roleCache = new Map<string, string>()
  async function roleOf(sessionID: string): Promise<string> {
    const cached = roleCache.get(sessionID)
    if (cached) return cached
    let role = "unknown"
    try {
      // real SDK shape: client.session.get({ path: { id } }) → { data: Session }
      const res: any = await client.session.get({ path: { id: sessionID } })
      if (res?.data?.parentID) role = "subagent"
      else if (res?.data) role = "primary"
    } catch {
      // unknown is NOT cached: transient failures are retried later
    }
    if (role !== "unknown") roleCache.set(sessionID, role)
    return role
  }

  return {
    event: async ({ event }: any) => {
      try {
        if (event.type !== "message.updated") return
        const info = event.properties?.info
        if (!info || info.role !== "assistant") return
        const rec = {
          ts: new Date(info.time?.created ?? Date.now()).toISOString(),
          harness: "opencode",
          session: info.sessionID,
          msg: info.id,
          role: await roleOf(info.sessionID),
          model: `${info.providerID ?? "?"}/${info.modelID ?? "?"}`,
          tokens_in: info.tokens?.input ?? 0,
          tokens_out: info.tokens?.output ?? 0,
          cache_read: info.tokens?.cache?.read ?? 0,
          cache_write: info.tokens?.cache?.write ?? 0,
        }
        await appendFileAsync(sinkPath, JSON.stringify(rec) + "\n")
      } catch (e: any) {
        if (process.env.USAGE_LOG_DEBUG) console.error("[usage-log]", e?.message ?? e)
      }
    },
  }
}
