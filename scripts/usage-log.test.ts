// Smoke tests for the opencode usage-log plugin (.opencode/plugins/usage-log.ts).
//
// The plugin factory is called with a mock context and driven with fixture
// events shaped exactly like the opencode SDK payloads (types.gen.d.ts):
// EventMessageUpdated { properties: { info: AssistantMessage } }.
//
// Usage:  bun test scripts/usage-log.test.ts
// Exit:   0 if every case passes, 1 otherwise.

import { describe, test, expect, beforeEach, afterEach } from "bun:test"
import { mkdtempSync, readFileSync, existsSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { UsageLog } from "../.opencode/plugins/usage-log"

let dir: string

function mockCtx(parents: Record<string, string> = {}) {
  return {
    worktree: dir,
    client: {
      session: {
        // real SDK shape: client.session.get({ path: { id } }) → { data: Session }
        get: async (args: { path: { id: string } }) => ({
          data: parents[args.path.id]
            ? { id: args.path.id, parentID: parents[args.path.id] }
            : { id: args.path.id },
        }),
      },
    },
  }
}

function msgEvent(
  id: string,
  sessionID: string,
  tokens: { input: number; output: number; cache?: { read: number; write: number } },
) {
  return {
    type: "message.updated",
    properties: {
      info: {
        id,
        sessionID,
        role: "assistant",
        time: { created: 1760000000000 },
        modelID: "glm-5.3-flash",
        providerID: "opencode-go",
        tokens: { input: tokens.input, output: tokens.output, reasoning: 0, cache: tokens.cache ?? { read: 0, write: 0 } },
      },
    },
  }
}

function sinkPath(): string {
  return join(dir, ".usage", "usage.jsonl")
}

describe("usage-log plugin", () => {
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "usage-log-test."))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  test("assistant message appended as one JSONL line", async () => {
    const plugin = await UsageLog(mockCtx() as any)
    await plugin.event({ event: msgEvent("msg1", "ses1", { input: 100, output: 50 }) } as any)
    const lines = readFileSync(sinkPath(), "utf8").trim().split("\n").filter(Boolean)
    expect(lines.length).toBe(1)
    const rec = JSON.parse(lines[0])
    expect(rec.harness).toBe("opencode")
    expect(rec.session).toBe("ses1")
    expect(rec.msg).toBe("msg1")
    expect(rec.model).toBe("opencode-go/glm-5.3-flash")
    expect(rec.tokens_in).toBe(100)
    expect(rec.tokens_out).toBe(50)
    expect(rec.role).toBe("primary")
    expect(rec.ts).toBe("2025-10-09T08:53:20.000Z")
  })

  test("cache tokens mapped", async () => {
    const plugin = await UsageLog(mockCtx() as any)
    await plugin.event({
      event: msgEvent("msg1", "ses1", { input: 10, output: 20, cache: { read: 500, write: 30 } }),
    } as any)
    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.cache_read).toBe(500)
    expect(rec.cache_write).toBe(30)
  })

  test("subagent session attributed via parentID", async () => {
    const plugin = await UsageLog(mockCtx({ sub1: "root1" }) as any)
    await plugin.event({ event: msgEvent("msg1", "sub1", { input: 5, output: 1 }) } as any)
    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.role).toBe("subagent")
  })

  test("user messages ignored", async () => {
    const plugin = await UsageLog(mockCtx() as any)
    await plugin.event({
      type: "message.updated",
      properties: { info: { id: "u1", sessionID: "ses1", role: "user", time: { created: 0 } } },
    } as any)
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("session lookup failure yields role unknown, line still written", async () => {
    const ctx = {
      worktree: dir,
      client: { session: { get: async () => { throw new Error("boom") } } },
    }
    const plugin = await UsageLog(ctx as any)
    await plugin.event({ event: msgEvent("msg1", "ses1", { input: 5, output: 1 }) } as any)
    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.role).toBe("unknown")
    expect(rec.tokens_in).toBe(5)
  })

  test("transient lookup failure is retried, not cached", async () => {
    let fail = true
    const ctx = {
      worktree: dir,
      client: {
        session: {
          get: async (args: { path: { id: string } }) => {
            if (fail) throw new Error("boom")
            return { data: { id: args.path.id, parentID: "root" } }
          },
        },
      },
    }
    const plugin = await UsageLog(ctx as any)
    await plugin.event({ event: msgEvent("msg1", "ses1", { input: 5, output: 1 }) } as any)
    expect(JSON.parse(readFileSync(sinkPath(), "utf8").trim()).role).toBe("unknown")
    fail = false // service recovers
    await plugin.event({ event: msgEvent("msg2", "ses1", { input: 5, output: 1 }) } as any)
    const lines = readFileSync(sinkPath(), "utf8").trim().split("\n").filter(Boolean)
    expect(JSON.parse(lines[1]).role).toBe("subagent")
  })

  test("plugin init survives unwritable worktree", async () => {
    const ctx = {
      worktree: "/proc/no-such-dir-here",
      client: { session: { get: async (args: { path: { id: string } }) => ({ data: { id: args.path.id } }) } },
    }
    const plugin = await UsageLog(ctx as any) // must not throw
    await plugin.event({ event: msgEvent("msg1", "ses1", { input: 5, output: 1 }) } as any) // and not throw
  })
})
