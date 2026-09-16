import Darwin
import XCTest
@testable import ComputerUseCore

final class StateStoreTests: XCTestCase {
    func testSnapshotRoundTripUsesPrivateModesAndAtomicName() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root)
        let record = snapshotRecord()

        try store.writeSnapshot(record)
        XCTAssertEqual(try store.readSnapshot(id: record.id), record)
        XCTAssertEqual(fileMode(root), 0o700)
        XCTAssertEqual(fileMode(root.appendingPathComponent("snapshots")), 0o700)
        XCTAssertEqual(fileMode(root.appendingPathComponent("snapshots/\(record.id).json")), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("snapshots").path), ["\(record.id).json"])
    }

    func testExpiredAndInvalidatedRecordsAreRejected() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root, now: { Date(timeIntervalSince1970: 1_000) })
        try store.writeSnapshot(snapshotRecord(createdAt: "1970-01-01T00:00:00Z", expiresAt: "1970-01-01T00:10:00Z"))
        XCTAssertThrowsError(try store.readSnapshot(id: fixedID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }

        let current = snapshotRecord(id: secondID, createdAt: "1970-01-01T00:10:00Z", expiresAt: "1970-01-01T00:20:00Z", invalidated: true)
        try store.writeSnapshot(current)
        XCTAssertThrowsError(try store.readSnapshot(id: secondID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testMalformedUnsupportedAndMismatchedRecordsAreRejected() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root, now: { Date(timeIntervalSince1970: 0) })
        try store.writeSnapshot(snapshotRecord())
        let path = root.appendingPathComponent("snapshots/\(fixedID).json")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        chmod(path.path, 0o600)
        XCTAssertThrowsError(try store.readSnapshot(id: fixedID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }

        object["version"] = 1
        object["id"] = secondID
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        chmod(path.path, 0o600)
        XCTAssertThrowsError(try store.readSnapshot(id: fixedID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testOnlyCanonicalUUIDsCanConstructRecordPaths() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root)
        for id in ["../outside", "not-a-uuid"] {
            XCTAssertThrowsError(try store.readSnapshot(id: id), id) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
        try store.writeSnapshot(snapshotRecord())
        XCTAssertEqual(try store.readSnapshot(id: fixedID.uppercased()).id, fixedID)
    }

    func testReadDoesNotFollowRecordSymlink() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root)
        try store.writeSnapshot(snapshotRecord())
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("private".utf8).write(to: outside)
        let path = root.appendingPathComponent("snapshots/\(fixedID).json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)

        XCTAssertThrowsError(try store.readSnapshot(id: fixedID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
        XCTAssertEqual(try String(contentsOf: outside), "private")
    }

    func testSweepRemovesExpiredOwnedRecordsAndPreservesUnrelatedFiles() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root, now: { Date(timeIntervalSince1970: 1_000) })
        try store.writeSnapshot(snapshotRecord(createdAt: "1970-01-01T00:00:00Z", expiresAt: "1970-01-01T00:10:00Z"))
        let snapshots = root.appendingPathComponent("snapshots")
        let unrelated = snapshots.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        try store.sweep()
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshots.appendingPathComponent("\(fixedID).json").path))
        XCTAssertEqual(try String(contentsOf: unrelated), "keep")
    }

    func testInvalidationRewritesAllRecordsForAppBeforeReturning() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root, now: { Date(timeIntervalSince1970: 0) })
        let first = snapshotRecord()
        let sameApp = snapshotRecord(id: secondID, target: resolvedTarget(pid: 99, bundleID: "com.example.Editor"))
        let other = snapshotRecord(id: thirdID, target: resolvedTarget(pid: 100, bundleID: "com.example.Other"))
        try [first, sameApp, other].forEach(store.writeSnapshot)

        try store.invalidateRecords(for: first.target.identity)

        XCTAssertThrowsError(try store.readSnapshot(id: first.id))
        XCTAssertThrowsError(try store.readSnapshot(id: sameApp.id))
        XCTAssertFalse(try store.readSnapshot(id: other.id).invalidated)
    }

    func testInvalidationFailsClosedForUnreadableRecognizedRecord() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root)
        try store.writeSnapshot(snapshotRecord())
        try store.writeSnapshot(snapshotRecord(id: secondID))
        let unreadable = root.appendingPathComponent("snapshots/\(secondID).json")
        chmod(unreadable.path, 0o000)

        XCTAssertThrowsError(try store.invalidateRecords(for: resolvedTarget().identity)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testRecordOpenAndReadRetryEINTR() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try StateStore(rootURL: root).writeSnapshot(snapshotRecord())
        var openCalls = 0
        var readCalls = 0
        let io = StateStoreIO(
            openRecord: { directory, name in
                openCalls += 1
                if openCalls == 1 { return SystemCallResult(value: -1, error: EINTR) }
                let result = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
                return SystemCallResult(value: result, error: result < 0 ? errno : 0)
            },
            read: { descriptor, buffer, count in
                readCalls += 1
                if readCalls == 1 { return SystemCallResult(value: -1, error: EINTR) }
                let result = Darwin.read(descriptor, buffer, count)
                return SystemCallResult(value: result, error: result < 0 ? errno : 0)
            }
        )

        XCTAssertNoThrow(try StateStore(rootURL: root, now: Date.init, io: io).readSnapshot(id: fixedID))
        XCTAssertGreaterThanOrEqual(openCalls, 2)
        XCTAssertGreaterThanOrEqual(readCalls, 2)
    }

    func testTransientReadFailureCannotBeSkippedDuringInvalidation() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = StateStore(rootURL: root)
        try writer.writeSnapshot(snapshotRecord())
        let io = StateStoreIO(read: { _, _, _ in SystemCallResult(value: -1, error: EIO) })
        let failingStore = StateStore(rootURL: root, now: Date.init, io: io)

        XCTAssertThrowsError(try failingStore.invalidateRecords(for: resolvedTarget().identity)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
        XCTAssertNoThrow(try writer.readSnapshot(id: fixedID))
    }

    func testRootSymlinkAndPathSwapNeverChmodUnrelatedObject() async throws {
        let parent = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let symlink = parent.appendingPathComponent("linked-root", isDirectory: true)
        XCTAssertEqual(mkdir(outside.path, 0o755), 0)
        XCTAssertEqual(fileMode(outside), 0o755)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        await XCTAssertThrowsErrorAsync({
            try await DesktopLock(rootURL: symlink).withLock(
                context: CommandContext(timeoutMilliseconds: 100)
            ) {}
        })
        XCTAssertEqual(fileMode(outside), 0o755)

        let root = parent.appendingPathComponent("root", isDirectory: true)
        let openedObject = parent.appendingPathComponent("opened", isDirectory: true)
        XCTAssertEqual(mkdir(root.path, 0o755), 0)
        let descriptor = try PrivateStateDirectory.openRoot(root, afterOpen: { _ in
            XCTAssertEqual(rename(root.path, openedObject.path), 0)
            XCTAssertEqual(mkdir(root.path, 0o755), 0)
        })
        close(descriptor)
        XCTAssertEqual(fileMode(openedObject), 0o700)
        XCTAssertEqual(fileMode(root), 0o755)
    }

    func testWriteRejectsEveryMalformedSemanticRecordClass() throws {
        let target = resolvedTarget()
        let rootNode = stateNode(
            path: [],
            role: "AXWindow",
            title: target.title,
            bounds: target.bounds,
            childCount: 0
        )
        let validEvidence = AXTreeEvidence(
            nodes: [rootNode],
            truncation: [],
            refs: [AXRefEvidence(ref: 1, path: [], node: rootNode)]
        )
        let childZero = stateNode(path: [0], role: "AXButton", childCount: 0)
        let childOne = stateNode(path: [1], role: "AXButton", childCount: 0)
        let parent = stateNode(path: [], role: "AXWindow", childCount: 2)
        let wrongRefNode = stateNode(path: [], role: "AXButton", childCount: 0)
        let twoNodeParent = stateNode(path: [], role: "AXWindow", childCount: 1)
        let twoNodeEvidence = AXTreeEvidence(
            nodes: [twoNodeParent, childZero],
            truncation: [],
            refs: [
                AXRefEvidence(ref: 1, path: [], node: twoNodeParent),
                AXRefEvidence(ref: 2, path: [0], node: childZero)
            ]
        )
        let truncatedOptions = TreeOptions(maxDepth: 8, maxElements: 2, hintMode: .full)
        let truncated = AXTree.snapshot(
            target: target,
            options: truncatedOptions,
            root: stateTruncationInput()
        )
        let firstBoundary = try XCTUnwrap(truncated.evidence.truncation.first)

        let cases: [(String, SnapshotRecord)] = [
            ("target IDs", snapshotRecord(target: resolvedTarget(pid: 0), evidence: validEvidence)),
            ("tree options", snapshotRecord(
                treeOptions: TreeOptions(maxDepth: 0, maxElements: 500, hintMode: .full),
                evidence: validEvidence
            )),
            ("negative counts", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [stateNode(path: [], role: "AXWindow", childCount: -1)],
                truncation: [],
                refs: []
            ))),
            ("unordered paths", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [parent, childOne, childZero],
                truncation: [],
                refs: []
            ))),
            ("duplicate paths", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [parent, childZero, childZero],
                truncation: [],
                refs: []
            ))),
            ("non-dense refs", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [],
                refs: [AXRefEvidence(ref: 2, path: [], node: rootNode)]
            ))),
            ("mismatched ref evidence", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [],
                refs: [AXRefEvidence(ref: 1, path: [], node: wrongRefNode)]
            ))),
            ("full mode missing refs", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [],
                refs: []
            ))),
            ("leaf mode unexpected ref", snapshotRecord(
                treeOptions: TreeOptions(maxDepth: 8, maxElements: 500, hintMode: .leafOnly),
                evidence: validEvidence
            )),
            ("reordered refs", snapshotRecord(evidence: AXTreeEvidence(
                nodes: twoNodeEvidence.nodes,
                truncation: [],
                refs: [twoNodeEvidence.refs[1], twoNodeEvidence.refs[0]]
            ))),
            ("duplicate boundaries", snapshotRecord(
                treeOptions: truncatedOptions,
                evidence: AXTreeEvidence(
                    nodes: truncated.evidence.nodes,
                    truncation: [firstBoundary, firstBoundary],
                    refs: truncated.evidence.refs
                )
            )),
            ("illegal truncation", snapshotRecord(evidence: AXTreeEvidence(
                nodes: [rootNode],
                truncation: [AXTraversalBoundary(
                    path: [],
                    reason: .maxDepth,
                    observedChildren: 1,
                    totalChildren: 0
                )],
                refs: []
            )))
        ]

        for (name, record) in cases {
            let root = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try StateStore(rootURL: root).writeSnapshot(record), name) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testReadAppliesTheSameSemanticValidationAsWrite() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StateStore(rootURL: root)
        try store.writeSnapshot(snapshotRecord())
        let path = root.appendingPathComponent("snapshots/\(fixedID).json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var target = try XCTUnwrap(object["target"] as? [String: Any])
        var identity = try XCTUnwrap(target["identity"] as? [String: Any])
        identity["pid"] = 0
        target["identity"] = identity
        object["target"] = target
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        chmod(path.path, 0o600)

        XCTAssertThrowsError(try store.readSnapshot(id: fixedID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testLifetimeMustBeExactlyTenMinutes() throws {
        let cases = [
            ("before", "2999-01-01T00:09:59.9995Z", false),
            ("at", "2999-01-01T00:10:00.0000Z", true),
            ("after", "2999-01-01T00:10:00.0005Z", false)
        ]
        for (name, expiration, accepted) in cases {
            let root = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let operation = { try StateStore(rootURL: root).writeSnapshot(snapshotRecord(createdAt: "2999-01-01T00:00:00.0000Z", expiresAt: expiration)) }
            if accepted {
                XCTAssertNoThrow(try operation(), name)
            } else {
                XCTAssertThrowsError(try operation(), name)
            }
        }
    }

    func testTimestampGrammarRejectsMalformedUTCForms() {
        let malformed = [
            "2999-01-01T00:00:00.Z",
            "2999-01-01T00:00:00.١Z",
            "2999/01/01T00:00:00Z",
            "٢999-01-01T00:00:00Z",
            "2999-01-01T00:00:00.1234567890Z",
            "2999-01-01T00:00:00z",
            "2999-01-01T00:00:00+00:00"
        ]

        for value in malformed {
            let root = temporaryStateDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            XCTAssertThrowsError(try StateStore(rootURL: root).writeSnapshot(snapshotRecord(
                createdAt: value,
                expiresAt: "2999-01-01T00:10:00Z"
            )), value) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testLargeValidEvidenceRoundTripsWithoutChangingPolicy() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let childCount = 10_000
        let options = TreeOptions(
            maxDepth: 8,
            maxElements: childCount + 1,
            hintMode: .full
        )
        let evidence = wideEvidence(childCount: childCount, mode: options.hintMode)
        let record = snapshotRecord(treeOptions: options, evidence: evidence)
        let store = StateStore(rootURL: root)

        XCTAssertNoThrow(try store.writeSnapshot(record))
        XCTAssertEqual(try store.readSnapshot(id: record.id), record)
    }

    func testExpiryBoundaryRemainsExpiredAtExactExpiration() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let expiration = Date(timeIntervalSince1970: 600)
        let store = StateStore(rootURL: root, now: { expiration })
        try store.writeSnapshot(snapshotRecord(createdAt: "1970-01-01T00:00:00Z", expiresAt: "1970-01-01T00:10:00Z"))
        XCTAssertThrowsError(try store.readSnapshot(id: fixedID)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testLockSetupDoesNotCreateSnapshotDirectory() async throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = DesktopLock(rootURL: root)
        try await lock.withLock(context: CommandContext(timeoutMilliseconds: 100)) {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("snapshots").path))
        XCTAssertEqual(fileMode(root.appendingPathComponent("desktop.lock")), 0o600)
    }
}

final class DesktopLockTests: XCTestCase {
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

    func testSubprocessLockHelper() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["LOCK_HELPER_ROOT"], let logPath = environment["LOCK_HELPER_LOG"] else { return }
        let hold = useconds_t(environment["LOCK_HELPER_HOLD"] ?? "0") ?? 0
        try await DesktopLock(rootURL: URL(fileURLWithPath: rootPath)).withLock(
            context: CommandContext(timeoutMilliseconds: 5_000)
        ) {
            appendEvent("start \(getpid())\n", to: logPath)
            if let readyPath = environment["LOCK_HELPER_READY"] {
                FileManager.default.createFile(atPath: readyPath, contents: Data())
            }
            if environment["LOCK_HELPER_FOREVER"] == "1" {
                while true { pause() }
            }
            usleep(hold)
            appendEvent("end \(getpid())\n", to: logPath)
        }
    }
}

private let fixedID = "11111111-1111-4111-8111-111111111111"
private let secondID = "22222222-2222-4222-8222-222222222222"
private let thirdID = "33333333-3333-4333-8333-333333333333"

private func snapshotRecord(
    id: String = fixedID,
    target: ResolvedTarget = resolvedTarget(),
    createdAt: String = "2999-01-01T00:00:00Z",
    expiresAt: String = "2999-01-01T00:10:00Z",
    treeOptions: TreeOptions = TreeOptions(maxDepth: 8, maxElements: 500, hintMode: .full),
    evidence: AXTreeEvidence? = nil,
    invalidated: Bool = false
) -> SnapshotRecord {
    let rootNode = stateNode(path: [], role: "AXWindow", title: target.title, bounds: target.bounds, childCount: 0)
    return SnapshotRecord(
        id: id,
        createdAt: createdAt,
        expiresAt: expiresAt,
        target: target,
        treeOptions: treeOptions,
        evidence: evidence ?? AXTreeEvidence(nodes: [rootNode], truncation: [], refs: [AXRefEvidence(ref: 1, path: [], node: rootNode)]),
        invalidated: invalidated
    )
}

private func stateNode(path: [Int], role: String, title: String? = nil, bounds: WindowBounds? = nil, childCount: Int) -> AXNodeEvidence {
    AXNodeEvidence(path: path, role: role, subrole: nil, identifier: nil, title: title, label: nil, value: nil, enabled: nil, focused: nil, selected: nil, actions: [], bounds: bounds, childCount: childCount)
}

private func stateTruncationInput() -> AXTreeInputNode {
    AXTreeInputNode(
        role: "AXWindow",
        children: [
            AXTreeInputNode(
                role: "AXGroup",
                children: [AXTreeInputNode(role: "AXButton")]
            ),
            AXTreeInputNode(role: "AXButton")
        ]
    )
}

private func wideEvidence(childCount: Int, mode: HintMode) -> AXTreeEvidence {
    let root = stateNode(path: [], role: "AXWindow", childCount: childCount)
    let children = (0..<childCount).map {
        stateNode(path: [$0], role: "AXButton", childCount: 0)
    }
    let nodes = [root] + children
    return AXTreeEvidence(
        nodes: nodes,
        truncation: [],
        refs: AXEvidencePolicy.deriveRefs(nodes: nodes, boundaries: [], mode: mode)
    )
}

private func resolvedTarget(pid: Int = 42, bundleID: String? = "com.example.Editor") -> ResolvedTarget {
    ResolvedTarget(
        identity: TargetIdentity(pid: pid, launchDate: "2026-09-08T10:00:00Z", bundleId: bundleID, windowId: 7),
        title: "Document",
        bounds: WindowBounds(x: 100, y: 100, width: 600, height: 400)
    )
}

private func temporaryStateDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    XCTAssertEqual(mkdir(url.path, 0o755), 0)
    return url
}

private func fileMode(_ url: URL) -> mode_t {
    var info = stat()
    XCTAssertEqual(lstat(url.path, &info), 0)
    return info.st_mode & 0o777
}

private func spawnLockHelper(
    root: URL,
    log: URL,
    holdMicroseconds: useconds_t = 0,
    holdForever: Bool = false,
    ready: URL? = nil
) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["xctest", "-XCTest", "ComputerUseCoreTests.DesktopLockTests/testSubprocessLockHelper", Bundle(for: DesktopLockTests.self).bundleURL.path]
    var environment = ProcessInfo.processInfo.environment
    environment["LOCK_HELPER_ROOT"] = root.path
    environment["LOCK_HELPER_LOG"] = log.path
    environment["LOCK_HELPER_HOLD"] = String(holdMicroseconds)
    if holdForever { environment["LOCK_HELPER_FOREVER"] = "1" }
    if let ready { environment["LOCK_HELPER_READY"] = ready.path }
    process.environment = environment
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    return process
}

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

private func waitForFile(_ url: URL) throws {
    let deadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: url.path) {
        guard Date() < deadline else { throw NativeFailure("TIMEOUT", "Lock helper did not become ready") }
        usleep(10_000)
    }
}

private func appendEvent(_ event: String, to path: String) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
    guard descriptor >= 0 else { return }
    let bytes = Array(event.utf8)
    _ = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
    close(descriptor)
}
