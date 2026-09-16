# Standalone CLI Foundation Lifecycle and Identity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close foundation blockers R2–R4 by giving each accepted native command one cancellable detached-task transaction, precise refreshed process/window/element identity, one monotonic deadline across lock/AX/state/action phases, and cleanup-complete host shutdown.

**Architecture:** The one-request Swift host creates one `CommandContext` and one retained `Task.detached`; that task owns the complete resource-bearing transaction while synchronous `MainActor.run` calls return only process metadata. `SnapshotService` remains the sole snapshot/action lock owner, `NativeService` owns the doctor lock only, and existing AX evidence and state-store implementations are extended in place rather than duplicated. Cooperative checks bound phase transitions and AX messaging, while durable snapshot publication and successful dispatch are explicit commit points.

**Tech Stack:** Node.js 22+, TypeScript 5.9, Vitest 3, Swift tools 5.9+ in Swift language mode v5, macOS 14+, Foundation, Dispatch, AppKit, ApplicationServices, CoreGraphics, Darwin, XCTest. No new package or framework dependency.

## Global Constraints

- Implementation starts from commit `5ce315185d53b24300108f438cb6f49b1abdf03c` in `/Users/marsch/Projects/nuvin-computer-use/.worktrees/standalone-cli`. Before each task, verify the preceding task commit is HEAD and inspect `git status --short`; never reset or absorb unrelated files.
- Public CLI syntax, `schemaVersion: 1`, the 15,000 ms default, accepted integer timeout range 1–120,000 ms, two-second Node-owned child cleanup grace, ten-minute record lifetime, state root, 0700 directories, and 0600 files remain unchanged.
- Keep exactly one package-local Swift host per command. Do not add a daemon, retry, implicit target, public `apps`/`windows`/actions/capture/cursor behavior, activation, input, permission prompt, live desktop test, or successful live snapshot test.
- One accepted request creates one absolute monotonic deadline and one lock-protected cancellation token. Parent/explicit cancellation and Swift task cancellation converge on it; at a checkpoint, interruption wins over simultaneous expiry.
- The worker is one retained `Task.detached` per accepted request. Do not create a shared/reentrant actor, `Task { }`, per-AX-call task, synchronous execute wrapper, `DispatchQueue.main.sync`, semaphore bridge to main, or nested desktop lock.
- `NSLock.lock()`/`unlock()` appear only in synchronous methods and are never held across `await`. `MainActor.run` bodies are synchronous and return only `Sendable` metadata values. Every injected `SnapshotService` transaction phase closure is async, throwing, and context-aware; pure identity predicates may remain synchronous.
- Use the injected sleeper whose system implementation is `Task.sleep(nanoseconds:)`. Do not use typed throws, `sending`, async autoclosures, `Synchronization.Mutex`, Swift Testing, Swift 6-only APIs, or new `Sendable` work around `WireRequest`.
- Before each live AX request group, fail if no positive budget remains, then call `AXUIElementSetMessagingTimeout` on the exact ref to be messaged with `Float(min(2.0, positiveRemainingSeconds))`. Equality of refs does not transfer timeout configuration.
- Production element continuity is `CFEqual` on verified `AXUIElement` refs. Do not add a production test marker, pointer-description parsing, serialized-handle identity, private API, or a test-only route into the executable target.
- Keep public identity key `launchDate`. Live production uses documented `ISO8601DateFormatter` options `[.withInternetDateTime, .withFractionalSeconds]`, UTC, which canonically emits three fractional digits. This intentionally preserves millisecond-separated same-second launches; it does not claim nanosecond output or distinguish sub-millisecond `Date` values. C4 parsers continue accepting 1–9 fractional digits and fixtures need not be rewritten.
- Preserve A1 classified AX statuses/type checks, A2 `AXEvidencePolicy`, A4 one no-follow owner-only fail-closed store and write/sync/rename/directory-sync order, C1 mock-only `npm test` versus current-source `npm run test:native-protocol`, C3 details plus exact `notStarted`/`potentiallyApplied`, and C4 snapshot shape plus `launchDate`.
- Durable snapshot publication commits only after rename and directory sync succeed. Do not check afterward, report timeout for an already committed record, delete a committed record as rollback, or add desktop mutation status to snapshot results.
- Action strictness: any post-hook process/window/evidence change or `CFEqual == false` is `STALE_SNAPSHOT` with zero dispatch. If continuity holds, rerun the same pure preflight on the refreshed element and dispatch only its newly prepared value with that refreshed element.
- Preflight is side-effect-free by contract. Preflight failure leaves records valid. Any failure after successful state-changing invalidation leaves them invalidated. Invalidation is private state, not desktop mutation. Before dispatch failures carry `notStarted`; once dispatch is invoked, uncertain failures carry `potentiallyApplied`.
- Host states are `ready`, `running`, `cancelling`, `finished`. Empty startup EOF is silent; partial unterminated input emits exactly one `PROTOCOL_ERROR`. Parent EOF during work cancels context and task, suppresses reply, and waits for completion/cleanup. Cancel-before-start worker execution still calls completion.
- New deterministic concurrency tests run blocked work in `Task.detached`, await bounded expectations from the test task, and release barriers from the test side. Every semaphore/barrier has bounded cleanup through `defer`; no test task blocks on a semaphore it alone can release.
- Every task follows RED then GREEN, receives scoped review, stages only listed files/hunks, and creates exactly one task commit. Do not run tasks in parallel on shared files.
- Record each task's RED/GREEN commands, scoped review verdict, commit SHA, and limitations in `.superpowers/sdd/foundation-lifecycle-identity-progress.md`. This ledger and the pre-existing untracked planning/review artifacts are out-of-band evidence; do not stage them in any L1–L6 task commit.

---

## File ownership and interface map

| Task | Owned files | Interface produced for later tasks |
|---|---|---|
| L1 | Create `native/Sources/ComputerUseCore/CommandContext.swift`; create `native/Tests/ComputerUseCoreTests/CommandContextTests.swift` | `NativeClock`, `CommandCancellation`, `CommandContext`, `check()`, `checkLockWait(observedContention:)`, clamped `sleep(nanoseconds:)` |
| L2 | Modify `DesktopLock.swift`, `HostSupport.swift`, `SnapshotService.swift`, `NativeService.swift`, `Protocol.swift`, `HostMain.swift`, and affected Swift tests; create `AsyncAssertions.swift` | Async context-aware lock/service boundary; `HostSession.Work -> Task<Void, Never>` retaining detached worker; no sync compatibility path |
| L3 | Modify `TargetResolver.swift`, visibility/identity seam in `AXTree.swift`, resolver defaults in `SnapshotService.swift`, `TargetResolverTests.swift` | Main-actor process metadata, selected-PID window provider, millisecond UTC launch identity, persisted failure mapping, `AXElementIdentity`/`liveAXElementsAreIdentical` |
| L4 | Modify `AXTree.swift`, `DesktopLock.swift` directory checkpoints, `StateStore.swift`, context plumbing in `SnapshotService.swift`/`TargetResolver.swift`, and focused tests | Context-aware AX traversal/capture and state methods; exact-ref AX timeout preparation; durable publication contract |
| L5 | Modify `SnapshotService.swift` and migrated `SnapshotTests.swift`; create `SnapshotTransactionTests.swift` | Final snapshot/action phase order, foreground seam, continuity, second preflight, dispatch pairing, mutation certainty |
| L6 | Modify `HostSupport.swift`, `HostMain.swift`, `HostLifecycleTests.swift`, `tests/native-protocol.test.ts` | Final four-state one-request host, empty/partial EOF classification, cleanup-before-main-thread shutdown |

### Frozen cross-task signatures

Later tasks must use these names exactly; if an earlier implementation cannot compile with them under Swift 5.9/v5, stop and amend that producer and every consumer in the same reviewed task rather than creating a second API.

```text
public struct NativeClock {
    public let monotonicNow: () -> UInt64
    public let wallNow: () -> Date
    public let sleepNanoseconds: (UInt64) async throws -> Void
}

public final class CommandCancellation {
    public var isCancelled: Bool { get }
    public func cancel()
    public func onCancel(_ handler: @escaping () -> Void)
}

public final class CommandContext {
    public let deadline: UInt64
    public let clock: NativeClock
    public let cancellation: CommandCancellation
    public var wallNow: Date { get }
    public var remainingNanoseconds: UInt64 { get }
    public var isCancelled: Bool { get }
    public func cancel()
    public func onCancel(_ handler: @escaping () -> Void)
    public func check() throws
    func checkLockWait(observedContention: Bool) throws
    public func sleep(nanoseconds: UInt64) async throws
}

public func DesktopLock.withLock<T>(
    context: CommandContext,
    _ body: () async throws -> T
) async throws -> T

public func NativeService.execute(_ request: WireRequest, context: CommandContext) async -> WireReply

public typealias AXElementIdentity = (LiveAXElement, LiveAXElement) -> Bool

SnapshotService.PrepareElement = (LiveAXElement, CommandContext) async throws -> Void
```

---

### Task L1: Command context, cancellation token, and clocks

**Files:**
- Create: `native/Sources/ComputerUseCore/CommandContext.swift`
- Create: `native/Tests/ComputerUseCoreTests/CommandContextTests.swift`
- Do not modify: all existing production and test files

**Interfaces:**
- Consumes: existing `NativeFailure` from `native/Sources/ComputerUseCore/Protocol.swift`.
- Produces: the frozen `NativeClock`, `CommandCancellation`, and `CommandContext` signatures above. L2–L6 use the same context object; no caller migration occurs in L1.

- [ ] **Step 1: Add the complete failing context test file**

Create `native/Tests/ComputerUseCoreTests/CommandContextTests.swift`:

```swift
import XCTest
@testable import ComputerUseCore

final class CommandContextTests: XCTestCase {
    func testDeadlineUsesExclusiveUpperBound() throws {
        var now: UInt64 = 1_000
        let context = CommandContext(timeoutMilliseconds: 1, clock: frozenClock { now })
        XCTAssertEqual(context.deadline, 1_001_000)
        XCTAssertNoThrow(try context.check())
        now = 1_001_000
        XCTAssertThrowsError(try context.check()) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
            XCTAssertEqual(($0 as? NativeFailure)?.message, "Desktop operation deadline expired")
        }
    }

    func testExplicitCancellationWinsAtExpiredDeadline() {
        var now: UInt64 = 0
        let cancellation = CommandCancellation()
        let context = CommandContext(
            timeoutMilliseconds: 1,
            clock: frozenClock { now },
            cancellation: cancellation
        )
        cancellation.cancel()
        now = context.deadline
        XCTAssertThrowsError(try context.check()) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
            XCTAssertEqual(($0 as? NativeFailure)?.message, "Interrupted")
        }
    }

    func testWallClockIsIndependentOfMonotonicDeadline() {
        var monotonic: UInt64 = 5
        var wall = Date(timeIntervalSince1970: 100)
        let context = CommandContext(
            timeoutMilliseconds: 1,
            clock: NativeClock(
                monotonicNow: { monotonic },
                wallNow: { wall },
                sleepNanoseconds: { _ in }
            )
        )
        monotonic = 50
        wall = Date(timeIntervalSince1970: 999)
        XCTAssertEqual(context.deadline, 1_000_005)
        XCTAssertEqual(context.wallNow.timeIntervalSince1970, 999)
        XCTAssertEqual(context.remainingNanoseconds, 999_955)
    }

    func testDeadlineArithmeticSaturatesOnOverflow() {
        XCTAssertEqual(CommandContext.deadlineNanoseconds(now: 10, timeoutMilliseconds: Int.max), UInt64.max)
        XCTAssertEqual(
            CommandContext.deadlineNanoseconds(now: UInt64.max - 999_999, timeoutMilliseconds: 1),
            UInt64.max
        )
        XCTAssertEqual(
            CommandContext.deadlineNanoseconds(now: UInt64.max - 1_000_000, timeoutMilliseconds: 1),
            UInt64.max
        )
        XCTAssertEqual(CommandContext.deadlineNanoseconds(now: 7, timeoutMilliseconds: 0), 7)
        XCTAssertEqual(CommandContext.deadlineNanoseconds(now: 7, timeoutMilliseconds: -5), 7)
    }

    func testSleepClampsToRemainingBudget() async throws {
        var slept: UInt64 = 0
        let context = CommandContext(
            timeoutMilliseconds: 5,
            clock: NativeClock(
                monotonicNow: { 100 },
                wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { slept = $0 }
            )
        )
        try await context.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(slept, 5_000_000)
    }

    func testSleepMapsTaskCancellationToSharedInterruption() async {
        let cancellation = CommandCancellation()
        let context = CommandContext(
            timeoutMilliseconds: 5_000,
            clock: NativeClock(
                monotonicNow: { 0 },
                wallNow: { Date(timeIntervalSince1970: 0) },
                sleepNanoseconds: { _ in throw CancellationError() }
            ),
            cancellation: cancellation
        )
        await XCTAssertThrowsErrorAsyncLocal({
            try await context.sleep(nanoseconds: 1_000)
        }) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
        }
        XCTAssertTrue(cancellation.isCancelled)
    }

    func testTaskCancellationBridgesIntoSharedToken() async {
        let context = CommandContext(timeoutMilliseconds: 5_000, clock: frozenClock { 0 })
        let entered = expectation(description: "cancelled task entered")
        let task = Task.detached {
            entered.fulfill()
            while !Task.isCancelled { await Task.yield() }
            XCTAssertThrowsError(try context.check()) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
            }
            XCTAssertTrue(context.isCancelled)
        }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        await task.value
    }

    func testLockWaitUsesBusyOnlyAfterObservedContention() {
        var now: UInt64 = 0
        let context = CommandContext(timeoutMilliseconds: 1, clock: frozenClock { now })
        now = context.deadline
        XCTAssertThrowsError(try context.checkLockWait(observedContention: false)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
        }
        XCTAssertThrowsError(try context.checkLockWait(observedContention: true)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
        }
        context.cancel()
        XCTAssertThrowsError(try context.checkLockWait(observedContention: true)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
        }
    }
}

private func frozenClock(_ monotonicNow: @escaping () -> UInt64) -> NativeClock {
    NativeClock(
        monotonicNow: monotonicNow,
        wallNow: { Date(timeIntervalSince1970: 0) },
        sleepNanoseconds: { _ in }
    )
}

private func XCTAssertThrowsErrorAsyncLocal<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Asynchronous expression did not throw", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
```

- [ ] **Step 2: Verify RED for the intended missing interface**

Run:

```sh
swift test --package-path native --filter CommandContextTests
```

Expected RED: command exits non-zero while compiling the test target because `CommandContext`, `NativeClock`, and `CommandCancellation` do not exist. The test helpers themselves are fully defined; no failure should mention an undefined test helper.

- [ ] **Step 3: Add the complete minimal implementation**

Create `native/Sources/ComputerUseCore/CommandContext.swift`:

```swift
import Dispatch
import Foundation

public struct NativeClock {
    public let monotonicNow: () -> UInt64
    public let wallNow: () -> Date
    public let sleepNanoseconds: (UInt64) async throws -> Void

    public init(
        monotonicNow: @escaping () -> UInt64,
        wallNow: @escaping () -> Date,
        sleepNanoseconds: @escaping (UInt64) async throws -> Void
    ) {
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.sleepNanoseconds = sleepNanoseconds
    }

    public static let system = NativeClock(
        monotonicNow: { DispatchTime.now().uptimeNanoseconds },
        wallNow: Date.init,
        sleepNanoseconds: { try await Task.sleep(nanoseconds: $0) }
    )
}

public final class CommandCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let pending = handlers
        handlers.removeAll()
        lock.unlock()
        pending.forEach { $0() }
    }

    public func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            handlers.append(handler)
            lock.unlock()
        }
    }
}

public final class CommandContext {
    public let deadline: UInt64
    public let clock: NativeClock
    public let cancellation: CommandCancellation

    public init(
        timeoutMilliseconds: Int,
        clock: NativeClock = .system,
        cancellation: CommandCancellation = CommandCancellation()
    ) {
        self.clock = clock
        self.cancellation = cancellation
        deadline = Self.deadlineNanoseconds(
            now: clock.monotonicNow(),
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public var wallNow: Date { clock.wallNow() }

    public var remainingNanoseconds: UInt64 {
        let now = clock.monotonicNow()
        return now >= deadline ? 0 : deadline - now
    }

    public var isCancelled: Bool { cancellation.isCancelled }

    public func cancel() { cancellation.cancel() }

    public func onCancel(_ handler: @escaping () -> Void) {
        cancellation.onCancel(handler)
    }

    public func check() throws {
        try checkInterruption()
        if clock.monotonicNow() >= deadline {
            try checkInterruption()
            throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
        }
    }

    func checkLockWait(observedContention: Bool) throws {
        try checkInterruption()
        guard remainingNanoseconds == 0 else { return }
        try checkInterruption()
        if observedContention {
            throw NativeFailure("BUSY", "Another desktop operation is in progress")
        }
        throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
    }

    public func sleep(nanoseconds requested: UInt64) async throws {
        try check()
        if requested == 0 { return }
        let duration = min(requested, remainingNanoseconds)
        guard duration > 0 else {
            try check()
            return
        }
        do {
            try await withTaskCancellationHandler(operation: {
                try await clock.sleepNanoseconds(duration)
            }, onCancel: {
                self.cancellation.cancel()
            })
        } catch is CancellationError {
            cancellation.cancel()
            throw NativeFailure("INTERRUPTED", "Interrupted")
        }
        try check()
    }

    static func deadlineNanoseconds(now: UInt64, timeoutMilliseconds: Int) -> UInt64 {
        let milliseconds = UInt64(max(0, timeoutMilliseconds))
        let (increment, multiplied) = milliseconds.multipliedReportingOverflow(by: 1_000_000)
        if multiplied { return UInt64.max }
        let (value, added) = now.addingReportingOverflow(increment)
        return added ? UInt64.max : value
    }

    private func checkInterruption() throws {
        if cancellation.isCancelled {
            throw NativeFailure("INTERRUPTED", "Interrupted")
        }
        if Task.isCancelled {
            cancellation.cancel()
            throw NativeFailure("INTERRUPTED", "Interrupted")
        }
    }
}
```

`CommandCancellation` contains all `NSLock` calls in synchronous methods. The operation-level `withTaskCancellationHandler` in L2 will use this same token; L1's sleep handler already proves cancellation cannot leak as an unrelated `CancellationError`.

- [ ] **Step 4: Verify focused and unaffected GREEN**

Run:

```sh
swift test --package-path native --filter CommandContextTests
swift test --package-path native --filter DesktopLockTests
swift test --package-path native --filter SnapshotTests
swift test --package-path native --filter ProtocolTests
swift test --package-path native --filter HostLifecycleTests
swift test --package-path native --filter StateStoreTests
```

Expected GREEN: each command exits 0; all `CommandContextTests` pass and all named pre-existing suites remain green. L1 does not migrate a production caller.

- [ ] **Step 5: Perform scoped review**

Review only the two new files and confirm: deadline computed once; overflow saturates; `now == deadline` expires; wall clock does not affect deadline; interruption is checked again before timeout; sleeper is clamped; all lock operations are synchronous; no caller or host behavior changed.

- [ ] **Step 6: Stage exactly L1 and create its one commit**

```sh
git add native/Sources/ComputerUseCore/CommandContext.swift \
  native/Tests/ComputerUseCoreTests/CommandContextTests.swift
git diff --cached --check
git diff --cached --name-only
git commit -m "feat: add native command context"
```

Expected staged names: exactly the two files above. Record RED/GREEN output and review verdict in the execution ledger before L2.

---

### Task L2: Atomic async worker, lock, service, and caller migration

**Files:**
- Create: `native/Tests/ComputerUseCoreTests/AsyncAssertions.swift`
- Modify: `native/Sources/ComputerUseCore/DesktopLock.swift`
- Modify: `native/Sources/ComputerUseCore/HostSupport.swift`
- Modify: `native/Sources/ComputerUseCore/SnapshotService.swift`
- Modify: `native/Sources/ComputerUseCore/NativeService.swift`
- Modify: `native/Sources/ComputerUseCore/Protocol.swift`
- Modify: `native/Sources/ComputerUseHost/HostMain.swift`
- Modify: `native/Tests/ComputerUseCoreTests/StateStoreTests.swift`
- Modify: `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`
- Modify: `native/Tests/ComputerUseCoreTests/ProtocolTests.swift`
- Modify: `native/Tests/ComputerUseCoreTests/HostLifecycleTests.swift`
- Do not modify: `StateStore.swift`, `AXTree.swift`, `TargetResolver.swift`, TypeScript, fixtures, or `native/Package.swift`

**Interfaces:**
- Consumes: all L1 declarations exactly as frozen.
- Produces: async `DesktopLock.withLock(context:_:)`, async `SnapshotService` closure/method signatures, async `NativeService.execute(_:context:)`, `WireRequest.timeoutMilliseconds`, and a context-owning `HostSession.Work` returning a retained `Task<Void, Never>`. L3/L4 consume the closure signatures; L6 changes only framing and state transitions.

- [ ] **Step 1: Add the complete async XCTest assertion helper**

Create `native/Tests/ComputerUseCoreTests/AsyncAssertions.swift`:

```swift
import XCTest

func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(
            message().isEmpty ? "Asynchronous expression did not throw" : message(),
            file: file,
            line: line
        )
    } catch {
        errorHandler(error)
    }
}
```

The expression is a normal closure, not an async autoclosure.

- [ ] **Step 2: Rewrite lock tests to the new contract and add complete RED coverage**

In `StateStoreTests.testRootSymlinkAndPathSwapNeverChmodUnrelatedObject`, make the method `async throws` and replace the lock assertion with:

```swift
await XCTAssertThrowsErrorAsync({
    try await DesktopLock(rootURL: symlink).withLock(
        context: CommandContext(timeoutMilliseconds: 100)
    ) {}
})
```

Make `testLockSetupDoesNotCreateSnapshotDirectory` `async throws` and replace its lock call with:

```swift
try await lock.withLock(context: CommandContext(timeoutMilliseconds: 100)) {}
```

Replace the three named methods in `DesktopLockTests` with these complete methods, and add the final three methods:

```swift
func testBusyAcquisitionIsDeadlineBounded() async throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let ready = root.appendingPathComponent("ready")
    let owner = try spawnLockHelper(
        root: root,
        log: root.appendingPathComponent("owner.log"),
        holdMicroseconds: 500_000,
        ready: ready
    )
    defer { terminateAndWait(owner) }
    try waitForFile(ready)

    let start = DispatchTime.now().uptimeNanoseconds
    await XCTAssertThrowsErrorAsync({
        try await DesktopLock(rootURL: root).withLock(
            context: CommandContext(timeoutMilliseconds: 50)
        ) {}
    }) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
    }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    XCTAssertLessThan(elapsed, 0.5)
    try waitForExit(owner)
    XCTAssertEqual(owner.terminationStatus, 0)
}

func testSuccessfulFlockAtDeadlineIsReleasedWithoutRunningBody() async {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var now: UInt64 = 9
    let context = CommandContext(
        timeoutMilliseconds: 1,
        clock: NativeClock(
            monotonicNow: { now },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
    var operations: [Int32] = []
    let lock = DesktopLock(rootURL: root, flock: { _, operation in
        operations.append(operation)
        now = context.deadline
        return SystemCallResult(value: 0, error: 0)
    })
    var bodyRan = false

    await XCTAssertThrowsErrorAsync({
        try await lock.withLock(context: context) { bodyRan = true }
    }) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
    }
    XCTAssertFalse(bodyRan)
    XCTAssertEqual(operations, [LOCK_EX | LOCK_NB, LOCK_UN])
}

func testEINTRRetryChecksDeadlineBeforeAnotherFlockAttempt() async {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var now: UInt64 = 9
    let context = CommandContext(
        timeoutMilliseconds: 1,
        clock: NativeClock(
            monotonicNow: { now },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
    var attempts = 0
    let lock = DesktopLock(rootURL: root, flock: { _, _ in
        attempts += 1
        now = context.deadline
        return SystemCallResult(value: -1, error: EINTR)
    })
    var bodyRan = false

    await XCTAssertThrowsErrorAsync({
        try await lock.withLock(context: context) { bodyRan = true }
    }) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
    }
    XCTAssertEqual(attempts, 1)
    XCTAssertFalse(bodyRan)
}

func testContendedWaitExpiresAsBusy() async {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var now: UInt64 = 0
    let lock = DesktopLock(rootURL: root, flock: { _, _ in
        now = 1_000_000
        return SystemCallResult(value: -1, error: EWOULDBLOCK)
    })
    let context = CommandContext(
        timeoutMilliseconds: 1,
        clock: NativeClock(
            monotonicNow: { now },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
    await XCTAssertThrowsErrorAsync({
        try await lock.withLock(context: context) {}
    }) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
    }
}

func testLockSleepIsClampedToRemainingBudget() async {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var now: UInt64 = 0
    var slept: [UInt64] = []
    let lock = DesktopLock(rootURL: root, flock: { _, _ in
        SystemCallResult(value: -1, error: EWOULDBLOCK)
    })
    let context = CommandContext(
        timeoutMilliseconds: 5,
        clock: NativeClock(
            monotonicNow: { now },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { duration in
                slept.append(duration)
                now = 5_000_000
            }
        )
    )
    await XCTAssertThrowsErrorAsync({
        try await lock.withLock(context: context) {}
    }) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
    }
    XCTAssertEqual(slept, [5_000_000])
}

func testCancellationDuringWaitDoesNotUnlockAnUnheldLock() async {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    var operations: [Int32] = []
    let context = CommandContext(
        timeoutMilliseconds: 5_000,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in throw CancellationError() }
        )
    )
    let lock = DesktopLock(rootURL: root, flock: { _, operation in
        operations.append(operation)
        return SystemCallResult(value: -1, error: EWOULDBLOCK)
    })
    await XCTAssertThrowsErrorAsync({
        try await lock.withLock(context: context) {}
    }) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
    }
    XCTAssertEqual(operations, [LOCK_EX | LOCK_NB])
}
```

Make `testSubprocessLockHelper` `async throws`, preserving its name and body control flow, and replace only its lock call header with:

```swift
try await DesktopLock(rootURL: URL(fileURLWithPath: rootPath)).withLock(
    context: CommandContext(timeoutMilliseconds: 5_000)
) {
```

Do not alter `spawnLockHelper`, any immediate child-process cleanup `defer`, `waitForExit`, `terminateAndWait`, or their TERM/KILL/reap behavior.

- [ ] **Step 3: Migrate service tests to async signatures before production changes**

At file scope in `SnapshotTests.swift`, add this complete helper:

```swift
private func snapshotCommandContext(
    wallNow: Date,
    timeoutMilliseconds: Int = 1_000
) -> CommandContext {
    CommandContext(
        timeoutMilliseconds: timeoutMilliseconds,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { wallNow },
            sleepNanoseconds: { _ in }
        )
    )
}
```

For each action test named below, change the method to `async throws`; the exact replacement closure signatures are shown after the list:

```text
testValidationFailureDoesNotInvalidateRecord
testStateChangingAttemptInvalidatesBeforeActionButNonChangingAttemptDoesNot
testFailedStateChangingPreparationDoesNotInvalidateOrDispatch
testInvalidationFailurePreventsActionDispatch
testDispatchFailureLeavesAllAppRecordsInvalidated
testEnumerationFailureAfterPreflightPreventsDispatch
testEveryInvalidationPublicationFailurePreventsDispatch
```

```swift
resolve: { selector, context in
    _ = selector
    _ = context
    return recorded.target
},
observe: { target, options, context in
    _ = target
    _ = options
    _ = context
    return AXTreeObservation(snapshot: live, liveElements: [2: LiveAXElement()])
},
validateTarget: { identity, context in
    _ = identity
    _ = context
    return recorded.target
}
```

Remove `now:` from each `SnapshotService` initializer. Replace each `timeoutMilliseconds: 1_000` action argument with:

```swift
context: snapshotCommandContext(wallNow: now),
```

Use three-argument preflight and two-argument L2 dispatch closures. The complete migrated throwing invocation shape is:

```swift
await XCTAssertThrowsErrorAsync({
    try await service.withValidatedSnapshotAction(
        snapshotID: record.id,
        ref: 2,
        context: snapshotCommandContext(wallNow: now),
        stateChanging: true,
        preflight: { element, target, context in
            _ = element
            _ = target
            _ = context
            throw NativeFailure("INVALID_REQUEST", "Action-specific preparation failed")
        },
        dispatch: { prepared, context in
            _ = prepared
            _ = context
            XCTFail("dispatch must not run")
        }
    )
}) {
    XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_REQUEST")
}
```

Preserve each existing test's setup and assertions. Do not change pure evidence tests.

Make `testSnapshotNativeDispatchUsesInjectedPureObservation` and `testNativeFailureDetailsRoundTripThroughDispatcher` `async throws`; use 2-argument resolve, 3-argument observe, remove `now:` from service initialization, and replace execute calls with:

```swift
let reply = await native.execute(
    request,
    context: snapshotCommandContext(wallNow: now)
)
```

and:

```swift
let reply = await NativeService(snapshotService: service).execute(
    request,
    context: snapshotCommandContext(wallNow: now)
)
```

The C3 assertion remains exactly:

```swift
XCTAssertEqual(reply.error?.details, [
    "mutationStatus": .string("notStarted"),
    "safe": .string("kept")
])
```

In `ProtocolTests`, replace `testUnsupportedValidRequestStagesUntilItsTask` with:

```swift
func testUnsupportedValidRequestStagesUntilItsTask() async throws {
    let request = try XCTUnwrap(WireRequest.decode([
        "schemaVersion": 1,
        "command": "apps",
        "options": ["timeoutMs": 1, "cursor": "on"]
    ]))
    let reply = await NativeService().execute(
        request,
        context: CommandContext(timeoutMilliseconds: 1)
    )
    XCTAssertEqual(reply.error?.code, "UNSUPPORTED_ACTION")
}
```

In `HostLifecycleTests`, replace the two existing session tests with these complete L2 versions, then add the detached-work test:

```swift
func testHostSessionStaysActiveUntilWorkCompletesWithoutWaitingForEOF() throws {
    var finish: ((WireReply) -> Void)?
    var replies = 0
    var shutdowns = 0
    let session = HostSession(
        context: CommandContext(timeoutMilliseconds: 1_000),
        work: { _, completion in
            finish = completion
            return Task.detached {}
        },
        onReply: { _ in replies += 1 },
        onShutdown: { shutdowns += 1 }
    )
    session.start()
    XCTAssertEqual(replies, 0)
    XCTAssertEqual(shutdowns, 0)
    try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "staged"))
    XCTAssertEqual(replies, 1)
    XCTAssertEqual(shutdowns, 1)
}

func testHostSessionCancelsAndShutsDownWhenParentClosesDuringWork() {
    let context = CommandContext(timeoutMilliseconds: 1_000)
    var workCancelled = false
    var replies = 0
    var shutdowns = 0
    context.onCancel { workCancelled = true }
    let session = HostSession(
        context: context,
        work: { _, _ in Task.detached {} },
        onReply: { _ in replies += 1 },
        onShutdown: { shutdowns += 1 }
    )
    session.start()
    session.parentDidClose()
    XCTAssertTrue(context.isCancelled)
    XCTAssertTrue(workCancelled)
    XCTAssertEqual(replies, 0)
    XCTAssertEqual(shutdowns, 1)
}

func testDetachedCommandWorkRunsOffMainAndCompletes() async {
    let completed = expectation(description: "detached completion")
    let context = CommandContext(timeoutMilliseconds: 1_000)
    let task = Task.detached {
        await withTaskCancellationHandler(operation: {
            XCTAssertFalse(Thread.isMainThread)
            completed.fulfill()
        }, onCancel: {
            context.cancel()
        })
    }
    await fulfillment(of: [completed], timeout: 1)
    await task.value
}
```

- [ ] **Step 4: Verify L2 RED as one atomic compile boundary**

Run only after all L2 test migrations above are present and before changing production:

```sh
swift test --package-path native --filter DesktopLockTests
swift test --package-path native --filter SnapshotTests
swift test --package-path native --filter ProtocolTests/testUnsupportedValidRequestStagesUntilItsTask
swift test --package-path native --filter HostLifecycleTests
```

Expected RED: compile errors report missing `withLock(context:)`, extra `context` arguments, old synchronous service closure types, old `HostSession` initializer/work return type, and async execute mismatch. There is intentionally no intermediate GREEN in L2; do not keep old APIs to make this state compile.

- [ ] **Step 5: Replace the lock API atomically**

In `DesktopLock`, replace stored properties and both initializers through the end of `withLock` with:

```swift
private let rootURL: URL
private let flockCall: (Int32, Int32) -> SystemCallResult<Int32>

public init(rootURL: URL = DesktopLock.defaultRootURL) {
    self.rootURL = rootURL
    flockCall = { descriptor, operation in
        let value = flock(descriptor, operation)
        return SystemCallResult(value: value, error: value < 0 ? errno : 0)
    }
}

init(
    rootURL: URL,
    flock: @escaping (Int32, Int32) -> SystemCallResult<Int32>
) {
    self.rootURL = rootURL
    flockCall = flock
}

public func withLock<T>(
    context: CommandContext,
    _ body: () async throws -> T
) async throws -> T {
    try context.check()
    let rootDescriptor = try PrivateStateDirectory.openRoot(
        rootURL,
        checkpoint: { try context.check() }
    )
    defer { close(rootDescriptor) }
    let descriptor = try openLockFile(
        in: rootDescriptor,
        checkpoint: { try context.check() }
    )
    defer { close(descriptor) }
    try verifyPrivateFile(descriptor)
    guard fchmod(descriptor, 0o600) == 0 else {
        throw stateFailure("Unable to protect the desktop lock")
    }

    var observedContention = false
    while true {
        try context.checkLockWait(observedContention: observedContention)
        let result = flockCall(descriptor, LOCK_EX | LOCK_NB)
        if result.value == 0 {
            do {
                try context.checkLockWait(observedContention: observedContention)
            } catch {
                _ = flockCall(descriptor, LOCK_UN)
                throw error
            }
            break
        }
        let lockError = result.error
        if lockError == EINTR {
            try context.checkLockWait(observedContention: observedContention)
            continue
        }
        guard lockError == EWOULDBLOCK || lockError == EAGAIN else {
            throw stateFailure("Unable to acquire the desktop lock")
        }
        observedContention = true
        try context.checkLockWait(observedContention: true)
        do {
            try await context.sleep(
                nanoseconds: min(10_000_000, context.remainingNanoseconds)
            )
        } catch let failure as NativeFailure where failure.code == "TIMEOUT" {
            try context.checkLockWait(observedContention: true)
        }
    }
    defer { _ = flockCall(descriptor, LOCK_UN) }
    return try await body()
}
```

Replace `openLockFile` with:

```swift
private func openLockFile(
    in rootDescriptor: Int32,
    checkpoint: () throws -> Void
) throws -> Int32 {
    while true {
        try checkpoint()
        let existing = openat(rootDescriptor, "desktop.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        if existing >= 0 { return existing }
        if errno == EINTR {
            try checkpoint()
            continue
        }
        guard errno == ENOENT else {
            throw stateFailure("Unable to open the desktop lock")
        }

        let created = openat(
            rootDescriptor,
            "desktop.lock",
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        if created >= 0 { return created }
        if errno == EINTR || errno == EEXIST {
            try checkpoint()
            continue
        }
        throw stateFailure("Unable to create the desktop lock")
    }
}
```

Change `PrivateStateDirectory.openRoot` to accept a defaulted synchronous checkpoint and invoke it before each retry:

```swift
static func openRoot(
    _ url: URL,
    checkpoint: () throws -> Void = {},
    afterOpen: (Int32) throws -> Void = { _ in }
) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else {
        throw stateFailure("Invalid state directory")
    }
    while mkdir(url.path, 0o700) != 0 {
        if errno == EINTR {
            try checkpoint()
            continue
        }
        guard errno == EEXIST else {
            throw stateFailure("Unable to create the state directory")
        }
        break
    }
    let descriptor: Int32
    while true {
        try checkpoint()
        let opened = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if opened >= 0 {
            descriptor = opened
            break
        }
        if errno == EINTR {
            try checkpoint()
            continue
        }
        throw stateFailure("Unable to open the state directory")
    }
    do {
        try afterOpen(descriptor)
        try verifyPrivateDirectory(descriptor)
        guard fchmod(descriptor, 0o700) == 0 else {
            throw stateFailure("Unable to protect the state directory")
        }
        return descriptor
    } catch {
        close(descriptor)
        throw error
    }
}
```

Do not alter `openChild` until L4. Delete `monotonicNow`, `wait`, `now()`, `withLock(timeoutMilliseconds:)`, and `withLock(deadline:)`; no compatibility overload remains.

- [ ] **Step 6: Replace the L2 `SnapshotService` declaration with the compile-boundary version**

Replace `public final class SnapshotService` through its closing brace, retaining the existing `validateEvidence` body verbatim, with:

```swift
public final class SnapshotService {
    public typealias Resolve = (TargetSelector, CommandContext) async throws -> ResolvedTarget
    public typealias Observe = (ResolvedTarget, TreeOptions, CommandContext) async throws -> AXTreeObservation
    public typealias ValidateTarget = (TargetIdentity, CommandContext) async throws -> ResolvedTarget

    private let lock: DesktopLock
    private let store: StateStore
    private let resolve: Resolve
    private let observe: Observe
    private let validateTarget: ValidateTarget

    public init(
        lock: DesktopLock = DesktopLock(),
        store: StateStore = StateStore(),
        resolve: @escaping Resolve = { selector, _ in try TargetResolver().resolve(selector) },
        observe: @escaping Observe = { target, options, _ in
            try AXTree.capture(target: target, options: options)
        },
        validateTarget: @escaping ValidateTarget = { identity, _ in
            try TargetResolver().validate(identity)
        }
    ) {
        self.lock = lock
        self.store = store
        self.resolve = resolve
        self.observe = observe
        self.validateTarget = validateTarget
    }

    public func snapshot(
        selector: TargetSelector,
        options: TreeOptions,
        context: CommandContext
    ) async throws -> SnapshotResult {
        try await lock.withLock(context: context) {
            try context.check()
            try store.sweep()
            let target = try await resolve(selector, context)
            try context.check()
            let observation = try await observe(target, options, context)
            guard observation.snapshot.target == target,
                  observation.snapshot.treeOptions == options else {
                throw NativeFailure(
                    "STALE_SNAPSHOT",
                    "Target or traversal evidence changed during snapshot"
                )
            }
            try context.check()
            let created = context.wallNow
            let record = SnapshotRecord(
                id: UUID().uuidString.lowercased(),
                createdAt: timestamp(created),
                expiresAt: timestamp(created.addingTimeInterval(snapshotLifetime)),
                target: target,
                treeOptions: options,
                evidence: observation.snapshot.evidence
            )
            try store.writeSnapshot(record)
            return SnapshotResult(record: record, snapshot: observation.snapshot)
        }
    }

    func withValidatedSnapshotAction<Prepared, Result>(
        snapshotID: String,
        ref: Int,
        context: CommandContext,
        stateChanging: Bool,
        preflight: (LiveAXElement, ResolvedTarget, CommandContext) async throws -> Prepared,
        dispatch: (Prepared, CommandContext) async throws -> Result
    ) async throws -> Result {
        try await lock.withLock(context: context) {
            try context.check()
            try store.sweep()
            let record = try store.readSnapshot(id: snapshotID)
            let target = try await validateTarget(record.target.identity, context)
            guard target == record.target else {
                throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
            }
            let live = try await observe(target, record.treeOptions, context)
            let recorded = AXTreeSnapshot(
                target: record.target,
                treeOptions: record.treeOptions,
                evidence: record.evidence
            )
            _ = try Self.validateEvidence(recorded, live: live.snapshot, ref: ref)
            guard let element = live.liveElements[ref] else {
                throw NativeFailure(
                    "STALE_SNAPSHOT",
                    "Live accessibility reference is unavailable"
                )
            }
            let prepared = try await preflight(element, target, context)
            try context.check()
            if stateChanging {
                try store.invalidateRecords(for: record.target.identity)
            }
            return try await dispatch(prepared, context)
        }
    }

    static func validateEvidence(
        _ recorded: AXTreeSnapshot,
        live: AXTreeSnapshot,
        ref: Int
    ) throws -> AXRefEvidence {
        try AXEvidencePolicy.validate(recorded.evidence, options: recorded.treeOptions)
        try AXEvidencePolicy.validate(live.evidence, options: live.treeOptions)
        guard recorded.target == live.target,
              recorded.treeOptions == live.treeOptions,
              recorded.evidence.nodes == live.evidence.nodes,
              recorded.evidence.truncation == live.evidence.truncation,
              recorded.evidence.refs == live.evidence.refs,
              let recordedRef = recorded.evidence.refs.first(where: { $0.ref == ref }),
              let liveRef = live.evidence.refs.first(where: { $0.ref == ref }),
              recordedRef == liveRef else {
            throw NativeFailure(
                "STALE_SNAPSHOT",
                "Snapshot evidence no longer matches the selected window"
            )
        }
        return liveRef
    }
}
```

This task intentionally preserves the current phase order. L4 supplies store/AX checkpoints; L5 supplies refresh, hook, continuity, second preflight, and commit semantics.

- [ ] **Step 7: Replace native dispatch and expose the already-validated timeout**

Replace `NativeService.execute` and delete `withDesktopLock`:

```swift
public func execute(_ request: WireRequest, context: CommandContext) async -> WireReply {
    do {
        try context.check()
        switch request.command {
        case .doctor:
            return try await desktopLock.withLock(context: context) {
                let result = doctor()
                try context.check()
                return result
            }
        case .snapshot:
            guard let selector = TargetSelector.decode(request.object["target"]),
                  let tree = decodeTreeOptions(request.object["tree"]) else {
                return .failure(
                    command: request.command,
                    code: "PROTOCOL_ERROR",
                    message: "Invalid snapshot request"
                )
            }
            let result = try await snapshotService.snapshot(
                selector: selector,
                options: tree,
                context: context
            )
            return .success(command: .snapshot, data: result.wireData)
        default:
            return .failure(
                command: request.command,
                code: "UNSUPPORTED_ACTION",
                message: "This command is not implemented by this helper version"
            )
        }
    } catch let failure as NativeFailure {
        return .failure(
            command: request.command,
            code: failure.code,
            message: failure.message,
            details: failure.details
        )
    } catch {
        return .failure(
            command: request.command,
            code: "NATIVE_FAILURE",
            message: "Native command failed"
        )
    }
}
```

In `Protocol.swift`, immediately after `WireRequest`, add:

```swift
extension WireRequest {
    public var timeoutMilliseconds: Int? {
        integer((object["options"] as? [String: Any])?["timeoutMs"])
    }
}
```

Delete the now-unused private `wireInteger` from `NativeService.swift`. `NativeService` never computes a deadline and never locks around snapshot.

- [ ] **Step 8: Migrate `HostSession` to own the one task without adding L6 state yet**

Delete `HostCancellation`. Replace the complete `HostSession` declaration in `HostSupport.swift` with:

```swift
public final class HostSession {
    public typealias Work = (
        _ context: CommandContext,
        _ completion: @escaping (WireReply) -> Void
    ) -> Task<Void, Never>

    private enum State {
        case ready
        case running
        case finished
    }

    private let lock = NSLock()
    private let context: CommandContext
    private let work: Work
    private let onReply: (WireReply) -> Void
    private let onShutdown: () -> Void
    private var state = State.ready
    private var task: Task<Void, Never>?

    public init(
        context: CommandContext,
        work: @escaping Work,
        onReply: @escaping (WireReply) -> Void,
        onShutdown: @escaping () -> Void
    ) {
        self.context = context
        self.work = work
        self.onReply = onReply
        self.onShutdown = onShutdown
    }

    public func start() {
        lock.lock()
        guard state == .ready else {
            lock.unlock()
            return
        }
        state = .running
        lock.unlock()

        let started = work(context) { [weak self] reply in
            self?.workDidFinish(reply)
        }

        lock.lock()
        if state == .finished {
            lock.unlock()
            started.cancel()
        } else {
            task = started
            lock.unlock()
        }
    }

    public func parentDidClose() {
        lock.lock()
        guard state != .finished else {
            lock.unlock()
            return
        }
        state = .finished
        let activeTask = task
        task = nil
        lock.unlock()

        context.cancel()
        activeTask?.cancel()
        onShutdown()
    }

    private func workDidFinish(_ reply: WireReply) {
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return
        }
        state = .finished
        task = nil
        lock.unlock()

        onReply(reply)
        onShutdown()
    }
}
```

This is only the atomic ownership/signature migration. Its immediate-on-parent-close behavior remains the focused L6 RED. It nevertheless uses one context token and retains/cancels the detached task.

- [ ] **Step 9: Replace `HostMain`'s accepted-request block with one detached transaction**

Keep startup framing unchanged in L2. Replace lines beginning with `_ = NSApplication.shared` through `parentObserver.stop()` by this block:

```swift
_ = NSApplication.shared
guard let timeout = request.timeoutMilliseconds else {
    write(.failure(
        command: request.command,
        code: "PROTOCOL_ERROR",
        message: "Invalid command options"
    ))
    return
}
let context = CommandContext(timeoutMilliseconds: timeout)
let session = HostSession(
    context: context,
    work: { context, completion in
        Task.detached {
            await withTaskCancellationHandler(operation: {
                let reply = await NativeService().execute(request, context: context)
                completion(reply)
            }, onCancel: {
                context.cancel()
            })
        }
    },
    onReply: write,
    onShutdown: {
        DispatchQueue.main.async {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
)
let parentObserver = ParentEOFObserver(fileHandle: .standardInput) {
    session.parentDidClose()
}
parentObserver.start()
session.start()
CFRunLoopRun()
parentObserver.stop()
```

There is no worker actor or worker wrapper. `HostSession` visibly owns the returned task, parent cancellation calls both `context.cancel()` and `task.cancel()`, and the task cancellation handler writes the same token. The detached body always calls completion; it has no cancelled-before-start guard.

- [ ] **Step 10: Verify atomic L2 GREEN**

Run:

```sh
swift test --package-path native --filter CommandContextTests
swift test --package-path native --filter DesktopLockTests
swift test --package-path native --filter SnapshotTests
swift test --package-path native --filter ProtocolTests
swift test --package-path native --filter HostLifecycleTests
swift test --package-path native --filter StateStoreTests
```

Expected GREEN: all commands exit 0. Specifically, real contention is `BUSY`, uncontended expiry is `TIMEOUT`, success-at-deadline unlocks exactly once without entering the body, cancellation does not unlock an unheld fd, C3 details remain unchanged, and the detached-work test observes `Thread.isMainThread == false`. No intermediate subset before all production replacements counts as GREEN.

- [ ] **Step 11: Run L2 preservation checks and scoped review**

```sh
swift test --package-path native --filter DesktopLockTests/testSubprocessOwnersNeverOverlapCriticalSections
swift test --package-path native --filter DesktopLockTests/testKilledOwnerReleasesKernelLockForAnotherProcess
swift test --package-path native --filter SnapshotTests/testEveryInvalidationPublicationFailurePreventsDispatch
swift test --package-path native --filter SnapshotTests/testNativeFailureDetailsRoundTripThroughDispatcher
swift test --package-path native --filter ProtocolTests/testMutationStatusWireSpellingsMatchSharedFixture
git grep -n 'withLock(timeoutMilliseconds:\|withLock(deadline:\|NativeCommandWorker\|Task {' -- native/Sources
```

Expected: all test commands pass; grep returns no old lock API, no shared worker abstraction, and no non-detached command task. Review confirms snapshot has one lock owner, doctor has one lock owner, `failure.details` survives, subprocess cleanup defers are unchanged, and L2 has not implemented L3–L6 behavior.

- [ ] **Step 12: Stage exactly L2 and create its one commit**

```sh
git add native/Tests/ComputerUseCoreTests/AsyncAssertions.swift \
  native/Sources/ComputerUseCore/DesktopLock.swift \
  native/Sources/ComputerUseCore/HostSupport.swift \
  native/Sources/ComputerUseCore/SnapshotService.swift \
  native/Sources/ComputerUseCore/NativeService.swift \
  native/Sources/ComputerUseCore/Protocol.swift \
  native/Sources/ComputerUseHost/HostMain.swift \
  native/Tests/ComputerUseCoreTests/StateStoreTests.swift \
  native/Tests/ComputerUseCoreTests/SnapshotTests.swift \
  native/Tests/ComputerUseCoreTests/ProtocolTests.swift \
  native/Tests/ComputerUseCoreTests/HostLifecycleTests.swift
git diff --cached --check
git diff --cached --name-only
git commit -m "refactor: make native command execution asynchronous"
```

Expected staged names: exactly the eleven listed files. One L2 commit contains the test migration and complete production compile boundary.


---

### Task L3: Selected-PID resolver and millisecond-precise launch identity

**Files:**
- Modify: `native/Sources/ComputerUseCore/TargetResolver.swift` (full provider/resolver replacement)
- Modify: `native/Sources/ComputerUseCore/AXTree.swift` (`liveAXAttribute` visibility and production element equality only)
- Modify: `native/Sources/ComputerUseCore/SnapshotService.swift` (two default closures only)
- Modify: `native/Tests/ComputerUseCoreTests/TargetResolverTests.swift` (full replacement)
- Do not modify: inventories, tree fixtures, C4 fixture, state store, host, protocol, or public command dispatch

**Interfaces:**
- Consumes: L1 `CommandContext`; L2 async `SnapshotService.Resolve` and `ValidateTarget`.
- Produces: `ProcessMetadata`, `TargetResolverProvider`, async `TargetResolver.resolve(_:context:)` and `validate(_:context:)`, `resolverOptionalRead(status:result:)` preserving A1 unavailable metadata, `ProcessLaunchDate.format(_:)`, `AXElementIdentity`, and `liveAXElementsAreIdentical`. L4 adds checkpoints/timeouts to the selected-PID live provider; L5 injects/uses the element predicate.

The precision decision is intentionally bounded: public `NSRunningApplication.launchDate` remains a `Date` until the main-actor metadata snapshot is reduced, then documented `ISO8601DateFormatter` fractional output emits canonical UTC milliseconds. Thus launches at `.000` and `.001` in one second differ; sub-millisecond distinctions are outside this design because Foundation documents only three fractional digits. C4's existing 1–9 digit parser remains broader than this producer and is not changed.

- [ ] **Step 1: Replace `TargetResolverTests.swift` with complete RED coverage**

```swift
import XCTest
@testable import ComputerUseCore

final class TargetResolverTests: XCTestCase {
    func testDuplicateAppNamesAreNotSelected() async {
        let resolver = TargetResolver(inventory: .fixture("duplicate-apps"))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.app("Editor", windowId: nil), context: resolverContext())
        }
    }

    func testPidReuseFailsIdentityValidation() async {
        let resolver = TargetResolver(inventory: .fixture("pid-reused"))
        await assertResolverFailure("STALE_SNAPSHOT") {
            try await resolver.validate(
                .init(pid: 42, launchDate: "old", bundleId: "com.example.Editor", windowId: 7),
                context: resolverContext()
            )
        }
    }

    func testMissingWindowRequiresExactlyOneEligibleWindow() async {
        let zero = TargetResolver(inventory: .fixture("zero-eligible-windows"))
        await assertResolverFailure("INELIGIBLE_TARGET") {
            try await zero.resolve(.pid(42, windowId: nil), context: resolverContext())
        }
        let multiple = TargetResolver(inventory: .fixture("multiple-eligible-windows"))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await multiple.resolve(.pid(42, windowId: nil), context: resolverContext())
        }
    }

    func testDuplicateAXToCGCandidatesAreRejected() async {
        let resolver = TargetResolver(inventory: .fixture("duplicate-ax-cg"))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.pid(42, windowId: 7), context: resolverContext())
        }
    }

    func testMinimizedAndOffSpaceWindowsAreIneligible() async {
        for fixture in ["minimized-window", "off-space-window"] {
            let resolver = TargetResolver(inventory: .fixture(fixture))
            await assertResolverFailure("INELIGIBLE_TARGET", message: fixture) {
                try await resolver.resolve(.pid(42, windowId: 7), context: resolverContext())
            }
        }
    }

    func testAmbiguousApplicationDoesNotQueryAXWindows() async {
        let queries = LockedValues<Int>()
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [
                    ProcessMetadata(name: "Editor", pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor"),
                    ProcessMetadata(name: "Editor", pid: 43, launchDate: "2026-09-08T10:00:00.001Z", bundleId: "com.example.Editor")
                ]
            },
            windowsForPID: { pid, _ in
                queries.append(pid)
                XCTFail("window provider must not run for an ambiguous app")
                return []
            }
        ))
        await assertResolverFailure("AMBIGUOUS_TARGET") {
            try await resolver.resolve(.app("Editor", windowId: nil), context: resolverContext())
        }
        XCTAssertEqual(queries.values, [])
    }

    func testExplicitPIDQueriesExactlyThatPID() async throws {
        let queries = LockedValues<Int>()
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [
                    ProcessMetadata(name: "Editor", pid: 42, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Editor"),
                    ProcessMetadata(name: "Other", pid: 99, launchDate: "2026-09-08T10:00:00.000Z", bundleId: "com.example.Other")
                ]
            },
            windowsForPID: { pid, _ in
                queries.append(pid)
                return [resolverWindow(id: 7)]
            }
        ))
        let target = try await resolver.resolve(
            .pid(42, windowId: 7),
            context: resolverContext()
        )
        XCTAssertEqual(queries.values, [42])
        XCTAssertEqual(target.identity.pid, 42)
        XCTAssertEqual(target.identity.windowId, 7)
    }

    func testMillisecondSeparatedSameSecondLaunchesHaveDifferentIdentity() async {
        let first = ProcessLaunchDate.format(Date(timeIntervalSince1970: 1_788_861_900.000))
        let second = ProcessLaunchDate.format(Date(timeIntervalSince1970: 1_788_861_900.001))
        XCTAssertTrue(first.hasSuffix(".000Z"), first)
        XCTAssertTrue(second.hasSuffix(".001Z"), second)
        XCTAssertNotEqual(first, second)

        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [ProcessMetadata(name: "Editor", pid: 42, launchDate: second, bundleId: "com.example.Editor")]
            },
            windowsForPID: { _, _ in [resolverWindow(id: 7)] }
        ))
        await assertResolverFailure("STALE_SNAPSHOT") {
            try await resolver.validate(
                TargetIdentity(pid: 42, launchDate: first, bundleId: "com.example.Editor", windowId: 7),
                context: resolverContext()
            )
        }
    }

    func testMissingLaunchDateRemainsMetadataButCannotBeTargeted() async {
        let queries = LockedValues<Int>()
        let metadata = ProcessMetadata(name: "Editor", pid: 42, launchDate: nil, bundleId: "com.example.Editor")
        XCTAssertNil(metadata.launchDate)
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: { [metadata] },
            windowsForPID: { pid, _ in queries.append(pid); return [] }
        ))
        await assertResolverFailure("TARGET_NOT_FOUND") {
            try await resolver.resolve(.pid(42, windowId: nil), context: resolverContext())
        }
        XCTAssertEqual(queries.values, [])
    }

    func testPersistedMissingWindowIsStaleButPermissionAndNativeFailuresSurvive() async {
        let identity = TargetIdentity(
            pid: 42,
            launchDate: "2026-09-08T10:00:00.000Z",
            bundleId: "com.example.Editor",
            windowId: 7
        )
        let applications = {
            [ProcessMetadata(name: "Editor", pid: 42, launchDate: identity.launchDate, bundleId: identity.bundleId)]
        }
        let missing = TargetResolver(provider: TargetResolverProvider(
            listApplications: applications,
            windowsForPID: { _, _ in [] }
        ))
        await assertResolverFailure("TARGET_NOT_FOUND") {
            try await missing.resolve(.pid(42, windowId: 7), context: resolverContext())
        }
        await assertResolverFailure("STALE_SNAPSHOT") {
            try await missing.validate(identity, context: resolverContext())
        }

        for code in ["PERMISSION_DENIED", "NATIVE_FAILURE"] {
            let resolver = TargetResolver(provider: TargetResolverProvider(
                listApplications: applications,
                windowsForPID: { _, _ in throw NativeFailure(code, "classified provider failure") }
            ))
            await assertResolverFailure(code) {
                try await resolver.validate(identity, context: resolverContext())
            }
        }
    }

    func testResolverUnavailableReadsRemainOptionalButHardFailuresStayClassified() throws {
        let unavailable: AXReadResult<String> = .unavailable
        XCTAssertNil(try resolverOptionalRead(status: .noValue, result: unavailable))

        for (status, code) in [
            (AXError.apiDisabled, "PERMISSION_DENIED"),
            (.cannotComplete, "NATIVE_FAILURE"),
            (.success, "NATIVE_FAILURE")
        ] {
            let failure: AXReadResult<String> = .failure
            XCTAssertThrowsError(try resolverOptionalRead(status: status, result: failure)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, code)
            }
        }
    }

    func testUnavailableAXMetadataCanCoexistWithValidSelectedWindow() async throws {
        let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
        let unsupported = TargetWindow(
            ax: AXWindowMetadata(
                role: nil,
                title: nil,
                bounds: nil,
                minimized: nil
            ),
            cg: CGWindowMetadata(
                id: 8,
                title: nil,
                bounds: bounds,
                onScreen: true,
                minimized: false
            )
        )
        let resolver = TargetResolver(provider: TargetResolverProvider(
            listApplications: {
                [ProcessMetadata(
                    name: "Editor",
                    pid: 42,
                    launchDate: "2026-09-08T10:00:00.000Z",
                    bundleId: "com.example.Editor"
                )]
            },
            windowsForPID: { _, _ in [unsupported, resolverWindow(id: 7)] }
        ))

        let target = try await resolver.resolve(
            .pid(42, windowId: 7),
            context: resolverContext()
        )
        XCTAssertEqual(target.identity.windowId, 7)
    }


    func testEmptyFixtureHandlesAreNotProductionEqual() {
        XCTAssertFalse(liveAXElementsAreIdentical(LiveAXElement(), LiveAXElement()))
    }
}

extension TargetInventory {
    static func fixture(_ name: String) -> TargetInventory {
        let url = Bundle.module.url(forResource: "inventories", withExtension: "json")!
        let fixtures = try! JSONDecoder().decode(
            [String: TargetInventory].self,
            from: Data(contentsOf: url)
        )
        return fixtures[name]!
    }
}

private final class LockedValues<Value> {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private func resolverContext() -> CommandContext {
    CommandContext(
        timeoutMilliseconds: 1_000,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
}

private func resolverWindow(id: Int) -> TargetWindow {
    let bounds = WindowBounds(x: 0, y: 0, width: 100, height: 100)
    return TargetWindow(
        ax: AXWindowMetadata(role: "AXWindow", title: "Draft", bounds: bounds, minimized: false),
        cg: CGWindowMetadata(id: id, title: "Draft", bounds: bounds, onScreen: true, minimized: false)
    )
}

private func assertResolverFailure<T>(
    _ code: String,
    message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: () async throws -> T
) async {
    do {
        _ = try await work()
        XCTFail(message.isEmpty ? "expected \(code)" : message, file: file, line: line)
    } catch let failure as NativeFailure {
        XCTAssertEqual(failure.code, code, message, file: file, line: line)
    } catch {
        XCTFail("unexpected error \(error)", file: file, line: line)
    }
}
```

- [ ] **Step 2: Verify L3 RED**

```sh
swift test --package-path native --filter TargetResolverTests
```

Expected RED: test-module compilation fails for missing `ProcessMetadata`, `TargetResolverProvider`, `ProcessLaunchDate`, contextual async resolver methods, and `liveAXElementsAreIdentical`. Existing helper definitions compile independently.

- [ ] **Step 3: Replace the complete resolver implementation**

Keep imports and the existing declarations for `TargetSelector`, its decode extension, `TargetIdentity`, `ResolvedTarget`, `WindowBounds`, `AXWindowMetadata`, `CGWindowMetadata`, `TargetWindow`, `TargetApplication`, and `TargetInventory`, except delete `TargetInventory.live()`. Replace everything from `public final class TargetResolver` through the helper before `targetInteger` with:

```swift
public struct ProcessMetadata: Equatable, Sendable {
    public let name: String
    public let pid: Int
    public let launchDate: String?
    public let bundleId: String?

    public init(name: String, pid: Int, launchDate: String?, bundleId: String?) {
        self.name = name
        self.pid = pid
        self.launchDate = launchDate
        self.bundleId = bundleId
    }

    init(application: TargetApplication) {
        name = application.name
        pid = application.pid
        launchDate = application.launchDate
        bundleId = application.bundleId
    }
}

public struct TargetResolverProvider {
    public let listApplications: () async throws -> [ProcessMetadata]
    public let windowsForPID: (Int, CommandContext) throws -> [TargetWindow]

    public init(
        listApplications: @escaping () async throws -> [ProcessMetadata],
        windowsForPID: @escaping (Int, CommandContext) throws -> [TargetWindow]
    ) {
        self.listApplications = listApplications
        self.windowsForPID = windowsForPID
    }

    public static var live: TargetResolverProvider {
        TargetResolverProvider(
            listApplications: {
                await MainActor.run { liveProcessMetadata() }
            },
            windowsForPID: { pid, context in
                try liveWindows(for: pid, context: context)
            }
        )
    }
}

public final class TargetResolver {
    private let provider: TargetResolverProvider

    public init() {
        provider = .live
    }

    public init(inventory: TargetInventory) {
        provider = TargetResolverProvider(
            listApplications: { inventory.apps.map(ProcessMetadata.init(application:)) },
            windowsForPID: { pid, _ in
                inventory.apps.first(where: { $0.pid == pid })?.windows ?? []
            }
        )
    }

    init(provider: TargetResolverProvider) {
        self.provider = provider
    }

    public func resolve(
        _ selector: TargetSelector,
        context: CommandContext
    ) async throws -> ResolvedTarget {
        try context.check()
        let applications = try await provider.listApplications()
        try context.check()

        let selected: [ProcessMetadata]
        switch selector {
        case let .app(name, _):
            selected = applications.filter { $0.name == name || $0.bundleId == name }
        case let .pid(pid, _):
            selected = applications.filter { $0.pid == pid }
        }
        guard selected.count == 1 else {
            throw NativeFailure(
                selected.isEmpty ? "TARGET_NOT_FOUND" : "AMBIGUOUS_TARGET",
                "Application selection is not unique"
            )
        }
        let application = selected[0]
        guard let launchDate = application.launchDate, !launchDate.isEmpty else {
            throw NativeFailure("TARGET_NOT_FOUND", "Process start identity is unavailable")
        }

        try context.check()
        let windows = try provider.windowsForPID(application.pid, context)
        try context.check()
        let requestedWindow: Int?
        switch selector {
        case let .app(_, windowID), let .pid(_, windowID):
            requestedWindow = windowID
        }
        let candidates = windows.filter {
            requestedWindow == nil || $0.cg.id == requestedWindow
        }
        guard !candidates.isEmpty else {
            throw NativeFailure("TARGET_NOT_FOUND", "Window was not found")
        }
        let eligible = candidates.filter { $0.cg.onScreen && !$0.cg.minimized }
        guard !eligible.isEmpty else {
            throw NativeFailure("INELIGIBLE_TARGET", "No eligible window is available")
        }
        guard eligible.count == 1 else {
            throw NativeFailure("AMBIGUOUS_TARGET", "Window selection is not unique")
        }
        let window = eligible[0]
        try context.check()
        return ResolvedTarget(
            identity: TargetIdentity(
                pid: application.pid,
                launchDate: launchDate,
                bundleId: application.bundleId,
                windowId: window.cg.id
            ),
            title: window.cg.title ?? "",
            bounds: window.cg.bounds
        )
    }

    public func validate(
        _ identity: TargetIdentity,
        context: CommandContext
    ) async throws -> ResolvedTarget {
        do {
            let target = try await resolve(
                .pid(identity.pid, windowId: identity.windowId),
                context: context
            )
            guard target.identity == identity else {
                throw NativeFailure("STALE_SNAPSHOT", "Process or window identity changed")
            }
            return target
        } catch let failure as NativeFailure {
            throw mapPersistedSelectionFailure(failure)
        }
    }
}

enum ProcessLaunchDate {
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

@MainActor
private func liveProcessMetadata() -> [ProcessMetadata] {
    NSWorkspace.shared.runningApplications.map { application in
        ProcessMetadata(
            name: application.localizedName ?? "",
            pid: Int(application.processIdentifier),
            launchDate: application.launchDate.map(ProcessLaunchDate.format),
            bundleId: application.bundleIdentifier
        )
    }
}

private func mapPersistedSelectionFailure(_ failure: NativeFailure) -> NativeFailure {
    switch failure.code {
    case "TARGET_NOT_FOUND", "AMBIGUOUS_TARGET", "INELIGIBLE_TARGET":
        return NativeFailure(
            "STALE_SNAPSHOT",
            "Recorded target is no longer eligible or unique"
        )
    default:
        return failure
    }
}

private func resolverReadFailure(_ status: AXError) -> NativeFailure {
    if status == .apiDisabled {
        return NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    return NativeFailure(
        "NATIVE_FAILURE",
        "Window identity could not be observed reliably"
    )
}

func resolverOptionalRead<Value>(
    status: AXError,
    result: AXReadResult<Value>
) throws -> Value? {
    switch result {
    case let .value(value):
        return value
    case .unavailable:
        return nil
    case .failure:
        throw resolverReadFailure(status)
    }
}

private func resolverString(
    _ element: AXUIElement,
    _ attribute: String
) throws -> String? {
    let read = liveAXAttribute(element, attribute)
    return try resolverOptionalRead(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )
    )
}

private func resolverBool(
    _ element: AXUIElement,
    _ attribute: String
) throws -> Bool? {
    let read = liveAXAttribute(element, attribute)
    return try resolverOptionalRead(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFBooleanGetTypeID(),
            decode: { $0 as? Bool }
        )
    )
}

private func resolverBounds(_ element: AXUIElement) throws -> WindowBounds? {
    let positionRead = liveAXAttribute(element, kAXPositionAttribute)
    let sizeRead = liveAXAttribute(element, kAXSizeAttribute)
    let position: AXReadResult<AXValue> = axReadResult(
        status: positionRead.status,
        value: positionRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { $0 as! AXValue }
    )
    let size: AXReadResult<AXValue> = axReadResult(
        status: sizeRead.status,
        value: sizeRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { $0 as! AXValue }
    )
    guard let positionValue = try resolverOptionalRead(
        status: positionRead.status,
        result: position
    ), let sizeValue = try resolverOptionalRead(
        status: sizeRead.status,
        result: size
    ) else {
        return nil
    }
    guard AXValueGetType(positionValue) == .cgPoint,
          AXValueGetType(sizeValue) == .cgSize else {
        throw NativeFailure("NATIVE_FAILURE", "Window identity could not be observed reliably")
    }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(positionValue, .cgPoint, &point),
          AXValueGetValue(sizeValue, .cgSize, &dimensions) else {
        throw NativeFailure("NATIVE_FAILURE", "Window identity could not be observed reliably")
    }
    return WindowBounds(
        x: point.x,
        y: point.y,
        width: dimensions.width,
        height: dimensions.height
    )
}

private func liveWindows(for pid: Int, context: CommandContext) throws -> [TargetWindow] {
    try context.check()
    guard AXIsProcessTrusted() else {
        throw NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    guard let nativePID = pid_t(exactly: pid), nativePID > 0 else {
        throw NativeFailure("TARGET_NOT_FOUND", "Process was not found")
    }
    let application = AXUIElementCreateApplication(nativePID)
    AXUIElementSetMessagingTimeout(application, 2.0)
    var rawWindows: CFTypeRef?
    let status = AXUIElementCopyAttributeValue(
        application,
        kAXWindowsAttribute as CFString,
        &rawWindows
    )
    let windowsResult: AXReadResult<[AXUIElement]> = axReadResult(
        status: status,
        value: rawWindows,
        expectedTypeID: CFArrayGetTypeID(),
        decode: { value in
            let array = value as! CFArray
            return decodeAXArray(
                array as [AnyObject],
                expectedElementTypeID: AXUIElementGetTypeID(),
                decode: { unsafeBitCast($0, to: AXUIElement.self) }
            )
        }
    )
    let windowElements: [AXUIElement]
    switch windowsResult {
    case let .value(values): windowElements = values
    case .unavailable: windowElements = []
    case .failure: throw resolverReadFailure(status)
    }

    var axWindows: [AXWindowMetadata] = []
    for element in windowElements {
        try context.check()
        axWindows.append(AXWindowMetadata(
            role: try resolverString(element, kAXRoleAttribute),
            title: try resolverString(element, kAXTitleAttribute),
            bounds: try resolverBounds(element),
            minimized: try resolverBool(element, kAXMinimizedAttribute)
        ))
    }
    let cgWindows = try liveCGWindows(for: pid)
    return axWindows.flatMap { ax in
        cgWindows.filter { matches(ax: ax, cg: $0) }.map { cg in
            TargetWindow(
                ax: ax,
                cg: CGWindowMetadata(
                    id: cg.id,
                    title: cg.title,
                    bounds: cg.bounds,
                    onScreen: cg.onScreen,
                    minimized: ax.minimized == true
                )
            )
        }
    }
}

private func liveCGWindows(for pid: Int) throws -> [CGWindowMetadata] {
    guard let values = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        throw NativeFailure("NATIVE_FAILURE", "Window inventory could not be read")
    }
    return try values.compactMap { value in
        guard value[kCGWindowOwnerPID as String] as? Int == pid else { return nil }
        guard let id = value[kCGWindowNumber as String] as? Int, id > 0,
              let dictionary = value[kCGWindowBounds as String] as? [String: CGFloat],
              let x = dictionary["X"],
              let y = dictionary["Y"],
              let width = dictionary["Width"],
              let height = dictionary["Height"],
              x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              width >= 0,
              height >= 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Window inventory contained invalid metadata")
        }
        return CGWindowMetadata(
            id: id,
            title: value[kCGWindowName as String] as? String,
            bounds: WindowBounds(x: x, y: y, width: width, height: height),
            onScreen: value[kCGWindowIsOnscreen as String] as? Bool ?? false,
            minimized: false
        )
    }
}

private func matches(ax: AXWindowMetadata, cg: CGWindowMetadata) -> Bool {
    guard ax.role == "AXWindow", ax.title == cg.title, let bounds = ax.bounds else {
        return false
    }
    return bounds == cg.bounds
}
```

Keep the existing `targetInteger` helper unchanged. The temporary 2.0-second app timeout is replaced by L4's context-clamped exact-ref helper before L3 is considered integrated; no live test is added.

- [ ] **Step 4: Add the production CF equality seam without test-only state**

In `AXTree.swift`, change only `private func liveAXAttribute` to internal `func liveAXAttribute`. Immediately after `LiveAXElement`, add:

```swift
public typealias AXElementIdentity = (LiveAXElement, LiveAXElement) -> Bool

func liveAXElementsAreIdentical(
    _ lhs: LiveAXElement,
    _ rhs: LiveAXElement
) -> Bool {
    guard let left = lhs.rawValue, let right = rhs.rawValue else { return false }
    return CFEqual(left, right)
}
```

`LiveAXElement` itself remains exactly:

```swift
public struct LiveAXElement {
    let rawValue: AXUIElement?

    public init() { rawValue = nil }
    init(_ rawValue: AXUIElement) { self.rawValue = rawValue }
}
```

No marker, identifier, description, or test constructor is added.

- [ ] **Step 5: Update only the resolver defaults in `SnapshotService`**

Replace the two initializer defaults with:

```swift
resolve: @escaping Resolve = { selector, context in
    try await TargetResolver().resolve(selector, context: context)
},
```

and:

```swift
validateTarget: @escaping ValidateTarget = { identity, context in
    try await TargetResolver().validate(identity, context: context)
}
```

The injected fixture closures already use the L2 arity and remain pure.

- [ ] **Step 6: Verify L3 GREEN and preservation**

```sh
swift test --package-path native --filter TargetResolverTests
swift test --package-path native --filter AXTrustTests
swift test --package-path native --filter SnapshotTests/testSnapshotWireDataMatchesSharedActualProducerFixture
swift test --package-path native --filter SnapshotTests
swift test --package-path native --filter StateStoreTests
```

Expected GREEN: all commands exit 0; ambiguous app invokes zero window reads; PID 42 invokes `[42]`; unavailable AX metadata remains optional while hard/type failures stay classified; `.000Z` differs from `.001Z`; persisted missing/replaced window is stale; permission/native codes survive; C4 fixture is byte-shape equivalent. No live AX path is invoked.

- [ ] **Step 7: Perform scoped review**

```sh
git grep -n 'TargetInventory.live\|ISO8601DateFormatter().string\|private func axAttribute\|private func axWindows\|String(describing:' -- native/Sources/ComputerUseCore
git grep -n 'launchDate' -- native/Sources/ComputerUseCore/TargetResolver.swift native/Sources/ComputerUseCore/SnapshotService.swift
```

Expected: first grep has no match; second shows the unchanged public key and millisecond formatter path. Review confirms `MainActor.run` has a synchronous body returning `[ProcessMetadata]`, missing launch date stays in metadata, only selected PID reaches AX/CG, A1 `axReadResult` and CF type IDs classify reads, and `apps`/`windows` remain unsupported.

- [ ] **Step 8: Stage exactly L3 and create its one commit**

```sh
git add native/Sources/ComputerUseCore/TargetResolver.swift \
  native/Sources/ComputerUseCore/AXTree.swift \
  native/Sources/ComputerUseCore/SnapshotService.swift \
  native/Tests/ComputerUseCoreTests/TargetResolverTests.swift
git diff --cached --check
git diff --cached --name-only
git commit -m "fix: resolve precise identity for the selected pid"
```

Expected staged names: exactly the four listed files.


---

### Task L4: Cooperative AX and state work boundaries

**Files:**
- Modify: `native/Sources/ComputerUseCore/AXTree.swift`
- Modify: `native/Sources/ComputerUseCore/DesktopLock.swift` (`PrivateStateDirectory.openChild` only)
- Modify: `native/Sources/ComputerUseCore/StateStore.swift`
- Modify: `native/Sources/ComputerUseCore/TargetResolver.swift` (replace temporary timeout and add exact group preparation)
- Modify: `native/Sources/ComputerUseCore/SnapshotService.swift` (context plumbing only)
- Modify: `native/Tests/ComputerUseCoreTests/AXTrustTests.swift`
- Modify: `native/Tests/ComputerUseCoreTests/StateStoreTests.swift`
- Modify: `native/Tests/ComputerUseCoreTests/SnapshotTests.swift`
- Do not modify: evidence policy, fixtures, host state, action phase order, protocol, or TypeScript

**Interfaces:**
- Consumes: L1 context/check/sleeper, L2 async closures and lock, L3 selected-PID provider and live-element wrapper.
- Produces: `AXTree.capture(target:options:context:)`; throwing live-reader closures with contextual `PERMISSION_DENIED`/`NATIVE_FAILURE` mapping while pure evidence mismatches remain `STALE_SNAPSHOT`; context-checking and exact-element-preparation parameters on `AXTree.readSnapshot`; `prepareLiveAXMessaging`; `prepareLiveAXElementMessaging`; context-aware directory enumeration; and context-required `StateStore.sweep`, `readSnapshot`, `writeSnapshot`, `invalidateRecords` using `context.wallNow` for expiry. L5 uses these methods and treats successful `writeSnapshot` return as the publication commit.

- [ ] **Step 1: Add complete deterministic AX RED tests**

Append these methods to `AXTrustTests`:

```swift
func testCancellationDuringBlockedReadStopsBeforeChildTraversal() async {
    let context = axTestContext()
    let entered = expectation(description: "AX read entered")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let calls = LockedInt()
    let reader = AXTreeReader<Int>(
        string: { element, attribute in
            if attribute == kAXRoleAttribute {
                let call = calls.increment()
                if call == 1 {
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 1)
                }
                return .value(element == 0 ? "AXWindow" : "AXButton")
            }
            return .unavailable
        },
        bool: { _, _ in .unavailable },
        children: { element in element == 0 ? .value([1]) : .unavailable },
        actions: { _ in .unavailable },
        bounds: { _ in .unavailable }
    )
    let work = Task.detached { () -> NativeFailure? in
        do {
            _ = try AXTree.readSnapshot(
                target: trustTarget(),
                options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
                root: 0,
                reader: reader,
                checkpoint: { try context.check() }
            )
            return nil
        } catch let failure as NativeFailure {
            return failure
        } catch {
            return NativeFailure("NATIVE_FAILURE", "unexpected test failure")
        }
    }
    await fulfillment(of: [entered], timeout: 1)
    context.cancel()
    release.signal()
    let failure = await work.value
    XCTAssertEqual(failure?.code, "INTERRUPTED")
    XCTAssertEqual(calls.value, 1)
}

func testMainQueueSentinelRunsWhileDetachedAXWorkIsBlocked() async {
    let entered = expectation(description: "detached AX entered")
    let sentinel = expectation(description: "main sentinel")
    let finished = expectation(description: "detached AX finished")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let reader = AXTreeReader<Int>(
        string: { _, attribute in
            if attribute == kAXRoleAttribute {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 1)
                return .value("AXWindow")
            }
            return .unavailable
        },
        bool: { _, _ in .unavailable },
        children: { _ in .unavailable },
        actions: { _ in .unavailable },
        bounds: { _ in .unavailable }
    )
    let work = Task.detached {
        _ = try? AXTree.readSnapshot(
            target: trustTarget(),
            options: TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full),
            root: 0,
            reader: reader
        )
        finished.fulfill()
    }
    await fulfillment(of: [entered], timeout: 1)
    DispatchQueue.main.async { sentinel.fulfill() }
    await fulfillment(of: [sentinel], timeout: 1)
    release.signal()
    await fulfillment(of: [finished], timeout: 1)
    await work.value
}

func testAXTimeoutIsPositiveAndClampedToRemainingBudget() throws {
    var now: UInt64 = 0
    let context = CommandContext(
        timeoutMilliseconds: 3_000,
        clock: NativeClock(
            monotonicNow: { now },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
    XCTAssertEqual(try axMessagingTimeout(context: context), Float(2.0))
    now = 2_750_000_000
    XCTAssertEqual(try axMessagingTimeout(context: context), Float(0.25))
    now = context.deadline
    XCTAssertThrowsError(try axMessagingTimeout(context: context)) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "TIMEOUT")
    }
}

func testLiveAXFailureMappingKeepsPermissionDistinctFromHardFailures() {
    XCTAssertEqual(liveAXFailure(for: .apiDisabled).code, "PERMISSION_DENIED")
    for status in [AXError.cannotComplete, .invalidUIElement, .failure, .success] {
        XCTAssertEqual(liveAXFailure(for: status).code, "NATIVE_FAILURE")
    }
}
```

Add these fully defined file-private helpers to `AXTrustTests.swift`:

```swift
private final class LockedInt {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() -> Int {
        lock.lock()
        storage += 1
        let result = storage
        lock.unlock()
        return result
    }
}

private func axTestContext() -> CommandContext {
    CommandContext(
        timeoutMilliseconds: 1_000,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { Date(timeIntervalSince1970: 0) },
            sleepNanoseconds: { _ in }
        )
    )
}
```

All semaphore waits occur in detached work and have a one-second bound plus test-side `defer` cleanup.

- [ ] **Step 2: Add complete deterministic state RED tests**

Append these methods to `StateStoreTests`:

```swift
func testCancellationBetweenSweepRecordsStopsFurtherOpens() async throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = StateStore(rootURL: root)
    try writer.writeSnapshot(
        snapshotRecord(createdAt: "1970-01-01T00:00:00Z", expiresAt: "1970-01-01T00:10:00Z"),
        context: stateTestContext()
    )
    try writer.writeSnapshot(
        snapshotRecord(id: secondID, createdAt: "1970-01-01T00:00:00Z", expiresAt: "1970-01-01T00:10:00Z"),
        context: stateTestContext()
    )
    let context = stateTestContext()
    let opens = LockedStateInt()
    let io = StateStoreIO(openRecord: { directory, name in
        let value = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if opens.increment() == 1 { context.cancel() }
        return SystemCallResult(value: value, error: value < 0 ? errno : 0)
    })
    let store = StateStore(rootURL: root, io: io)
    XCTAssertThrowsError(try store.sweep(context: context)) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
    }
    XCTAssertEqual(opens.value, 1)
}

func testCancellationDuringBlockedStateReadDoesNotOpenNextRecord() async throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = StateStore(rootURL: root)
    try writer.writeSnapshot(snapshotRecord(), context: stateTestContext())
    try writer.writeSnapshot(snapshotRecord(id: secondID), context: stateTestContext())
    let context = stateTestContext()
    let entered = expectation(description: "state read entered")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let reads = LockedStateInt()
    let opens = LockedStateInt()
    let io = StateStoreIO(
        openRecord: { directory, name in
            opens.increment()
            let value = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        read: { descriptor, buffer, count in
            if reads.increment() == 1 {
                entered.fulfill()
                _ = release.wait(timeout: .now() + 1)
            }
            let value = Darwin.read(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        }
    )
    let store = StateStore(rootURL: root, io: io)
    let work = Task.detached { () -> NativeFailure? in
        do {
            try store.invalidateRecords(for: resolvedTarget().identity, context: context)
            return nil
        } catch let failure as NativeFailure {
            return failure
        } catch {
            return NativeFailure("NATIVE_FAILURE", "unexpected test failure")
        }
    }
    await fulfillment(of: [entered], timeout: 1)
    context.cancel()
    release.signal()
    let failure = await work.value
    XCTAssertEqual(failure?.code, "INTERRUPTED")
    XCTAssertEqual(opens.value, 1)
}

func testCancellationInsideDirectoryEnumerationPreservesInterrupted() throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let context = stateTestContext()
    var enumerationCalls = 0
    let io = StateStoreIO(directoryNames: { _, checkpoint in
        enumerationCalls += 1
        context.cancel()
        try checkpoint()
        return []
    })
    let store = StateStore(rootURL: root, io: io)
    XCTAssertThrowsError(try store.sweep(context: context)) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "INTERRUPTED")
    }
    XCTAssertEqual(enumerationCalls, 1)
}

func testExpiryUsesCommandContextWallClock() throws {
    let root = temporaryStateDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = StateStore(rootURL: root)
    let record = snapshotRecord(
        createdAt: "1970-01-01T00:00:00Z",
        expiresAt: "1970-01-01T00:10:00Z"
    )
    try store.writeSnapshot(
        record,
        context: stateTestContext(wallNow: Date(timeIntervalSince1970: 0))
    )
    XCTAssertNoThrow(try store.readSnapshot(
        id: record.id,
        context: stateTestContext(wallNow: Date(timeIntervalSince1970: 599))
    ))
    XCTAssertThrowsError(try store.readSnapshot(
        id: record.id,
        context: stateTestContext(wallNow: Date(timeIntervalSince1970: 600))
    )) {
        XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
    }
}
```

Add these complete file-private helpers to `StateStoreTests.swift`:

```swift
private final class LockedStateInt {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    @discardableResult
    func increment() -> Int {
        lock.lock()
        storage += 1
        let result = storage
        lock.unlock()
        return result
    }
}

private func stateTestContext(
    wallNow: Date = Date(timeIntervalSince1970: 0),
    cancellation: CommandCancellation = CommandCancellation()
) -> CommandContext {
    CommandContext(
        timeoutMilliseconds: 5_000,
        clock: NativeClock(
            monotonicNow: { 0 },
            wallNow: { wallNow },
            sleepNanoseconds: { _ in }
        ),
        cancellation: cancellation
    )
}
```

- [ ] **Step 3: Verify focused L4 RED**

```sh
swift test --package-path native --filter AXTrustTests/testCancellationDuringBlockedReadStopsBeforeChildTraversal
swift test --package-path native --filter AXTrustTests/testMainQueueSentinelRunsWhileDetachedAXWorkIsBlocked
swift test --package-path native --filter AXTrustTests/testAXTimeoutIsPositiveAndClampedToRemainingBudget
swift test --package-path native --filter AXTrustTests/testLiveAXFailureMappingKeepsPermissionDistinctFromHardFailures
swift test --package-path native --filter StateStoreTests/testCancellationBetweenSweepRecordsStopsFurtherOpens
swift test --package-path native --filter StateStoreTests/testCancellationDuringBlockedStateReadDoesNotOpenNextRecord
swift test --package-path native --filter StateStoreTests/testCancellationInsideDirectoryEnumerationPreservesInterrupted
swift test --package-path native --filter StateStoreTests/testExpiryUsesCommandContextWallClock
```

Expected RED: compile failures identify missing `checkpoint:`, `axMessagingTimeout`, `liveAXFailure(for:)`, the context-aware directory-enumeration closure arity, context parameters on state APIs, and the new `StateStore(rootURL:io:)` initializer; the expiry test also lacks context-owned wall-time behavior. The barriers and helper types are all defined, so RED is not a deadlock or missing-test-helper failure.

- [ ] **Step 4: Add AX checkpoints and exact-ref messaging preparation**

First replace `AXTreeReader` so injected live reads can throw classified failures without weakening pure A1 evidence tests:

```swift
struct AXTreeReader<Element> {
    let string: (Element, String) throws -> AXReadResult<String>
    let bool: (Element, String) throws -> AXReadResult<Bool>
    let children: (Element) throws -> AXReadResult<[Element]>
    let actions: (Element) throws -> AXReadResult<[String]>
    let bounds: (Element) throws -> AXReadResult<WindowBounds>
}
```

Existing nonthrowing fixture closures remain valid for these throwing function types. Their explicit `.failure` values still mean untrusted persisted evidence and continue mapping to `STALE_SNAPSHOT`; only the production live closures below throw contextual API failures.
Replace `AXTree.readSnapshot` and `readNode` with:

```swift
static func readSnapshot<Element>(
    target: ResolvedTarget,
    options: TreeOptions,
    root: Element,
    reader: AXTreeReader<Element>,
    checkpoint: () throws -> Void = {},
    prepare: (Element) throws -> Void = { _ in }
) throws -> (snapshot: AXTreeSnapshot, elementsByRef: [Int: Element]) {
    var visited = 0
    var elementsByPath: [[Int]: Element] = [:]
    let input = try readNode(
        root,
        path: [],
        depth: 0,
        options: options,
        reader: reader,
        checkpoint: checkpoint,
        prepare: prepare,
        visited: &visited,
        elementsByPath: &elementsByPath
    )
    let snapshot = snapshot(target: target, options: options, root: input)
    var elementsByRef: [Int: Element] = [:]
    for ref in snapshot.evidence.refs {
        try checkpoint()
        guard let element = elementsByPath[ref.path] else { throw observationFailure() }
        elementsByRef[ref.ref] = element
    }
    return (snapshot, elementsByRef)
}

private static func readNode<Element>(
    _ element: Element,
    path: [Int],
    depth: Int,
    options: TreeOptions,
    reader: AXTreeReader<Element>,
    checkpoint: () throws -> Void,
    prepare: (Element) throws -> Void,
    visited: inout Int,
    elementsByPath: inout [[Int]: Element]
) throws -> AXTreeInputNode {
    try checkpoint()
    try prepare(element)
    visited += 1
    elementsByPath[path] = element
    let role = try required(reader.string(element, kAXRoleAttribute))
    let subrole = try optional(reader.string(element, kAXSubroleAttribute))
    let identifier = try optional(reader.string(element, kAXIdentifierAttribute))
    let title = try optional(reader.string(element, kAXTitleAttribute))
    let label = try optional(reader.string(element, kAXDescriptionAttribute))
    let value = try optional(reader.string(element, kAXValueAttribute))
    let enabled = try optional(reader.bool(element, kAXEnabledAttribute))
    let focused = try optional(reader.bool(element, kAXFocusedAttribute))
    let selected = try optional(reader.bool(element, kAXSelectedAttribute))
    let rawChildren = try collection(reader.children(element))
    let actions = try collection(reader.actions(element))
    let bounds = try optional(reader.bounds(element))

    var children: [AXTreeInputNode] = []
    if depth < options.maxDepth {
        for (index, child) in rawChildren.enumerated() {
            guard visited < options.maxElements else { break }
            try checkpoint()
            children.append(try readNode(
                child,
                path: path + [index],
                depth: depth + 1,
                options: options,
                reader: reader,
                checkpoint: checkpoint,
                prepare: prepare,
                visited: &visited,
                elementsByPath: &elementsByPath
            ))
        }
    }
    return AXTreeInputNode(
        role: role,
        subrole: subrole,
        identifier: identifier,
        title: title,
        label: label,
        value: value,
        enabled: enabled,
        focused: focused,
        selected: selected,
        actions: actions,
        bounds: bounds,
        children: children,
        totalChildCount: rawChildren.count
    )
}
```

Replace `AXTree.capture` with:

```swift
public static func capture(
    target: ResolvedTarget,
    options: TreeOptions,
    context: CommandContext
) throws -> AXTreeObservation {
    try context.check()
    guard AXIsProcessTrusted() else {
        throw NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    guard let pid = pid_t(exactly: target.identity.pid), pid > 0 else {
        throw observationFailure()
    }
    let app = AXUIElementCreateApplication(pid)
    try prepareLiveAXMessaging(app, context: context)
    let reader = liveAXTreeReader()
    guard case let .value(windows) = try liveAXChildren(
        app,
        attribute: kAXWindowsAttribute
    ) else {
        throw observationFailure()
    }
    var matches: [AXUIElement] = []
    for window in windows {
        try context.check()
        try prepareLiveAXMessaging(window, context: context)
        guard case let .value(role) = try reader.string(window, kAXRoleAttribute),
              case let .value(title) = try reader.string(window, kAXTitleAttribute),
              case let .value(bounds) = try reader.bounds(window) else {
            throw observationFailure()
        }
        if role == "AXWindow" && title == target.title && bounds == target.bounds {
            matches.append(window)
        }
    }
    guard matches.count == 1 else {
        throw NativeFailure("STALE_SNAPSHOT", "Selected window identity is no longer unique")
    }
    let result = try readSnapshot(
        target: target,
        options: options,
        root: matches[0],
        reader: reader,
        checkpoint: { try context.check() },
        prepare: { try prepareLiveAXMessaging($0, context: context) }
    )
    return AXTreeObservation(
        snapshot: result.snapshot,
        liveElements: result.elementsByRef.mapValues(LiveAXElement.init)
    )
}
```

Add these internal helpers after `LiveAXElement`:

```swift
func axMessagingTimeout(context: CommandContext) throws -> Float {
    try context.check()
    let remaining = Double(context.remainingNanoseconds) / 1_000_000_000
    guard remaining > 0 else {
        try context.check()
        throw NativeFailure("TIMEOUT", "Desktop operation deadline expired")
    }
    return Float(min(2.0, remaining))
}

func prepareLiveAXMessaging(
    _ element: AXUIElement,
    context: CommandContext
) throws {
    let timeout = try axMessagingTimeout(context: context)
    let status = AXUIElementSetMessagingTimeout(element, timeout)
    guard status == .success else { throw liveAXFailure(for: status) }
}

func prepareLiveAXElementMessaging(
    _ element: LiveAXElement,
    context: CommandContext
) throws {
    guard let rawValue = element.rawValue else {
        throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
    }
    try prepareLiveAXMessaging(rawValue, context: context)
}
```

Add `liveAXFailure` and `classifyLiveAXResult` immediately before `liveAXTreeReader`; replace `liveAXTreeReader`; keep L3's internal `liveAXAttribute` implementation in place; then replace `liveAXString`, `liveAXBool`, `liveAXChildren`, `liveAXActions`, and `liveAXBounds` with the corresponding declarations below:

```swift
func liveAXFailure(for status: AXError) -> NativeFailure {
    if status == .apiDisabled {
        return NativeFailure("PERMISSION_DENIED", "Accessibility access is unavailable")
    }
    return NativeFailure("NATIVE_FAILURE", "Accessibility data could not be read reliably")
}

private func classifyLiveAXResult<Value>(
    status: AXError,
    result: AXReadResult<Value>
) throws -> AXReadResult<Value> {
    if case .failure = result { throw liveAXFailure(for: status) }
    return result
}

private func liveAXTreeReader() -> AXTreeReader<AXUIElement> {
    AXTreeReader(
        string: liveAXString,
        bool: liveAXBool,
        children: { try liveAXChildren($0, attribute: kAXChildrenAttribute) },
        actions: liveAXActions,
        bounds: liveAXBounds
    )
}

private func liveAXString(
    _ element: AXUIElement,
    _ attribute: String
) throws -> AXReadResult<String> {
    let read = liveAXAttribute(element, attribute)
    return try classifyLiveAXResult(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFStringGetTypeID(),
            decode: { $0 as? String }
        )
    )
}

private func liveAXBool(
    _ element: AXUIElement,
    _ attribute: String
) throws -> AXReadResult<Bool> {
    let read = liveAXAttribute(element, attribute)
    return try classifyLiveAXResult(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFBooleanGetTypeID(),
            decode: { $0 as? Bool }
        )
    )
}

private func liveAXChildren(
    _ element: AXUIElement,
    attribute: String
) throws -> AXReadResult<[AXUIElement]> {
    let read = liveAXAttribute(element, attribute)
    return try classifyLiveAXResult(
        status: read.status,
        result: axReadResult(
            status: read.status,
            value: read.value,
            expectedTypeID: CFArrayGetTypeID(),
            decode: { value in
                let array = value as! CFArray
                return decodeAXArray(
                    array as [AnyObject],
                    expectedElementTypeID: AXUIElementGetTypeID(),
                    decode: { unsafeBitCast($0, to: AXUIElement.self) }
                )
            }
        )
    )
}

private func liveAXActions(_ element: AXUIElement) throws -> AXReadResult<[String]> {
    var names: CFArray?
    let status = AXUIElementCopyActionNames(element, &names)
    return try classifyLiveAXResult(
        status: status,
        result: axReadResult(
            status: status,
            value: names,
            expectedTypeID: CFArrayGetTypeID(),
            decode: { value in
                let array = value as! CFArray
                return decodeAXArray(
                    array as [AnyObject],
                    expectedElementTypeID: CFStringGetTypeID(),
                    decode: { $0 as? String }
                )
            }
        )
    )
}

private func liveAXBounds(_ element: AXUIElement) throws -> AXReadResult<WindowBounds> {
    let positionRead = liveAXAttribute(element, kAXPositionAttribute)
    let sizeRead = liveAXAttribute(element, kAXSizeAttribute)
    let position: AXReadResult<AXValue> = axReadResult(
        status: positionRead.status,
        value: positionRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { $0 as! AXValue }
    )
    let size: AXReadResult<AXValue> = axReadResult(
        status: sizeRead.status,
        value: sizeRead.value,
        expectedTypeID: AXValueGetTypeID(),
        decode: { $0 as! AXValue }
    )

    switch (position, size) {
    case (.failure, _):
        throw liveAXFailure(for: positionRead.status)
    case (_, .failure):
        throw liveAXFailure(for: sizeRead.status)
    case (.unavailable, _), (_, .unavailable):
        return .unavailable
    case let (.value(position), .value(size)):
        guard AXValueGetType(position) == .cgPoint,
              AXValueGetType(size) == .cgSize else {
            throw liveAXFailure(for: .success)
        }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &dimensions) else {
            throw liveAXFailure(for: .success)
        }
        return .value(WindowBounds(
            x: point.x,
            y: point.y,
            width: dimensions.width,
            height: dimensions.height
        ))
    }
}
```

This preserves A1's unavailable/type distinctions while preventing a live permission or hard AX failure from being collapsed into `STALE_SNAPSHOT`.

- [ ] **Step 5: Clamp exact AX refs and checkpoint every selected-PID window group**

In `TargetResolver.liveWindows`, replace the hard-coded app timeout with:

```swift
try prepareLiveAXMessaging(application, context: context)
```

At the top of each `for element in windowElements` iteration, use:

```swift
try context.check()
try prepareLiveAXMessaging(element, context: context)
```

This sets timeout separately on the app request ref and each exact window ref; no equal-ref timeout assumption is made.
Replace the `liveWindows` tail beginning at `let cgWindows` with:

```swift
let cgWindows = try liveCGWindows(for: pid, context: context)
var matched: [TargetWindow] = []
for ax in axWindows {
    try context.check()
    for cg in cgWindows {
        try context.check()
        guard matches(ax: ax, cg: cg) else { continue }
        matched.append(TargetWindow(
            ax: ax,
            cg: CGWindowMetadata(
                id: cg.id,
                title: cg.title,
                bounds: cg.bounds,
                onScreen: cg.onScreen,
                minimized: ax.minimized == true
            )
        ))
    }
}
return matched
```

Replace `liveCGWindows` with:

```swift
private func liveCGWindows(
    for pid: Int,
    context: CommandContext
) throws -> [CGWindowMetadata] {
    try context.check()
    guard let values = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else {
        throw NativeFailure("NATIVE_FAILURE", "Window inventory could not be read")
    }
    try context.check()
    var windows: [CGWindowMetadata] = []
    for value in values {
        try context.check()
        guard value[kCGWindowOwnerPID as String] as? Int == pid else { continue }
        guard let id = value[kCGWindowNumber as String] as? Int, id > 0,
              let dictionary = value[kCGWindowBounds as String] as? [String: CGFloat],
              let x = dictionary["X"],
              let y = dictionary["Y"],
              let width = dictionary["Width"],
              let height = dictionary["Height"],
              x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              width >= 0,
              height >= 0 else {
            throw NativeFailure("NATIVE_FAILURE", "Window inventory contained invalid metadata")
        }
        windows.append(CGWindowMetadata(
            id: id,
            title: value[kCGWindowName as String] as? String,
            bounds: WindowBounds(x: x, y: y, width: width, height: height),
            onScreen: value[kCGWindowIsOnscreen as String] as? Bool ?? false,
            minimized: false
        ))
    }
    return windows
}
```

The system CG call cannot be preempted, but checks run immediately before and after it, between every returned entry, and in the AX-to-CG matching loop. Together with the exact-ref preparation above, no selected-PID window group resets or escapes the command context.

- [ ] **Step 6: Make child-directory retries context-aware**

Replace `PrivateStateDirectory.openChild` with:

```swift
static func openChild(
    _ name: String,
    rootDescriptor: Int32,
    create: Bool,
    checkpoint: () throws -> Void = {}
) throws -> Int32 {
    if create {
        while mkdirat(rootDescriptor, name, 0o700) != 0 {
            if errno == EINTR {
                try checkpoint()
                continue
            }
            guard errno == EEXIST else {
                throw stateFailure("Unable to create the state records directory")
            }
            break
        }
    }
    let descriptor: Int32
    while true {
        try checkpoint()
        let opened = openat(
            rootDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if opened >= 0 {
            descriptor = opened
            break
        }
        if errno == EINTR {
            try checkpoint()
            continue
        }
        throw stateFailure("Unable to open the state records directory")
    }
    do {
        try verifyPrivateDirectory(descriptor)
        guard fchmod(descriptor, 0o700) == 0 else {
            throw stateFailure("Unable to protect the state records directory")
        }
        return descriptor
    } catch {
        close(descriptor)
        throw error
    }
}
```

- [ ] **Step 7: Make `CommandContext` own state time and replace context-aware I/O loops**
Delete `StateStore.currentDate`. Replace its stored-property and initializer block with:

```swift
private let rootURL: URL
private let encoder: JSONEncoder
private let decoder = JSONDecoder()
private let io: StateStoreIO

public init(rootURL: URL = DesktopLock.defaultRootURL) {
    self.rootURL = rootURL
    io = StateStoreIO()
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
}

init(rootURL: URL, io: StateStoreIO) {
    self.rootURL = rootURL
    self.io = io
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
}
```

There is no retained compatibility `now` closure: record timestamps and expiry decisions use the one command context wall clock.
First change only the `directoryNames` field and matching initializer parameter in `StateStoreIO`:

```swift
let directoryNames: (Int32, () throws -> Void) throws -> [String]
```

```swift
directoryNames: @escaping (Int32, () throws -> Void) throws -> [String] = liveDirectoryNames,
```

Keep the other five seam fields, initializer parameters, assignments, and live defaults unchanged. Replace `liveDirectoryNames` with:

```swift
private func liveDirectoryNames(
    _ descriptor: Int32,
    checkpoint: () throws -> Void
) throws -> [String] {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else {
        if duplicate >= 0 { close(duplicate) }
        throw stateFailure("Unable to enumerate snapshot state")
    }
    defer { closedir(directory) }
    var names: [String] = []
    while true {
        try checkpoint()
        errno = 0
        guard let entry = readdir(directory) else {
            if errno == EINTR {
                try checkpoint()
                continue
            }
            guard errno == 0 else {
                throw stateFailure("Unable to enumerate snapshot state")
            }
            break
        }
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                String(cString: $0)
            }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
}
```

The live enumerator checks before every entry and again after `EINTR` before retrying.

Replace the four public methods with:

```swift
public func writeSnapshot(_ record: SnapshotRecord, context: CommandContext) throws {
    guard validateRecord(record, expectedID: record.id) else { throw staleSnapshot() }
    try context.check()
    let data: Data
    do { data = try encoder.encode(record) }
    catch { throw stateFailure("Unable to encode snapshot state") }
    try withSnapshotDirectory(create: true, context: context) { descriptor in
        try atomicWrite(
            data,
            named: recordFileName(record.id),
            directoryDescriptor: descriptor,
            replacing: false,
            context: context
        )
    }
}

public func readSnapshot(id: String, context: CommandContext) throws -> SnapshotRecord {
    guard let id = canonicalUUID(id) else { throw staleSnapshot() }
    try context.check()
    return try withSnapshotDirectory(create: false, context: context) { descriptor in
        let record = try decodeRecord(
            named: recordFileName(id),
            directoryDescriptor: descriptor,
            context: context
        )
        guard validateRecord(record, expectedID: id),
              !record.invalidated,
              let expiration = parseSnapshotTimestamp(record.expiresAt)?.date,
              context.wallNow < expiration else { throw staleSnapshot() }
        try context.check()
        return record
    }
}

public func sweep(context: CommandContext) throws {
    try context.check()
    try withSnapshotDirectory(create: true, context: context) { descriptor in
        let names = try io.directoryNames(descriptor) { try context.check() }
        for name in names {
            try context.check()
            if temporaryRecordName(name) {
                _ = unlinkat(descriptor, name, 0)
                continue
            }
            guard let id = recordID(from: name) else { continue }
            let record: SnapshotRecord
            do {
                record = try decodeRecord(
                    named: name,
                    directoryDescriptor: descriptor,
                    context: context
                )
            } catch let failure as NativeFailure
                where failure.code == "INTERRUPTED" || failure.code == "TIMEOUT" {
                throw failure
            } catch {
                continue
            }
            let expired = parseSnapshotTimestamp(record.expiresAt).map {
                context.wallNow >= $0.date
            } ?? false
            if record.id == id && (record.invalidated || expired) {
                _ = unlinkat(descriptor, name, 0)
            }
        }
        try context.check()
        guard fsync(descriptor) == 0 else {
            throw stateFailure("Unable to synchronize snapshot state")
        }
    }
    try context.check()
}

public func invalidateRecords(
    for identity: TargetIdentity,
    context: CommandContext
) throws {
    try context.check()
    try withSnapshotDirectory(create: true, context: context) { descriptor in
        let names = try io.directoryNames(descriptor) { try context.check() }
        for name in names {
            try context.check()
            guard let id = recordID(from: name) else { continue }
            let record = try decodeRecord(
                named: name,
                directoryDescriptor: descriptor,
                context: context
            )
            guard validateRecord(record, expectedID: id) else { throw staleSnapshot() }
            guard sameApplication(record.target.identity, identity),
                  !record.invalidated else { continue }
            let data: Data
            do { data = try encoder.encode(record.invalidatedCopy()) }
            catch { throw stateFailure("Unable to encode invalidated state") }
            try atomicWrite(
                data,
                named: name,
                directoryDescriptor: descriptor,
                replacing: true,
                context: context
            )
        }
    }
    try context.check()
}
```

Replace the four private methods with:

```swift
private func withSnapshotDirectory<T>(
    create: Bool,
    context: CommandContext,
    _ body: (Int32) throws -> T
) throws -> T {
    let checkpoint = { try context.check() }
    let rootDescriptor = try PrivateStateDirectory.openRoot(
        rootURL,
        checkpoint: checkpoint
    )
    defer { close(rootDescriptor) }
    let snapshotDescriptor: Int32
    do {
        snapshotDescriptor = try PrivateStateDirectory.openChild(
            "snapshots",
            rootDescriptor: rootDescriptor,
            create: create,
            checkpoint: checkpoint
        )
    } catch let failure as NativeFailure
        where failure.code == "INTERRUPTED" || failure.code == "TIMEOUT" {
        throw failure
    } catch where !create && errno == ENOENT {
        throw staleSnapshot()
    }
    defer { close(snapshotDescriptor) }
    return try body(snapshotDescriptor)
}

private func decodeRecord(
    named name: String,
    directoryDescriptor: Int32,
    context: CommandContext
) throws -> SnapshotRecord {
    let descriptor: Int32
    while true {
        try context.check()
        let result = io.openRecord(directoryDescriptor, name)
        if result.value >= 0 {
            descriptor = result.value
            break
        }
        if result.error == EINTR {
            try context.check()
            continue
        }
        throw staleSnapshot()
    }
    defer { close(descriptor) }
    do { try verifyPrivateFile(descriptor) } catch { throw staleSnapshot() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
          info.st_size >= 0,
          info.st_size <= 16 * 1_024 * 1_024,
          info.st_mode & 0o777 == 0o600 else { throw staleSnapshot() }
    var data = Data(count: Int(info.st_size))
    let count = try data.withUnsafeMutableBytes { buffer -> Int in
        var offset = 0
        while offset < buffer.count {
            try context.check()
            let result = io.read(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                buffer.count - offset
            )
            if result.value < 0 && result.error == EINTR {
                try context.check()
                continue
            }
            if result.value <= 0 { return -1 }
            offset += result.value
        }
        return offset
    }
    guard count == data.count,
          let record = try? decoder.decode(SnapshotRecord.self, from: data) else {
        throw staleSnapshot()
    }
    return record
}

private func atomicWrite(
    _ data: Data,
    named name: String,
    directoryDescriptor: Int32,
    replacing: Bool,
    context: CommandContext
) throws {
    try context.check()
    if !replacing {
        var info = stat()
        guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else {
            throw stateFailure("Snapshot state already exists")
        }
    }
    let temporaryName = ".tmp.\(UUID().uuidString.lowercased()).json"
    let descriptor = openat(
        directoryDescriptor,
        temporaryName,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0o600
    )
    guard descriptor >= 0 else { throw stateFailure("Unable to create snapshot state") }
    var shouldRemoveTemporary = true
    defer {
        close(descriptor)
        if shouldRemoveTemporary { _ = unlinkat(directoryDescriptor, temporaryName, 0) }
    }
    guard fchmod(descriptor, 0o600) == 0 else {
        throw stateFailure("Unable to protect snapshot state")
    }
    try verifyPrivateFile(descriptor)
    let wroteAll = try data.withUnsafeBytes { buffer -> Bool in
        var offset = 0
        while offset < buffer.count {
            try context.check()
            let result = io.write(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                buffer.count - offset
            )
            if result.value < 0 && result.error == EINTR {
                try context.check()
                continue
            }
            if result.value <= 0 { return false }
            offset += result.value
        }
        return true
    }
    guard wroteAll else { throw stateFailure("Unable to write snapshot state") }
    try context.check()
    guard io.sync(descriptor).value == 0 else {
        throw stateFailure("Unable to write snapshot state")
    }
    try context.check()
    let renamed = io.renameRecord(
        directoryDescriptor,
        temporaryName,
        directoryDescriptor,
        name
    )
    guard renamed.value == 0 else {
        throw stateFailure("Unable to publish snapshot state")
    }
    shouldRemoveTemporary = false
    guard io.sync(directoryDescriptor).value == 0 else {
        throw stateFailure("Unable to synchronize snapshot state")
    }
    // COMMIT: rename is immediately followed by directory sync; no cancellation check or deletion occurs after publication begins.
}
```

The other state I/O seam fields and `validateRecord`/timestamp parser remain unchanged. Directory enumeration now receives the same context checkpoint and invokes it before each entry and after `EINTR`. Once rename begins publication, no cancellation/deadline check occurs before or after directory sync. Directory-sync failure after rename remains a native failure with no rollback deletion.

- [ ] **Step 8: Migrate every state call site in one compile boundary**

Apply these exact API substitutions in `StateStoreTests.swift` and `SnapshotTests.swift`; use each file's fully defined `stateTestContext()` or `snapshotCommandContext(wallNow:)`:
Delete every `now:` argument from `StateStore` initialization. Where a test previously injected a store date, keep that value in a local `wallNow` and pass it to every state operation through `stateTestContext(wallNow:)`. For example:

```swift
let wallNow = Date(timeIntervalSince1970: 1_000)
let context = stateTestContext(wallNow: wallNow)
let store = StateStore(rootURL: root)
try store.writeSnapshot(record, context: context)
try store.sweep(context: context)
```

This is a clock ownership migration, not a fixture-date rewrite.

```swift
try store.writeSnapshot(record, context: stateTestContext())
try store.readSnapshot(id: record.id, context: stateTestContext())
try store.sweep(context: stateTestContext())
try store.invalidateRecords(for: identity, context: stateTestContext())
```

In `StateStoreTests.testInvalidationRewritesAllRecordsForAppBeforeReturning`, replace the method-reference call with:

```swift
for record in [first, sameApp, other] {
    try store.writeSnapshot(record, context: stateTestContext())
}
```

In `StateStoreTests.testLifetimeMustBeExactlyTenMinutes`, replace `operation` with:

```swift
let operation = {
    try StateStore(rootURL: root).writeSnapshot(
        snapshotRecord(
            createdAt: "2999-01-01T00:00:00.0000Z",
            expiresAt: expiration
        ),
        context: stateTestContext()
    )
}
```

All other state invocations use the same direct one-context form; there is no default context and no overload.

In `SnapshotTests.testEnumerationFailureAfterPreflightPreventsDispatch`, migrate the injected enumerator to the new arity without changing its fault order:

```swift
directoryNames: { descriptor, _ in
    enumerationCount += 1
    if enumerationCount == 1 { return try testDirectoryNames(descriptor) }
    throw NativeFailure("NATIVE_FAILURE", "Injected enumeration failure")
}
```

No other test injects `directoryNames`.

In `SnapshotTests.swift`, pass `snapshotCommandContext(wallNow: now)` to each `writeSnapshot`, `readSnapshot`, and action-internal assertion. In tests with no local `now`, define:

```swift
let now = Date(timeIntervalSince1970: 1_788_861_900)
```

Construct `StateStore` without `now:` and use `snapshotCommandContext(wallNow: now)` for every write, read, sweep, invalidation, and action call. Preserve every pre-existing assertion and fault-injection seam.

- [ ] **Step 9: Plumb context through service defaults and calls**

In `SnapshotService`, replace the observe default with:

```swift
observe: @escaping Observe = { target, options, context in
    try AXTree.capture(target: target, options: options, context: context)
},
```

Replace store calls exactly:

```swift
try store.sweep(context: context)
try store.writeSnapshot(record, context: context)
let record = try store.readSnapshot(id: snapshotID, context: context)
try store.invalidateRecords(for: record.target.identity, context: context)
```

Do not otherwise reorder `SnapshotService` in L4.

- [ ] **Step 10: Verify L4 GREEN and preserved contracts**

```sh
swift test --package-path native --filter AXTrustTests
swift test --package-path native --filter StateStoreTests
swift test --package-path native --filter TargetResolverTests
swift test --package-path native --filter SnapshotTests
swift test --package-path native
```

Expected GREEN: all commands exit 0. Cancellation stops after the first AX/state group; the main sentinel runs before release; timeout clamps to 2.0 then 0.25 and fails at zero; A1/A2/A4 tests, subprocess cleanup tests, and C4 producer fixture remain green.

- [ ] **Step 11: Perform scoped review**

```sh
git grep -n 'AXUIElementSetMessagingTimeout([^,]*, 2' -- native/Sources
git grep -n 'func sweep()\|func writeSnapshot(_ record: SnapshotRecord)\|func capture(target: ResolvedTarget, options: TreeOptions)' -- native/Sources
git grep -n 'currentDate\|StateStore(.*now:' -- native
git grep -n 'Synchronization.Mutex\|DispatchSemaphore' -- native/Sources
git diff --check
```

Expected: no hard-coded AX timeout, no context-free production APIs, no second `StateStore` wall clock, no production mutex/semaphore, and no whitespace errors. Review confirms exact ref timeout before each group, checks after EINTR and between records/nodes, context-owned expiry, no changed evidence/store path, no cancellation check after rename begins publication, no rollback deletion, and no L5 phase types.

- [ ] **Step 12: Stage exactly L4 and create its one commit**

```sh
git add native/Sources/ComputerUseCore/AXTree.swift \
  native/Sources/ComputerUseCore/DesktopLock.swift \
  native/Sources/ComputerUseCore/StateStore.swift \
  native/Sources/ComputerUseCore/TargetResolver.swift \
  native/Sources/ComputerUseCore/SnapshotService.swift \
  native/Tests/ComputerUseCoreTests/AXTrustTests.swift \
  native/Tests/ComputerUseCoreTests/StateStoreTests.swift \
  native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --cached --check
git diff --cached --name-only
git commit -m "fix: check cancellation across AX and state work"
```

Expected staged names: exactly the eight listed files.


---

### Task L5: Snapshot publication and strict refreshed action transaction

**Files:**
- Create: `native/Tests/ComputerUseCoreTests/SnapshotTransactionTests.swift`
- Modify: `native/Sources/ComputerUseCore/SnapshotService.swift` (complete class replacement)
- Modify: `native/Tests/ComputerUseCoreTests/SnapshotTests.swift` (final dispatch arity and second-preflight-safe expectations)
- Do not modify: `AXTree.swift`, `StateStore.swift`, resolver, host, protocol, TypeScript, or fixtures

**Interfaces:**
- Consumes: context-aware lock/store/capture from L1–L4, precise `validateTarget` from L3, `AXElementIdentity`, `liveAXElementsAreIdentical`, and `prepareLiveAXElementMessaging`.
- Produces: final `SnapshotService` phase machine with async, throwing, context-aware `PrepareForeground`, `PrepareElement`, `Preflight`, and `Dispatch` closure contracts. No public command starts using the internal action method in this task.

- [ ] **Step 1: Create the complete transaction RED test file**

Create `native/Tests/ComputerUseCoreTests/SnapshotTransactionTests.swift`:

```swift
import ApplicationServices
import Darwin
import XCTest
@testable import ComputerUseCore

final class SnapshotTransactionTests: XCTestCase {
    private let wall = Date(timeIntervalSince1970: 1_788_861_900)

    func testSnapshotRefreshesIdentityAfterObservationBeforePublishing() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let changed = changedLaunchTarget(snapshot.target)
        let store = StateStore(rootURL: root)
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            resolve: { _, _ in snapshot.target },
            observe: { _, _, _ in AXTreeObservation(snapshot: snapshot, liveElements: [:]) },
            validateTarget: { _, _ in changed },
            prepareElement: { _, _ in }
        )
        await assertTransactionFailure("STALE_SNAPSHOT") {
            try await service.snapshot(
                selector: .pid(42, windowId: 7),
                options: snapshot.treeOptions,
                context: self.context()
            )
        }
        let snapshots = root.appendingPathComponent("snapshots")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [], [])
    }

    func testActionPhaseOrderRunsSecondPreflightAndDispatchesFreshPair() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        let first = LiveAXElement(AXUIElementCreateApplication(42))
        let second = LiveAXElement(AXUIElementCreateApplication(43))
        var observes = 0
        var preflights = 0
        var validates = 0
        var phases: [String] = []
        var refreshedRaw: AXUIElement?
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { _, _, _ in
                observes += 1
                phases.append("observe-\(observes)")
                return AXTreeObservation(
                    snapshot: snapshot,
                    liveElements: [2: observes == 1 ? first : second]
                )
            },
            validateTarget: { _, _ in
                validates += 1
                phases.append("validate-\(validates)")
                return snapshot.target
            },
            sameLiveElement: { _, fresh in
                phases.append("continuity")
                refreshedRaw = fresh.rawValue
                return true
            },
            prepareForeground: { _, _, _ in phases.append("foreground") },
            prepareElement: { _, _ in phases.append("prepare-element") }
        )

        try await service.withValidatedSnapshotAction(
            snapshotID: id,
            ref: 2,
            context: context(),
            stateChanging: true,
            preflight: { _, _, _ in
                preflights += 1
                phases.append("preflight-\(preflights)")
                return "prepared-\(preflights)"
            },
            dispatch: { prepared, element, _ in
                phases.append("dispatch")
                XCTAssertEqual(prepared, "prepared-2")
                XCTAssertNotNil(refreshedRaw)
                XCTAssertNotNil(element.rawValue)
                let expected = try XCTUnwrap(refreshedRaw)
                let actual = try XCTUnwrap(element.rawValue)
                XCTAssertTrue(CFEqual(expected, actual))
            }
        )

        XCTAssertEqual(observes, 2)
        XCTAssertEqual(preflights, 2)
        XCTAssertEqual(validates, 6)
        XCTAssertEqual(phases, [
            "validate-1", "observe-1", "validate-2", "prepare-element",
            "preflight-1", "validate-3", "foreground", "validate-4",
            "observe-2", "validate-5", "continuity", "prepare-element",
            "preflight-2", "validate-6", "prepare-element", "dispatch"
        ])
        XCTAssertNil(try? store.readSnapshot(id: id, context: context()))
    }

    func testPreflightFailureKeepsRecordAndDoesNotDispatch() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        var dispatches = 0
        let service = transactionService(root: root, store: store, snapshots: [snapshot])
        let failure = await captureTransactionFailure {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: self.context(),
                stateChanging: true,
                preflight: { _, _, _ in
                    throw NativeFailure("INVALID_REQUEST", "preflight failed", details: ["safe": .string("kept")])
                },
                dispatch: { _, _, _ in dispatches += 1 }
            )
        }
        XCTAssertEqual(failure?.code, "INVALID_REQUEST")
        XCTAssertEqual(failure?.details, [
            "safe": .string("kept"),
            "mutationStatus": .string("notStarted")
        ])
        XCTAssertEqual(dispatches, 0)
        XCTAssertNoThrow(try store.readSnapshot(id: id, context: context()))
    }

    func testInvalidationFailurePreventsHookSecondPreflightAndDispatch() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        try populatedStore(root: root, snapshot: snapshot, id: id)
        let io = StateStoreIO(write: { _, _, _ in SystemCallResult(value: -1, error: EIO) })
        let store = StateStore(rootURL: root, io: io)
        var preflights = 0
        var hooks = 0
        var dispatches = 0
        let service = transactionService(root: root, store: store, snapshots: [snapshot]) {
            hooks += 1
        }
        let failure = await captureTransactionFailure {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: self.context(),
                stateChanging: true,
                preflight: { _, _, _ in preflights += 1; return "ok" },
                dispatch: { _, _, _ in dispatches += 1 }
            )
        }
        XCTAssertEqual(failure?.details?["mutationStatus"], .string("notStarted"))
        XCTAssertEqual(preflights, 1)
        XCTAssertEqual(hooks, 0)
        XCTAssertEqual(dispatches, 0)
    }

    func testDeadlineCrossingDuringInvalidationLeavesInvalidatedAndZeroDispatch() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        try populatedStore(root: root, snapshot: snapshot, id: id)
        let ticks = LockedUInt64(0)
        let context = self.context(timeoutMilliseconds: 1, monotonicNow: { ticks.value })
        let io = StateStoreIO(renameRecord: { oldDirectory, oldName, newDirectory, newName in
            let value = renameat(oldDirectory, oldName, newDirectory, newName)
            if value == 0 { ticks.value = context.deadline }
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        })
        let store = StateStore(rootURL: root, io: io)
        var hooks = 0
        var dispatches = 0
        let service = transactionService(root: root, store: store, snapshots: [snapshot]) {
            hooks += 1
        }
        let failure = await captureTransactionFailure {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: context,
                stateChanging: true,
                preflight: { _, _, _ in "ok" },
                dispatch: { _, _, _ in dispatches += 1 }
            )
        }
        XCTAssertEqual(failure?.code, "TIMEOUT")
        XCTAssertEqual(failure?.details?["mutationStatus"], .string("notStarted"))
        XCTAssertEqual(hooks, 0)
        XCTAssertEqual(dispatches, 0)
        XCTAssertNil(try? store.readSnapshot(id: id, context: self.context()))
    }

    func testDeadlineCrossingDuringForegroundPreparationStopsBeforeRefreshAndDispatch() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "56565656-5656-4565-8565-565656565656"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        let ticks = LockedUInt64(0)
        let context = self.context(timeoutMilliseconds: 1, monotonicNow: { ticks.value })
        var observations = 0
        var preflights = 0
        var dispatches = 0
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { _, _, _ in
                observations += 1
                return AXTreeObservation(
                    snapshot: snapshot,
                    liveElements: [2: LiveAXElement()]
                )
            },
            validateTarget: { _, _ in snapshot.target },
            sameLiveElement: { _, _ in true },
            prepareForeground: { _, _, _ in ticks.value = context.deadline },
            prepareElement: { _, _ in }
        )
        let failure = await captureTransactionFailure {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: context,
                stateChanging: true,
                preflight: { _, _, _ in preflights += 1; return "ok" },
                dispatch: { _, _, _ in dispatches += 1 }
            )
        }
        XCTAssertEqual(failure?.code, "TIMEOUT")
        XCTAssertEqual(failure?.details?["mutationStatus"], .string("notStarted"))
        XCTAssertEqual(observations, 1)
        XCTAssertEqual(preflights, 1)
        XCTAssertEqual(dispatches, 0)
        XCTAssertNil(try? store.readSnapshot(id: id, context: self.context()))
    }


    func testReplacementAfterFirstPreflightIsStaleBeforeInvalidation() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        var validations = 0
        var dispatches = 0
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { _, _, _ in AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()]) },
            validateTarget: { _, _ in
                validations += 1
                return validations >= 3 ? changedLaunchTarget(snapshot.target) : snapshot.target
            },
            sameLiveElement: { _, _ in true },
            prepareElement: { _, _ in }
        )
        await assertTransactionFailure("STALE_SNAPSHOT") {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: self.context(),
                stateChanging: true,
                preflight: { _, _, _ in "ok" },
                dispatch: { _, _, _ in dispatches += 1 }
            )
        }
        XCTAssertEqual(dispatches, 0)
        XCTAssertNoThrow(try store.readSnapshot(id: id, context: context()))
    }

    func testPostHookProcessWindowOrTreeChangeIsStaleAfterInvalidation() async throws {
        let ids = [
            "process": "ffffffff-ffff-4fff-8fff-ffffffffffff",
            "window": "12121212-1212-4121-8121-121212121212",
            "tree": "13131313-1313-4131-8131-131313131313"
        ]
        for mode in ["process", "window", "tree"] {
            let root = transactionRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let before = try transactionFixture("save-cancel")
            let after = try transactionFixture("changed-label")
            let id = try XCTUnwrap(ids[mode])
            let store = try populatedStore(root: root, snapshot: before, id: id)
            var validations = 0
            var observations = 0
            var dispatches = 0
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root),
                store: store,
                observe: { _, _, _ in
                    observations += 1
                    let value = mode == "tree" && observations == 2 ? after : before
                    return AXTreeObservation(snapshot: value, liveElements: [2: LiveAXElement()])
                },
                validateTarget: { _, _ in
                    validations += 1
                    guard validations >= 4 else { return before.target }
                    if mode == "process" { return changedLaunchTarget(before.target) }
                    if mode == "window" { return changedWindowTarget(before.target) }
                    return before.target
                },
                sameLiveElement: { _, _ in true },
                prepareElement: { _, _ in }
            )
            await assertTransactionFailure("STALE_SNAPSHOT", message: mode) {
                try await service.withValidatedSnapshotAction(
                    snapshotID: id,
                    ref: 2,
                    context: self.context(),
                    stateChanging: true,
                    preflight: { _, _, _ in "ok" },
                    dispatch: { _, _, _ in dispatches += 1 }
                )
            }
            XCTAssertEqual(dispatches, 0, mode)
            XCTAssertNil(try? store.readSnapshot(id: id, context: context()), mode)
        }
    }

    func testElementReplacementIsStaleBeforeSecondPreflight() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "23232323-2323-4232-8232-232323232323"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        var preflights = 0
        var dispatches = 0
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { _, _, _ in AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()]) },
            validateTarget: { _, _ in snapshot.target },
            sameLiveElement: { _, _ in false },
            prepareElement: { _, _ in }
        )
        await assertTransactionFailure("STALE_SNAPSHOT") {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: self.context(),
                stateChanging: true,
                preflight: { _, _, _ in preflights += 1; return "ok" },
                dispatch: { _, _, _ in dispatches += 1 }
            )
        }
        XCTAssertEqual(preflights, 1)
        XCTAssertEqual(dispatches, 0)
        XCTAssertNil(try? store.readSnapshot(id: id, context: context()))
    }

    func testNonStateChangingActionRunsFreshPreflightWithoutInvalidating() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "34343434-3434-4343-8343-343434343434"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        var preflights = 0
        let service = transactionService(root: root, store: store, snapshots: [snapshot, snapshot])
        try await service.withValidatedSnapshotAction(
            snapshotID: id,
            ref: 2,
            context: context(),
            stateChanging: false,
            preflight: { _, _, _ in preflights += 1; return preflights },
            dispatch: { prepared, _, _ in XCTAssertEqual(prepared, 2) }
        )
        XCTAssertEqual(preflights, 2)
        XCTAssertNoThrow(try store.readSnapshot(id: id, context: context()))
    }

    func testDispatchFailureIsPotentiallyAppliedAndLeavesInvalidated() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let id = "45454545-4545-4454-8454-454545454545"
        let store = try populatedStore(root: root, snapshot: snapshot, id: id)
        let service = transactionService(root: root, store: store, snapshots: [snapshot, snapshot])
        let failure = await captureTransactionFailure {
            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: self.context(),
                stateChanging: true,
                preflight: { _, _, _ in "fresh" },
                dispatch: { _, _, _ in
                    throw NativeFailure("NATIVE_FAILURE", "dispatch failed", details: ["safe": .string("kept")])
                }
            )
        }
        XCTAssertEqual(failure?.details, [
            "safe": .string("kept"),
            "mutationStatus": .string("potentiallyApplied")
        ])
        XCTAssertNil(try? store.readSnapshot(id: id, context: context()))
    }

    func testDurablePublicationRemainsSuccessWhenCancellationArrivesAtCommit() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let context = self.context()
        var directorySyncs = 0
        let io = StateStoreIO(sync: { descriptor in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                return SystemCallResult(value: -1, error: errno)
            }
            let value = fsync(descriptor)
            if value == 0 && (info.st_mode & S_IFMT) == S_IFDIR {
                directorySyncs += 1
                if directorySyncs == 2 { context.cancel() }
            }
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        })
        let store = StateStore(rootURL: root, io: io)
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            resolve: { _, _ in snapshot.target },
            observe: { _, _, _ in AXTreeObservation(snapshot: snapshot, liveElements: [:]) },
            validateTarget: { _, _ in snapshot.target },
            prepareElement: { _, _ in }
        )
        let result = try await service.snapshot(
            selector: .pid(42, windowId: 7),
            options: snapshot.treeOptions,
            context: context
        )
        XCTAssertTrue(context.isCancelled)
        XCTAssertNoThrow(try store.readSnapshot(id: result.record.id, context: self.context()))
    }

    private func context(
        timeoutMilliseconds: Int = 1_000,
        monotonicNow: @escaping () -> UInt64 = { 0 }
    ) -> CommandContext {
        CommandContext(
            timeoutMilliseconds: timeoutMilliseconds,
            clock: NativeClock(
                monotonicNow: monotonicNow,
                wallNow: { self.wall },
                sleepNanoseconds: { _ in }
            )
        )
    }

    private func populatedStore(
        root: URL,
        snapshot: AXTreeSnapshot,
        id: String
    ) throws -> StateStore {
        let store = StateStore(rootURL: root)
        try store.writeSnapshot(
            SnapshotRecord(
                id: id,
                createdAt: "2026-09-08T10:00:00Z",
                expiresAt: "2026-09-08T10:10:00Z",
                target: snapshot.target,
                treeOptions: snapshot.treeOptions,
                evidence: snapshot.evidence
            ),
            context: context()
        )
        return store
    }

    private func transactionService(
        root: URL,
        store: StateStore,
        snapshots: [AXTreeSnapshot],
        foreground: @escaping () -> Void = {}
    ) -> SnapshotService {
        var observations = 0
        let target = snapshots[0].target
        return SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { _, _, _ in
                let index = min(observations, snapshots.count - 1)
                observations += 1
                return AXTreeObservation(snapshot: snapshots[index], liveElements: [2: LiveAXElement()])
            },
            validateTarget: { _, _ in target },
            sameLiveElement: { _, _ in true },
            prepareForeground: { _, _, _ in foreground() },
            prepareElement: { _, _ in }
        )
    }
}

private final class LockedUInt64 {
    private let lock = NSLock()
    private var storage: UInt64

    init(_ value: UInt64) { storage = value }

    var value: UInt64 {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private func transactionRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func transactionFixture(_ name: String) throws -> AXTreeSnapshot {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let fixtures = try JSONDecoder().decode(
        [String: AXTreeSnapshot].self,
        from: Data(contentsOf: root.appendingPathComponent("fixtures/native/trees.json"))
    )
    return try XCTUnwrap(fixtures[name])
}

private func changedLaunchTarget(_ target: ResolvedTarget) -> ResolvedTarget {
    ResolvedTarget(
        identity: TargetIdentity(
            pid: target.identity.pid,
            launchDate: "2026-09-08T10:00:00.001Z",
            bundleId: target.identity.bundleId,
            windowId: target.identity.windowId
        ),
        title: target.title,
        bounds: target.bounds
    )
}

private func changedWindowTarget(_ target: ResolvedTarget) -> ResolvedTarget {
    ResolvedTarget(
        identity: target.identity,
        title: target.title + " replaced",
        bounds: target.bounds
    )
}

private func captureTransactionFailure<T>(
    _ work: () async throws -> T
) async -> NativeFailure? {
    do {
        _ = try await work()
        return nil
    } catch let failure as NativeFailure {
        return failure
    } catch {
        return NativeFailure("NATIVE_FAILURE", "unexpected test failure")
    }
}

private func assertTransactionFailure<T>(
    _ code: String,
    message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ work: () async throws -> T
) async {
    let failure = await captureTransactionFailure(work)
    XCTAssertEqual(failure?.code, code, message, file: file, line: line)
}
```


The tests use captured observe/preflight counters and injected continuity closures; production has no marker. The fresh-pair test creates inert public AX application refs but performs no AX read, write, permission prompt, or desktop operation.

- [ ] **Step 2: Verify L5 RED**

```sh
swift test --package-path native --filter SnapshotTransactionTests
```

Expected RED: compile errors identify missing `sameLiveElement`, `prepareForeground`, `prepareElement`, and 3-argument dispatch, or assertions show only one observation/preflight and no post-invalidation checkpoint. No helper is undefined.

- [ ] **Step 3: Replace the complete `SnapshotService` class with the final transaction**

Keep `SnapshotResult`, `timestamp`, JSON rendering, and wire shape unchanged. Replace only `public final class SnapshotService` with:

```swift
public final class SnapshotService {
    public typealias Resolve = (TargetSelector, CommandContext) async throws -> ResolvedTarget
    public typealias Observe = (ResolvedTarget, TreeOptions, CommandContext) async throws -> AXTreeObservation
    public typealias ValidateTarget = (TargetIdentity, CommandContext) async throws -> ResolvedTarget
    public typealias PrepareForeground = (ResolvedTarget, LiveAXElement, CommandContext) async throws -> Void
    public typealias PrepareElement = (LiveAXElement, CommandContext) async throws -> Void
    public typealias Preflight<Prepared> = (LiveAXElement, ResolvedTarget, CommandContext) async throws -> Prepared
    public typealias Dispatch<Prepared, Result> = (Prepared, LiveAXElement, CommandContext) async throws -> Result

    private let lock: DesktopLock
    private let store: StateStore
    private let resolve: Resolve
    private let observe: Observe
    private let validateTarget: ValidateTarget
    private let sameLiveElement: AXElementIdentity
    private let prepareForeground: PrepareForeground
    private let prepareElement: PrepareElement

    public init(
        lock: DesktopLock = DesktopLock(),
        store: StateStore = StateStore(),
        resolve: @escaping Resolve = { selector, context in
            try await TargetResolver().resolve(selector, context: context)
        },
        observe: @escaping Observe = { target, options, context in
            try AXTree.capture(target: target, options: options, context: context)
        },
        validateTarget: @escaping ValidateTarget = { identity, context in
            try await TargetResolver().validate(identity, context: context)
        },
        sameLiveElement: AXElementIdentity? = nil,
        prepareForeground: @escaping PrepareForeground = { _, _, _ in },
        prepareElement: PrepareElement? = nil
    ) {
        self.lock = lock
        self.store = store
        self.resolve = resolve
        self.observe = observe
        self.validateTarget = validateTarget
        self.sameLiveElement = sameLiveElement ?? liveAXElementsAreIdentical
        self.prepareForeground = prepareForeground
        self.prepareElement = prepareElement ?? { element, context in
            try prepareLiveAXElementMessaging(element, context: context)
        }
    }

    public func snapshot(
        selector: TargetSelector,
        options: TreeOptions,
        context: CommandContext
    ) async throws -> SnapshotResult {
        try context.check()
        return try await lock.withLock(context: context) {
            try context.check()
            try store.sweep(context: context)
            let target = try await resolve(selector, context)
            try context.check()
            let observation = try await observe(target, options, context)
            try context.check()
            let refreshed = try await validateTarget(
                observation.snapshot.target.identity,
                context
            )
            try context.check()
            guard refreshed == target,
                  observation.snapshot.target == refreshed,
                  observation.snapshot.treeOptions == options else {
                throw NativeFailure(
                    "STALE_SNAPSHOT",
                    "Target or traversal evidence changed during snapshot"
                )
            }
            let created = context.wallNow
            let record = SnapshotRecord(
                id: UUID().uuidString.lowercased(),
                createdAt: timestamp(created),
                expiresAt: timestamp(created.addingTimeInterval(snapshotLifetime)),
                target: refreshed,
                treeOptions: options,
                evidence: observation.snapshot.evidence
            )
            try store.writeSnapshot(record, context: context)
            // Durable publication committed; do not check or roll back after return.
            return SnapshotResult(record: record, snapshot: observation.snapshot)
        }
    }

    func withValidatedSnapshotAction<Prepared, Result>(
        snapshotID: String,
        ref: Int,
        context: CommandContext,
        stateChanging: Bool,
        preflight: @escaping Preflight<Prepared>,
        dispatch: @escaping Dispatch<Prepared, Result>
    ) async throws -> Result {
        var dispatchEntered = false
        do {
            try context.check()
            return try await lock.withLock(context: context) {
                try context.check()
                try store.sweep(context: context)
                let record = try store.readSnapshot(id: snapshotID, context: context)
                let recorded = AXTreeSnapshot(
                    target: record.target,
                    treeOptions: record.treeOptions,
                    evidence: record.evidence
                )

                let target = try await validateTarget(record.target.identity, context)
                try context.check()
                guard target == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                let live = try await observe(target, record.treeOptions, context)
                try context.check()
                _ = try Self.validateEvidence(recorded, live: live.snapshot, ref: ref)
                guard let element = live.liveElements[ref] else {
                    throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
                }
                let identityAfterObservation = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityAfterObservation == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }

                try await prepareElement(element, context)
                _ = try await preflight(element, target, context)
                try context.check()
                let identityAfterPreflight = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityAfterPreflight == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }

                if stateChanging {
                    try store.invalidateRecords(
                        for: record.target.identity,
                        context: context
                    )
                }
                try context.check()

                try await prepareForeground(target, element, context)
                try context.check()

                let freshTarget = try await validateTarget(record.target.identity, context)
                try context.check()
                guard freshTarget == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                let freshLive = try await observe(
                    freshTarget,
                    record.treeOptions,
                    context
                )
                try context.check()
                _ = try Self.validateEvidence(
                    recorded,
                    live: freshLive.snapshot,
                    ref: ref
                )
                guard let freshElement = freshLive.liveElements[ref] else {
                    throw NativeFailure("STALE_SNAPSHOT", "Live accessibility reference is unavailable")
                }
                let identityAfterFreshObservation = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityAfterFreshObservation == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                guard sameLiveElement(element, freshElement) else {
                    throw NativeFailure("STALE_SNAPSHOT", "Live accessibility element was replaced")
                }

                try await prepareElement(freshElement, context)
                let freshlyPrepared = try await preflight(
                    freshElement,
                    freshTarget,
                    context
                )
                try context.check()
                let identityBeforeDispatch = try await validateTarget(
                    record.target.identity,
                    context
                )
                try context.check()
                guard identityBeforeDispatch == record.target else {
                    throw NativeFailure("STALE_SNAPSHOT", "Window evidence changed")
                }
                try await prepareElement(freshElement, context)
                try context.check()

                dispatchEntered = true
                let result = try await dispatch(freshlyPrepared, freshElement, context)
                // Successful dispatch is the action commit; no post-commit check.
                return result
            }
        } catch {
            throw Self.attachingMutationStatus(
                to: error,
                status: dispatchEntered ? .potentiallyApplied : .notStarted
            )
        }
    }

    static func validateEvidence(
        _ recorded: AXTreeSnapshot,
        live: AXTreeSnapshot,
        ref: Int
    ) throws -> AXRefEvidence {
        try AXEvidencePolicy.validate(recorded.evidence, options: recorded.treeOptions)
        try AXEvidencePolicy.validate(live.evidence, options: live.treeOptions)
        guard recorded.target == live.target,
              recorded.treeOptions == live.treeOptions,
              recorded.evidence.nodes == live.evidence.nodes,
              recorded.evidence.truncation == live.evidence.truncation,
              recorded.evidence.refs == live.evidence.refs,
              let recordedRef = recorded.evidence.refs.first(where: { $0.ref == ref }),
              let liveRef = live.evidence.refs.first(where: { $0.ref == ref }),
              recordedRef == liveRef else {
            throw NativeFailure(
                "STALE_SNAPSHOT",
                "Snapshot evidence no longer matches the selected window"
            )
        }
        return liveRef
    }

    private static func attachingMutationStatus(
        to error: Error,
        status: MutationStatus
    ) -> NativeFailure {
        let failure = error as? NativeFailure
            ?? NativeFailure("NATIVE_FAILURE", "Native command failed")
        var details = failure.details ?? [:]
        details["mutationStatus"] = .string(status.rawValue)
        return NativeFailure(failure.code, failure.message, details: details)
    }
}
```

The initial prepared value is intentionally discarded. Each preflight is the same injected closure; only the second result and refreshed handle reach dispatch. The exact refreshed AX ref is timeout-prepared before second preflight and again immediately before dispatch.

- [ ] **Step 4: Finish existing `SnapshotTests` migration without weakening assertions**

Every action dispatch closure now has `(prepared, element, context)` arity. Replace L2's two-argument dispatch closure form with:

```swift
dispatch: { prepared, _, _ in
    _ = prepared
}
```

Because successful action paths now preflight twice, replace boolean preflight side effects in `testStateChangingAttemptInvalidatesBeforeActionButNonChangingAttemptDoesNot` with an invocation count:

```swift
var preflightCount = 0
```

and:

```swift
preflight: { _, _, _ in
    preflightCount += 1
    validDuringPreflight = (try? store.readSnapshot(
        id: id,
        context: snapshotCommandContext(wallNow: now)
    )) != nil
},
```

Then assert:

```swift
XCTAssertEqual(preflightCount, 2)
```

Preflight-failure and invalidation-failure tests still expect one preflight and zero dispatch. In `testDispatchFailureLeavesAllAppRecordsInvalidated`, capture the thrown `NativeFailure` and add:

```swift
XCTAssertEqual(failure.details?["mutationStatus"], .string("potentiallyApplied"))
```

Do not change `testNativeFailureDetailsRoundTripThroughDispatcher`; snapshot observation failures retain their injected details with no action wrapper.

- [ ] **Step 5: Verify L5 GREEN and preservation**

```sh
swift test --package-path native --filter SnapshotTransactionTests
swift test --package-path native --filter SnapshotTests
swift test --package-path native --filter ProtocolTests
swift test --package-path native --filter StateStoreTests
```

Expected GREEN: all commands exit 0. Snapshot refreshes after observation; committed publication survives immediate cancellation; deadline expiry during invalidation or foreground preparation yields zero dispatch and leaves invalidated state intact; each success path has two preflights; all changed identity/evidence/element paths have zero dispatch; non-state-changing records remain valid; mutation details preserve `safe` and use only the two C3 spellings.

- [ ] **Step 6: Perform scoped review**

```sh
git grep -n 'testMarker\|String(describing:.*AX\|DispatchQueue.main.sync\|withValidatedSnapshotAction' -- native/Sources
git grep -n 'notStarted\|potentiallyApplied' -- native/Sources/ComputerUseCore
git diff --check
```

Expected: no test marker or pointer description; one action transaction; exact mutation spellings only; no whitespace errors. Review each required zero-dispatch branch, confirm the second preflight data/handle pair, confirm no post-publication or post-successful-dispatch check, and confirm `NativeService` gained no action implementation.

- [ ] **Step 7: Stage exactly L5 and create its one commit**

```sh
git add native/Tests/ComputerUseCoreTests/SnapshotTransactionTests.swift \
  native/Sources/ComputerUseCore/SnapshotService.swift \
  native/Tests/ComputerUseCoreTests/SnapshotTests.swift
git diff --cached --check
git diff --cached --name-only
git commit -m "fix: refresh identity before snapshot action dispatch"
```

Expected staged names: exactly the three listed files.

---

### Task L6: Host cancellation/completion state machine and startup EOF framing

**Files:**
- Modify: `native/Sources/ComputerUseCore/HostSupport.swift`
- Modify: `native/Sources/ComputerUseHost/HostMain.swift`
- Modify: `native/Tests/ComputerUseCoreTests/HostLifecycleTests.swift` (full replacement)
- Modify: `tests/native-protocol.test.ts` (one current-source empty-EOF integration test)
- Do not modify: worker/context/lock/service/resolver/AX/state/action implementations, package scripts, or Node cleanup helpers

**Interfaces:**
- Consumes: L2 `HostSession.Work` returning `Task<Void, Never>`, the one `CommandContext`, async `NativeService.execute`, and retained detached-task ownership.
- Produces: final `ready → running → cancelling → finished` host behavior, `.emptyEndOfFile` framing, reply suppression, and main-thread shutdown scheduling after completion. L6 closes host state only.

- [ ] **Step 1: Replace `HostLifecycleTests.swift` with complete state-machine RED tests**

```swift
import Foundation
import XCTest
@testable import ComputerUseCore

private final class LockedHostEvents {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

final class HostLifecycleTests: XCTestCase {
    func testBoundedLineReaderAcceptsOnlyTerminatedInputWithinLimit() {
        var reader = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(reader.consume(Data("hello".utf8)), .awaitingInput)
        XCTAssertEqual(
            reader.consume(Data("\nignored".utf8)),
            .line(Data("hello".utf8))
        )
    }

    func testBoundedLineReaderRejectsOverflowWithoutBufferingIt() {
        var reader = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(reader.consume(Data("123456".utf8)), .invalid)
        XCTAssertLessThanOrEqual(reader.bufferedByteCount, 5)
    }

    func testEmptyEOFIsDistinctFromPartialUnterminatedEOF() {
        var empty = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(empty.consume(Data(), endOfFile: true), .emptyEndOfFile)

        var partial = BoundedLineReader(maximumBytes: 5)
        XCTAssertEqual(
            partial.consume(Data("hello".utf8), endOfFile: true),
            .invalid
        )

        var line = BoundedLineReader(maximumBytes: 16)
        XCTAssertEqual(
            line.consume(Data("hello\n".utf8), endOfFile: true),
            .line(Data("hello".utf8))
        )
    }

    func testNormalCompletionEmitsOneReplyThenShutsDown() throws {
        var finish: ((WireReply) -> Void)?
        var events: [String] = []
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, completion in
                finish = completion
                return Task.detached {}
            },
            onReply: { _ in events.append("reply") },
            onShutdown: { events.append("shutdown") }
        )
        session.start()
        XCTAssertEqual(events, [])
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "first"))
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "duplicate"))
        session.start()
        XCTAssertEqual(events, ["reply", "shutdown"])
    }

    func testParentEOFDuringWorkCancelsAndWaitsForCleanupWithoutReply() throws {
        var finish: ((WireReply) -> Void)?
        var replies = 0
        var events: [String] = []
        let context = CommandContext(timeoutMilliseconds: 1_000)
        context.onCancel { events.append("cancelled") }
        let session = HostSession(
            context: context,
            work: { _, completion in
                events.append("work-start")
                finish = completion
                return Task.detached {}
            },
            onReply: { _ in replies += 1; events.append("reply") },
            onShutdown: { events.append("shutdown") }
        )
        session.start()
        session.parentDidClose()
        session.parentDidClose() // duplicate EOF while cancelling is ignored
        XCTAssertTrue(context.isCancelled)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(events, ["work-start", "cancelled"])

        events.append("lock-released")
        try XCTUnwrap(finish)(.failure(code: "INTERRUPTED", message: "Interrupted"))
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(events, ["work-start", "cancelled", "lock-released", "shutdown"])
    }

    func testReadyParentEOFDoesNotStartWorkOrReply() {
        var workStarts = 0
        var replies = 0
        var shutdowns = 0
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, _ in
                workStarts += 1
                return Task.detached {}
            },
            onReply: { _ in replies += 1 },
            onShutdown: { shutdowns += 1 }
        )
        session.parentDidClose()
        session.start()
        XCTAssertEqual(workStarts, 0)
        XCTAssertEqual(replies, 0)
        XCTAssertEqual(shutdowns, 1)
    }

    func testCancellationBeforeReturnedTaskIsOwnedStillCompletesAndShutsDown() async {
        let workEntered = expectation(description: "work factory entered")
        let taskCancelled = expectation(description: "returned task cancelled")
        let operationEntered = expectation(description: "command operation entered")
        let shutdown = expectation(description: "shutdown after completion")
        let allowWorkReturn = DispatchSemaphore(value: 0)
        let allowOperationCompletion = DispatchSemaphore(value: 0)
        defer {
            allowWorkReturn.signal()
            allowOperationCompletion.signal()
        }
        let events = LockedHostEvents()
        var replies = 0
        let context = CommandContext(timeoutMilliseconds: 1_000)
        let session = HostSession(
            context: context,
            work: { context, completion in
                workEntered.fulfill()
                _ = allowWorkReturn.wait(timeout: .now() + 1)
                return Task.detached {
                    await withTaskCancellationHandler(operation: {
                        operationEntered.fulfill()
                        _ = allowOperationCompletion.wait(timeout: .now() + 1)
                        XCTAssertTrue(Task.isCancelled)
                        events.append("operation-finished")
                        completion(.failure(code: "INTERRUPTED", message: "Interrupted"))
                    }, onCancel: {
                        context.cancel()
                        taskCancelled.fulfill()
                    })
                }
            },
            onReply: { _ in replies += 1 },
            onShutdown: {
                events.append("shutdown")
                shutdown.fulfill()
            }
        )

        let starter = Task.detached { session.start() }
        await fulfillment(of: [workEntered], timeout: 1)
        session.parentDidClose()
        XCTAssertTrue(context.isCancelled)
        XCTAssertEqual(events.values, [])

        allowWorkReturn.signal()
        await fulfillment(of: [taskCancelled, operationEntered], timeout: 1)
        allowOperationCompletion.signal()
        await fulfillment(of: [shutdown], timeout: 1)
        await starter.value

        XCTAssertEqual(replies, 0)
        XCTAssertEqual(events.values, ["operation-finished", "shutdown"])
    }

    func testLateParentEOFAndDuplicateCompletionAreIgnored() throws {
        var finish: ((WireReply) -> Void)?
        var replies = 0
        var shutdowns = 0
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, completion in
                finish = completion
                return Task.detached {}
            },
            onReply: { _ in replies += 1 },
            onShutdown: { shutdowns += 1 }
        )
        session.start()
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "done"))
        session.parentDidClose()
        try XCTUnwrap(finish)(.failure(code: "UNSUPPORTED_ACTION", message: "late"))
        XCTAssertEqual(replies, 1)
        XCTAssertEqual(shutdowns, 1)
    }

    func testMainQueueSentinelRunsWhileSessionWorkerIsActive() async {
        let workerEntered = expectation(description: "worker entered")
        let sentinel = expectation(description: "main sentinel")
        let shutdown = expectation(description: "shutdown")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let session = HostSession(
            context: CommandContext(timeoutMilliseconds: 1_000),
            work: { _, completion in
                Task.detached {
                    workerEntered.fulfill()
                    _ = release.wait(timeout: .now() + 1)
                    completion(.failure(code: "UNSUPPORTED_ACTION", message: "done"))
                }
            },
            onReply: { _ in },
            onShutdown: { shutdown.fulfill() }
        )
        session.start()
        await fulfillment(of: [workerEntered], timeout: 1)
        DispatchQueue.main.async { sentinel.fulfill() }
        await fulfillment(of: [sentinel], timeout: 1)
        release.signal()
        await fulfillment(of: [shutdown], timeout: 1)
    }

    func testParentEOFObserverIgnoresDataAndReportsClosure() {
        let pipe = Pipe()
        let closed = expectation(description: "parent closure observed")
        let observer = ParentEOFObserver(fileHandle: pipe.fileHandleForReading) {
            closed.fulfill()
        }
        observer.start()
        pipe.fileHandleForWriting.write(Data("still-open".utf8))
        pipe.fileHandleForWriting.closeFile()
        wait(for: [closed], timeout: 1)
        observer.stop()
    }
}
```

Every blocked worker is detached, every wait is bounded, and each release has test-side `defer` cleanup.

- [ ] **Step 2: Add the current-source empty-EOF integration RED test**

In `tests/native-protocol.test.ts`, after the existing unterminated-input test, add:

```ts
it('shuts down silently on empty stdin EOF', async () => {
  const result = await invoke([], '', true);
  expect(result.code).toBe(0);
  expect(result.stdout).toBe('');
  expect(result.stderr).toBe('');
});
```

Do not modify `invoke`, `terminateAndWait`, the required `NUVIN_COMPUTER_USE_TEST_HOST` check, or the partial/overflow tests.

- [ ] **Step 3: Verify L6 RED without running the integration yet**

```sh
swift test --package-path native --filter HostLifecycleTests
```

Expected RED: compilation fails because `.emptyEndOfFile` is missing, then the parent-during-work test fails because L2 shuts down immediately instead of waiting for completion. Tests that already protect reply-once/ready EOF may pass; the suite remains RED for the intended missing state.

- [ ] **Step 4: Add the empty-EOF framing result**

Replace the enum with:

```swift
public enum BoundedLineReadResult: Equatable {
    case awaitingInput
    case line(Data)
    case invalid
    case emptyEndOfFile
}
```

In `BoundedLineReader.consume`, replace the EOF branch with:

```swift
buffer.append(chunk)
if endOfFile {
    finished = true
    return buffer.isEmpty ? .emptyEndOfFile : .invalid
}
return .awaitingInput
```

The newline and overflow branches remain unchanged.

- [ ] **Step 5: Replace `HostSession` with the complete four-state machine**

```swift
public final class HostSession {
    public typealias Work = (
        _ context: CommandContext,
        _ completion: @escaping (WireReply) -> Void
    ) -> Task<Void, Never>

    private enum State {
        case ready
        case running
        case cancelling
        case finished
    }

    private let lock = NSLock()
    private let context: CommandContext
    private let work: Work
    private let onReply: (WireReply) -> Void
    private let onShutdown: () -> Void
    private var state = State.ready
    private var task: Task<Void, Never>?

    public init(
        context: CommandContext,
        work: @escaping Work,
        onReply: @escaping (WireReply) -> Void,
        onShutdown: @escaping () -> Void
    ) {
        self.context = context
        self.work = work
        self.onReply = onReply
        self.onShutdown = onShutdown
    }

    public func start() {
        lock.lock()
        guard state == .ready else {
            lock.unlock()
            return
        }
        state = .running
        lock.unlock()

        let started = work(context) { [weak self] reply in
            self?.workDidFinish(reply)
        }

        lock.lock()
        switch state {
        case .running:
            task = started
            lock.unlock()
        case .cancelling, .finished:
            lock.unlock()
            started.cancel()
        case .ready:
            lock.unlock()
        }
    }

    public func parentDidClose() {
        lock.lock()
        switch state {
        case .ready:
            state = .finished
            lock.unlock()
            context.cancel()
            onShutdown()
        case .running:
            state = .cancelling
            let activeTask = task
            lock.unlock()
            context.cancel()
            activeTask?.cancel()
        case .cancelling, .finished:
            lock.unlock()
        }
    }

    private func workDidFinish(_ reply: WireReply) {
        lock.lock()
        switch state {
        case .running:
            state = .finished
            task = nil
            lock.unlock()
            onReply(reply)
            onShutdown()
        case .cancelling:
            state = .finished
            task = nil
            lock.unlock()
            onShutdown()
        case .ready, .finished:
            lock.unlock()
        }
    }
}
```

Normal completion replies once then shuts down. Cancelling completion suppresses reply and is the only path from `cancelling` to shutdown. All callbacks execute outside the lock.

- [ ] **Step 6: Replace `HostMain` with exact startup classification and detached completion**

Replace the complete `ComputerUseHost` declaration with:

```swift
@main
struct ComputerUseHost {
    private enum StartupRead {
        case emptyEndOfFile
        case invalid
        case line(Data)
    }

    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--protocol-version"]) {
            print(protocolVersion)
            return
        }
        guard CommandLine.arguments.count == 1 else {
            write(.failure(code: "PROTOCOL_ERROR", message: "Invalid host invocation"))
            return
        }
        switch readRequestLine() {
        case .emptyEndOfFile:
            return
        case .invalid:
            write(.failure(code: "PROTOCOL_ERROR", message: "Invalid request"))
            return
        case let .line(data):
            guard let request = WireRequest.decode(data: data) else {
                write(.failure(code: "PROTOCOL_ERROR", message: "Invalid request"))
                return
            }
            run(request)
        }
    }

    private static func run(_ request: WireRequest) {
        guard let timeout = request.timeoutMilliseconds else {
            write(.failure(
                command: request.command,
                code: "PROTOCOL_ERROR",
                message: "Invalid command options"
            ))
            return
        }
        _ = NSApplication.shared
        let context = CommandContext(timeoutMilliseconds: timeout)
        let session = HostSession(
            context: context,
            work: { context, completion in
                Task.detached {
                    await withTaskCancellationHandler(operation: {
                        let reply = await NativeService().execute(
                            request,
                            context: context
                        )
                        completion(reply)
                    }, onCancel: {
                        context.cancel()
                    })
                }
            },
            onReply: write,
            onShutdown: {
                DispatchQueue.main.async {
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
        )
        let parentObserver = ParentEOFObserver(fileHandle: .standardInput) {
            session.parentDidClose()
        }
        parentObserver.start()
        session.start()
        CFRunLoopRun()
        parentObserver.stop()
    }

    private static func readRequestLine() -> StartupRead {
        var reader = BoundedLineReader()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    FileHandle.standardInput.fileDescriptor,
                    $0.baseAddress,
                    $0.count
                )
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .invalid
            }
            let chunk = Data(buffer.prefix(count))
            switch reader.consume(chunk, endOfFile: count == 0) {
            case .awaitingInput:
                continue
            case let .line(line):
                return .line(line)
            case .emptyEndOfFile:
                return .emptyEndOfFile
            case .invalid:
                return .invalid
            }
        }
    }

    private static func write(_ reply: WireReply) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(reply),
              let line = String(data: data, encoding: .utf8) else {
            FileHandle.standardError.write(
                Data("Native host failed to encode a response\n".utf8)
            )
            return
        }
        print(line)
    }
}
```

Keep the existing imports. The worker is explicitly `Task.detached`, its cancellation handler writes the one context token, it always invokes completion even if already cancelled, and shutdown is always enqueued on main after the session accepts completion/cleanup.

- [ ] **Step 7: Verify L6 GREEN including current-source framing**

```sh
swift test --package-path native --filter HostLifecycleTests
npm run test:native-protocol
```

Expected GREEN: `HostLifecycleTests` passes; native protocol tests build the current host and pass protocol version, invalid request matrix, partial unterminated one-reply case, overflow one-reply case, and empty-EOF silent exit. No executable-target test access route is added.

- [ ] **Step 8: Perform scoped host review**

```sh
git grep -n 'Task {' -- native/Sources/ComputerUseHost native/Sources/ComputerUseCore/HostSupport.swift
git grep -n 'guard !.*isCancelled.*return\|CFRunLoopStop' -- native/Sources/ComputerUseHost/HostMain.swift
git diff --check
```

Expected: no `Task { }`, no cancellation early return, one `CFRunLoopStop` inside `DispatchQueue.main.async`, and no whitespace errors. Review all state/event pairs: duplicate start ignored; ready EOF no work/reply; running EOF cancellation and no early shutdown; cancelling completion no reply then shutdown; running completion one reply then shutdown; duplicate/late completion ignored.

- [ ] **Step 9: Stage exactly L6 and create its one commit**

```sh
git add native/Sources/ComputerUseCore/HostSupport.swift \
  native/Sources/ComputerUseHost/HostMain.swift \
  native/Tests/ComputerUseCoreTests/HostLifecycleTests.swift \
  tests/native-protocol.test.ts
git diff --cached --check
git diff --cached --name-only
git commit -m "fix: wait for native cleanup before host shutdown"
```

Expected staged names: exactly the four listed files.

---

## Integrated verification and review gate

After all six task commits and local reviews, run exactly:

```sh
swift test --package-path native
npm run typecheck
npm test
npm run test:native-protocol
npm run test:build-hygiene
npm run build
npm test
```

Expected: every command exits 0; `npm test` remains mock-only; `npm run test:native-protocol` rebuilds and uses current native source; no live desktop operation or permission prompt occurs.

Then verify source and artifact boundaries:

```sh
test ! -e dist/tools
test ! -e dist/ports.js
test -f src/tools/ComputerUseTool.ts
test -x dist/native/computer-use-host
git diff --check
git status --short --branch
```

Expected: all `test` commands exit 0, diff check is clean, and status contains only the pre-existing untracked planning/review artifacts plus `.superpowers/sdd/foundation-lifecycle-identity-progress.md` and any explicitly documented task-review evidence.

Request one integrated independent review of the A/C recovery plus L1–L6 range. The reviewer must explicitly confirm R2, R3, and R4 closure and the following requirement map:

| Approved requirement | Implemented/proved by |
|---|---|
| One context owns the absolute monotonic deadline and wall time for timestamps/expiry; overflow, interruption precedence, clamped sleep | L1 context tests plus L4 context-wall state tests |
| One detached transaction off main, cancellable lock wait, no nested lock, BUSY only after contention | L2 lock/worker tests and ownership review |
| MainActor process metadata only; selected PID window reads; missing date listable; same-second replacement identity | L3 resolver/provider tests |
| C4 `launchDate` and 1–9 digit parser retained; documented producer precision | L3 millisecond formatter test plus unchanged TS/state parsers |
| Classified AX failures and exact-ref positive remaining timeout | L3 provider classification plus L4 live-reader mapping and timeout/checkpoint tests |
| Checks between AX/state groups, EINTR retries, records, write/publication boundaries; main queue serviceable | L4 deterministic blocked-work tests and A1/A4 suites |
| Snapshot refresh after observation and publication commit after rename+dirsync | L5 snapshot tests |
| Pure preflight before invalidation; deadline after invalidation; foreground hook; fresh identity/evidence/element; second preflight pairing | L5 phase/zero-dispatch tests |
| `notStarted` before dispatch, `potentiallyApplied` once entered, existing details retained | L5 mutation tests plus C3 preservation tests |
| Ready/running/cancelling/finished; cancellation before returned-task ownership still completes; reply suppression; cleanup before main shutdown | L6 lifecycle tests |
| Empty EOF silent, partial EOF one protocol error, one request then exit | L6 unit tests and current-source native protocol integration |
| A1/A2/A4/C1/C3/C4 retained; no public feature expansion/live tests | Per-task preservation commands and integrated gate |

Do not declare foundation readiness until the integrated reviewer resolves every implementation-related Important/Critical finding. Even after approval, apps/windows, actions, capture, input, cursor, packaging, and live acceptance remain later-stage work.


