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

    func testLockSetupDoesNotCreateSnapshotDirectory() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = DesktopLock(rootURL: root)
        try lock.withLock(timeoutMilliseconds: 100) {}
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
        let second = try spawnLockHelper(root: root, log: log, holdMicroseconds: 150_000)
        first.waitUntilExit()
        second.waitUntilExit()
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
        try waitForFile(ready)
        XCTAssertEqual(kill(owner.processIdentifier, SIGKILL), 0)
        owner.waitUntilExit()
        XCTAssertEqual(owner.terminationReason, .uncaughtSignal)
        XCTAssertEqual(owner.terminationStatus, SIGKILL)

        let successor = try spawnLockHelper(root: root, log: root.appendingPathComponent("successor.log"), holdMicroseconds: 0)
        successor.waitUntilExit()
        XCTAssertEqual(successor.terminationStatus, 0)
    }

    func testBusyAcquisitionIsDeadlineBounded() throws {
        let root = temporaryStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready")
        let owner = try spawnLockHelper(root: root, log: root.appendingPathComponent("owner.log"), holdMicroseconds: 500_000, ready: ready)
        try waitForFile(ready)

        let start = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try DesktopLock(rootURL: root).withLock(timeoutMilliseconds: 50) {}) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "BUSY")
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        XCTAssertLessThan(elapsed, 0.5)
        owner.waitUntilExit()
        XCTAssertEqual(owner.terminationStatus, 0)
    }

    func testSubprocessLockHelper() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["LOCK_HELPER_ROOT"], let logPath = environment["LOCK_HELPER_LOG"] else { return }
        let hold = useconds_t(environment["LOCK_HELPER_HOLD"] ?? "0") ?? 0
        try DesktopLock(rootURL: URL(fileURLWithPath: rootPath)).withLock(timeoutMilliseconds: 5_000) {
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
    invalidated: Bool = false
) -> SnapshotRecord {
    SnapshotRecord(
        id: id,
        createdAt: createdAt,
        expiresAt: expiresAt,
        target: target,
        treeOptions: TreeOptions(maxDepth: 8, maxElements: 500, hintMode: .full),
        evidence: AXTreeEvidence(nodes: [], truncation: [], refs: []),
        invalidated: invalidated
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
