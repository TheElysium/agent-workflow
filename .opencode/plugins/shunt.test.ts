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

function readRecords(): any[] {
  if (!existsSync(sinkPath())) return []
  return readFileSync(sinkPath(), "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((l) => JSON.parse(l))
}

async function callRead(plugin: any, sessionID: string, filePath: string | undefined, extra: { offset?: unknown; limit?: unknown } = {}) {
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

  test("denied read (line-threshold) appends one JSONL line with reason 'lines', decision 'deny'", async () => {
    const filePath = join(dir, "big-lines.txt")
    // 400 short lines: under the 65_536-byte threshold, over the 350-line threshold.
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses1", filePath)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.harness).toBe("opencode")
    expect(rec.session).toBe("ses1")
    expect(rec.tool).toBe("read")
    expect(rec.decision).toBe("deny")
    expect(rec.reason).toBe("lines")
    expect(rec.path).toBe(filePath)
    expect(rec.lines).toBe(401)
    expect(typeof rec.bytes).toBe("number")
    expect(rec.threshold_bytes).toBe(65_536)
    expect(rec.threshold_lines).toBe(350)
    expect("command" in rec).toBe(false)
    expect(typeof rec.ts).toBe("string")
  })

  test("denied read (byte-threshold) appends one JSONL line with reason 'bytes', lines null, decision 'deny'", async () => {
    const filePath = join(dir, "big-bytes.txt")
    // Single line, no trailing newline: bytes over threshold, never gets to line counting.
    writeFileSync(filePath, "y".repeat(70_000))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses2", filePath)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("deny")
    expect(rec.reason).toBe("bytes")
    expect(rec.lines).toBeNull()
    expect(rec.bytes).toBe(70_000)
    expect(rec.threshold_bytes).toBe(65_536)
  })

  test("denied bash cat call appends one line with tool 'bash', command field, decision 'deny'", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses3", `cat ${filePath}`)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(`cat ${filePath}`)
    expect(rec.path).toBe(filePath)
    expect("offset" in rec).toBe(false)
    expect("limit" in rec).toBe(false)
  })

  test("allowed read under threshold logs one record with reason 'under_threshold'", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callRead(plugin, "ses4", filePath) // must not throw

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("under_threshold")
    expect(rec.tool).toBe("read")
    expect(rec.path).toBe(filePath)
    expect(typeof rec.bytes).toBe("number")
    expect(typeof rec.lines).toBe("number")
    expect("command" in rec).toBe(false)
  })

  test("subagent read logs one record with reason 'subagent' and no measurement", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    // Mark the session as a delegated subagent via the plugin's own event hook.
    await plugin.event({
      event: { properties: { info: { id: "sub1", parentID: "root1" } } },
    } as any)
    await callRead(plugin, "sub1", filePath) // subagent reads always pass, must not throw

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("subagent")
    expect(rec.tool).toBe("read")
    expect(rec.path).toBe(filePath)
    expect(rec.bytes).toBeNull()
    expect(rec.lines).toBeNull()
  })

  test("subagent bash logs one record with reason 'subagent', path null, command present", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await plugin.event({
      event: { properties: { info: { id: "sub2", parentID: "root1" } } },
    } as any)
    const command = `cat ${filePath}`
    await callBash(plugin, "sub2", command)

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("subagent")
    expect(rec.tool).toBe("bash")
    expect(rec.path).toBeNull()
    expect(rec.command).toBe(command)
    expect("offset" in rec).toBe(false)
    expect("limit" in rec).toBe(false)
  })

  test("write failure does not throw from the plugin; redirect Error still thrown (deny unchanged)", async () => {
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

  test("write failure does not throw from the plugin on allow decisions either", async () => {
    const blockerFile = join(dir, "not-a-dir2")
    writeFileSync(blockerFile, "i am a file, not a directory")
    const unwritableWorktree = join(blockerFile, "nested")

    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin({ directory: unwritableWorktree, worktree: unwritableWorktree } as any)

    await expect(callRead(plugin, "ses-allow-fail", filePath)).resolves.toBeUndefined()
  })

  test("non-read/bash tool logs nothing", async () => {
    const plugin = await ShuntPlugin(mockCtx() as any)
    await plugin["tool.execute.before"](
      { tool: "write", sessionID: "ses-other", callID: "call1" } as any,
      { args: { filePath: join(dir, "x.txt"), content: "hi" } } as any,
    )
    expect(existsSync(sinkPath())).toBe(false)
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

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].decision).toBe("deny")
    expect(recs[0].offset).toBe(10)
    expect(recs[0].limit).toBeNull()
  })

  test("read big file with offset and limit is targeted", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses-read-both", filePath, { offset: 10, limit: 20 })).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("targeted")
    expect(rec.path).toBe(filePath)
    expect(rec.offset).toBe(10)
    expect(rec.limit).toBe(20)
    expect(rec.bytes).toBeNull()
    expect(rec.lines).toBeNull()
  })

  test("read big file with offset=0 and limit is targeted, offset logged as 0 not null", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callRead(plugin, "ses-read-zero", filePath, { offset: 0, limit: 20 })).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("targeted")
    expect(recs[0].offset).toBe(0)
    expect(recs[0].limit).toBe(20)
  })

  test("read without filePath logs one record with reason 'no_input', path null", async () => {
    const plugin = await ShuntPlugin(mockCtx() as any)
    await callRead(plugin, "ses-no-input", undefined)

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("no_input")
    expect(rec.tool).toBe("read")
    expect(rec.path).toBeNull()
    expect("command" in rec).toBe(false)
  })

  test("read of nonexistent file logs one record with reason 'missing', decision 'allow'", async () => {
    const filePath = join(dir, "does-not-exist.txt")
    const plugin = await ShuntPlugin(mockCtx() as any)
    await callRead(plugin, "ses-missing", filePath)

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("missing")
    expect(rec.bytes).toBeNull()
    expect(rec.lines).toBeNull()
    expect(rec.path).toBe(filePath)
  })
})

describe("shunt plugin bash blocking", () => {
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "shunt-test."))
  })
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  test("denied bash grep call ends in a deny record after a 'missing' record for the pattern arg", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `grep foo ${filePath}`
    await expect(callBash(plugin, "ses6", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(2)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("missing")
    const rec = recs[1]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash sed call ends in a deny record after a 'missing' record for the script arg", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `sed p ${filePath}`
    await expect(callBash(plugin, "ses7", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(2)
    const rec = recs[1]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash awk call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `awk ${filePath}`
    await expect(callBash(plugin, "ses8", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash rg call ends in a deny record after a 'missing' record for the pattern arg", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `rg foo ${filePath}`
    await expect(callBash(plugin, "ses9", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(2)
    const rec = recs[1]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash xxd call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `xxd ${filePath}`
    await expect(callBash(plugin, "ses10", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash base64 call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `base64 ${filePath}`
    await expect(callBash(plugin, "ses11", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("denied bash strings call appends one line and throws", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `strings ${filePath}`
    await expect(callBash(plugin, "ses12", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("passing bash grep call on small file logs one 'missing' and one 'under_threshold' allow record", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callBash(plugin, "ses13", `grep hello ${filePath}`)

    const recs = readRecords()
    expect(recs.length).toBe(2)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("missing")
    expect(recs[0].path).toBe(join(dir, "hello"))
    expect(recs[1].decision).toBe("allow")
    expect(recs[1].reason).toBe("under_threshold")
    expect(recs[1].path).toBe(filePath)
  })

  test("passing bash sed call on small file logs one 'missing' and one 'under_threshold' allow record", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callBash(plugin, "ses14", `sed p ${filePath}`)

    const recs = readRecords()
    expect(recs.length).toBe(2)
    expect(recs[0].reason).toBe("missing")
    expect(recs[0].path).toBe(join(dir, "p"))
    expect(recs[1].reason).toBe("under_threshold")
    expect(recs[1].path).toBe(filePath)
  })

  test("denied bash grep with leading flag on big file is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `grep -c foo ${filePath}`
    await expect(callBash(plugin, "ses15", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    const rec = recs[recs.length - 1]
    expect(rec.tool).toBe("bash")
    expect(rec.decision).toBe("deny")
    expect(rec.command).toBe(command)
    expect(rec.path).toBe(filePath)
  })

  test("bounded sed -n 244,260p on big file passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses16", `sed -n 244,260p ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("bounded")
    expect(recs[0].path).toBeNull()
  })

  test("bounded sed -n quoted 244,260p on big file passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses17", `sed -n '244,260p' ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("bounded head -n 20 on big file passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses18", `head -n 20 ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("bounded head -c 500 on big file passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses19", `head -c 500 ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("bounded tail -n 20 on big file passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses20", `tail -n 20 ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("bounded head -n 200 on fat single-line file passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-bytes.txt")
    writeFileSync(filePath, "y".repeat(70_000))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses21", `head -n 200 ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
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

  test("compound cat && echo ok on big file passes with one 'compound' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `cat ${filePath} && echo ok`
    await expect(callBash(plugin, "ses25", command)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("compound")
    expect(recs[0].path).toBeNull()
    expect(recs[0].command).toBe(command)
  })

  test("compound sed -n 100,$p; echo ok on big file passes with one 'compound' record (accepted gap)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses26", `sed -n '100,$p' ${filePath}; echo ok`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("compound")
  })

  test("python3 read of big file passes with one 'verb' record (uncovered verb)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses27", `python3 -c 'print(open("${filePath}").read())'`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("verb")
    expect(recs[0].path).toBeNull()
  })

  test("multi-line bash command passes with one 'compound' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses28", `cat ${filePath}\necho ok`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("compound")
  })

  test("verb boundary requires whitespace (head-file passes with one 'verb' record)", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses29", `head-file ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("verb")
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

  test("head -n0 is bounded and passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses33", `head -n0 ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("head -n 0 is bounded and passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses34", `head -n 0 ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("sed -n 1p is bounded and passes with one 'bounded' record", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses35", `sed -n 1p ${filePath}`)).resolves.toBeUndefined()

    const recs = readRecords()
    expect(recs.length).toBe(1)
    expect(recs[0].reason).toBe("bounded")
  })

  test("sed -ne '100p' is a script, not a window, and is denied", async () => {
    const filePath = join(dir, "big-lines.txt")
    writeFileSync(filePath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    await expect(callBash(plugin, "ses36", `sed -ne '100p' ${filePath}`)).rejects.toThrow("BLOCKED by shunt")
  })

  test("empty bash command logs one record with reason 'no_input'", async () => {
    const plugin = await ShuntPlugin(mockCtx() as any)
    await callBash(plugin, "ses-empty", "")

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("no_input")
    expect(rec.tool).toBe("bash")
    expect(rec.path).toBeNull()
    expect(rec.command).toBe("")
  })

  test("whitelisted bash verb with only flags logs one record with reason 'no_input'", async () => {
    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = "cat -n"
    await callBash(plugin, "ses-verb-only", command)

    const recs = readRecords()
    expect(recs.length).toBe(1)
    const rec = recs[0]
    expect(rec.decision).toBe("allow")
    expect(rec.reason).toBe("no_input")
    expect(rec.command).toBe(command)
    expect(rec.path).toBeNull()
  })

  test("bash command is logged exactly as received, untrimmed", async () => {
    const filePath = join(dir, "small.txt")
    writeFileSync(filePath, "hello\n")
    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `  cat ${filePath}  `
    await callBash(plugin, "ses-untrimmed", command)

    const recs = readRecords()
    expect(recs[recs.length - 1].command).toBe(command)
  })

  test("multi-file bash with two small files logs two allow records", async () => {
    const p1 = join(dir, "a.txt")
    const p2 = join(dir, "b.txt")
    writeFileSync(p1, "hello\n")
    writeFileSync(p2, "world\n")

    const plugin = await ShuntPlugin(mockCtx() as any)
    await callBash(plugin, "ses-multi2", `cat ${p1} ${p2}`)

    const recs = readRecords()
    expect(recs.length).toBe(2)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("under_threshold")
    expect(recs[0].path).toBe(p1)
    expect(recs[1].decision).toBe("allow")
    expect(recs[1].reason).toBe("under_threshold")
    expect(recs[1].path).toBe(p2)
  })

  test("multi-file bash stops at first oversized file: allow then deny", async () => {
    const smallPath = join(dir, "small.txt")
    const bigPath = join(dir, "big-lines.txt")
    writeFileSync(smallPath, "hello\n")
    writeFileSync(bigPath, "x\n".repeat(400))

    const plugin = await ShuntPlugin(mockCtx() as any)
    const command = `cat ${smallPath} ${bigPath}`
    await expect(callBash(plugin, "ses-multi", command)).rejects.toThrow("BLOCKED by shunt")

    const recs = readRecords()
    expect(recs.length).toBe(2)
    expect(recs[0].decision).toBe("allow")
    expect(recs[0].reason).toBe("under_threshold")
    expect(recs[0].path).toBe(smallPath)
    expect(recs[1].decision).toBe("deny")
    expect(recs[1].path).toBe(bigPath)
  })
})
