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
                if directorySyncs == 1 { context.cancel() }
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
