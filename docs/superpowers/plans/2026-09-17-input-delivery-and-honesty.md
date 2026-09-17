# Input Delivery + Honesty Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver `key`/`type` to the focused app via the HID event tap (so input reaches panel- and helper-hosted UI), add `type --global` and a `--to-process` opt-in, and make `verification` / `mutationStatus` report truthfully.

**Architecture:** The native helper (`native/Sources/ComputerUseCore/`) owns input posting and result classification; the TS CLI (`src/`) parses flags, serializes the request to the wire, and projects the reply. Today `key`/`type` post into the *target process's* event queue (`CGEvent.postToPid`), which never reaches UI owned by another process (open/save panels, helper-hosted windows). The fix has two halves: (1) **activate the target** — raise it frontmost so the intended app is focused — then (2) **deliver to the HID event tap** — the same mechanism bare `key` already uses — so the chord lands on the now-focused app, including panels and helper-hosted UI. `--app X` therefore means what it reads as: bring X to the front, then send to X.

**Tech Stack:** Swift 5.9 (AppKit, ApplicationServices, CoreGraphics), TypeScript (Node 22), XCTest + Vitest.

**Spec:** `docs/superpowers/specs/2026-09-17-window-targeting-and-input-delivery-design.md` — executors should read it first; it records the AX↔CG model, the activation-then-focus contract, and every rejected alternative. Field report: `docs/verification/2026-09-17-live-run-defects.md`. The window-targeting fixes those defects blocked on are already implemented and verified; this plan assumes that work is committed first (Task 1).

## Global Constraints

- One process per command: no in-memory state survives between CLI invocations.
- TDD: every behavior change gets a failing test first. Run `cd native && swift test` for Swift, `npm test` for TS, `npm run typecheck` for the CLI.
- `CGEvent` construction failure → `NATIVE_FAILURE`. Unrecognized chord → `INVALID_ARGUMENT`.
- Secrets must never travel via `--text` (visible in process lists); use `--text-file -` (stdin) for them. The CLI keeps text off argv already — don't regress that.
- A `--window` selector always requires `--app`/`--pid`. A targetless `key`/`type`/`scroll` is legal and means "deliver to focus."
- `--app`/`--pid` on `key`/`type` means "activate this app, then type into it." Activation raises the app frontmost first; if it can't be raised, the command fails `FOCUS_FAILED` rather than typing into the wrong app.
- **Wire validation gate:** `validRequest`/`hasExactKeys` (Protocol.swift:118-147) rejects any request whose keys don't exactly match a per-command allowlist — `PROTOCOL_ERROR` before dispatch. Adding `toProcess` or making `type`'s `target` optional changes the wire shape, so each task that touches the request shape MUST also update `validRequest` for that command. Without it the new dispatch code is unreachable.
- **Error/enum allowlists on the TS side:** `STABLE_ERROR_CODES` (macos.ts:10-16) rejects unknown error codes as `PROTOCOL_ERROR`; `CONTROLLED_RESULT_VALUES.verification` (macos.ts:18) is the documented legal-value set. New values (`FOCUS_FAILED`, `dispatched`) must be added there — `FOCUS_FAILED` must be added or every focus failure surfaces as `PROTOCOL_ERROR`.

---

### Task 1: Commit the targeting fix (precondition)

The join refactor (`WindowIDResolver.swift`, `TargetResolver.swift`, `AXTree.swift`) is uncommitted and later tasks touch the same files. Land it as its own commit so the diff stays reviewable and `git bisect` stays meaningful.

**Files:**
- Modify: `native/Sources/ComputerUseCore/AXTree.swift`, `native/Sources/ComputerUseCore/TargetResolver.swift`
- Create: `native/Sources/ComputerUseCore/WindowIDResolver.swift`, `native/Tests/ComputerUseCoreTests/WindowIDJoinTests.swift`
- Modify: `native/Tests/ComputerUseCoreTests/AXTrustTests.swift`

- [ ] **Step 1: Verify the suite is green**

Run: `cd native && swift test 2>&1 | tail -3`
Expected: `Executed 182 tests, with 0 failures`

- [ ] **Step 2: Verify the fix live**

Run: `node dist/cli.js windows --app "Google Chrome" --json`
Expected: `ok:true` with at least one Chrome window listed and `eligible:true`. (The id is machine/session-specific — e.g. `51732` in the field report — do not hardcode it.)

- [ ] **Step 3: Commit**

```bash
git add native/Sources/ComputerUseCore/AXTree.swift \
        native/Sources/ComputerUseCore/TargetResolver.swift \
        native/Sources/ComputerUseCore/WindowIDResolver.swift \
        native/Tests/ComputerUseCoreTests/WindowIDJoinTests.swift \
        native/Tests/ComputerUseCoreTests/AXTrustTests.swift
git commit -m "fix: join AX windows to CG ids via _AXUIElementGetWindow; degrade absent optional attrs"
```

> Leave `docs/verification/2026-09-17-live-run-defects.md` uncommitted or commit it separately — it is the field report, not the fix.

---

### Task 2: Add `postFocusedKey` to the input driver

A targeted `key`/`type` should deliver to whatever holds focus (the HID tap), like real hardware — this is what reaches open/save panels. The existing `postGlobalKey` already posts to `.cghidEventTap` but is named for the targetless case; add a clearly-named `postFocusedKey` that does the same posting, so `postGlobalKey` keeps its meaning and the targeted path gains focus delivery.

**Files:**
- Modify: `native/Sources/ComputerUseCore/NativeInput.swift` — both the `NativeInputDriver` **protocol** (:7-30, add `postFocusedKey`) and the `LiveInputDriver` conformance.
- Test: `native/Tests/ComputerUseCoreTests/ForegroundExecutionTests.swift` (records driver calls)

**Interfaces:**
- Consumes: existing `postGlobalKey(_ chord:context:)` driver method.
- Produces: `func postFocusedKey(_ chord: String, context: CommandContext) throws` on `NativeInput` **and** the `NativeInputDriver` protocol (both must be updated or the build breaks); `NativeInput.key` gains a `delivery` parameter.

- [ ] **Step 1: Write the failing test**

In `ForegroundExecutionTests.swift`, a `NativeInputDriver` recording mock already exists (it captures `keys`, `globalKeys`, `actions`). Add a test asserting a focused-delivery call hits the tap, not the pid path:

```swift
func testKeyFocusedDeliveryPostsToHIDTap() throws {
    let recorder = RecordingInputDriver()
    let input = NativeInput(driver: recorder)
    try input.key("cmd+s", to: 42, delivery: .focused, context: recordingContext())
    XCTAssertEqual(recorder.tapKeys, ["cmd+s"])
    XCTAssertEqual(recorder.pidKeys, [])
}
```

> If the recorder doesn't yet separate `tapKeys` from `pidKeys`, extend the mock: give `postKey` append to `pidKeys` and a new `postFocusedKey` append to `tapKeys`. Add `postFocusedKey` to the protocol's mock too.

- [ ] **Step 2: Run to verify it fails**

Run: `cd native && swift test --filter testKeyFocusedDeliveryPostsToHIDTap`
Expected: FAIL — `delivery:` argument label and `tapKeys` don't exist. Note this is a **compile** failure (Swift TDD-by-compilation): `swift test --filter` exits non-zero at build, not with a red test name. That satisfies the red step.

- [ ] **Step 3: Implement**

In `NativeInputDriver` (NativeInput.swift:7-30), add (and mirror in `RecordingDriver` in the test file, or the build fails):

```swift
/// Post a key/modifier chord to whatever currently holds keyboard focus,
/// via the HID event tap. Used by targeted key/type so input reaches
/// panel- and helper-hosted UI that does not share the app's event queue.
func postFocusedKey(_ chord: String, context: CommandContext) throws
```

Implement it in the concrete driver next to `postGlobalKey` (:175-190), sharing the chord→events construction:

```swift
public func postFocusedKey(_ chord: String, context: CommandContext) throws {
    try postKeyToTap(chord, context: context)
}

public func postGlobalKey(_ chord: String, context: CommandContext) throws {
    try postKeyToTap(chord, context: context)
}

private func postKeyToTap(_ chord: String, context: CommandContext) throws {
    try context.check()
    guard let (key, modifiers) = KeyChord.toCGEvent(chord) else {
        throw NativeFailure("INVALID_ARGUMENT", "Unrecognized key/modifier combination")
    }
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false) else {
        throw NativeFailure("NATIVE_FAILURE", "Unable to construct key event")
    }
    down.flags = modifiers
    up.flags = modifiers
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}
```

In `NativeInput`, add a `delivery` enum and overload `key` (:51-56):

```swift
public enum KeyDelivery {
    /// Post to the app's own event queue (reaches background apps, not panels).
    case process
    /// Post to the HID tap so the event lands on whatever holds focus (reaches
    /// panels and helper-hosted UI; the target must be focused).
    case focused
}

public func key(_ chord: String, to pid: Int, delivery: KeyDelivery = .focused, context: CommandContext) throws {
    guard KeyChord.isValid(chord) else {
        throw NativeFailure("INVALID_ARGUMENT", "Unrecognized key/modifier combination")
    }
    switch delivery {
    case .focused: try driver.postFocusedKey(chord, context: context)
    case .process: try driver.postKey(chord, to: pid, context: context)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd native && swift test --filter testKeyFocusedDeliveryPostsToHIDTap`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add native/Sources/ComputerUseCore/NativeInput.swift native/Tests/ComputerUseCoreTests/ForegroundExecutionTests.swift
git commit -m "feat: add focused-delivery key path via HID event tap"
```

---

### Task 3: Activate the target, then deliver `key`/`type` to focus

Two halves. (a) A targeted `key`/`type` first **activates** the resolved app — raises it frontmost — so the input lands on the app the flag named, not whatever happens to be focused. (b) It then posts to the **HID tap**, so the event reaches panels/helper-hosted UI inside that now-frontmost app. `--to-process` opts back into the background-queue path (`postToPid`), skipping activation.

**Files:**
- Modify: `native/Sources/ComputerUseCore/NativeService.swift` (:251-271 key, :272-290 type, `dispatchTargetMutation` :496-525, `init` :42-57, add the `activate` method)
- Modify: `native/Sources/ComputerUseCore/NativeInput.swift` (`type` delivery overload + focused text)
- Modify: `native/Sources/ComputerUseCore/Protocol.swift` (`validRequest` :143-147 for `.key`, :139-142 for `.type` — allow `toProcess`)
- Modify: `src/cli/parse.ts` (`--to-process`), `src/core/protocol.ts` (`toProcess` field)
- Modify: `src/backend/macos.ts` (add `'FOCUS_FAILED'` to `STABLE_ERROR_CODES` :10-16)
- Test: `native/Tests/ComputerUseCoreTests/ForegroundExecutionTests.swift`, `tests/cli-parse.test.ts`

**Interfaces:**
- Consumes: `NativeInput.key(_:to:delivery:context:)`, `.focused`/`.process`, `context.sleep(nanoseconds:)` (CommandContext.swift:113-129).
- Produces:
  - `protocol AppActivator { func activate(pid: Int, context: CommandContext) async throws }` — the test seam. `LiveActivator` is the real implementation; `NativeService.init` gains an `activator: AppActivator = LiveActivator()` parameter (same injection pattern as the existing `input:`/`environment:` params at :42-57). The service stores it and calls it in the `key`/`type` dispatch closure.
  - `key`/`type` wire field `toProcess: boolean` (optional, default false) — and `validRequest` must accept it (see Global Constraints).
  - `NativeInput.type(_:to:delivery:context:)`.
  - Test-only conveniences on `NativeService` that build a `WireRequest` and call `execute(_:context:)`, returning the `WireReply`. **These do not exist** — only `execute(_ request:context:)` exists today (:78). Add them as thin wrappers so the tests read `service.key(...)` instead of hand-building wire dicts. Signatures must match how the tests call them:
    - `func key(chord: String, to pid: Int?, toProcess: Bool = false, context: CommandContext) async -> WireReply` — `to:` optional (nil = global), `toProcess` defaulted so `service.key(chord:to:context:)` compiles.
    - `func type(text: String, to pid: Int?, toProcess: Bool = false, context: CommandContext) async -> WireReply` — same; `to: nil` is the global path.
    - `func press(snapshotId: String, ref: Int, context: CommandContext) async -> WireReply` — optional; only needed if Task 5 exercises the `verified` path through `execute` rather than relying on existing coverage (see Task 5 note).

#### Sub-task 3a: Activation primitive

- [ ] **Step 1: Write the failing test**

```swift
// A controllable AppActivator. `pollsUntilFrontmost` lets the test decide how
// many frontmost checks pass before the app reports frontmost; nil = never.
final class FakeActivator: AppActivator {
    var calls: [Int] = []
    var polls = 0
    let pollsUntilFrontmost: Int?
    init(pid: Int = 0, pollsUntilFrontmost: Int? = 1) { self.pollsUntilFrontmost = pollsUntilFrontmost }
    func activate(pid: Int, context: CommandContext) async throws {
        calls.append(pid)
        polls = 0
        guard let limit = pollsUntilFrontmost else {
            // never comes front — spin until the deadline trips
            while true { try context.check(); try await context.sleep(nanoseconds: 1_000_000) }
        }
        while polls < limit { polls += 1; try await context.sleep(nanoseconds: 1_000_000) }
    }
}

func testActivateWaitsUntilAppIsFrontmost() async throws {
    let activator = FakeActivator(pollsUntilFrontmost: 3)
    try await activator.activate(pid: 42, context: ctx)
    XCTAssertEqual(activator.calls, [42])
    XCTAssertGreaterThanOrEqual(activator.polls, 1)
}

func testActivateFailsWhenAppNeverComesFront() async throws {
    let activator = FakeActivator(pollsUntilFrontmost: nil)   // never frontmost
    await assertResolverFailure("FOCUS_FAILED") {
        try await activator.activate(pid: 42, context: shortContext())  // short deadline
    }
}
```

The `AppActivator` seam lives next to `NativeInput` (or in `NativeService.swift`); the service's `init` gains `activator: AppActivator = LiveActivator()` and the test injects `FakeActivator` so "frontmost" is controllable. `LiveActivator.activate` is the `NSRunningApplication`/`NSWorkspace` polling body below.

- [ ] **Step 2: Run to verify it fails**

Run: `cd native && swift test --filter testActivate`
Expected: FAIL — `AppActivator`/`activate`/`FOCUS_FAILED` don't exist yet (compile failure = red step).

- [ ] **Step 3: Implement activation**

Define the seam and the live implementation. Activation is a foreground operation (AppKit), so it runs on the main actor and inside the command deadline:

```swift
public protocol AppActivator {
    func activate(pid: Int, context: CommandContext) async throws
}

public struct LiveActivator: AppActivator {
    public init() {}
    /// Raise `pid` frontmost and wait until it actually is. The app may take a
    /// moment to activate; poll `NSWorkspace.shared.frontmostApplication` at a
    /// short interval bounded by the command deadline. Fails FOCUS_FAILED if the
    /// app cannot be brought forward.
    public func activate(pid: Int, context: CommandContext) async throws {
        let nsapp = await MainActor.run { NSRunningApplication(processIdentifier: pid_t(pid)) }
        guard let nsapp else { throw NativeFailure("TARGET_NOT_FOUND", "Process was not found") }

        await MainActor.run {
            nsapp.activate(options: [.activateAllWindows])
        }

        while true {
            try context.check()
            let frontPid = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
            if frontPid == pid_t(pid) { return }
            try await context.sleep(nanoseconds: 20_000_000)   // 20ms poll
        }
    }
}
```

(`NSRunningApplication.activate` returns `Bool`, not throws — drop `try`.) Wire it in: `NativeService.init` gains `activator: AppActivator = LiveActivator()` stored as `self.activator`; the `key`/`type` dispatch closure calls `self.activator.activate(...)`.

On expiry `context.check()` throws `TIMEOUT`; catch it and rethrow as `FOCUS_FAILED` so the caller sees a distinct, retryable code rather than a generic deadline error:

```swift
    } catch let failure as NativeFailure where failure.code == "TIMEOUT" {
        throw NativeFailure("FOCUS_FAILED", "App could not be brought to the front")
    }
```

> Note: `NSRunningApplication.activate` and `NSWorkspace.frontmostApplication` are AppKit/AppKit-adjacent — they must run on `MainActor`. Whether `.activateAllWindows` is wanted depends on whether a window-scoped `--window` should raise only that window; for the plain `--app` case it raises the app. Keep the option on the helper, not exposed to the CLI.

- [ ] **Step 4: Run to verify it passes**

Run: `cd native && swift test --filter testActivate`
Expected: PASS

#### Sub-task 3b: Wire activation + focused delivery into dispatch

- [ ] **Step 1: Write the failing test**

The service under test is built with `input: NativeInput(driver: recorder)` **and** `activator: FakeActivator()`. Extend `Recorder` with the members the asserts read: `tapKeys: [String]` (append in `postFocusedKey`), `pidKeys: [String]` (append in `postKey`), `tapText: [String]` (append in `postFocusedText`, added in Step 3). `FakeActivator.calls` is the activation record. The `service.key(chord:to:toProcess:context:)` / `service.type(text:to:toProcess:context:)` conveniences (see Interfaces) build the `WireRequest` and call `execute`.

```swift
func testTargetedKeyActivatesThenPostsToTap() async throws {
    _ = try await service.key(chord: "cmd+s", to: windowPid, context: ctx)
    XCTAssertEqual(activator.calls, [windowPid])   // activated first
    XCTAssertEqual(recorder.tapKeys, ["cmd+s"])    // then tapped to focus
    XCTAssertEqual(recorder.pidKeys, [])
}

func testToProcessKeySkipsActivationAndPostsToQueue() async throws {
    _ = try await service.key(chord: "cmd+s", to: windowPid, toProcess: true, context: ctx)
    XCTAssertEqual(activator.calls, [])
    XCTAssertEqual(recorder.pidKeys, ["cmd+s"])
}
```

And the wrong-app guard — a `key` whose activation fails must not type into whatever is focused:

```swift
func testKeyFailsRatherThanTypingIntoWrongAppWhenFocusFails() async throws {
    // service built with FakeActivator(pollsUntilFrontmost: nil) — never frontmost
    let reply = await service.key(chord: "cmd+s", to: windowPid, context: shortContext())
    XCTAssertFalse(reply.ok)
    XCTAssertEqual(replyErrorCode(reply), "FOCUS_FAILED")
    XCTAssertEqual(recorder.tapKeys, [])   // nothing was dispatched
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd native && swift test --filter testTargetedKeyActivates`
Expected: FAIL — no `AppActivator`, `toProcess`, `service.key`, or recorder `tapKeys`/`pidKeys`/`tapText` (compile failure = red step).

- [ ] **Step 3: Implement**

`src/core/protocol.ts` (:17-18): add `toProcess?: boolean` to `type` and `key`.
`src/cli/parse.ts`: add `'to-process'` to `key` and `type` flag lists; map both cases to `toProcess: true`. In `key`/`type`, reject `--to-process` without a target (a bare `key` is already global).

`src/backend/macos.ts` (:10-16): add `'FOCUS_FAILED'` to `STABLE_ERROR_CODES` — otherwise a focus failure projects as `PROTOCOL_ERROR` and `mutationStatus` is dropped.

`native/Sources/ComputerUseCore/Protocol.swift` `validRequest`: allow `toProcess`. For `.key` (:143-147) accept `base ∪ {key, toProcess}` and `base ∪ {target, key, toProcess}` (and validate `toProcess` is a bool when present). For `.type` (:139-142) add `toProcess` to the accepted set — the optional-`target` change lands in Task 4, so for now keep `target` required.

`NativeService.swift` `key` dispatch (:251-271):

```swift
let toProcess = request.object["toProcess"] as? Bool ?? false
let resolved = try await targetResolver.resolve(selector, context: context)
return try await dispatchTargetMutation(
    command: .key, target: resolved, context: context
) { context in
    if !toProcess {
        try await self.activator.activate(pid: resolved.identity.pid, context: context)
    }
    try self.input.key(key, to: resolved.identity.pid,
                       delivery: toProcess ? .process : .focused, context: context)
    return mutationResult(method: "cg-event", verification: "dispatched")
}
```

`type` dispatch (:272-290) mirrors this: activate unless `toProcess`, then `input.type(text, to: pid, delivery: ...)` — `.focused` → `postFocusedText`, `.process` → `postText`.

`NativeInput.swift`: add `postFocusedText` to the `NativeInputDriver` protocol **and** `LiveInputDriver` (post each scalar's down/up to `.cghidEventTap`, same 4ms pacing as `postText`) plus a `NativeInput.type(_:to:delivery:context:)` overload switching on `KeyDelivery`. Mirror `postFocusedText` in the test `RecordingDriver` (append to `tapText`).

- [ ] **Step 4: Run to verify it passes**

Run: `cd native && swift test` and `npm test -- tests/cli-parse.test.ts` and `npm run typecheck`
Expected: all PASS. Also re-run `tests/backend-macos.test.ts` — adding `FOCUS_FAILED` to `STABLE_ERROR_CODES` should not regress the existing invalid-code projections.

- [ ] **Step 5: Commit**

```bash
git add native/Sources/ComputerUseCore/ src/cli/parse.ts src/core/protocol.ts src/backend/macos.ts native/Tests/ tests/
git commit -m "feat: activate target then deliver key/type to focus; add --to-process opt-in"
```

---

### Task 4: Add `type --global` (targetless text entry)

`key` already has a targetless mode (bare `key` → `postGlobalKey` → HID tap). `type` requires `--app`, so when targeting breaks there is no way to enter text. Add `type --global` — and bare `type` with no target — posting to focus.

**Files:**
- Modify: `src/cli/parse.ts` (:104-123 `type` valueNames + case; `FlagName` :15 add `'global'`), `src/core/protocol.ts` (:17 — make `type`'s `target` optional)
- Modify: `native/Sources/ComputerUseCore/NativeService.swift` (:272-290)
- Modify: `native/Sources/ComputerUseCore/Protocol.swift` (`validRequest` `.type` :139-142 — `target` now optional, `toProcess` allowed)
- Modify: `src/cli/run.ts` (help line :41 — `type` target is now optional; add `--to-process`/`--global`)
- Test: `tests/cli-parse.test.ts`, `native/Tests/ComputerUseCoreTests/ForegroundExecutionTests.swift`

**Interfaces:**
- Consumes: `postFocusedText` from Task 3, `dispatchGlobalMutation` (:529-538), `service.type(text:to:context:)` convenience from Task 3.
- Produces: `type` accepts `{ command:'type'; target?: Target; text: string; toProcess?: boolean }`; a `--global` flag on `type` (explicit no-target, equivalent to bare `type`).

- [ ] **Step 1: Write the failing test**

`tests/cli-parse.test.ts` — bare `type` and explicit `--global`:

```ts
it('type without a target parses as global text entry', () => {
  const r = parse(['type', '--text', 'hello']);
  expect(r.kind).toBe('request');
  // @ts-expect-error narrow
  expect(r.request.target).toBeUndefined();
});
it('type --global parses as global text entry', () => {
  const r = parse(['type', '--global', '--text', 'hello']);
  expect(r.kind).toBe('request');
  // @ts-expect-error narrow
  expect(r.request.target).toBeUndefined();
});
it('type --to-process without a target is rejected', () => {
  const r = parse(['type', '--to-process', '--text', 'hello']);
  expect(r.kind).toBe('error');   // --to-process requires a target
});
```

`ForegroundExecutionTests.swift` — targetless type hits the tap (uses the `service.type(text:to:context:)` convenience and `recorder.tapText` from Task 3):

```swift
func testGlobalTypePostsToHIDTap() async throws {
    _ = await service.type(text: "hello", to: nil, context: ctx)
    XCTAssertEqual(recorder.tapText, ["hello"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tests/cli-parse.test.ts`
Expected: FAIL — `type` currently requires `--app`/`--pid` (`target()` throws), and `--global` is an unknown option (not in `FlagName`).

- [ ] **Step 3: Implement**

`src/core/protocol.ts:17`: `target?: Target` on `type`.
`src/cli/parse.ts`: add `'global'` to `FlagName` (:15). In `valuesFor` make `type` accept the optional target flags and add `global`/`to-process` to its flag list. In `case 'type'` use `optionalTarget` (not `target`); treat `--global` as "target must be absent" — reject `--global` together with `--app`/`--pid`/`--window`. Mirror `key`'s `--window`-without-target guard. Reject `--to-process` when there is no target.

`src/cli/run.ts` (:41-42): update the `type` help line — target now optional — and add `--to-process`/`--global` to `type` and `key` help.

`native/Sources/ComputerUseCore/Protocol.swift` `validRequest` `.type` (:139-142): `target` is now optional and `toProcess` allowed — accept `base ∪ {text, allowClipboardReplace}`, `… ∪ {target}`, `… ∪ {toProcess}`, and `… ∪ {target, toProcess}`; validate `target`/`toProcess`/`allowClipboardReplace` only when present.

`NativeService.swift` `type` dispatch: when `TargetSelector.decode` returns nil, run `dispatchGlobalMutation` → `input.globalText` (a new `NativeInput` method → `driver.postFocusedText`) instead of `resolve`.

- [ ] **Step 4: Run to verify it passes**

Run: `npm test -- tests/cli-parse.test.ts` and `cd native && swift test --filter testGlobalTypePostsToHIDTap`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add src/cli/parse.ts src/core/protocol.ts src/cli/run.ts native/Sources/ComputerUseCore/ tests/
git commit -m "feat: add type --global / targetless text entry via HID tap"
```

---

### Task 5: Honest `verification` field

`mutationResult(method:verification:)` (:395-401) emits `"verified"` as a literal. For AX actions (press/set-value/scroll-ref) the AX call result is a real verification. For CG-event input (`cg-event` method) only dispatch is provable — the event may be delivered but unobserved. Emit `"dispatched"` for `cg-event` results and keep `"verified"` for `accessibility` results.

**Files:**
- Modify: `native/Sources/ComputerUseCore/NativeService.swift` (:209-287, :477)
- Modify: `src/backend/macos.ts` (`CONTROLLED_RESULT_VALUES.verification` :18 — add `'dispatched'`)
- Test: `native/Tests/ComputerUseCoreTests/ForegroundExecutionTests.swift` — assert the wire `verification` value per method
- Docs: `docs/cli.md`, `docs/agent-guide.md`

**Interfaces:**
- Consumes: nothing new.
- Produces: `verification: "dispatched" | "verified"` on mutation replies. `projectResultValue` (macos.ts:466-469) passes `"dispatched"` through *functionally* — it only rejects values that reflect supplied text — but `CONTROLLED_RESULT_VALUES.verification` (:18) is the documented legal set, so add `'dispatched'` to it for contract cleanliness rather than relying on the pass-through.

- [ ] **Step 1: Write the failing test**

```swift
func testCGEventResultReportsDispatchedNotVerified() async throws {
    let reply = await service.key(chord: "cmd+s", to: windowPid, context: ctx)   // convenience from Task 3
    XCTAssertEqual(replyVerification(reply), "dispatched")
}
```

The `verified` accessibility side is a **non-regression** — those `mutationResult(method: "accessibility", ...)` sites are untouched and already covered by `testPressPerformsAXPress` (which drives `NativeInput.press` directly). Reaching `press`/`set-value` through `execute` needs a persisted snapshot (`withValidatedSnapshotAction`, SnapshotTests.swift:220) — too heavy for this task. So the positive check is the cg-event `dispatched` assertion above; confirm `verified` stays put by re-running the existing accessibility tests in Step 4, not by building a new end-to-end press. (If you do want the service-level verified check, add the optional `press` convenience and a snapshot fixture — not required.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd native && swift test --filter testCGEventResultReportsDispatchedNotVerified`
Expected: FAIL — currently emits `"verified"`.

- [ ] **Step 3: Implement**

At each `mutationResult(method: "cg-event", ...)` call site (:249, :262, :270, :287, :477) change `verification: "verified"` → `"dispatched"`. Leave the three `"accessibility"` sites (:209, :221, :230) as `"verified"`. If a shared helper makes this a one-argument change, prefer that.

`src/backend/macos.ts` (:18): add `'dispatched'` to `CONTROLLED_RESULT_VALUES.verification`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd native && swift test`
Expected: PASS; confirm no other test asserts `"verified"` for cg-event results.

- [ ] **Step 5: Update docs + Commit**

`docs/cli.md` and `docs/agent-guide.md`: correct the claim that `"verified"` means the input had effect. Concretely update: the pointer-ops line (`agent-guide.md:142` "Pointer ops report `verified` (the event dispatched)" — now `dispatched`), the `mutationStatus` honesty block (`agent-guide.md:170`), and any `FOCUS_FAILED`/`notStarted` mentions so docs enumerate the new code and the `dispatched` value. Then:

```bash
git add native/Sources/ComputerUseCore/NativeService.swift src/backend/macos.ts native/Tests/ docs/
git commit -m "fix: report cg-event mutations as dispatched, not verified"
```

---

### Task 6: Honest `mutationStatus` for pre-dispatch failures

`attachingStatus` (:556-561) already emits `notStarted` when `entered == false`, and `entered` only becomes true after validation inside the lock. Two distinct gaps keep a pre-dispatch `notStarted` from reaching the reply:

- **Native may not emit it.** `resolve` (:265) runs *before* `dispatchTargetMutation` is called, so a `TARGET_NOT_FOUND` thrown there is caught by the outer `catch` in `run` — which doesn't go through `attachingStatus` — and emits **no** `mutationStatus`.
- **TS drops it.** `projectReply` (macos.ts:198-201) sets `publicStatus` to `'potentiallyApplied'` only when `wireStatus === 'potentiallyApplied' || (wireStatus === undefined && requestDispatched)` — a wire-supplied `notStarted` is **dropped** (`publicStatus → undefined`, no `mutationStatus` in details), not coerced.

A `TARGET_NOT_FOUND` thrown during `resolve` must surface `notStarted` end-to-end.

**Files:**
- Modify: `src/backend/macos.ts` (:198-201 projection), `native/Sources/ComputerUseCore/NativeService.swift` (ensure every pre-dispatch failure emits `notStarted`)
- Modify: `contracts/fixtures/native-replies.json` (`mutationStatuses` :3 — `notStarted` `public` `null` → `"notStarted"`)
- Test: `tests/backend-macos.test.ts`, `native/Tests/ComputerUseCoreTests/ForegroundExecutionTests.swift`

**Interfaces:**
- Consumes: `readMutationStatus`, `projectReply`, `attachingStatus`.
- Produces: a wire error whose `details.mutationStatus` is `notStarted` when dispatch never began; the TS boundary preserves it.

- [ ] **Step 1: Write the failing test**

`tests/backend-macos.test.ts` — a dispatched `key` that fails with `TARGET_NOT_FOUND` and a wire `mutationStatus` of `notStarted` must project `notStarted`, not `potentiallyApplied`:

```ts
it('projects notStarted for a pre-dispatch target failure', async () => {
  // stub invoke() to return a wire error with details.mutationStatus='notStarted'
  const reply = await backend.execute(keyRequest, signal);
  expect(reply.error?.details?.mutationStatus).toBe('notStarted');
});
```

`ForegroundExecutionTests.swift` — a `key` whose resolve throws `TARGET_NOT_FOUND` before `dispatch` runs reports `notStarted`:

```swift
func testResolveFailureReportsNotStarted() async throws {
    await assertResolverFailure("TARGET_NOT_FOUND") { /* resolver that finds no window */ }
    // and the surfaced reply carries details.mutationStatus == "notStarted"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `npm test -- tests/backend-macos.test.ts` and `cd native && swift test --filter testResolveFailureReportsNotStarted`
Expected: FAIL — `notStarted` is dropped by `projectReply` (and may not be emitted natively at all).

- [ ] **Step 3: Implement**

Fix both ends:

1. `NativeService.swift` `run` catch-all: ensure a `NativeFailure` thrown before dispatch (e.g. `resolve` `TARGET_NOT_FOUND`, or `FOCUS_FAILED` from activation) attaches `mutationStatus: notStarted` for mutating commands (press/set-value/type/key/scroll/click/move/drag), matching the contract in `docs/agent-guide.md`. If the failure is caught before `dispatchTargetMutation`/`attachingStatus` runs, emit `notStarted` on that path too.
2. `macos.ts` `projectReply` (:198-201): when the wire supplies `notStarted`, **emit it** rather than dropping it — `publicStatus` should be `'notStarted'`, not `undefined`. Keep `potentiallyApplied` only for `wireStatus === 'potentiallyApplied' || (undefined && requestDispatched)`.
3. `contracts/fixtures/native-replies.json` (:3): change `{"name":"not-started","wire":"notStarted","public":null}` → `"public":"notStarted"`. The existing test `'projects exactly the shared native mutation-status spellings'` (backend-macos.test.ts:210-227) derives its expectation from this fixture (`public === null → {safe:'kept'}`, else `+ mutationStatus`), so the fixture update alone makes it assert the new behavior — no test-code edit needed. Verify it now expects `{safe:'kept', mutationStatus:'notStarted'}`.

- [ ] **Step 4: Run to verify it passes**

Run: `cd native && swift test` and `npm test`
Expected: PASS; the earlier `key`/`type` `TARGET_NOT_FOUND` replies now carry `mutationStatus: notStarted`, and the fixture-driven spellings test passes against the updated fixture.

- [ ] **Step 5: Commit**

```bash
git add src/backend/macos.ts native/Sources/ComputerUseCore/NativeService.swift contracts/fixtures/native-replies.json tests/
git commit -m "fix: emit mutationStatus notStarted for pre-dispatch target failures"
```

---

### Task 7: Re-verify the live failure matrix

End-to-end proof across the apps and defects this plan addresses.

- [ ] **Step 1: Reproduce the original failures**

```bash
node dist/cli.js windows --app "Google Chrome" --json          # was [] → now lists the window
node dist/cli.js snapshot --app "Google Chrome" --json          # was TARGET_NOT_FOUND → nodes+refs
node dist/cli.js snapshot --app Notes --json                    # was NATIVE_FAILURE → nodes+refs
```

Expected: all `ok:true`, nodes > 0, refs present.

- [ ] **Step 2: Verify focus delivery reaches a panel**

Open a TextEdit save/open panel, target TextEdit, `key --app TextEdit --key escape`, confirm the panel dismisses (previously no-op'd). Caveat: a save/open panel may be hosted by `openAndSavePanelService` (see `docs/cli.md` known-limitations), so activating TextEdit may not focus the panel — if escape doesn't dismiss it, that is a panel-hosting limitation to note, not necessarily a regression in focused delivery. Treat as a manual signal, not a deterministic pass/fail.

- [ ] **Step 3: Verify honesty fields**

```bash
node dist/cli.js key --app "Google Chrome" --key cmd+t --json    # verification: dispatched (not verified)
node dist/cli.js key --app "Nonexistent" --key cmd+t --json       # error FOCUS_FAILED + mutationStatus: notStarted
node dist/cli.js type --text "x" --json                            # works with no target (global)
node dist/cli.js type --global --text "x" --json                   # explicit global also works
```

Note `key --app "Nonexistent"` exercises `FOCUS_FAILED` only if the app resolves but can't be raised; a truly absent name resolves to `TARGET_NOT_FOUND` instead — both must carry `mutationStatus: notStarted`. Use a resolvable-but-unraisable target to specifically hit `FOCUS_FAILED`.

- [ ] **Step 4: Full suite**

Run: `cd native && swift test` and `npm test` and `npm run typecheck`
Expected: all green, no regressions.

- [ ] **Step 5: Commit nothing** — verification only.

---

## Out of scope (recorded, not in this plan)

- **D2** — `AXManualAccessibility` for Chromium renderer trees (separate concern; the semantic path already works on Chrome's chrome UI).
- **D5** — `activate`/open-window verb (new feature).
- **D6** — display-capture metadata (cosmetic).
- **Activity Monitor 0-node snapshot** — pre-existing `maxElements`/timeout issue, confirmed identical before and after the join fix.
