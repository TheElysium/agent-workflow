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

async function callRead(plugin: any, sessionID: string, filePath: string, extra: { offset?: unknown; limit?: unknown } = {}) {
  return plugin["tool.execute.before"](
    { tool: "read", sessionID, callID: "call1" },
    { args: { filePath, ...extra } },
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

describe("shunt plugin read targeting", () => {
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shunt-test."))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  test("read big file with offset alone is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses-read-offset", filePath, { offset: 10 })).rejects.toThrow("BLOCKED by shunt")
  })

  test("read big file with offset and limit is targeted", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses-read-both", filePath, { offset: 10, limit: 20 })).resolves.toBeUndefined()
  })

  test("read big file with offset=0 and limit is targeted", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses-read-zero", filePath, { offset: 0, limit: 20 })).resolves.toBeUndefined()
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

  test("bounded sed -n 244,260p on big file passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses16", `sed -n 244,260p ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("bounded sed -n quoted 244,260p on big file passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses17", `sed -n '244,260p' ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("bounded head -n 20 on big file passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses18", `head -n 20 ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("bounded head -c 500 on big file passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses19", `head -c 500 ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("bounded tail -n 20 on big file passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses20", `tail -n 20 ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("bounded head -n 200 on fat single-line file passes", async () => {
    const filePath = join(dir, "big-bytes.txt")
    writeFileSync(filePath, "y".repeat(70_000))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses21", `head -n 200 ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("sed -n 100,$p on big file is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses22", `sed -n '100,$p' ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("tail -n +100 on big file is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses23", `tail -n +100 ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("sed without -n on big file is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses24", `sed '244,260p' ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("compound cat && echo ok on big file passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses25", `cat ${filePath} && echo ok`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("compound sed -n 100,$p; echo ok on big file passes (accepted gap)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses26", `sed -n '100,$p' ${filePath}; echo ok`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("python3 read of big file passes (uncovered verb)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses27", `python3 -c 'print(open("${filePath}").read())'`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("multi-line bash command passes untouched", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses28", `cat ${filePath}\necho ok`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("verb boundary requires whitespace (head-file passes untouched)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses29", `head-file ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("head -n +20 is denied (plus prefix is unbounded)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses30", `head -n +20 ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("tail -c +100 is denied (start-at-byte to EOF is unbounded)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses31", `tail -c +100 ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("sed -n '244, 260p' is denied (space inside range)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses32", `sed -n '244, 260p' ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("head -n0 is bounded and passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses33", `head -n0 ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("head -n 0 is bounded and passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses34", `head -n 0 ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("sed -n 1p is bounded and passes", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses35", `sed -n 1p ${filePath}`)).resolves.toBeUndefined()
    expect(existsSync(sinkPath())).toBe(false)
  })

  test("sed -ne '100p' is a script, not a window, and is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses36", `sed -ne '100p' ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })
})
