// Smoke tests for the opencode shunt plugin (.opencode/plugins/shunt.ts).
//
// The plugin factory is called with a mock context ({ directory, worktree })
// and driven with fixture tool.execute.before invocations shaped like the
// opencode SDK: input { tool, sessionID, callID }, output { args }.
//
// Usage:  bun test .opencode/plugins/shunt.test.ts

import { describe, test, expect, beforeEach, afterEach } from "bun:test"
import { mkdtempSync, writeFileSync, existsSync, readFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { ShuntPlugin } from "./shunt"

let dir: string

function mockCtx() {
  return { directory: dir, worktree: dir }
}

function sinkPath(): string {
  return join(dir, ".usage", "shunt.jsonl")
}

async function callRead(plugin: any, sessionID: string, filePath: string) {
  return plugin["tool.execute.before"](
    { tool: "read", sessionID, callID: "call1" },
    { args: { filePath } },
  )
}

async function callBash(plugin: any, sessionID: string, command: string) {
  return plugin["tool.execute.before"](
    { tool: "bash", sessionID, callID: "call1" },
    { args: { command } },
  )
}

describe("shunt plugin telemetry", () => {
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shunt-test."))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  test("denied read (line-threshold) appends one JSONL line with reason 'lines'", async () => {
    const filePath = join(dir, "big-lines.txt")
    // 400 short lines: under the 65_536-byte threshold, over the 350-line threshold.
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses1", filePath)).rejects.toThrow("BLOCKED by shunt")

    const lines = readFileSync(sinkPath(), "utf8").trim().split("\n").filter(Boolean)
    expect(lines.length).toBe(1)
    const rec = JSON.parse(lines[0])
    expect(rec.harness).toBe("opencode")
    expect(rec.session).toBe("ses1")
    expect(rec.tool).toBe("read")
    expect(rec.reason).toBe("lines")
    expect(rec.path).toBe(filePath)
    expect(rec.lines).toBe(401)
    expect(typeof rec.bytes).toBe("number")
    expect(rec.threshold_bytes).toBe(65_536)
    expect(rec.threshold_lines).toBe(350)
    expect(rec.command).toBeUndefined()
    expect("command" in rec).toBe(false)
    expect(typeof rec.ts).toBe("string")
  })

  test("denied read (byte-threshold) appends one JSONL line with reason 'bytes', lines null", async () => {
    const filePath = join(dir, "big-bytes.txt")
    // Single line, no trailing newline: bytes over threshold, never gets to line counting.
    writeFileSync(filePath, "y".repeat(70_000))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses2", filePath)).rejects.toThrow("BLOCKED by shunt")

    const lines = readFileSync(sinkPath(), "utf8").trim().split("\n").filter(Boolean)
    expect(lines.length).toBe(1)
    const rec = JSON.parse(lines[0])
    expect(rec.reason).toBe("bytes")
    expect(rec.lines).toBeNull()
    expect(rec.bytes).toBe(70_000)
    expect(rec.threshold_bytes).toBe(65_536)
  })

  test("denied bash cat call appends one line with tool 'bash' and command field", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses3", `cat ${filePath}`)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(`cat ${filePath}`)
    expect(rec.path).toBe(filePath)
  })

  test("a passing call (small file) writes nothing to shunt.jsonl", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callRead(plugin, "ses4", filePath) // must not throw

    expect(existsSync(sinkPath())).toBe(false)
  })

  test("a passing call (subagent session) writes nothing to shunt.jsonl", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    // Mark the session as a delegated subagent via the plugin's own event hook.
    await plugin.event({
      event: { properties: { info: { id: "sub1", parentID: "root1" } } },
    } as any)
    await callRead(plugin, "sub1", filePath) // subagent reads always pass, must not throw

    expect(existsSync(sinkPath())).toBe(false)
  })

  test("write failure does not throw from the plugin; redirect Error still thrown", async () => {
    // Point worktree at a path whose parent segment is a regular file, so
    // mkdirSync(recursive) and appendFile both fail deterministically.
    const blockerFile = join(dir, "not-a-dir")
    writeFileSync(blockerFile, "i am a file, not a directory")
    const unwritableWorktree = join(blockerFile, "nested")

    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin({ directory: unwritableWorktree, worktree: unwritableWorktree } as any)

    // The redirect Error must still be thrown even though the sink write failed.
    await expect(callRead(plugin, "ses5", filePath)).rejects.toThrow("BLOCKED by shunt")
  })
})

describe("shunt plugin bash blocking", () => {
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shunt-test."))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  test("denied bash grep call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `grep foo ${filePath}`
    await expect(callBash(plugin, "ses6", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash sed call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `sed p ${filePath}`
    await expect(callBash(plugin, "ses7", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash awk call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `awk ${filePath}`
    await expect(callBash(plugin, "ses8", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash rg call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `rg foo ${filePath}`
    await expect(callBash(plugin, "ses9", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash xxd call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `xxd ${filePath}`
    await expect(callBash(plugin, "ses10", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash base64 call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `base64 ${filePath}`
    await expect(callBash(plugin, "ses11", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash strings call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `strings ${filePath}`
    await expect(callBash(plugin, "ses12", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("passing bash grep call on small file writes nothing", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callBash(plugin, "ses13", `grep hello ${filePath}`)

    expect(existsSync(sinkPath())).toBe(false)
  })

  test("passing bash sed call on small file writes nothing", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callBash(plugin, "ses14", `sed p ${filePath}`)

    expect(existsSync(sinkPath())).toBe(false)
  })

  test("denied bash grep with leading flag on big file is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `grep -c foo ${filePath}`
    await expect(callBash(plugin, "ses15", command)).rejects.toThrow("BLOCKED by shunt")

    const rec = JSON.parse(readFileSync(sinkPath(), "utf8").trim())
    expect(rec.tool).toBe("bash")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })
})
