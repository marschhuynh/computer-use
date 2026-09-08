import Darwin
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

    func testMatchingTruncatedEvidenceNeverAuthorizesUnsafeRefInAnyHintMode() throws {
        let fixture = try treeFixture("truncated-before")
        for mode in [HintMode.full, .leafOnly, .leafCompact] {
            let snapshot = AXTreeSnapshot(
                target: fixture.target,
                treeOptions: TreeOptions(maxDepth: fixture.treeOptions.maxDepth, maxElements: fixture.treeOptions.maxElements, hintMode: mode),
                evidence: fixture.evidence
            )
            XCTAssertThrowsError(try SnapshotService.validateEvidence(snapshot, live: snapshot, ref: 2), mode.rawValue) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testBoundaryAncestorMakesDescendantRefUnsafeEvenWhenEvidenceMatches() throws {
        let fixture = try treeFixture("truncated-before")
        XCTAssertTrue(fixture.evidence.truncation.contains { boundary in
            fixture.evidence.refs[1].path.starts(with: boundary.path)
        })
        XCTAssertThrowsError(try SnapshotService.validateEvidence(fixture, live: fixture, ref: 2)) {
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

    func testProducerRefsRespectDepthBoundaryInEveryHintMode() throws {
        let target = try treeFixture("save-cancel").target
        let input = truncationPolicyInput()
        let expected: [HintMode: [[Int]]] = [
            .full: [[], [1]],
            .leafOnly: [[1]],
            .leafCompact: [[1]]
        ]

        for mode in [HintMode.full, .leafOnly, .leafCompact] {
            let options = TreeOptions(maxDepth: 1, maxElements: 20, hintMode: mode)
            let snapshot = AXTree.snapshot(target: target, options: options, root: input)

            XCTAssertEqual(snapshot.evidence.truncation, [
                AXTraversalBoundary(
                    path: [0],
                    reason: .maxDepth,
                    observedChildren: 0,
                    totalChildren: 1
                )
            ], mode.rawValue)
            XCTAssertEqual(snapshot.evidence.refs.map(\.path), expected[mode], mode.rawValue)
            XCTAssertNoThrow(try AXEvidencePolicy.validate(snapshot.evidence, options: options), mode.rawValue)
        }
    }

    func testRootMaxElementsBoundaryProducesNoRefsInEveryHintMode() throws {
        let target = try treeFixture("save-cancel").target
        let input = truncationPolicyInput()

        for mode in [HintMode.full, .leafOnly, .leafCompact] {
            let options = TreeOptions(maxDepth: 8, maxElements: 2, hintMode: mode)
            let snapshot = AXTree.snapshot(target: target, options: options, root: input)

            XCTAssertEqual(snapshot.evidence.truncation, [
                AXTraversalBoundary(
                    path: [0],
                    reason: .maxElements,
                    observedChildren: 0,
                    totalChildren: 1
                ),
                AXTraversalBoundary(
                    path: [],
                    reason: .maxElements,
                    observedChildren: 1,
                    totalChildren: 2
                )
            ], mode.rawValue)
            XCTAssertEqual(snapshot.evidence.refs, [], mode.rawValue)
            XCTAssertNoThrow(try AXEvidencePolicy.validate(snapshot.evidence, options: options), mode.rawValue)
        }
    }

    func testEvidencePolicyRejectsDuplicateBoundariesAndModeIncoherentRefs() throws {
        let target = try treeFixture("save-cancel").target
        let truncatedOptions = TreeOptions(maxDepth: 8, maxElements: 2, hintMode: .full)
        let truncated = AXTree.snapshot(target: target, options: truncatedOptions, root: truncationPolicyInput())
        let firstBoundary = try XCTUnwrap(truncated.evidence.truncation.first)
        let duplicateBoundaryEvidence = AXTreeEvidence(
            nodes: truncated.evidence.nodes,
            truncation: [firstBoundary, firstBoundary],
            refs: truncated.evidence.refs
        )

        XCTAssertThrowsError(try AXEvidencePolicy.validate(duplicateBoundaryEvidence, options: truncatedOptions)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }

        let completeOptions = TreeOptions(maxDepth: 8, maxElements: 20, hintMode: .full)
        let complete = AXTree.snapshot(
            target: target,
            options: completeOptions,
            root: AXTreeInputNode(role: "AXWindow")
        )
        let missingRefEvidence = AXTreeEvidence(
            nodes: complete.evidence.nodes,
            truncation: complete.evidence.truncation,
            refs: []
        )

        XCTAssertThrowsError(try AXEvidencePolicy.validate(missingRefEvidence, options: completeOptions)) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
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

        XCTAssertThrowsError(try service.withValidatedSnapshotAction(snapshotID: record.id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: true, preflight: { _, _ in
            XCTFail("preflight must not run")
        }, dispatch: { _ in
            XCTFail("dispatch must not run")
        })) {
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
            var validDuringPreflight = false
            var invalidatedDuringAction = false

            try service.withValidatedSnapshotAction(snapshotID: id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: stateChanging, preflight: { _, _ in
                validDuringPreflight = (try? store.readSnapshot(id: id)) != nil
            }, dispatch: { _ in
                invalidatedDuringAction = (try? store.readSnapshot(id: id)) == nil
            })
            XCTAssertTrue(validDuringPreflight)
            XCTAssertEqual(invalidatedDuringAction, stateChanging)
            XCTAssertEqual((try? store.readSnapshot(id: id)) == nil, stateChanging)
        }
    }

    func testFailedStateChangingPreparationDoesNotInvalidateOrDispatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try treeFixture("save-cancel")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        let store = StateStore(rootURL: root, now: { now })
        let record = SnapshotRecord(id: "77777777-7777-4777-8777-777777777777", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
        try store.writeSnapshot(record)
        let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store, resolve: { _ in snapshot.target }, observe: { _, _ in
            AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
        }, validateTarget: { _ in snapshot.target }, now: { now })
        var dispatched = false

        XCTAssertThrowsError(try service.withValidatedSnapshotAction(snapshotID: record.id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: true, preflight: { _, _ in
            throw NativeFailure("INVALID_REQUEST", "Action-specific preparation failed")
        }, dispatch: { _ in
            dispatched = true
        })) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_REQUEST")
        }
        XCTAssertNoThrow(try store.readSnapshot(id: record.id))
        XCTAssertFalse(dispatched)
    }

    func testInvalidationFailurePreventsActionDispatch() throws {
        for contents in [Data("not-json".utf8), Data("{}".utf8)] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try treeFixture("save-cancel")
            let now = Date(timeIntervalSince1970: 1_788_861_900)
            let store = StateStore(rootURL: root, now: { now })
            let record = SnapshotRecord(id: "88888888-8888-4888-8888-888888888888", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
            try store.writeSnapshot(record)
            let malformed = root.appendingPathComponent("snapshots/00000000-0000-4000-8000-000000000000.json")
            try contents.write(to: malformed)
            chmod(malformed.path, 0o600)
            let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store, observe: { _, _ in
                AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
            }, validateTarget: { _ in snapshot.target }, now: { now })
            var actionRan = false

            XCTAssertThrowsError(try service.withValidatedSnapshotAction(snapshotID: record.id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: true, preflight: { _, _ in
                ()
            }, dispatch: { _ in
                actionRan = true
            }))
            XCTAssertFalse(actionRan)
        }
    }

    func testDispatchFailureLeavesAllAppRecordsInvalidated() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try treeFixture("save-cancel")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        let store = StateStore(rootURL: root, now: { now })
        let record = SnapshotRecord(id: "99999999-9999-4999-8999-999999999999", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
        try store.writeSnapshot(record)
        let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store, observe: { _, _ in
            AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
        }, validateTarget: { _ in snapshot.target }, now: { now })

        XCTAssertThrowsError(try service.withValidatedSnapshotAction(snapshotID: record.id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: true, preflight: { _, _ in
            "prepared"
        }, dispatch: { prepared in
            XCTAssertEqual(prepared, "prepared")
            throw NativeFailure("NATIVE_FAILURE", "Dispatch failed")
        }))
        XCTAssertThrowsError(try store.readSnapshot(id: record.id))
    }

    func testEnumerationFailureAfterPreflightPreventsDispatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try treeFixture("save-cancel")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        var enumerationCount = 0
        let io = StateStoreIO(directoryNames: { descriptor in
            enumerationCount += 1
            if enumerationCount == 1 { return try testDirectoryNames(descriptor) }
            throw NativeFailure("NATIVE_FAILURE", "Injected enumeration failure")
        })
        let store = StateStore(rootURL: root, now: { now }, io: io)
        let record = SnapshotRecord(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
        try store.writeSnapshot(record)
        let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store, observe: { _, _ in
            AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
        }, validateTarget: { _ in snapshot.target }, now: { now })
        var preflightRan = false
        var dispatchRan = false

        XCTAssertThrowsError(try service.withValidatedSnapshotAction(snapshotID: record.id, ref: 2, timeoutMilliseconds: 1_000, stateChanging: true, preflight: { _, _ in
            preflightRan = true
        }, dispatch: { _ in
            dispatchRan = true
        }))
        XCTAssertTrue(preflightRan)
        XCTAssertFalse(dispatchRan)
    }

    func testEveryInvalidationPublicationFailurePreventsDispatch() throws {
        for failure in InvalidationIOFailure.allCases {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try treeFixture("save-cancel")
            let now = Date(timeIntervalSince1970: 1_788_861_900)
            let record = SnapshotRecord(
                id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                createdAt: "2026-09-08T10:00:00Z",
                expiresAt: "2026-09-08T10:10:00Z",
                target: snapshot.target,
                treeOptions: snapshot.treeOptions,
                evidence: snapshot.evidence
            )
            try StateStore(rootURL: root, now: { now }).writeSnapshot(record)

            let store = StateStore(
                rootURL: root,
                now: { now },
                io: failingInvalidationIO(failure)
            )
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root),
                store: store,
                observe: { _, _ in
                    AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
                },
                validateTarget: { _ in snapshot.target },
                now: { now }
            )
            var preflightRan = false
            var dispatchRan = false

            XCTAssertThrowsError(try service.withValidatedSnapshotAction(
                snapshotID: record.id,
                ref: 2,
                timeoutMilliseconds: 1_000,
                stateChanging: true,
                preflight: { _, _ in
                    preflightRan = true
                },
                dispatch: { _ in
                    dispatchRan = true
                }
            ), failure.rawValue)
            XCTAssertTrue(preflightRan, failure.rawValue)
            XCTAssertFalse(dispatchRan, failure.rawValue)

            let remainsValid = (try? StateStore(rootURL: root, now: { now }).readSnapshot(id: record.id)) != nil
            XCTAssertEqual(remainsValid, failure != .directorySync, failure.rawValue)
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

private func testDirectoryNames(_ descriptor: Int32) throws -> [String] {
    let duplicate = dup(descriptor)
    guard duplicate >= 0, let directory = fdopendir(duplicate) else { throw NativeFailure("NATIVE_FAILURE", "test enumeration failed") }
    defer { closedir(directory) }
    var names: [String] = []
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: entry.pointee.d_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
        }
        if name != "." && name != ".." { names.append(name) }
    }
    return names.sorted()
}

private func truncationPolicyInput() -> AXTreeInputNode {
    AXTreeInputNode(
        role: "AXWindow",
        actions: ["AXRaise"],
        children: [
            AXTreeInputNode(
                role: "AXGroup",
                actions: ["AXPress"],
                children: [
                    AXTreeInputNode(role: "AXButton", title: "Deep", actions: ["AXPress"])
                ]
            ),
            AXTreeInputNode(role: "AXButton", title: "Safe sibling", actions: ["AXPress"])
        ]
    )
}

private enum InvalidationIOFailure: String, CaseIterable {
    case write
    case fileSync
    case rename
    case directorySync
}

private func failingInvalidationIO(_ failure: InvalidationIOFailure) -> StateStoreIO {
    var directorySyncCalls = 0
    return StateStoreIO(
        write: { descriptor, buffer, count in
            if failure == .write { return SystemCallResult(value: -1, error: EIO) }
            let value = Darwin.write(descriptor, buffer, count)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        sync: { descriptor in
            var info = stat()
            guard fstat(descriptor, &info) == 0 else {
                return SystemCallResult(value: -1, error: errno)
            }
            let fileType = info.st_mode & S_IFMT
            if fileType == S_IFREG && failure == .fileSync {
                return SystemCallResult(value: -1, error: EIO)
            }
            if fileType == S_IFDIR {
                directorySyncCalls += 1
                if failure == .directorySync && directorySyncCalls == 1 {
                    return SystemCallResult(value: -1, error: EIO)
                }
            }
            let value = fsync(descriptor)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        },
        renameRecord: { oldDirectory, oldName, newDirectory, newName in
            if failure == .rename { return SystemCallResult(value: -1, error: EIO) }
            let value = renameat(oldDirectory, oldName, newDirectory, newName)
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        }
    )
}
