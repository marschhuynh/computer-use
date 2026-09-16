# Protocol and Test Integration Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the current standalone CLI foundation without discarding useful unfinished work or adding live desktop behavior.

**Architecture:** Preserve the TypeScript CLI/Swift helper split. This volume supplies small reviewed changes under the approved recovery design; the recovery index owns execution order and cross-volume interface amendments.

**Tech Stack:** Node.js 22+, TypeScript, Vitest 3, Swift 5.9+ in Swift v5 mode, macOS 14+, Foundation/AppKit/ApplicationServices, XCTest.

## Global Constraints

- Approved recovery design: `../specs/2026-09-08-foundation-recovery-design.md`; public product spec: `../specs/2026-09-08-standalone-cli-design.md`.
- Execute only in `/Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli`, based on `9b3a6d5` plus the preserved seven unfinished implementation paths.
- Follow `2026-09-08-foundation-recovery.md` for exact inter-volume order. A volume is not permission to skip prerequisites.
- Foreground automation first, macOS only; no daemon, MCP, model execution, private APIs, or implicit target.
- Default deadline is 15 seconds; integer timeout range is 1–120,000 ms inclusive. Cancellation cleanup has a separate 2-second grace period.
- Records expire after 10 minutes. State root is `~/Library/Application Support/nuvin-computer-use/`; directories 0700, files 0600.
- No live apps/windows/doctor/snapshot success, permission prompts, captures, activation, or input during recovery verification. Pure fixtures and injected providers only.
- Do not delete original restored source, discard inherited edits, use `git clean`/`git reset`, or blanket-stage changes. New recovery code may replace obsolete new-CLI internals when the task names them.
- Planning itself makes no implementation edits or commits. During execution, retain the user's prior authorization for baseline/task commits, but inspect only task-owned hunks before each commit; never push, merge, publish, or delete originals implicitly.
- Every reviewable task records RED evidence, focused GREEN evidence, changed files, known limitations, and review verdict. Do not relabel stale binary tests as current-source verification.

---

### Placement and prerequisites

This draft is the Stage C slice of the approved foundation recovery. The controller will supply the final plan header and global constraints. Execute these tasks only after the earlier native-compilability/trustworthy-AX recovery has made a fresh `swift test --package-path native` compile. All commands below run from:

```sh
cd /Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli
```

The four tasks are intentionally ordered:

1. **C1** makes test evidence honest before any contract-green claim.
2. **C2** freezes request shape parity.
3. **C3** freezes structured native error/mutation-certainty parity.
4. **C4** validates snapshot replies against the existing Swift producer.

Do not run `apps`, `windows`, `doctor`, or a successful `snapshot` against the real host in these tasks. Do not add a production environment-variable helper override. Do not change the public error-code set, the approved privacy projection, timeout floors, state lifetime/modes, or any future capture-result shape.

---

## Task C1: Separate fresh native protocol integration from default mock-only TypeScript tests

**One concern:** Make the default TypeScript suite incapable of dispatching the native host, while giving native protocol integration one explicit command that builds the current host, injects only a test-owned path, sends only protocol-safe requests, and always bounds/reaps spawned children.

**Files:**

- Modify: `package.json` (`scripts`)
- Create: `scripts/native-protocol-tests.mjs`
- Modify: `tests/native-protocol.test.ts` (entire integration harness)
- Modify: `native/Tests/ComputerUseCoreTests/StateStoreTests.swift` (`DesktopLockTests` subprocess tests and local process helpers)

**Consumes:**

- `WireRequest.decode(data:)` and host framing/version behavior.
- `contracts/fixtures/native-protocol.json` validity cases.
- Existing test-only `MacOSBackend({ helper })` constructor injection; production lookup in `src/backend/macos.ts:MacOSBackend.constructor` remains unchanged.
- Existing two-second owned-child cleanup grace.

**Produces:**

- `npm test`: TypeScript/mock-only; explicitly excludes `tests/native-protocol.test.ts`.
- `npm run test:native-protocol`: builds `computer-use-host` from current Swift source in that invocation, obtains SwiftPM's current bin path, sets `NUVIN_COMPUTER_USE_TEST_HOST` only for the integration test process, and runs only `tests/native-protocol.test.ts`.
- `invoke(args,input,closeStdin)` in the integration test with a 15-second operation bound and TERM → two-second grace → KILL cleanup.
- `waitForExit(_:timeout:)` and `terminateAndWait(_:)` for XCTest-owned lock helper processes.

### C1.1 — Make the native test require explicit test-only host injection (2–5 min)

- [ ] Replace `tests/native-protocol.test.ts` completely with the following test-first harness. It deliberately has no `dist/native` fallback, removes TypeScript parser checks (those move to the default suite in C2), skips every valid fixture request, and owns every child in `finally` plus `afterEach` cleanup.

```ts
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { afterEach, describe, expect, it } from 'vitest';

const INVOCATION_TIMEOUT_MS = 15_000;
const CLEANUP_GRACE_MS = 2_000;
const configuredHost = process.env.NUVIN_COMPUTER_USE_TEST_HOST;
if (configuredHost === undefined || configuredHost === '') {
  throw new Error('NUVIN_COMPUTER_USE_TEST_HOST is required; run npm run test:native-protocol');
}
const host = resolve(configuredHost);

type Fixture = { name: string; valid: boolean; request: Record<string, unknown> };
type Invocation = { stdout: string; stderr: string; code: number | null };

const activeChildren = new Set<ChildProcessWithoutNullStreams>();

function waitForClose(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  return new Promise((resolveClose, reject) => {
    const timer = setTimeout(() => {
      child.removeListener('close', close);
      reject(new Error(`native protocol child did not exit within ${timeoutMs} ms`));
    }, timeoutMs);
    const close = () => {
      clearTimeout(timer);
      resolveClose();
    };
    child.once('close', close);
  });
}

async function terminateAndWait(child: ChildProcessWithoutNullStreams): Promise<void> {
  child.stdin.destroy();
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill('SIGTERM');
  try {
    await waitForClose(child, CLEANUP_GRACE_MS);
  } catch {
    child.kill('SIGKILL');
    await waitForClose(child, 1_000);
  }
}

async function invoke(args: string[], input?: string, closeStdin = false): Promise<Invocation> {
  const child = spawn(host, args, { shell: false, stdio: ['pipe', 'pipe', 'pipe'] });
  activeChildren.add(child);
  child.stdin.on('error', () => {});
  let stdout = '';
  let stderr = '';
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });

  const completion = new Promise<Invocation>((resolveInvocation, reject) => {
    child.once('error', reject);
    child.once('close', code => resolveInvocation({ stdout, stderr, code }));
    if (input !== undefined) {
      if (closeStdin) child.stdin.end(input);
      else child.stdin.write(input);
    }
  });
  let timeoutTimer: NodeJS.Timeout | undefined;
  const timeout = new Promise<never>((_resolve, reject) => {
    timeoutTimer = setTimeout(
      () => reject(new Error(`native protocol invocation exceeded ${INVOCATION_TIMEOUT_MS} ms`)),
      INVOCATION_TIMEOUT_MS,
    );
  });

  try {
    return await Promise.race([completion, timeout]);
  } finally {
    if (timeoutTimer !== undefined) clearTimeout(timeoutTimer);
    await terminateAndWait(child);
    activeChildren.delete(child);
  }
}

afterEach(async () => {
  await Promise.all([...activeChildren].map(terminateAndWait));
  activeChildren.clear();
});

describe('fresh native protocol integration', { timeout: 120_000 }, () => {
  it('reports the binding protocol version without GUI work', async () => {
    await expect(invoke(['--protocol-version'])).resolves.toEqual({ stdout: '1\n', stderr: '', code: 0 });
  });

  it('rejects every invalid shared request before native command dispatch', async () => {
    const fixtures = JSON.parse(
      await readFile(new URL('../contracts/fixtures/native-protocol.json', import.meta.url), 'utf8'),
    ) as { cases: Fixture[] };
    const invalid = fixtures.cases.filter(fixture => !fixture.valid);
    expect(invalid.length).toBeGreaterThan(0);
    for (const fixture of invalid) {
      const result = await invoke([], `${JSON.stringify(fixture.request)}\n`);
      expect(result.code, fixture.name).toBe(0);
      expect(JSON.parse(result.stdout), fixture.name).toMatchObject({
        schemaVersion: 1,
        ok: false,
        error: { code: 'PROTOCOL_ERROR' },
      });
      expect(result.stderr, fixture.name).toBe('');
    }
  });

  it('rejects an unterminated request with one structured response', async () => {
    const request = JSON.stringify({ schemaVersion: 1, command: 'apps', options: { timeoutMs: 1, cursor: 'on' } });
    const result = await invoke([], request, true);
    const replies = result.stdout.trim().split('\n');
    expect(result.code).toBe(0);
    expect(replies).toHaveLength(1);
    expect(JSON.parse(replies[0])).toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    expect(result.stderr).toBe('');
  });

  it('rejects a request line over the 1 MiB protocol limit with one structured response', async () => {
    const result = await invoke([], `${'x'.repeat(1_048_577)}\n`, true);
    const replies = result.stdout.trim().split('\n');
    expect(result.code).toBe(0);
    expect(replies).toHaveLength(1);
    expect(JSON.parse(replies[0])).toMatchObject({ ok: false, error: { code: 'PROTOCOL_ERROR' } });
    expect(result.stderr).toBe('');
  });
});
```

- [ ] Run the test directly without the injection:

```sh
npx vitest run tests/native-protocol.test.ts
```

Expected **RED**: module setup fails with `NUVIN_COMPUTER_USE_TEST_HOST is required; run npm run test:native-protocol`. This proves the test cannot silently consume ignored `dist/native/computer-use-host`.

### C1.2 — Add the single-invocation native build/test launcher (2–5 min)

- [ ] Create `scripts/native-protocol-tests.mjs` with this complete content. The environment variable is scoped to the Vitest child and is never read by production code.

```js
import { constants } from 'node:fs';
import { access } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createRequire } from 'node:module';
import { spawn } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const vitest = join(dirname(require.resolve('vitest/package.json')), 'vitest.mjs');
const COMMAND_TIMEOUT_MS = 10 * 60 * 1_000;
const CLEANUP_GRACE_MS = 2_000;

function run(command, args, { capture = false, env = process.env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: root,
      env,
      shell: false,
      stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit',
    });
    let stdout = '';
    let timedOut = false;
    let forceTimer;
    if (capture) {
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', chunk => { stdout += chunk; });
    }
    const deadlineTimer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      forceTimer = setTimeout(() => child.kill('SIGKILL'), CLEANUP_GRACE_MS);
    }, COMMAND_TIMEOUT_MS);
    child.once('error', error => {
      clearTimeout(deadlineTimer);
      if (forceTimer !== undefined) clearTimeout(forceTimer);
      reject(error);
    });
    child.once('close', code => {
      clearTimeout(deadlineTimer);
      if (forceTimer !== undefined) clearTimeout(forceTimer);
      if (timedOut) reject(new Error(`${command} exceeded ${COMMAND_TIMEOUT_MS} ms`));
      else if (code !== 0) reject(new Error(`${command} exited with ${code}`));
      else resolve(stdout.trim());
    });
  });
}

if (process.platform !== 'darwin') {
  throw new Error('Native protocol integration requires macOS; no tests were run');
}
await run('swift', ['build', '--package-path', 'native', '--product', 'computer-use-host']);
const binPath = await run('swift', ['build', '--package-path', 'native', '--show-bin-path'], { capture: true });
const host = join(binPath, 'computer-use-host');
await access(host, constants.X_OK);
await run(process.execPath, [vitest, 'run', 'tests/native-protocol.test.ts'], {
  env: { ...process.env, NUVIN_COMPUTER_USE_TEST_HOST: host },
});
```

### C1.3 — Exclude native integration from the default suite (2–5 min)

- [ ] Replace only the `scripts` object in `package.json` with the complete object below; all other package fields remain byte-for-byte unchanged.

```json
"scripts": {
  "build:ts": "node scripts/clean-dist.mjs && tsc -p tsconfig.build.json",
  "build:native": "node scripts/build-native.mjs",
  "build": "npm run build:ts && npm run build:native",
  "native-tests": "node scripts/native-tests.mjs",
  "test:build-hygiene": "node scripts/test-build-hygiene.mjs",
  "typecheck": "tsc --noEmit",
  "test": "vitest run --exclude tests/native-protocol.test.ts",
  "test:native-protocol": "node scripts/native-protocol-tests.mjs",
  "ax-helper": "make ax-helper"
}
```

- [ ] Run:

```sh
npm test
```

Expected **GREEN**: all discovered default suites pass, and output contains no `fresh native protocol integration` suite. This is mock-only evidence; it is not native-source evidence.

- [ ] Run:

```sh
npm run test:native-protocol
```

Expected **GREEN** after the prerequisite native-compilability recovery: SwiftPM builds the current host before Vitest starts; four protocol-safe integration tests pass. Expected failure before that prerequisite is an honest current-source Swift compile error, never fallback to `dist/`.

### C1.4 — Bound and clean up XCTest subprocess owners (2–5 min)

- [ ] In `native/Tests/ComputerUseCoreTests/StateStoreTests.swift`, replace the three subprocess-owning test methods with the following complete methods. Place each `defer` immediately after its successful spawn so setup/assertion failure cannot leak the child.

```swift
func testSubprocessOwnersNeverOverlapCriticalSections() throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let log = root.appendingPathComponent("critical.log")
    let first = try spawnLockHelper(root: root, log: log, holdMicroseconds: 150_000)
    defer { terminateAndWait(first) }
    let second = try spawnLockHelper(root: root, log: log, holdMicroseconds: 150_000)
    defer { terminateAndWait(second) }
    try waitForExit(first)
    try waitForExit(second)
    XCTAssertEqual(first.terminationStatus, 0)
    XCTAssertEqual(second.terminationStatus, 0)

    let events = try String(contentsOf: log).split(separator: "\n").map(String.init)
    guard events.count == 4 else { return XCTFail("expected four critical-section events, got \(events)") }
    XCTAssertTrue(events[0].hasPrefix("start "))
    XCTAssertTrue(events[1].hasPrefix("end "))
    XCTAssertTrue(events[2].hasPrefix("start "))
    XCTAssertTrue(events[3].hasPrefix("end "))
    XCTAssertEqual(events[0].split(separator: " ")[1], events[1].split(separator: " ")[1])
    XCTAssertEqual(events[2].split(separator: " ")[1], events[3].split(separator: " ")[1])
}

func testKilledOwnerReleasesKernelLockForAnotherProcess() throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready")
    let owner = try spawnLockHelper(root: root, log: root.appendingPathComponent("owner.log"), holdForever: true, ready: ready)
    defer { terminateAndWait(owner) }
    try waitForFile(ready)
    XCTAssertEqual(kill(owner.processIdentifier, SIGKILL), 0)
    try waitForExit(owner)
    XCTAssertEqual(owner.terminationReason, .uncaughtSignal)
    XCTAssertEqual(owner.terminationStatus, SIGKILL)

    let successor = try spawnLockHelper(root: root, log: root.appendingPathComponent("successor.log"), holdMicroseconds: 0)
    defer { terminateAndWait(successor) }
    try waitForExit(successor)
    XCTAssertEqual(successor.terminationStatus, 0)
}

func testBusyAcquisitionIsDeadlineBounded() throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready")
    let owner = try spawnLockHelper(root: root, log: root.appendingPathComponent("owner.log"), holdMicroseconds: 500_000, ready: ready)
    defer { terminateAndWait(owner) }
    try waitForFile(ready)

    let start = DispatchTime.now().uptimeNanoseconds
    XCTAssertThrowsError(try DesktopLock(rootURL: root).withLock(timeoutMilliseconds: 50) {}) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    XCTAssertLessThan(elapsed, 0.5)
    try waitForExit(owner)
    XCTAssertEqual(owner.terminationStatus, 0)
}
```

- [ ] Insert these complete local helpers immediately before existing `waitForFile(_:)`:

```swift
private func waitForExit(_ process: Process, timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { usleep(10_000) }
    guard !process.isRunning else { throw NativeFailure("TIMEOUT", "Lock helper did not exit") }
    process.waitUntilExit()
}

private func terminateAndWait(_ process: Process) {
    guard process.isRunning else {
        process.waitUntilExit()
        return
    }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < deadline { usleep(10_000) }
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}
```

- [ ] Run:

```sh
swift test --package-path native --filter DesktopLockTests
```

Expected **GREEN**: subprocess lock tests pass and no helper remains after normal, timeout, setup, or assertion exits.

### C1.5 — Review and checkpoint only this concern (2–5 min)

- [ ] Review only the intended paths and whitespace:

```sh
git diff --check
git diff -- package.json scripts/native-protocol-tests.mjs tests/native-protocol.test.ts native/Tests/ComputerUseCoreTests/StateStoreTests.swift
git status --short
```

Confirm that `src/backend/macos.ts` still has constructor-only helper injection and no production environment lookup. Confirm `tests/native-protocol.test.ts` sends no valid command to `NativeService`.

- [ ] If and only if a commit is separately authorized, interactively stage the C1 hunks in the inherited-dirty Swift test instead of staging the whole file:

```sh
git add package.json scripts/native-protocol-tests.mjs tests/native-protocol.test.ts
git add -p native/Tests/ComputerUseCoreTests/StateStoreTests.swift
git diff --cached --check
git diff --cached
git commit -m "test: isolate fresh native protocol integration"
```

Do not use `git add .`, `git add -A`, reset, clean, or discard inherited Task 4 changes.

---

## Task C2: Enforce exact-key request parity and reject mixed scroll forms

**One concern:** Freeze the set of accepted request keys in Swift and make the TypeScript CLI reject `--amount` in snapshot/ref scroll form, with the same shared validity fixtures on both sides.

**Files:**

- Modify: `contracts/fixtures/native-protocol.json`
- Modify: `tests/cli-parse.test.ts` (shared fixture assertion)
- Modify: `native/Tests/ComputerUseCoreTests/ProtocolTests.swift` (all-command top-level exact-key assertion)
- Modify: `src/cli/parse.ts` (`case 'scroll'` conflict guard only)
- Modify: `native/Sources/ComputerUseCore/Protocol.swift` (`validRequest`, nested validators, exact-key helper)

**Consumes:**

- TS `Request` union in `src/core/protocol.ts` unchanged.
- Swift `WireRequest.command/object` and existing snapshot decoding in `NativeService` remain unchanged.
- Existing safe-integer, strict UUID, timeout, target, tree, and point predicates.

**Produces:**

- Exact top-level key sets for every command and both scroll forms.
- Exact nested key sets for `options`, each `target` variant, `tree`, and points.
- Presence-based app/PID exclusivity: `{app:"Editor",pid:-1}` is invalid rather than silently selecting `app`.
- Snapshot/ref scroll rejects every target/directional field, including `amount`; directional scroll rejects snapshot/ref fields.

### C2.1 — Extend the shared request fixtures (2–5 min)

- [ ] Replace `contracts/fixtures/native-protocol.json` completely with the following fixture set:

```json
{
  "protocolVersion": 1,
  "cases": [
    {"name":"valid-apps","valid":true,"request":{"schemaVersion":1,"command":"apps","options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"valid-windows","valid":true,"request":{"schemaVersion":1,"command":"windows","target":{"pid":42},"options":{"timeoutMs":120000,"cursor":"off"}}},
    {"name":"valid-snapshot","valid":true,"request":{"schemaVersion":1,"command":"snapshot","target":{"app":"Editor","windowId":7},"tree":{"maxDepth":8,"maxElements":500,"hintMode":"leafCompact"},"options":{"timeoutMs":15000,"cursor":"on"}}},
    {"name":"valid-scroll-ref","valid":true,"argv":["scroll","--snapshot","123e4567-e89b-42d3-a456-426614174000","--ref","2"],"request":{"schemaVersion":1,"command":"scroll","snapshotId":"123e4567-e89b-42d3-a456-426614174000","ref":2,"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"valid-scroll-direction","valid":true,"argv":["scroll","--app","Editor","--direction","down","--amount","3"],"request":{"schemaVersion":1,"command":"scroll","target":{"app":"Editor"},"direction":"down","amount":3,"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unknown-action","valid":false,"request":{"schemaVersion":1,"command":"unknown","options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"protocol-version-mismatch","valid":false,"request":{"schemaVersion":2,"command":"apps","options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"bad-timeout-number","valid":false,"request":{"schemaVersion":1,"command":"apps","options":{"timeoutMs":1.5,"cursor":"on"}}},
    {"name":"bad-window-number","valid":false,"request":{"schemaVersion":1,"command":"windows","target":{"pid":42,"windowId":0},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"safe-pid-maximum","valid":true,"argv":["windows","--pid","9007199254740991"],"request":{"schemaVersion":1,"command":"windows","target":{"pid":9007199254740991},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unsafe-pid","valid":false,"argv":["windows","--pid","9007199254740992"],"request":{"schemaVersion":1,"command":"windows","target":{"pid":9007199254740992},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unsafe-window","valid":false,"argv":["windows","--pid","42","--window","9007199254740992"],"request":{"schemaVersion":1,"command":"windows","target":{"pid":42,"windowId":9007199254740992},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unsafe-ref","valid":false,"argv":["press","--snapshot","123e4567-e89b-42d3-a456-426614174000","--ref","9007199254740992"],"request":{"schemaVersion":1,"command":"press","snapshotId":"123e4567-e89b-42d3-a456-426614174000","ref":9007199254740992,"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unsafe-tree-depth","valid":false,"argv":["snapshot","--app","Editor","--depth","9007199254740992"],"request":{"schemaVersion":1,"command":"snapshot","target":{"app":"Editor"},"tree":{"maxDepth":9007199254740992,"maxElements":500,"hintMode":"leafCompact"},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unsafe-tree-elements","valid":false,"argv":["snapshot","--app","Editor","--max-elements","9007199254740992"],"request":{"schemaVersion":1,"command":"snapshot","target":{"app":"Editor"},"tree":{"maxDepth":8,"maxElements":9007199254740992,"hintMode":"leafCompact"},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"unsafe-scroll-amount","valid":false,"argv":["scroll","--app","Editor","--direction","down","--amount","9007199254740992"],"request":{"schemaVersion":1,"command":"scroll","target":{"app":"Editor"},"direction":"down","amount":9007199254740992,"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"empty-app","valid":false,"argv":["windows","--app",""],"request":{"schemaVersion":1,"command":"windows","target":{"app":""},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"missing-target","valid":false,"request":{"schemaVersion":1,"command":"windows","options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"app-plus-invalid-pid","valid":false,"argv":["windows","--app","Editor","--pid","-1"],"request":{"schemaVersion":1,"command":"windows","target":{"app":"Editor","pid":-1},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"ref-scroll-plus-amount","valid":false,"argv":["scroll","--snapshot","123e4567-e89b-42d3-a456-426614174000","--ref","2","--amount","9"],"request":{"schemaVersion":1,"command":"scroll","snapshotId":"123e4567-e89b-42d3-a456-426614174000","ref":2,"amount":9,"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"ref-scroll-plus-direction-target","valid":false,"argv":["scroll","--snapshot","123e4567-e89b-42d3-a456-426614174000","--ref","2","--app","Editor","--direction","down"],"request":{"schemaVersion":1,"command":"scroll","snapshotId":"123e4567-e89b-42d3-a456-426614174000","ref":2,"target":{"app":"Editor"},"direction":"down","options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"direction-scroll-plus-snapshot","valid":false,"request":{"schemaVersion":1,"command":"scroll","target":{"app":"Editor"},"direction":"down","amount":3,"snapshotId":"123e4567-e89b-42d3-a456-426614174000","options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"extra-command-key","valid":false,"request":{"schemaVersion":1,"command":"apps","unexpected":true,"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"extra-options-key","valid":false,"request":{"schemaVersion":1,"command":"apps","options":{"timeoutMs":1,"cursor":"on","unexpected":true}}},
    {"name":"extra-target-key","valid":false,"request":{"schemaVersion":1,"command":"windows","target":{"pid":42,"unexpected":true},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"extra-tree-key","valid":false,"request":{"schemaVersion":1,"command":"snapshot","target":{"app":"Editor"},"tree":{"maxDepth":8,"maxElements":500,"hintMode":"full","unexpected":true},"options":{"timeoutMs":1,"cursor":"on"}}},
    {"name":"extra-point-key","valid":false,"request":{"schemaVersion":1,"command":"move","captureId":"123e4567-e89b-42d3-a456-426614174001","point":{"x":1,"y":2,"unexpected":true},"options":{"timeoutMs":1,"cursor":"on"}}}
  ]
}
```

### C2.2 — Move TypeScript fixture validity into the default suite and prove RED (2–5 min)

- [ ] Add this import to `tests/cli-parse.test.ts`:

```ts
import { readFileSync } from 'node:fs';
```

- [ ] Add these complete local definitions after `captureId`:

```ts
type ProtocolFixture = { name: string; valid: boolean; argv?: string[] };
const protocolFixtures = (JSON.parse(
  readFileSync(new URL('../contracts/fixtures/native-protocol.json', import.meta.url), 'utf8'),
) as { cases: ProtocolFixture[] }).cases.filter(
  (fixture): fixture is ProtocolFixture & { argv: string[] } => fixture.argv !== undefined,
);
```

- [ ] Add this complete test inside `describe('parse', ...)`:

```ts
it('matches shared request-fixture validity for every CLI-backed case', () => {
  for (const fixture of protocolFixtures) {
    const parseFixture = () => parse(fixture.argv);
    if (fixture.valid) expect(parseFixture, fixture.name).not.toThrow();
    else expect(parseFixture, fixture.name).toThrow();
  }
});
```

- [ ] In `native/Tests/ComputerUseCoreTests/ProtocolTests.swift`, add this complete test method:

```swift
func testEveryCommandFormRejectsAnUnexpectedTopLevelKey() {
    for original in validRequestsForEveryCommandForm() {
        XCTAssertNotNil(WireRequest.decode(original), String(describing: original["command"]))
        var request = original
        request["unexpected"] = true
        XCTAssertNil(WireRequest.decode(request), String(describing: original["command"]))
    }
}
```

- [ ] Add this complete local helper after `ProtocolTests` and before `ProtocolFixture`:

```swift
private func validRequestsForEveryCommandForm() -> [[String: Any]] {
    let options: [String: Any] = ["timeoutMs": 1, "cursor": "on"]
    let target: [String: Any] = ["pid": 42]
    let tree: [String: Any] = ["maxDepth": 8, "maxElements": 500, "hintMode": "full"]
    let snapshotID = "123e4567-e89b-42d3-a456-426614174000"
    let captureID = "123e4567-e89b-42d3-a456-426614174001"
    return [
        ["schemaVersion": 1, "command": "doctor", "options": options],
        ["schemaVersion": 1, "command": "apps", "options": options],
        ["schemaVersion": 1, "command": "windows", "target": target, "options": options],
        ["schemaVersion": 1, "command": "snapshot", "target": target, "tree": tree, "options": options],
        ["schemaVersion": 1, "command": "press", "snapshotId": snapshotID, "ref": 1, "options": options],
        ["schemaVersion": 1, "command": "set-value", "snapshotId": snapshotID, "ref": 1, "text": "", "options": options],
        ["schemaVersion": 1, "command": "type", "target": target, "text": "", "allowClipboardReplace": false, "options": options],
        ["schemaVersion": 1, "command": "key", "target": target, "key": "cmd+s", "options": options],
        ["schemaVersion": 1, "command": "scroll", "snapshotId": snapshotID, "ref": 1, "options": options],
        ["schemaVersion": 1, "command": "scroll", "target": target, "direction": "down", "amount": 3, "options": options],
        ["schemaVersion": 1, "command": "screenshot", "target": target, "output": "image.png", "overwrite": false, "annotated": false, "tree": tree, "options": options],
        ["schemaVersion": 1, "command": "click", "captureId": captureID, "point": ["x": 1, "y": 2], "button": "left", "count": 1, "options": options],
        ["schemaVersion": 1, "command": "move", "captureId": captureID, "point": ["x": 1, "y": 2], "options": options],
        ["schemaVersion": 1, "command": "drag", "captureId": captureID, "from": ["x": 1, "y": 2], "to": ["x": 3, "y": 4], "options": options]
    ]
}
```

- [ ] Run:

```sh
npm test -- tests/cli-parse.test.ts
```

Expected **RED**: `ref-scroll-plus-amount` does not throw because `src/cli/parse.ts` currently omits `amount` from the ref-form conflict guard.

- [ ] Add these complete tests to `ProtocolTests` before changing validation. They prevent Foundation numeric-to-Bool bridging and empty required strings from weakening exact-key validation:

```swift
func testWireFlagsRequireJSONBooleans() throws {
    let options: [String: Any] = ["timeoutMs": 15_000, "cursor": "on"]
    let target: [String: Any] = ["pid": 42]
    let tree: [String: Any] = ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"]
    let cases: [[String: Any]] = [
        ["schemaVersion": 1, "command": "type", "options": options,
         "target": target, "text": "sample", "allowClipboardReplace": 1],
        ["schemaVersion": 1, "command": "screenshot", "options": options,
         "target": target, "output": "/tmp/requested.png", "tree": tree,
         "overwrite": 0, "annotated": false],
        ["schemaVersion": 1, "command": "screenshot", "options": options,
         "target": target, "output": "/tmp/requested.png", "tree": tree,
         "overwrite": false, "annotated": 1]
    ]
    for request in cases {
        XCTAssertNil(WireRequest.decode(data: try JSONSerialization.data(withJSONObject: request)))
    }
}

func testWireRequiredKeyAndOutputCannotBeEmpty() throws {
    let options: [String: Any] = ["timeoutMs": 15_000, "cursor": "on"]
    let target: [String: Any] = ["pid": 42]
    let tree: [String: Any] = ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"]
    let cases: [[String: Any]] = [
        ["schemaVersion": 1, "command": "key", "options": options, "target": target, "key": ""],
        ["schemaVersion": 1, "command": "screenshot", "options": options,
         "target": target, "output": "", "tree": tree, "overwrite": false, "annotated": false]
    ]
    for request in cases {
        XCTAssertNil(WireRequest.decode(data: try JSONSerialization.data(withJSONObject: request)))
    }
}
```

The path in the malformed request is data only; these tests decode requests and never capture/write a screenshot.

- [ ] Run, after the earlier AX compile prerequisite is green:

```sh
swift test --package-path native --filter ProtocolTests
```

Expected **RED**: `extra-command-key`/nested extra-key fixtures and the all-command unexpected-key test are accepted by current Swift validation; `app-plus-invalid-pid` is also accepted.

### C2.3 — Reject `--amount` in TS ref-scroll form (2–5 min)

- [ ] In `src/cli/parse.ts`, replace only `case 'scroll'` with this complete case:

```ts
case 'scroll': {
  const snapshot = stringValue(values, 'snapshot');
  const ref = stringValue(values, 'ref');
  const direction = stringValue(values, 'direction');
  const amount = stringValue(values, 'amount');
  if (snapshot !== undefined || ref !== undefined) {
    if (direction !== undefined || amount !== undefined || stringValue(values, 'app') !== undefined
      || stringValue(values, 'pid') !== undefined || stringValue(values, 'window') !== undefined) {
      throw new ArgumentError('scroll forms are mutually exclusive');
    }
    request = {
      ...base,
      command,
      snapshotId: recordId(required(values, 'snapshot'), 'snapshot'),
      ref: safeInteger(required(values, 'ref'), 'ref'),
    };
  } else {
    if (direction !== 'up' && direction !== 'down' && direction !== 'left' && direction !== 'right') {
      throw new ArgumentError('--direction is required and must be valid');
    }
    request = {
      ...base,
      command,
      target: target(values),
      direction: direction as Direction,
      amount: amount === undefined ? 3 : safeInteger(required(values, 'amount'), 'amount'),
    };
  }
  break;
}
```

- [ ] Re-run:

```sh
npm test -- tests/cli-parse.test.ts
```

Expected **GREEN** for TypeScript fixture parity, including exact rejection of ref-scroll `--amount`.

### C2.4 — Make Swift request and nested objects exact-key (2–5 min)

- [ ] In `native/Sources/ComputerUseCore/Protocol.swift`, replace `validRequest(_:)`, `validOptions(_:)`, `validTarget(_:)`, `validTree(_:)`, and `validPoint(_:)` with the complete implementations below, and insert `hasExactKeys` immediately after them. Keep `validID`, numeric helpers, `WireRequest.object`, and current command-specific decode consumers unchanged.

```swift
private func validRequest(_ request: [String: Any]) -> Bool {
    guard integer(request["schemaVersion"]) == protocolVersion,
          let commandName = request["command"] as? String,
          let command = WireCommand(rawValue: commandName),
          validOptions(request["options"]) else { return false }
    let base: Set<String> = ["schemaVersion", "command", "options"]
    switch command {
    case .doctor, .apps:
        return hasExactKeys(request, base)
    case .windows:
        return hasExactKeys(request, base.union(["target"])) && validTarget(request["target"])
    case .snapshot:
        return hasExactKeys(request, base.union(["target", "tree"]))
            && validTarget(request["target"]) && validTree(request["tree"])
    case .press:
        return hasExactKeys(request, base.union(["snapshotId", "ref"]))
            && validID(request["snapshotId"]) && positiveInteger(request["ref"])
    case .setValue:
        return hasExactKeys(request, base.union(["snapshotId", "ref", "text"]))
            && validID(request["snapshotId"]) && positiveInteger(request["ref"])
            && request["text"] is String
    case .type:
        return hasExactKeys(request, base.union(["target", "text", "allowClipboardReplace"]))
            && validTarget(request["target"]) && request["text"] is String
            && validBoolean(request["allowClipboardReplace"])
    case .key:
        return hasExactKeys(request, base.union(["target", "key"]))
            && validTarget(request["target"]) && !(request["key"] as? String ?? "").isEmpty
    case .scroll:
        let refKeys = base.union(["snapshotId", "ref"])
        if hasExactKeys(request, refKeys) {
            return validID(request["snapshotId"]) && positiveInteger(request["ref"])
        }
        let directionalKeys = base.union(["target", "direction", "amount"])
        return hasExactKeys(request, directionalKeys)
            && validTarget(request["target"])
            && ["up", "down", "left", "right"].contains(request["direction"] as? String ?? "")
            && positiveInteger(request["amount"])
    case .screenshot:
        return hasExactKeys(request, base.union(["target", "output", "overwrite", "annotated", "tree"]))
            && validTarget(request["target"]) && !(request["output"] as? String ?? "").isEmpty
            && validBoolean(request["overwrite"]) && validBoolean(request["annotated"])
            && validTree(request["tree"])
    case .click:
        return hasExactKeys(request, base.union(["captureId", "point", "button", "count"]))
            && validID(request["captureId"]) && validPoint(request["point"])
            && ["left", "right", "middle"].contains(request["button"] as? String ?? "")
            && [1, 2, 3].contains(integer(request["count"]) ?? 0)
    case .move:
        return hasExactKeys(request, base.union(["captureId", "point"]))
            && validID(request["captureId"]) && validPoint(request["point"])
    case .drag:
        return hasExactKeys(request, base.union(["captureId", "from", "to"]))
            && validID(request["captureId"]) && validPoint(request["from"])
            && validPoint(request["to"])
    }
}

private func validOptions(_ value: Any?) -> Bool {
    guard let options = value as? [String: Any],
          hasExactKeys(options, ["timeoutMs", "cursor"]),
          let timeout = integer(options["timeoutMs"]) else { return false }
    return (1...maximumTimeoutMilliseconds).contains(timeout)
        && ["on", "off"].contains(options["cursor"] as? String ?? "")
}

private func validTarget(_ value: Any?) -> Bool {
    guard let target = value as? [String: Any] else { return false }
    let keys = Set(target.keys)
    if keys == ["app"] || keys == ["app", "windowId"] {
        guard let app = target["app"] as? String, !app.isEmpty else { return false }
        return keys == ["app"] || positiveInteger(target["windowId"])
    }
    if keys == ["pid"] || keys == ["pid", "windowId"] {
        guard positiveInteger(target["pid"]) else { return false }
        return keys == ["pid"] || positiveInteger(target["windowId"])
    }
    return false
}

private func validTree(_ value: Any?) -> Bool {
    guard let tree = value as? [String: Any],
          hasExactKeys(tree, ["maxDepth", "maxElements", "hintMode"]) else { return false }
    return positiveInteger(tree["maxDepth"]) && positiveInteger(tree["maxElements"])
        && ["full", "leafOnly", "leafCompact"].contains(tree["hintMode"] as? String ?? "")
}

private func validPoint(_ value: Any?) -> Bool {
    guard let point = value as? [String: Any], hasExactKeys(point, ["x", "y"]),
          let x = number(point["x"]), let y = number(point["y"]) else { return false }
    return x.isFinite && y.isFinite && x >= 0 && y >= 0
}

private func validBoolean(_ value: Any?) -> Bool {
    guard let value = value as? NSNumber else { return false }
    return CFGetTypeID(value) == CFBooleanGetTypeID()
}

private func hasExactKeys(_ object: [String: Any], _ expected: Set<String>) -> Bool {
    Set(object.keys) == expected
}
```

- [ ] Run:

```sh
swift test --package-path native --filter ProtocolTests
npm run test:native-protocol
```

Expected **GREEN**: pure Swift accepts/rejects all shared fixtures and rejects an extra root field for every command form; fresh host integration rejects all invalid fixtures without command dispatch.

### C2.5 — Review and checkpoint only request parity (2–5 min)

- [ ] Review:

```sh
git diff --check
git diff -- contracts/fixtures/native-protocol.json tests/cli-parse.test.ts native/Tests/ComputerUseCoreTests/ProtocolTests.swift src/cli/parse.ts native/Sources/ComputerUseCore/Protocol.swift
git status --short
```

Confirm `WireCommand` cases, timeout bounds, UUID grammar, and TS `Command` union are unchanged. Confirm no valid native command was added to the integration suite.

- [ ] If separately authorized, stage only C2 paths/hunks and commit:

```sh
git add contracts/fixtures/native-protocol.json tests/cli-parse.test.ts native/Tests/ComputerUseCoreTests/ProtocolTests.swift src/cli/parse.ts native/Sources/ComputerUseCore/Protocol.swift
git diff --cached --check
git diff --cached
git commit -m "fix: enforce exact native request shapes"
```

If any path contains inherited edits at execution time, use `git add -p` for that path instead of the whole-file command.

---

## Task C3: Round-trip native error details and freeze mutation-certainty semantics

**One concern:** Add structured Swift `error.details` and make native mutation certainty survive the wire while the public CLI exposes only conservative `potentiallyApplied` where relevant.

**Frozen internal ledger:**

```text
error.details.mutationStatus = "notStarted" | "potentiallyApplied"
```

Semantics:

- Swift and the TypeScript native-wire validator admit exactly `notStarted` and `potentiallyApplied`.
- A mutating native structured failure with `potentiallyApplied` publicly includes `{mutationStatus:"potentiallyApplied"}`.
- A mutating native structured failure with explicit `notStarted` suppresses public mutation uncertainty; `notStarted` itself is never projected by the CLI.
- If a structured failure has no status after the mutation request was dispatched to the host, the public CLI conservatively adds `potentiallyApplied`.
- A status on a non-mutating command is not relevant and is not publicly projected.
- An unknown status makes the native reply a protocol error; because the mutation request was dispatched, that synthetic protocol failure is conservatively `potentiallyApplied`.
- Existing synthetic transport behavior remains: pre-dispatch failures have no mutation status; post-dispatch failures on mutating commands are `potentiallyApplied`.
- `STABLE_ERROR_CODES` and `contracts/errors.json` remain unchanged.
- The existing supplied-text privacy guard remains structurally unchanged: status is separated before free-form projection, and native producers remain responsible for never emitting input content.

**Files:**

- Create: `contracts/fixtures/native-replies.json`
- Modify: `src/core/protocol.ts` (`MutationStatus`, wire-details type)
- Modify: `native/Sources/ComputerUseCore/Protocol.swift` (`MutationStatus`, `JSONValue`, `NativeFailure`, `WireError`, `WireReply.failure`)
- Modify: `native/Sources/ComputerUseCore/NativeService.swift` (forward `NativeFailure.details`)
- Modify: `fixtures/cli/mock-host.mjs` (status fixture mode)
- Modify: `tests/backend-macos.test.ts` (wire/public status assertions)
- Modify: `native/Tests/ComputerUseCoreTests/ProtocolTests.swift` (shared spelling/encoding assertions)
- Modify: `native/Tests/ComputerUseCoreTests/SnapshotTests.swift` (dispatcher roundtrip with injected pure failure)
- Modify: `src/backend/macos.ts` (`projectReply`, status parsing, `projectDetails`)

**Consumes:**

- Existing `Reply.error.details` JSON object.
- Existing `mutatesDesktop`, `syntheticFailure`, and supplied-value privacy functions.
- Existing `NativeService` error catch boundary.

**Produces:**

- `MutationStatus` with identical raw values in TS and Swift.
- `NativeFailure.details: [String: JSONValue]?` → `WireError.details` → encoded host reply.
- Conservative status projection for structured failures after dispatch.

### C3.1 — Add shared status spellings and red contract tests (2–5 min)

- [ ] Create `contracts/fixtures/native-replies.json` with this complete content:

```json
{
  "mutationStatuses": [
    {"name":"not-started","wire":"notStarted","public":null},
    {"name":"potentially-applied","wire":"potentiallyApplied","public":"potentiallyApplied"}
  ],
  "invalidMutationStatuses": ["not-started", "potentially_applied", "unknown", ""]
}
```

- [ ] In `fixtures/cli/mock-host.mjs`, insert this complete switch case immediately before `case 'stable-error-code'`:

```js
case 'mutation-status':
  writeAndExit(`${JSON.stringify({
    schemaVersion: 1,
    ok: false,
    command: request.command,
    error: {
      code: 'NATIVE_FAILURE',
      message: 'Mutation failed',
      details: request.text === '__missing__'
        ? { safe: 'kept' }
        : { mutationStatus: request.text ?? 'potentiallyApplied', safe: 'kept' },
    },
  })}\n`);
  break;
```

- [ ] In `tests/backend-macos.test.ts`, replace the existing `node:fs/promises` import and `modes` declaration with the following complete code:

```ts
import { chmod, copyFile, mkdtemp, readFile, rm } from 'node:fs/promises';

const modes = [
  'valid-response', 'invalid-json', 'wrong-command', 'invalid-response-data',
  'failure-missing-command', 'failure-wrong-command', 'incompatible-version',
  'execution-spawn-failure', 'nonzero-exit', 'success-then-exit-1',
  'never-exits', 'exits-after-receiving-request', 'ignores-sigterm',
  'requires-open-stdin', 'stdout-overflow', 'stderr-overflow',
  'request-on-stderr', 'reflected-success-data', 'reflected-root-target',
  'reflected-reordered-subtree', 'reflected-method', 'reflected-verification',
  'reflected-visualization', 'future-result-values', 'type-result', 'invalid-type-result',
  'reflected-error-message', 'reflected-error-details', 'reflected-root-error-details',
  'stable-error-code', 'unknown-error-code', 'slow-version', 'mutation-status',
];
```

- [ ] Add these complete tests after the existing synthetic post-dispatch mutation test:

```ts
it('projects exactly the shared native mutation-status spellings', async () => {
  const fixtures = JSON.parse(
    await readFile(new URL('../contracts/fixtures/native-replies.json', import.meta.url), 'utf8'),
  ) as {
    mutationStatuses: Array<{ name: string; wire: string; public: string | null }>;
    invalidMutationStatuses: string[];
  };
  const backend = new MacOSBackend({ helper: fixture('mutation-status') });
  for (const status of fixtures.mutationStatuses) {
    const reply = await backend.execute(mutationRequest(status.wire), new AbortController().signal);
    expect(reply, status.name).toMatchObject({ ok: false, error: { code: 'NATIVE_FAILURE' } });
    if (reply.ok) throw new Error('Expected failure');
    expect(reply.error.details, status.name).toEqual(
      status.public === null
        ? { safe: 'kept' }
        : { safe: 'kept', mutationStatus: status.public },
    );
  }
  for (const status of fixtures.invalidMutationStatuses) {
    const reply = await backend.execute(mutationRequest(status), new AbortController().signal);
    expect(reply, status).toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'set-value',
      error: {
        code: 'PROTOCOL_ERROR',
        message: 'Native helper returned an invalid response',
        details: { mutationStatus: 'potentiallyApplied' },
      },
    });
  }
});

it('conservatively marks a structured mutation failure with missing status', async () => {
  const backend = new MacOSBackend({ helper: fixture('mutation-status') });
  const reply = await backend.execute(mutationRequest('__missing__'), new AbortController().signal);
  expect(reply).toEqual({
    schemaVersion: 1,
    ok: false,
    command: 'set-value',
    error: {
      code: 'NATIVE_FAILURE',
      message: 'Mutation failed',
      details: { safe: 'kept', mutationStatus: 'potentiallyApplied' },
    },
  });
});

it('does not project mutation status for a non-mutating command', async () => {
  const backend = new MacOSBackend({ helper: fixture('mutation-status') });
  await expect(backend.execute(appsRequest(), new AbortController().signal)).resolves.toEqual({
    schemaVersion: 1,
    ok: false,
    command: 'apps',
    error: { code: 'NATIVE_FAILURE', message: 'Mutation failed', details: { safe: 'kept' } },
  });
});
```

- [ ] Replace the two existing exact expectations for reflected free-form error details with the following assertions, because status absence after dispatch is now conservative while the privacy result remains unchanged:

```ts
expect(reply.error.details).toEqual({ safe: 'kept', mutationStatus: 'potentiallyApplied' });
```

The affected tests are anchored by these current names:

- `does not expose supplied text from reflected error details at the CLI reply boundary`
- `omits supplied text represented as JSON ... from free-form error details`

- [ ] Run:

```sh
npm test -- tests/backend-macos.test.ts
```

Expected **RED**: explicit `notStarted` is currently discarded without being used to suppress uncertainty, missing structured status is not classified, and unknown status is silently removed rather than rejecting the wire reply.

### C3.2 — Add Swift details/status contract tests and prove RED (2–5 min)

- [ ] Add this complete test to `native/Tests/ComputerUseCoreTests/ProtocolTests.swift`:

```swift
func testMutationStatusWireSpellingsMatchSharedFixture() throws {
    let fixture = try contractFixture(named: "native-replies.json")
    let statuses = try XCTUnwrap(fixture["mutationStatuses"] as? [[String: Any]])
    let fixtureValues = try statuses.map { try XCTUnwrap($0["wire"] as? String) }
    let invalidValues = try XCTUnwrap(fixture["invalidMutationStatuses"] as? [String])
    XCTAssertEqual(Set(fixtureValues), Set(MutationStatus.allCases.map(\.rawValue)))
    for value in invalidValues { XCTAssertNil(MutationStatus(rawValue: value), value) }

    for value in fixtureValues {
        let status = try XCTUnwrap(MutationStatus(rawValue: value))
        let reply = WireReply.failure(
            command: .press,
            code: "NATIVE_FAILURE",
            message: "Mutation failed",
            details: ["mutationStatus": .string(status.rawValue)]
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any]
        let error = try XCTUnwrap(object?["error"] as? [String: Any])
        let details = try XCTUnwrap(error["details"] as? [String: Any])
        XCTAssertEqual(details["mutationStatus"] as? String, value)
    }
}
```

- [ ] Add this complete helper before `protocolFixtures()` and replace the path-loading body of `protocolFixtures()` with the implementation shown:

```swift
private func contractFixture(named name: String) throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("contracts/fixtures/\(name)")
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func protocolFixtures() throws -> [ProtocolFixture] {
    let object = try contractFixture(named: "native-protocol.json")
    return try XCTUnwrap(object["cases"] as? [[String: Any]]).map {
        ProtocolFixture(
            name: try XCTUnwrap($0["name"] as? String),
            valid: try XCTUnwrap($0["valid"] as? Bool),
            request: try XCTUnwrap($0["request"] as? [String: Any])
        )
    }
}
```

- [ ] Add this complete injected roundtrip test to `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`:

```swift
func testNativeFailureDetailsRoundTripThroughDispatcher() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try treeFixture("save-cancel")
    let lock = DesktopLock(rootURL: root)
    let now = Date(timeIntervalSince1970: 1_789_000_000)
    let service = SnapshotService(
        lock: lock,
        store: StateStore(rootURL: root, now: { now }),
        resolve: { _ in fixture.target },
        observe: { _, _ in
            throw NativeFailure(
                "NATIVE_FAILURE",
                "Injected observation failure",
                details: ["mutationStatus": .string("notStarted"), "safe": .string("kept")]
            )
        },
        now: { now }
    )
    let request = try XCTUnwrap(WireRequest.decode([
        "schemaVersion": 1,
        "command": "snapshot",
        "target": ["pid": 42, "windowId": 7],
        "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "full"],
        "options": ["timeoutMs": 1_000, "cursor": "off"]
    ]))

    let reply = NativeService(snapshotService: service).execute(request)

    XCTAssertEqual(reply.error?.code, "NATIVE_FAILURE")
    XCTAssertEqual(reply.error?.details, [
        "mutationStatus": .string("notStarted"),
        "safe": .string("kept")
    ])
}
```

- [ ] Run:

```sh
swift test --package-path native --filter ProtocolTests
swift test --package-path native --filter SnapshotTests/testNativeFailureDetailsRoundTripThroughDispatcher
```

Expected **RED at compile time**: `MutationStatus`, `NativeFailure(...details:)`, `WireReply.failure(...details:)`, `WireError.details`, and `JSONValue: Equatable` do not exist.

### C3.3 — Implement Swift details propagation without changing codes (2–5 min)

- [ ] In `native/Sources/ComputerUseCore/Protocol.swift`, insert this enum after the protocol constants:

```swift
public enum MutationStatus: String, Codable, CaseIterable {
    case notStarted, potentiallyApplied
}
```

- [ ] Replace `NativeFailure` with this complete struct:

```swift
public struct NativeFailure: Error, Equatable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?

    public init(_ code: String, _ message: String, details: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}
```

- [ ] Change the declaration of existing `JSONValue` to this exact declaration; its cases and Codable implementation remain unchanged by exact symbol reference:

```swift
public indirect enum JSONValue: Codable, Equatable {
```

- [ ] Replace `WireError` with this complete struct:

```swift
public struct WireError: Codable, Equatable {
    public let code: String
    public let message: String
    public let details: [String: JSONValue]?
}
```

- [ ] Replace `WireReply.failure` with this complete method:

```swift
public static func failure(
    command: WireCommand? = nil,
    code: String,
    message: String,
    details: [String: JSONValue]? = nil
) -> WireReply {
    WireReply(
        ok: false,
        command: command?.rawValue,
        data: nil,
        error: WireError(code: code, message: message, details: details)
    )
}
```

- [ ] In `native/Sources/ComputerUseCore/NativeService.swift`, replace only the `NativeFailure` catch clause with:

```swift
} catch let failure as NativeFailure {
    return .failure(
        command: request.command,
        code: failure.code,
        message: failure.message,
        details: failure.details
    )
```

- [ ] Run:

```sh
swift test --package-path native --filter ProtocolTests
swift test --package-path native --filter SnapshotTests/testNativeFailureDetailsRoundTripThroughDispatcher
```

Expected **GREEN**: both shared spellings encode exactly and injected details survive `NativeFailure → NativeService → WireReply`.

### C3.4 — Implement TS wire admission and conservative public projection (2–5 min)

- [ ] In `src/core/protocol.ts`, insert the status/details types immediately after `JsonValue`, then replace the failure member of `Reply` with the shown complete member:

```ts
export type MutationStatus = 'notStarted' | 'potentiallyApplied';
export type WireErrorDetails = Record<string, JsonValue> & { mutationStatus?: MutationStatus };
```

```ts
| { schemaVersion: 1; ok: false; command?: Command['command']; error: { code: string; message: string; details?: WireErrorDetails } };
```

- [ ] In `src/backend/macos.ts`, add `MutationStatus` to the existing type import so it becomes:

```ts
import type { Backend, JsonValue, MutationStatus, Reply, Request } from '../core/protocol.js';
```

- [ ] Replace the `projectReply` call in `MacOSBackend.execute` with:

```ts
return projectReply(value, request, execution.requestDispatched)
  ?? syntheticFailure(request, 'PROTOCOL_ERROR', 'Native helper returned an invalid response', execution.requestDispatched);
```

- [ ] Replace `projectReply` with this complete function:

```ts
function projectReply(value: unknown, request: Request, requestDispatched: boolean): Reply | undefined {
  if (!isRecord(value) || value.schemaVersion !== 1 || typeof value.ok !== 'boolean'
    || value.command !== request.command) return undefined;
  const supplied = suppliedValue(request);
  if (!value.ok) {
    if (!isRecord(value.error) || typeof value.error.code !== 'string' || typeof value.error.message !== 'string'
      || (value.error.details !== undefined && !isJsonRecord(value.error.details))
      || !STABLE_ERROR_CODES.has(value.error.code)) return undefined;
    const wireStatus = readMutationStatus(value.error.details);
    if (wireStatus === null) return undefined;
    const publicStatus = mutatesDesktop(request.command)
      && (wireStatus === 'potentiallyApplied' || (wireStatus === undefined && requestDispatched))
      ? 'potentiallyApplied'
      : undefined;
    const details = projectDetails(value.error.details ?? {}, supplied, publicStatus);
    return {
      schemaVersion: 1,
      ok: false,
      command: request.command,
      error: {
        code: value.error.code,
        message: reflectsSuppliedValue(value.error.message, supplied) ? '' : value.error.message,
        ...(details === undefined ? {} : { details }),
      },
    };
  }
  if (!isRecord(value.data)) return undefined;
  const data = projectData(request, value.data, supplied);
  return data === undefined
    ? undefined
    : { schemaVersion: 1, ok: true, command: request.command, data };
}
```

- [ ] Insert this complete parser immediately before `projectDetails`:

```ts
function readMutationStatus(value: Record<string, JsonValue> | undefined): MutationStatus | undefined | null {
  if (value === undefined || !Object.hasOwn(value, 'mutationStatus')) return undefined;
  if (value.mutationStatus === 'notStarted' || value.mutationStatus === 'potentiallyApplied') {
    return value.mutationStatus;
  }
  return null;
}
```

- [ ] Replace `projectDetails` with this complete function. This preserves the current free-form supplied-value checks and changes only mutation-status handling plus omission of an otherwise empty details object.

```ts
function projectDetails(
  value: Record<string, JsonValue>,
  supplied: SuppliedValue | undefined,
  mutationStatus: 'potentiallyApplied' | undefined,
): Record<string, JsonValue> | undefined {
  const freeForm: Record<string, JsonValue> = {};
  for (const [key, item] of Object.entries(value)) {
    if (key !== 'mutationStatus') freeForm[key] = item;
  }
  const contaminatedRoot = reflectsSuppliedValue(value, supplied) || reflectsSuppliedValue(freeForm, supplied);
  const projected = contaminatedRoot ? undefined : projectFreeFormRecord(freeForm, supplied);
  if (projected === undefined) return mutationStatus === undefined ? undefined : { mutationStatus };
  if (mutationStatus !== undefined) projected.mutationStatus = mutationStatus;
  return Object.keys(projected).length === 0 ? undefined : projected;
}
```

- [ ] Run:

```sh
npm test -- tests/backend-macos.test.ts
npm run typecheck
```

Expected **GREEN**: explicit `notStarted` suppresses public uncertainty, explicit/missing uncertainty is conservative after dispatch, malformed status becomes `PROTOCOL_ERROR` plus uncertainty, pre-dispatch tests remain status-free, and all privacy tests still omit supplied text.

### C3.5 — Review and checkpoint only error details/status (2–5 min)

- [ ] Review:

```sh
git diff --check
git diff -- contracts/fixtures/native-replies.json src/core/protocol.ts native/Sources/ComputerUseCore/Protocol.swift native/Sources/ComputerUseCore/NativeService.swift fixtures/cli/mock-host.mjs tests/backend-macos.test.ts native/Tests/ComputerUseCoreTests/ProtocolTests.swift native/Tests/ComputerUseCoreTests/SnapshotTests.swift src/backend/macos.ts
git status --short
```

Confirm:

- `contracts/errors.json` and `STABLE_ERROR_CODES` have no additions/removals.
- no native detail contains request text or full arguments;
- `projectFreeFormRecord`, `projectFreeFormValue`, `reflectsSuppliedValue`, and `equalJsonValues` are unchanged;
- `notStarted` appears only as internal native evidence and never in a returned public CLI fixture.

- [ ] If separately authorized, use interactive staging for inherited-dirty native files and commit only reviewed C3 hunks:

```sh
git add contracts/fixtures/native-replies.json src/core/protocol.ts fixtures/cli/mock-host.mjs tests/backend-macos.test.ts src/backend/macos.ts
git add -p native/Sources/ComputerUseCore/Protocol.swift native/Sources/ComputerUseCore/NativeService.swift native/Tests/ComputerUseCoreTests/ProtocolTests.swift native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --cached --check
git diff --cached
git commit -m "fix: preserve native mutation certainty"
```

---

## Task C4: Validate snapshot replies against the actual Swift producer shape

**One concern:** Replace snapshot's shallow JSON-object checks with a command-specific validator derived from `SnapshotResult.wireData`, `ResolvedTarget.jsonValue`, and `AXTreeSnapshot.treeJSON`. Do not infer or change screenshot/capture data.

**Files:**

- Create: `contracts/fixtures/snapshot-reply.json`
- Modify: `native/Tests/ComputerUseCoreTests/SnapshotTests.swift` (producer-to-fixture equality)
- Modify: `fixtures/cli/mock-host.mjs` (test sidecar reply mode)
- Modify: `tests/backend-macos.test.ts` (accept actual fixture; reject malformed variants)
- Modify: `src/core/validate.ts` (`isRecordId` predicate reused by throwing parser)
- Modify: `src/backend/macos.ts` (`snapshot` branch and snapshot-only validators)

**Consumes actual current producer fields:**

- `SnapshotResult.wireData`: `snapshotId`, `target`, `tree`, `truncated`, `createdAt`, `expiresAt`.
- `ResolvedTarget.jsonValue`: `pid`, `launchDate`, `bundleId`, `windowId`, `title`, `bounds`.
- `AXTreeSnapshot.treeJSON`: `{elements:[...]}` where every node requires `role`; may include `ref`, `subrole`, `identifier`, `title`, `label`, `value`, `actions`, `enabled`, `focused`, `selected`, `bounds`, and recursive `children`.
- Producer omission behavior: empty optional arrays/children and nil fields are omitted; `leafCompact` may legitimately produce `elements: []` when there are no refs.

**Produces:**

- Strict UUID validation for `snapshotId` using the same grammar as CLI record IDs.
- Strict UTC timestamp grammar for target launch and record times, plus exact ten-minute `createdAt → expiresAt` interval.
- Positive safe target IDs and refs; finite target/node bounds with nonnegative width/height.
- Recursive tree-node validation and projection of only actual producer fields.
- `PROTOCOL_ERROR` for malformed snapshot data.
- No change to the `screenshot` case; capture shape remains owned by its future design gate.

### C4.1 — Freeze one actual producer fixture and assert Swift emits it (2–5 min)

- [ ] Create `contracts/fixtures/snapshot-reply.json` with this complete envelope, rendered from current `save-cancel` evidence through the current producer rules:

```json
{
  "schemaVersion": 1,
  "ok": true,
  "command": "snapshot",
  "data": {
    "snapshotId": "123e4567-e89b-42d3-a456-426614174000",
    "target": {
      "pid": 42,
      "launchDate": "2026-09-08T10:00:00Z",
      "bundleId": "com.example.Editor",
      "windowId": 7,
      "title": "Document",
      "bounds": {"x": 100, "y": 100, "width": 600, "height": 400}
    },
    "tree": {
      "elements": [
        {
          "role": "AXWindow",
          "ref": 1,
          "title": "Document",
          "bounds": {"x": 100, "y": 100, "width": 600, "height": 400},
          "children": [
            {
              "role": "AXButton",
              "ref": 2,
              "title": "Save",
              "actions": ["AXPress"],
              "bounds": {"x": 500, "y": 450, "width": 70, "height": 30}
            },
            {
              "role": "AXButton",
              "ref": 3,
              "title": "Cancel",
              "actions": ["AXPress"],
              "bounds": {"x": 410, "y": 450, "width": 70, "height": 30}
            }
          ]
        }
      ]
    },
    "truncated": false,
    "createdAt": "2026-09-08T10:00:00.000Z",
    "expiresAt": "2026-09-08T10:10:00.000Z"
  }
}
```

- [ ] Add this complete test to `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`:

```swift
func testSnapshotWireDataMatchesSharedActualProducerFixture() throws {
    let snapshot = try treeFixture("save-cancel")
    let record = SnapshotRecord(
        id: "123e4567-e89b-42d3-a456-426614174000",
        createdAt: "2026-09-08T10:00:00.000Z",
        expiresAt: "2026-09-08T10:10:00.000Z",
        target: snapshot.target,
        treeOptions: snapshot.treeOptions,
        evidence: snapshot.evidence
    )
    let reply = WireReply.success(
        command: .snapshot,
        data: SnapshotResult(record: record, snapshot: snapshot).wireData
    )
    let actual = try XCTUnwrap(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? NSDictionary
    )
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let expected = try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("contracts/fixtures/snapshot-reply.json"))
        ) as? NSDictionary
    )

    XCTAssertEqual(actual, expected)
}
```

- [ ] Run:

```sh
swift test --package-path native --filter SnapshotTests/testSnapshotWireDataMatchesSharedActualProducerFixture
```

Expected **GREEN before TS implementation**. If it is red, stop and correct the fixture from `SnapshotResult.wireData`/`treeJSON` rather than changing production output to fit the draft. This is a producer-shape guard, not authorization to redesign the producer.

### C4.2 — Add backend acceptance/rejection tests and prove RED (2–5 min)

- [ ] In `fixtures/cli/mock-host.mjs`, add `readFileSync` to the imports:

```js
import { readFileSync } from 'node:fs';
```

- [ ] Insert this complete block immediately after `writeAndExit` is declared and before the existing `switch (mode)`:

```js
if (mode.startsWith('snapshot-reply-')) {
  const reply = readFileSync(`${process.argv[1]}.json`, 'utf8').trim();
  writeAndExit(`${reply}\n`);
  return;
}
```

- [ ] In `tests/backend-macos.test.ts`, replace the existing fs import with:

```ts
import { chmod, copyFile, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
```

- [ ] Add these mode constants immediately after `mockHost`, and spread them into the existing `modes` array:

```ts
const snapshotReplyModes = [
  'snapshot-reply-valid',
  'snapshot-reply-invalid-id',
  'snapshot-reply-invalid-target',
  'snapshot-reply-invalid-tree',
  'snapshot-reply-invalid-created-at',
  'snapshot-reply-invalid-lifetime',
];
```

```ts
...snapshotReplyModes,
```

- [ ] Add this complete request helper after `typeRequest`:

```ts
function snapshotRequest(): Request {
  return {
    schemaVersion: 1,
    command: 'snapshot',
    options: { timeoutMs: DEFAULT_TIMEOUT_MS, cursor: 'on' },
    target: { app: 'Editor', windowId: 7 },
    tree: { maxDepth: 8, maxElements: 500, hintMode: 'full' },
  };
}
```

- [ ] Append this complete setup block to the existing `beforeAll`, after all mode executables are copied/chmodded. It writes only test-owned sidecars in the temporary fixture directory.

```ts
const validSnapshotReply = JSON.parse(
  await readFile(new URL('../contracts/fixtures/snapshot-reply.json', import.meta.url), 'utf8'),
) as Record<string, unknown>;
const snapshotReplies: Record<string, Record<string, unknown>> = {
  'snapshot-reply-valid': structuredClone(validSnapshotReply),
  'snapshot-reply-invalid-id': structuredClone(validSnapshotReply),
  'snapshot-reply-invalid-target': structuredClone(validSnapshotReply),
  'snapshot-reply-invalid-tree': structuredClone(validSnapshotReply),
  'snapshot-reply-invalid-created-at': structuredClone(validSnapshotReply),
  'snapshot-reply-invalid-lifetime': structuredClone(validSnapshotReply),
};
const dataFor = (mode: string) => (snapshotReplies[mode].data as Record<string, unknown>);
dataFor('snapshot-reply-invalid-id').snapshotId = 'not-a-uuid';
(dataFor('snapshot-reply-invalid-target').target as Record<string, unknown>).pid = 0;
const tree = dataFor('snapshot-reply-invalid-tree').tree as { elements: Array<{ children: Array<Record<string, unknown>> }> };
tree.elements[0].children[0].ref = 0;
dataFor('snapshot-reply-invalid-created-at').createdAt = '2026-09-08 10:00:00';
dataFor('snapshot-reply-invalid-lifetime').expiresAt = '2026-09-08T10:11:00.000Z';
await Promise.all(Object.entries(snapshotReplies).map(([mode, reply]) =>
  writeFile(`${fixture(mode)}.json`, `${JSON.stringify(reply)}\n`, { mode: 0o600 }),
));
```

- [ ] Add these complete tests after the general valid-response test:

```ts
it('accepts the shared snapshot reply emitted by the Swift producer shape', async () => {
  const expected = JSON.parse(
    await readFile(new URL('../contracts/fixtures/snapshot-reply.json', import.meta.url), 'utf8'),
  );
  const backend = new MacOSBackend({ helper: fixture('snapshot-reply-valid') });
  await expect(backend.execute(snapshotRequest(), new AbortController().signal)).resolves.toEqual(expected);
});

it.each(snapshotReplyModes.filter(mode => mode !== 'snapshot-reply-valid'))(
  'rejects malformed snapshot data from %s',
  async mode => {
    const backend = new MacOSBackend({ helper: fixture(mode) });
    await expect(backend.execute(snapshotRequest(), new AbortController().signal)).resolves.toEqual({
      schemaVersion: 1,
      ok: false,
      command: 'snapshot',
      error: { code: 'PROTOCOL_ERROR', message: 'Native helper returned an invalid response' },
    });
  },
);
```

- [ ] Run:

```sh
npm test -- tests/backend-macos.test.ts
```

Expected **RED**: current snapshot projection accepts malformed UUID, target IDs, nested refs/tree fields, timestamp grammar, and lifetime because it checks only strings/JSON records.

### C4.3 — Share strict UUID recognition with reply validation (2–5 min)

- [ ] In `src/core/validate.ts`, replace `recordId` with these complete functions; keep the current `UUID_PATTERN` unchanged:

```ts
export function isRecordId(value: unknown): value is string {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

export function recordId(value: string, name: string): string {
  if (!isRecordId(value)) throw new ArgumentError(`${name} must be a strict UUID`);
  return value;
}
```

- [ ] Add this import to `src/backend/macos.ts`:

```ts
import { isRecordId } from '../core/validate.js';
```

- [ ] Run:

```sh
npm run typecheck
npm test -- tests/cli-parse.test.ts
```

Expected **GREEN**: CLI UUID behavior is unchanged and the new predicate is available to the backend.

### C4.4 — Implement snapshot-only target/tree/time projection (2–5 min)

- [ ] In `src/backend/macos.ts:projectData`, replace only the current `case 'snapshot'` with:

```ts
case 'snapshot':
  return projectSnapshotData(data);
```

- [ ] Insert the following complete snapshot-only helpers immediately before the existing `type DoctorCheck` declaration. Do not reuse them in `case 'screenshot'` in this task.

```ts
function projectSnapshotData(data: Record<string, unknown>): Record<string, JsonValue> | undefined {
  if (typeof data.createdAt !== 'string' || typeof data.expiresAt !== 'string') return undefined;
  const target = projectSnapshotTarget(data.target);
  const tree = projectSnapshotTree(data.tree);
  const createdAt = parseWireTimestamp(data.createdAt);
  const expiresAt = parseWireTimestamp(data.expiresAt);
  if (!isRecordId(data.snapshotId) || target === undefined || tree === undefined
    || typeof data.truncated !== 'boolean' || createdAt === undefined || expiresAt === undefined
    || expiresAt.seconds !== createdAt.seconds + 10 * 60
    || expiresAt.nanoseconds !== createdAt.nanoseconds) return undefined;
  return {
    snapshotId: data.snapshotId,
    target,
    tree,
    truncated: data.truncated,
    createdAt: data.createdAt,
    expiresAt: data.expiresAt,
  };
}

function projectSnapshotTarget(value: unknown): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || !positiveSafeInteger(value.pid) || !isWireTimestamp(value.launchDate)
    || (typeof value.bundleId !== 'string' && value.bundleId !== null)
    || !positiveSafeInteger(value.windowId) || typeof value.title !== 'string') return undefined;
  const bounds = projectBounds(value.bounds);
  if (bounds === undefined) return undefined;
  return {
    pid: value.pid,
    launchDate: value.launchDate,
    bundleId: value.bundleId,
    windowId: value.windowId,
    title: value.title,
    bounds,
  };
}

function projectSnapshotTree(value: unknown): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || !Array.isArray(value.elements) || value.elements.length > 1) return undefined;
  const refs = new Set<number>();
  const elements: JsonValue[] = [];
  for (const element of value.elements) {
    const projected = projectSnapshotNode(element, refs);
    if (projected === undefined) return undefined;
    elements.push(projected);
  }
  for (let ref = 1; ref <= refs.size; ref += 1) {
    if (!refs.has(ref)) return undefined;
  }
  return { elements };
}

function projectSnapshotNode(value: unknown, refs: Set<number>): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || typeof value.role !== 'string' || value.role.length === 0) return undefined;
  const projected: Record<string, JsonValue> = { role: value.role };
  if (value.ref !== undefined) {
    if (!positiveSafeInteger(value.ref) || refs.has(value.ref)) return undefined;
    refs.add(value.ref);
    projected.ref = value.ref;
  }
  for (const field of ['subrole', 'identifier', 'title', 'label', 'value'] as const) {
    const item = value[field];
    if (item !== undefined) {
      if (typeof item !== 'string') return undefined;
      projected[field] = item;
    }
  }
  if (value.actions !== undefined) {
    if (!Array.isArray(value.actions) || !value.actions.every(item => typeof item === 'string')) return undefined;
    projected.actions = value.actions;
  }
  for (const field of ['enabled', 'focused', 'selected'] as const) {
    const item = value[field];
    if (item !== undefined) {
      if (typeof item !== 'boolean') return undefined;
      projected[field] = item;
    }
  }
  if (value.bounds !== undefined) {
    const bounds = projectBounds(value.bounds);
    if (bounds === undefined) return undefined;
    projected.bounds = bounds;
  }
  if (value.children !== undefined) {
    if (!Array.isArray(value.children)) return undefined;
    const children: JsonValue[] = [];
    for (const child of value.children) {
      const projectedChild = projectSnapshotNode(child, refs);
      if (projectedChild === undefined) return undefined;
      children.push(projectedChild);
    }
    projected.children = children;
  }
  return projected;
}

function projectBounds(value: unknown): Record<string, JsonValue> | undefined {
  if (!isRecord(value) || !finiteNumber(value.x) || !finiteNumber(value.y)
    || !nonnegativeFiniteNumber(value.width) || !nonnegativeFiniteNumber(value.height)) return undefined;
  return { x: value.x, y: value.y, width: value.width, height: value.height };
}

type WireTimestamp = { seconds: number; nanoseconds: number };

function parseWireTimestamp(value: unknown): WireTimestamp | undefined {
  if (typeof value !== 'string') return undefined;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?Z$/.exec(value);
  if (match === null) return undefined;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, fractionText = ''] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const date = new Date(0);
  date.setUTCFullYear(year, month - 1, day);
  date.setUTCHours(hour, minute, second, 0);
  if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1
    || date.getUTCDate() !== day || date.getUTCHours() !== hour
    || date.getUTCMinutes() !== minute || date.getUTCSeconds() !== second) return undefined;
  return {
    seconds: Math.floor(date.getTime() / 1_000),
    nanoseconds: Number(fractionText.padEnd(9, '0')),
  };
}

function isWireTimestamp(value: unknown): value is string {
  return parseWireTimestamp(value) !== undefined;
}
```

- [ ] Replace the existing `finiteNumber` helper declaration near the end of `src/backend/macos.ts` with this type-predicate form; behavior is unchanged, but it lets `projectBounds` return narrowed numbers without a cast:

```ts
function finiteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}
```

- [ ] Run:

```sh
npm test -- tests/backend-macos.test.ts
npm run typecheck
```

Expected **GREEN**: shared actual snapshot envelope is preserved exactly and every malformed sidecar becomes `PROTOCOL_ERROR`. Existing screenshot and mutation-result tests remain unchanged.

### C4.5 — Focused and integrated green verification (2–5 min each)

- [ ] Run the paired producer/consumer checks:

```sh
swift test --package-path native --filter SnapshotTests/testSnapshotWireDataMatchesSharedActualProducerFixture
npm test -- tests/backend-macos.test.ts
```

Expected **GREEN**.

- [ ] Run all mock-only TS checks and type diagnostics:

```sh
npm test
npm run typecheck
```

Expected **GREEN**; `npm test` still prints no native integration suite.

- [ ] Run current-source native checks separately:

```sh
npm run native-tests
npm run test:native-protocol
```

Expected **GREEN**; the second command visibly builds the host in the same invocation and then sends only version/malformed protocol input.

### C4.6 — Review and checkpoint only snapshot reply validation (2–5 min)

- [ ] Review:

```sh
git diff --check
git diff -- contracts/fixtures/snapshot-reply.json native/Tests/ComputerUseCoreTests/SnapshotTests.swift fixtures/cli/mock-host.mjs tests/backend-macos.test.ts src/core/validate.ts src/backend/macos.ts
git status --short
```

Confirm:

- every validated snapshot field is emitted by the current `wireData`/`jsonValue`/`treeJSON` symbols;
- no evidence-only fields such as paths, child counts, truncation boundaries, or live AX handles were invented in public `tree`;
- `case 'screenshot'` is unchanged;
- no privacy helper changed;
- no real desktop command appears in default or native integration tests.

- [ ] If separately authorized, interactively stage inherited-dirty files and commit only C4:

```sh
git add contracts/fixtures/snapshot-reply.json fixtures/cli/mock-host.mjs tests/backend-macos.test.ts src/core/validate.ts src/backend/macos.ts
git add -p native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --cached --check
git diff --cached
git commit -m "fix: validate native snapshot reply shape"
```

---

## Stage C exit criteria

- [ ] `npm test` is mock-only by construction and passes without a host path or native build artifact.
- [ ] `npm run test:native-protocol` builds current Swift source in the same invocation, passes the host by the test-only `NUVIN_COMPUTER_USE_TEST_HOST`, and never sends a protocol-valid desktop command.
- [ ] Every Node/XCTest child created by the touched integration/lock helpers has a deadline and TERM/KILL/reap cleanup on success and failure.
- [ ] TS CLI fixtures and Swift request fixtures agree on valid/invalid cases, including exact keys, app plus invalid PID, both exclusive scroll forms, and ref-scroll plus amount.
- [ ] Swift details round-trip through `NativeFailure → NativeService → WireReply`; TS admits exactly `notStarted|potentiallyApplied` as wire evidence.
- [ ] Public CLI output never exposes `notStarted`; it exposes `potentiallyApplied` only for mutating commands where native evidence says it may have started or dispatched structured failure lacks trustworthy status.
- [ ] Error-code set is unchanged and all supplied-text privacy tests remain green.
- [ ] The shared snapshot reply is produced by actual Swift `wireData/treeJSON/target` code and accepted by TS; malformed ID/target/tree/time/lifetime cases become `PROTOCOL_ERROR`.
- [ ] No capture-result shape, privacy redesign, live acceptance, install, obsolete-source deletion, or native mutation implementation is included.

