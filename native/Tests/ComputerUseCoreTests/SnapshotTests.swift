import XCTest
@testable import ComputerUseCore

final class SnapshotTests: XCTestCase {
    func testReorderedLiveTreeRejectsOldRef() throws {
        let before = try treeFixture("save-cancel")
        let after = try treeFixture("cancel-save")
        XCTAssertThrowsError(try SnapshotService.validateEvidence(before, live: after, ref: 2)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testChangedTargetEvidenceRejectsOldRef() throws {
        let before = try treeFixture("save-cancel")
        for name in ["changed-label", "changed-actions", "changed-geometry", "removed-target"] {
            XCTAssertThrowsError(try SnapshotService.validateEvidence(before, live: treeFixture(name), ref: 2), name) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testProcessStartIdentityRejectsPidReuse() throws {
        XCTAssertThrowsError(try SnapshotService.validateEvidence(treeFixture("save-cancel"), live: treeFixture("pid-reused"), ref: 2)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testObservedTruncationBoundaryMustMatch() throws {
        XCTAssertThrowsError(try SnapshotService.validateEvidence(treeFixture("truncated-before"), live: treeFixture("truncated-after"), ref: 2)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
    }

    func testMatchingEvidenceSelectsOnlyTheNewLiveRef() throws {
        let live = try treeFixture("save-cancel")
        let selected = try SnapshotService.validateEvidence(live, live: live, ref: 2)
        XCTAssertEqual(selected.path, [0])
        XCTAssertEqual(selected.node.title, "Save")
    }

    func testTraversalPreservesCustomDepthLimitAndObservedBoundaries() throws {
        let target = try treeFixture("save-cancel").target
        let input = AXTreeInputNode(role: "AXWindow", title: "Document", bounds: target.bounds, children: [
            AXTreeInputNode(role: "AXGroup", children: [
                AXTreeInputNode(role: "AXButton", title: "Deep", actions: ["AXPress"])
            ]),
            AXTreeInputNode(role: "AXButton", title: "Second", actions: ["AXPress"]),
            AXTreeInputNode(role: "AXButton", title: "Unobserved", actions: ["AXPress"])
        ])
        let options = TreeOptions(maxDepth: 1, maxElements: 2, hintMode: .full)
        let snapshot = AXTree.snapshot(target: target, options: options, root: input)

        XCTAssertEqual(snapshot.treeOptions, options)
        XCTAssertEqual(snapshot.evidence.nodes.map(\.path), [[], [0]])
        XCTAssertEqual(snapshot.evidence.truncation, [
            AXTraversalBoundary(path: [0], reason: .maxDepth, observedChildren: 0, totalChildren: 1),
            AXTraversalBoundary(path: [], reason: .maxElements, observedChildren: 1, totalChildren: 3)
        ])
        XCTAssertTrue(snapshot.truncated)
    }

    func testFullEvidenceDoesNotDependOnDisplayHintFormatting() throws {
        let target = try treeFixture("save-cancel").target
        let input = AXTreeInputNode(role: "AXWindow", title: "Document", bounds: target.bounds, children: [
            AXTreeInputNode(role: "AXGroup", children: [
                AXTreeInputNode(role: "AXButton", title: "Save", actions: ["AXPress"])
            ])
        ])
        let full = AXTree.snapshot(target: target, options: .init(maxDepth: 8, maxElements: 20, hintMode: .full), root: input)
        let compact = AXTree.snapshot(target: target, options: .init(maxDepth: 8, maxElements: 20, hintMode: .leafCompact), root: input)

        XCTAssertEqual(full.evidence.nodes, compact.evidence.nodes)
        XCTAssertEqual(full.evidence.truncation, compact.evidence.truncation)
        XCTAssertNotEqual(full.evidence.refs, compact.evidence.refs)
    }

    func testValidationFailureDoesNotInvalidateRecord() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = try treeFixture("save-cancel")
        let live = try treeFixture("changed-label")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        let store = StateStore(rootURL: root, now: { now })
        let record = SnapshotRecord(id: "44444444-4444-4444-8444-444444444444", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: recorded.target, treeOptions: recorded.treeOptions, evidence: recorded.evidence)
        try store.writeSnapshot(record)
        let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store, resolve: { _ in recorded.target }, observe: { _, _ in
            AXTreeObservation(snapshot: live, liveElements: [2: LiveAXElement()])
        }, validateTarget: { _ in recorded.target }, now: { now })

        XCTAssertThrowsError(try service.withValidatedSnapshotAction(snapshotID: record.id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: true) { _, _ in
            XCTFail("action must not run")
        }) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
        XCTAssertFalse(try store.readSnapshot(id: record.id).invalidated)
    }

    func testStateChangingAttemptInvalidatesBeforeActionButNonChangingAttemptDoesNot() throws {
        for stateChanging in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try treeFixture("save-cancel")
            let now = Date(timeIntervalSince1970: 1_788_861_900)
            let store = StateStore(rootURL: root, now: { now })
            let id = stateChanging ? "55555555-5555-4555-8555-555555555555" : "66666666-6666-4666-8666-666666666666"
            let record = SnapshotRecord(id: id, createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
            try store.writeSnapshot(record)
            let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store, resolve: { _ in snapshot.target }, observe: { _, _ in
                AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
            }, validateTarget: { _ in snapshot.target }, now: { now })
            var invalidatedDuringAction = false

            try service.withValidatedSnapshotAction(snapshotID: id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: stateChanging) { _, _ in
                invalidatedDuringAction = (try? store.readSnapshot(id: id)) == nil
            }
            XCTAssertEqual(invalidatedDuringAction, stateChanging)
            XCTAssertEqual((try? store.readSnapshot(id: id)) == nil, stateChanging)
        }
    }


    func testSnapshotNativeDispatchUsesInjectedPureObservation() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try treeFixture("save-cancel")
        let lock = DesktopLock(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let store = StateStore(rootURL: root, now: { now })
        let service = SnapshotService(lock: lock, store: store, resolve: { _ in fixture.target }, observe: { _, _ in
            AXTreeObservation(snapshot: fixture, liveElements: [:])
        }, now: { now })
        let native = NativeService(snapshotService: service)
        let request = try XCTUnwrap(WireRequest.decode([
            "schemaVersion": 1,
            "command": "snapshot",
            "target": ["pid": 42, "windowId": 7],
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "full"],
            "options": ["timeoutMs": 1_000, "cursor": "off"]
        ]))

        let reply = native.execute(request)
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.command, "snapshot")
        guard case let .string(snapshotID)? = reply.data?["snapshotId"] else { return XCTFail("missing snapshot ID") }
        XCTAssertNoThrow(try store.readSnapshot(id: snapshotID))
    }
}

private func treeFixture(_ name: String) throws -> AXTreeSnapshot {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = root.appendingPathComponent("fixtures/native/trees.json")
    let fixtures = try JSONDecoder().decode([String: AXTreeSnapshot].self, from: Data(contentsOf: url))
    return try XCTUnwrap(fixtures[name])
}

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}
