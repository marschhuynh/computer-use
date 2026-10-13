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
            guard case let .object(coverage) = presentationWire(snapshot)["coverage"] else {
                XCTFail("missing coverage"); continue
            }
            XCTAssertEqual(coverage["refCount"], .number(0))
            XCTAssertEqual(coverage["emittedNodes"], .number(2))
            XCTAssertEqual(coverage["noRefReason"], .string("traversalLimited"))
            XCTAssertEqual(SnapshotPresentation(snapshot: snapshot).emittedNodes, 2)
            XCTAssertNotEqual(presentationWire(snapshot)["tree"], .object(["elements": .array([])]))
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

    func testValidationFailureDoesNotInvalidateRecord() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorded = try treeFixture("save-cancel")
        let live = try treeFixture("changed-label")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        let store = StateStore(rootURL: root)
        let record = SnapshotRecord(id: "44444444-4444-4444-8444-444444444444", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: recorded.target, treeOptions: recorded.treeOptions, evidence: recorded.evidence)
        try store.writeSnapshot(record, context: snapshotCommandContext(wallNow: now))
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
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
            prepareSnapshot: { _, _ in },
            validateTarget: { identity, context in
                _ = identity
                _ = context
                return recorded.target
            },
            sameLiveElement: { _, _ in true },
            prepareElement: { _, _ in }
        )

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
                    XCTFail("preflight must not run")
                },
                dispatch: { prepared, _, _ in
                    _ = prepared
                    XCTFail("dispatch must not run")
                }
            )
        }) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
        }
        XCTAssertFalse(try store.readSnapshot(id: record.id, context: snapshotCommandContext(wallNow: now)).invalidated)
    }

    func testStateChangingAttemptInvalidatesBeforeActionButNonChangingAttemptDoesNot() async throws {
        for stateChanging in [false, true] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try treeFixture("save-cancel")
            let now = Date(timeIntervalSince1970: 1_788_861_900)
            let store = StateStore(rootURL: root)
            let id = stateChanging ? "55555555-5555-4555-8555-555555555555" : "66666666-6666-4666-8666-666666666666"
            let record = SnapshotRecord(id: id, createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
            try store.writeSnapshot(record, context: snapshotCommandContext(wallNow: now))
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root),
                store: store,
                resolve: { selector, context in
                    _ = selector
                    _ = context
                    return snapshot.target
                },
                observe: { target, options, context in
                    _ = target
                    _ = options
                    _ = context
                    return AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
                },
                prepareSnapshot: { _, _ in },
                validateTarget: { identity, context in
                    _ = identity
                    _ = context
                    return snapshot.target
                },
                sameLiveElement: { _, _ in true },
                prepareElement: { _, _ in }
            )
            var preflightCount = 0
            var validDuringPreflight = false
            var invalidatedDuringAction = false

            try await service.withValidatedSnapshotAction(
                snapshotID: id,
                ref: 2,
                context: snapshotCommandContext(wallNow: now),
                stateChanging: stateChanging,
                preflight: { _, _, _ in
                    preflightCount += 1
                    if preflightCount == 1 {
                        validDuringPreflight = (try? store.readSnapshot(
                            id: id,
                            context: snapshotCommandContext(wallNow: now)
                        )) != nil
                    }
                },
                dispatch: { prepared, _, _ in
                    _ = prepared
                    invalidatedDuringAction = (try? store.readSnapshot(id: id, context: snapshotCommandContext(wallNow: now))) == nil
                }
            )
            XCTAssertEqual(preflightCount, 2)
            XCTAssertTrue(validDuringPreflight)
            XCTAssertEqual(invalidatedDuringAction, stateChanging)
            XCTAssertEqual((try? store.readSnapshot(id: id, context: snapshotCommandContext(wallNow: now))) == nil, stateChanging)
        }
    }

    func testFailedStateChangingPreparationDoesNotInvalidateOrDispatch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try treeFixture("save-cancel")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        let store = StateStore(rootURL: root)
        let record = SnapshotRecord(id: "77777777-7777-4777-8777-777777777777", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
        try store.writeSnapshot(record, context: snapshotCommandContext(wallNow: now))
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            resolve: { selector, context in
                _ = selector
                _ = context
                return snapshot.target
            },
            observe: { target, options, context in
                _ = target
                _ = options
                _ = context
                return AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
            },
            prepareSnapshot: { _, _ in },
            validateTarget: { identity, context in
                _ = identity
                _ = context
                return snapshot.target
            },
            sameLiveElement: { _, _ in true },
            prepareElement: { _, _ in }
        )
        var dispatched = false

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
                dispatch: { prepared, _, _ in
                    _ = prepared
                    dispatched = true
                }
            )
        }) {
            XCTAssertEqual(($0 as? NativeFailure)?.code, "INVALID_REQUEST")
        }
        XCTAssertNoThrow(try store.readSnapshot(id: record.id, context: snapshotCommandContext(wallNow: now)))
        XCTAssertFalse(dispatched)
    }

    func testInvalidationFailurePreventsActionDispatch() async throws {
        for contents in [Data("not-json".utf8), Data("{}".utf8)] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let snapshot = try treeFixture("save-cancel")
            let now = Date(timeIntervalSince1970: 1_788_861_900)
            let store = StateStore(rootURL: root)
            let record = SnapshotRecord(id: "88888888-8888-4888-8888-888888888888", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
            try store.writeSnapshot(record, context: snapshotCommandContext(wallNow: now))
            let malformed = root.appendingPathComponent("snapshots/00000000-0000-4000-8000-000000000000.json")
            try contents.write(to: malformed)
            chmod(malformed.path, 0o600)
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root),
                store: store,
                observe: { target, options, context in
                    _ = target
                    _ = options
                    _ = context
                    return AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
                },
                prepareSnapshot: { _, _ in },
                validateTarget: { identity, context in
                    _ = identity
                    _ = context
                    return snapshot.target
                },
                sameLiveElement: { _, _ in true },
                prepareElement: { _, _ in }
            )
            var actionRan = false

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
                    },
                    dispatch: { prepared, _, _ in
                        _ = prepared
                        actionRan = true
                    }
                )
            })
            XCTAssertFalse(actionRan)
        }
    }

    func testDispatchFailureLeavesAllAppRecordsInvalidated() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try treeFixture("save-cancel")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        let store = StateStore(rootURL: root)
        let record = SnapshotRecord(id: "99999999-9999-4999-8999-999999999999", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
        try store.writeSnapshot(record, context: snapshotCommandContext(wallNow: now))
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { target, options, context in
                _ = target
                _ = options
                _ = context
                return AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
            },
            prepareSnapshot: { _, _ in },
            validateTarget: { identity, context in
                _ = identity
                _ = context
                return snapshot.target
            },
            sameLiveElement: { _, _ in true },
            prepareElement: { _, _ in }
        )

        var capturedFailure: NativeFailure?
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
                    return "prepared"
                },
                dispatch: { prepared, _, _ in
                    XCTAssertEqual(prepared, "prepared")
                    throw NativeFailure("NATIVE_FAILURE", "Dispatch failed")
                }
            )
        }) { error in
            capturedFailure = error as? NativeFailure
        }
        let failure = try XCTUnwrap(capturedFailure)
        XCTAssertEqual(failure.details?["mutationStatus"], .string("potentiallyApplied"))
        XCTAssertThrowsError(try store.readSnapshot(id: record.id, context: snapshotCommandContext(wallNow: now)))
    }

    func testEnumerationFailureAfterPreflightPreventsDispatch() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try treeFixture("save-cancel")
        let now = Date(timeIntervalSince1970: 1_788_861_900)
        var enumerationCount = 0
        let io = StateStoreIO(directoryNames: { descriptor, _ in
            enumerationCount += 1
            // sweep now enumerates both record dirs (snapshots, captures) before
            // preflight; let those succeed and fail only during invalidation.
            if enumerationCount <= 2 { return try testDirectoryNames(descriptor) }
            throw NativeFailure("NATIVE_FAILURE", "Injected enumeration failure")
        })
        let store = StateStore(rootURL: root, io: io)
        let record = SnapshotRecord(id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", createdAt: "2026-09-08T10:00:00Z", expiresAt: "2026-09-08T10:10:00Z", target: snapshot.target, treeOptions: snapshot.treeOptions, evidence: snapshot.evidence)
        try store.writeSnapshot(record, context: snapshotCommandContext(wallNow: now))
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            observe: { target, options, context in
                _ = target
                _ = options
                _ = context
                return AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
            },
            prepareSnapshot: { _, _ in },
            validateTarget: { identity, context in
                _ = identity
                _ = context
                return snapshot.target
            },
            sameLiveElement: { _, _ in true },
            prepareElement: { _, _ in }
        )
        var preflightRan = false
        var dispatchRan = false

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
                    preflightRan = true
                },
                dispatch: { prepared, _, _ in
                    _ = prepared
                    dispatchRan = true
                }
            )
        })
        XCTAssertTrue(preflightRan)
        XCTAssertFalse(dispatchRan)
    }

    func testEveryInvalidationPublicationFailurePreventsDispatch() async throws {
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
            try StateStore(rootURL: root).writeSnapshot(record, context: snapshotCommandContext(wallNow: now))

            let store = StateStore(
                rootURL: root,
                io: failingInvalidationIO(failure)
            )
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root),
                store: store,
                observe: { target, options, context in
                    _ = target
                    _ = options
                    _ = context
                    return AXTreeObservation(snapshot: snapshot, liveElements: [2: LiveAXElement()])
                },
                prepareSnapshot: { _, _ in },
                validateTarget: { identity, context in
                    _ = identity
                    _ = context
                    return snapshot.target
                },
                sameLiveElement: { _, _ in true },
                prepareElement: { _, _ in }
            )
            var preflightRan = false
            var dispatchRan = false

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
                        preflightRan = true
                    },
                    dispatch: { prepared, _, _ in
                        _ = prepared
                        dispatchRan = true
                    }
                )
            }, failure.rawValue)
            XCTAssertTrue(preflightRan, failure.rawValue)
            XCTAssertFalse(dispatchRan, failure.rawValue)

            let remainsValid = (try? StateStore(rootURL: root).readSnapshot(id: record.id, context: snapshotCommandContext(wallNow: now))) != nil
            XCTAssertEqual(remainsValid, failure != .directorySync, failure.rawValue)
        }
    }

    func testShippingPreparationDefaultRemainsExplicitlyNoOp() throws {
        // Inspect the release gate without executing a default that a future
        // candidate might wire to live AX against a fixture PID.
        let native = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: native.appendingPathComponent("Sources/ComputerUseCore/SnapshotService.swift"))
        XCTAssertTrue(source.contains("prepareSnapshot: @escaping PrepareSnapshot = { _, _ in }"))
        XCTAssertFalse(source.contains("AXSnapshotPreparation."))
    }

    func testZeroRefSnapshotPreparesOnceWithoutAutomaticScreenshot() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try presentationSnapshot(zeroRefTextInput())
        let store = StateStore(rootURL: root)
        var preparations = 0
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root), store: store,
            resolve: { _, _ in snapshot.target },
            observe: { _, _, _ in AXTreeObservation(snapshot: snapshot, liveElements: [:]) },
            prepareSnapshot: { _, _ in preparations += 1 },
            validateTarget: { _, _ in snapshot.target }
        )
        let native = NativeService(snapshotService: service,
            captureService: CaptureService(capturer: { _, _, _ in
                XCTFail("zero refs must not trigger an automatic screenshot")
                throw NativeFailure("NATIVE_FAILURE", "unexpected capture")
            }, store: store))
        let request = try XCTUnwrap(WireRequest.decode([
            "schemaVersion": 1, "command": "snapshot", "target": ["pid": 42, "windowId": 7],
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "leafCompact"],
            "options": ["timeoutMs": 1_000, "cursor": "off"]
        ]))
        let command = snapshotCommandContext(wallNow: Date(timeIntervalSince1970: 1_789_000_000))
        let reply = await native.execute(request, context: command)
        XCTAssertTrue(reply.ok, "\(String(describing: reply.error))")
        XCTAssertEqual(preparations, 1)
        XCTAssertTrue(snapshot.evidence.refs.isEmpty)
        guard case let .string(id)? = reply.data?["snapshotId"] else { return XCTFail("missing snapshot ID") }
        XCTAssertEqual(try store.readSnapshot(id: id, context: command).evidence, snapshot.evidence)
        XCTAssertNil(reply.data?["captureId"])
    }

    func testSnapshotNativeDispatchUsesInjectedPureObservation() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try treeFixture("save-cancel")
        let lock = DesktopLock(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let store = StateStore(rootURL: root)
        let service = SnapshotService(
            lock: lock,
            store: store,
            resolve: { selector, context in
                _ = selector
                _ = context
                return fixture.target
            },
            observe: { target, options, context in
                _ = target
                _ = options
                _ = context
                return AXTreeObservation(snapshot: fixture, liveElements: [:])
            },
            prepareSnapshot: { _, _ in },
            validateTarget: { _, _ in fixture.target }
        )
        let native = NativeService(snapshotService: service)
        let request = try XCTUnwrap(WireRequest.decode([
            "schemaVersion": 1,
            "command": "snapshot",
            "target": ["pid": 42, "windowId": 7],
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "full"],
            "options": ["timeoutMs": 1_000, "cursor": "off"]
        ]))

        let reply = await native.execute(
            request,
            context: snapshotCommandContext(wallNow: now)
        )
        XCTAssertTrue(reply.ok)
        XCTAssertEqual(reply.command, "snapshot")
        guard case let .string(snapshotID)? = reply.data?["snapshotId"] else { return XCTFail("missing snapshot ID") }
        XCTAssertNoThrow(try store.readSnapshot(id: snapshotID, context: snapshotCommandContext(wallNow: now)))
    }

    func testNativeFailureDetailsRoundTripThroughDispatcher() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try treeFixture("save-cancel")
        let lock = DesktopLock(rootURL: root)
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let service = SnapshotService(
            lock: lock,
            store: StateStore(rootURL: root),
            resolve: { selector, context in
                _ = selector
                _ = context
                return fixture.target
            },
            observe: { target, options, context in
                _ = target
                _ = options
                _ = context
                throw NativeFailure(
                    "NATIVE_FAILURE",
                    "Injected observation failure",
                    details: ["mutationStatus": .string("notStarted"), "safe": .string("kept")]
                )
            },
            prepareSnapshot: { _, _ in },
            validateTarget: { _, _ in fixture.target }
        )
        let request = try XCTUnwrap(WireRequest.decode([
            "schemaVersion": 1,
            "command": "snapshot",
            "target": ["pid": 42, "windowId": 7],
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "full"],
            "options": ["timeoutMs": 1_000, "cursor": "off"]
        ]))

        let reply = await NativeService(snapshotService: service).execute(
            request,
            context: snapshotCommandContext(wallNow: now)
        )

        XCTAssertEqual(reply.error?.code, "NATIVE_FAILURE")
        XCTAssertEqual(reply.error?.details, [
            "mutationStatus": .string("notStarted"),
            "safe": .string("kept")
        ])
    }

    func testCompactCollapsesNeutralWrapperButPreservesControlStateAndEvidence() throws {
        let compact = try presentationSnapshot(neutralWrapperInput())
        let verbose = try presentationSnapshot(neutralWrapperInput(), mode: .leafOnly)
        let before = compact.evidence
        XCTAssertEqual(presentationWire(compact)["tree"], .object(["elements": .array([
            .object(["role": .string("AXWindow"), "children": .array([
                .object(["role": .string("AXButton"), "ref": .number(1),
                    "title": .string(" Save "), "label": .string("Commit"), "value": .string("draft"),
                    "actions": .array([.string("AXPress")]), "enabled": .bool(true),
                    "focused": .bool(false), "selected": .bool(false)])
            ])])
        ])]))
        XCTAssertEqual(SnapshotPresentation(snapshot: compact).emittedNodes, 2)
        XCTAssertEqual(compact.evidence, before)
        XCTAssertEqual(compact.evidence, verbose.evidence)
        XCTAssertEqual(compact.evidence.refs.map(\.path), [[0, 0]])
    }

    func testCompactZeroRefSnapshotKeepsRealRootAndText() throws {
        let snapshot = try presentationSnapshot(zeroRefTextInput())
        XCTAssertTrue(snapshot.evidence.refs.isEmpty)
        XCTAssertEqual(presentationWire(snapshot)["tree"], .object(["elements": .array([
            .object(["role": .string("AXWindow"), "children": .array([
                .object(["role": .string("AXStaticText"), "value": .string("Read only")])
            ])])
        ])]))
        XCTAssertEqual(SnapshotPresentation(snapshot: snapshot).emittedNodes, 2)
    }

    func testCompactKeepsDescriptiveWrappers() throws {
        let button = AXTreeInputNode(role: "AXButton", actions: ["AXPress"])
        let cases: [(AXTreeInputNode, String)] = [
            (.init(role: "AXGroup", title: " Named ", children: [button]), #""title":" Named ""#),
            (.init(role: "AXGroup", label: " Label ", children: [button]), #""label":" Label ""#),
            (.init(role: "AXGroup", value: " Value ", children: [button]), #""value":" Value ""#),
            (.init(role: "AXGroup", subrole: " AXSection ", children: [button]), #""subrole":" AXSection ""#),
            (.init(role: "AXGroup", identifier: " section-id ", children: [button]), #""identifier":" section-id ""#)
        ]
        for (wrapper, field) in cases {
            try assertCompactPresentation(.init(role: "AXWindow", children: [wrapper]), expected: """
                {"elements":[{"role":"AXWindow","children":[
                    {"role":"AXGroup",\(field),"children":[{"role":"AXButton","ref":1,"actions":["AXPress"]}]}
                ]}]}
                """, emittedNodes: 3, refPaths: [[0, 0]])
        }
    }

    func testCompactKeepsMeaningfulStatesEvenWithoutRefs() throws {
        let button = AXTreeInputNode(role: "AXButton", actions: ["AXPress"])
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXGroup", enabled: false, children: [button]),
            .init(role: "AXGroup", focused: true, children: [button]),
            .init(role: "AXScrollArea", selected: true, children: [button]),
            .init(role: "AXButton", enabled: true, focused: false, selected: false),
            .init(role: "AXGroup", enabled: true, focused: false, selected: false,
                children: [.init(role: "AXGroup")]),
            .init(role: "AXGroup", enabled: false),
            .init(role: "AXGroup", focused: true),
            .init(role: "AXScrollArea", selected: true)
        ])
        try assertCompactPresentation(root, expected: """
            {"elements":[{"role":"AXWindow","children":[
                {"role":"AXGroup","enabled":false,"children":[{"role":"AXButton","ref":1,"actions":["AXPress"]}]},
                {"role":"AXGroup","focused":true,"children":[{"role":"AXButton","ref":2,"actions":["AXPress"]}]},
                {"role":"AXScrollArea","selected":true,"children":[{"role":"AXButton","ref":3,"actions":["AXPress"]}]},
                {"role":"AXButton","enabled":true,"focused":false,"selected":false},
                {"role":"AXGroup","enabled":true,"focused":false,"selected":false},
                {"role":"AXGroup","enabled":false},
                {"role":"AXGroup","focused":true},
                {"role":"AXScrollArea","selected":true}
            ]}]}
            """, emittedNodes: 12, refPaths: [[0, 0], [1, 0], [2, 0]])
    }

    func testCompactPreservesMultiChildAndUnknownAncestorsInDFSOrder() throws {
        let button = AXTreeInputNode(role: "AXButton", actions: ["AXPress"])
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXGroup", children: [button, .init(role: "AXGroup")]),
            .init(role: "AXUnknownContainer", children: [button]),
            .init(role: "AXScrollArea", children: [.init(role: "AXGroup", children: [button])]),
            .init(role: "AXGroup", children: [button, button])
        ])
        try assertCompactPresentation(root, expected: """
            {"elements":[{"role":"AXWindow","children":[
                {"role":"AXGroup","children":[{"role":"AXButton","ref":1,"actions":["AXPress"]}]},
                {"role":"AXUnknownContainer","children":[{"role":"AXButton","ref":2,"actions":["AXPress"]}]},
                {"role":"AXButton","ref":3,"actions":["AXPress"]},
                {"role":"AXGroup","children":[
                    {"role":"AXButton","ref":4,"actions":["AXPress"]},
                    {"role":"AXButton","ref":5,"actions":["AXPress"]}
                ]}
            ]}]}
            """, emittedNodes: 9, refPaths: [[0, 0], [1, 0], [2, 0, 0], [3, 0], [3, 1]])
    }

    func testCompactUsesWhitespaceOnlyForRetentionWithoutChangingText() throws {
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXStaticText", title: " \n\t", value: " "),
            .init(role: "AXGroup", title: " \n", children: [
                .init(role: "AXStaticText", title: " ", label: " Label ", value: " Read only \n")
            ])
        ])
        try assertCompactPresentation(root, expected: #"""
            {"elements":[{"role":"AXWindow","children":[
                {"role":"AXStaticText","title":" ","label":" Label ","value":" Read only \n"}
            ]}]}
            """#, emittedNodes: 2, refPaths: [])
        try assertCompactPresentation(.init(role: "AXGroup", enabled: true, focused: false, selected: false,
            children: [.init(role: "AXButton", actions: ["AXPress"])]), expected: """
            {"elements":[{"role":"AXGroup","enabled":true,"focused":false,"selected":false,"children":[
                {"role":"AXButton","ref":1,"actions":["AXPress"]}
            ]}]}
            """, emittedNodes: 2, refPaths: [[0]])
        try assertCompactPresentation(.init(role: "AXScrollArea"), expected:
            #"{"elements":[{"role":"AXScrollArea"}]}"#, emittedNodes: 1, refPaths: [])
    }

    func testCompactKeepsAnonymousBoundaryAndOriginalEvidencePathsWithoutRefs() throws {
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXGroup", children: [.init(role: "AXScrollArea", children: [
                .init(role: "AXButton", actions: ["AXPress"])
            ])])
        ])
        try assertCompactPresentation(root, expected:
            #"{"elements":[{"role":"AXWindow","children":[{"role":"AXScrollArea"}]}]}"#,
            emittedNodes: 2, refPaths: [], maxDepth: 2)
        let snapshot = try presentationSnapshot(root, maxDepth: 2)
        XCTAssertEqual(snapshot.evidence.truncation, [
            AXTraversalBoundary(path: [0, 0], reason: .maxDepth, observedChildren: 0, totalChildren: 1)
        ])
    }

    func testCompactKeepsActionNodesEvenWhenBoundaryExcludesTheirRefs() throws {
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXGroup", children: [.init(role: "AXButton", actions: ["AXPress"])]),
            .init(role: "AXGroup")
        ])
        try assertCompactPresentation(root, expected: """
            {"elements":[{"role":"AXWindow","children":[{"role":"AXButton","actions":["AXPress"]}]}]}
            """, emittedNodes: 2, refPaths: [], maxElements: 3)
    }

    func testCompactOmitsOnlyNonRefBoundsAndKeepsFalseControlStates() throws {
        let bounds = WindowBounds(x: 10, y: 20, width: 30, height: 40)
        let root = AXTreeInputNode(role: "AXWindow", bounds: bounds, children: [
            .init(role: "AXGroup", subrole: "AXSection", identifier: "editor", title: " Toolbar ",
                label: "Tools", value: "Draft", enabled: true, focused: false, selected: false,
                actions: ["AXRaise"], bounds: bounds, children: [
                    .init(role: "AXButton", enabled: false, focused: false, selected: false,
                        actions: ["AXPress"], bounds: bounds)
                ])
        ])
        try assertCompactPresentation(root, expected: """
            {"elements":[{"role":"AXWindow","children":[
                {"role":"AXGroup","subrole":"AXSection","identifier":"editor","title":" Toolbar ",
                 "label":"Tools","value":"Draft","enabled":true,"focused":false,"selected":false,
                 "actions":["AXRaise"],"children":[
                    {"role":"AXButton","ref":1,"enabled":false,"focused":false,"selected":false,
                     "actions":["AXPress"],"bounds":{"x":10,"y":20,"width":30,"height":40}}
                ]}
            ]}]}
            """, emittedNodes: 3, refPaths: [[0, 0]])
        let verbose = try presentationSnapshot(root, mode: .leafOnly)
        let expectedVerbose = #"""
            {"elements":[{"role":"AXWindow","bounds":{"x":10,"y":20,"width":30,"height":40},"children":[
                {"role":"AXGroup","subrole":"AXSection","identifier":"editor","title":" Toolbar ",
                 "label":"Tools","value":"Draft","enabled":true,"focused":false,"selected":false,
                 "actions":["AXRaise"],"bounds":{"x":10,"y":20,"width":30,"height":40},"children":[
                    {"role":"AXButton","ref":1,"enabled":false,"focused":false,"selected":false,
                     "actions":["AXPress"],"bounds":{"x":10,"y":20,"width":30,"height":40}}
                ]}
            ]}]}
            """#
        XCTAssertEqual(presentationWire(verbose)["tree"],
            try JSONDecoder().decode(JSONValue.self, from: Data(expectedVerbose.utf8)))
        XCTAssertEqual(SnapshotPresentation(snapshot: verbose).emittedNodes, verbose.evidence.nodes.count)
        XCTAssertEqual(presentationWire(try presentationSnapshot(root))["target"], presentationWire(verbose)["target"])
        XCTAssertEqual(verbose.evidence.nodes.map(\.bounds), [bounds, bounds, bounds])
    }

    func testCompactKeepsRefBearingGroupAndItsGeometry() throws {
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXGroup", enabled: true, focused: false, selected: false,
                actions: ["AXPress"], bounds: .init(x: 10, y: 20, width: 30, height: 40), children: [
                    .init(role: "AXStaticText", value: "Details")
                ])
        ])
        try assertCompactPresentation(root, expected: """
            {"elements":[{"role":"AXWindow","children":[
                {"role":"AXGroup","ref":1,"enabled":true,"focused":false,"selected":false,
                 "actions":["AXPress"],"bounds":{"x":10,"y":20,"width":30,"height":40},"children":[
                    {"role":"AXStaticText","value":"Details"}
                ]}
            ]}]}
            """, emittedNodes: 3, refPaths: [[0]])
    }

    func testCompactDoesNotCollapseBoundaryWithOneObservedAndRetainedChild() throws {
        let root = AXTreeInputNode(role: "AXWindow", children: [
            .init(role: "AXGroup", enabled: true, focused: false, selected: false, children: [
                .init(role: "AXButton", actions: ["AXPress"]),
                .init(role: "AXButton", actions: ["AXPress"])
            ])
        ])
        try assertCompactPresentation(root, expected: """
            {"elements":[{"role":"AXWindow","children":[
                {"role":"AXGroup","enabled":true,"focused":false,"selected":false,"children":[
                    {"role":"AXButton","actions":["AXPress"]}
                ]}
            ]}]}
            """, emittedNodes: 3, refPaths: [], maxElements: 3)
        XCTAssertEqual(try presentationSnapshot(root, maxElements: 3).evidence.truncation, [
            AXTraversalBoundary(path: [0], reason: .maxElements, observedChildren: 1, totalChildren: 2)
        ])
    }

    func testCollapsedWrapperStateAndBoundsStillInvalidateActions() throws {
        let bounds = WindowBounds(x: 10, y: 20, width: 30, height: 40)
        func input(enabled: Bool? = true, focused: Bool? = false, selected: Bool? = false,
                   bounds: WindowBounds) -> AXTreeInputNode {
            .init(role: "AXWindow", children: [
                .init(role: "AXGroup", enabled: enabled, focused: focused, selected: selected,
                    bounds: bounds, children: [.init(role: "AXButton", actions: ["AXPress"])])
            ])
        }
        let recorded = try presentationSnapshot(input(bounds: bounds))
        let record = SnapshotRecord(id: "123e4567-e89b-42d3-a456-426614174000",
            createdAt: "2026-09-08T10:00:00.000Z", expiresAt: "2026-09-08T10:10:00.000Z",
            target: recorded.target, treeOptions: recorded.treeOptions, evidence: recorded.evidence)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let persistedBefore = try encoder.encode(record)
        let wire = SnapshotResult(record: record, snapshot: recorded).wireData
        XCTAssertEqual(try encoder.encode(record), persistedBefore)
        XCTAssertEqual(SnapshotPresentation(snapshot: recorded).emittedNodes, 2)
        XCTAssertNoThrow(try SnapshotService.validateEvidence(recorded, live: recorded, ref: 1))
        for changed in [
            input(enabled: nil, bounds: bounds),
            input(focused: nil, bounds: bounds),
            input(selected: nil, bounds: bounds),
            input(bounds: .init(x: 11, y: 20, width: 30, height: 40))
        ] {
            let live = try presentationSnapshot(changed)
            XCTAssertEqual(presentationWire(live)["tree"], wire["tree"])
            XCTAssertNotEqual(recorded.evidence.nodes, live.evidence.nodes)
            XCTAssertEqual(recorded.evidence.refs, live.evidence.refs)
            XCTAssertThrowsError(try SnapshotService.validateEvidence(recorded, live: live, ref: 1)) {
                XCTAssertEqual(($0 as? NativeFailure)?.code, "STALE_SNAPSHOT")
            }
        }
    }

    func testLeafOnlyPresentationPreservesEveryObservedNodeAndField() throws {
        let snapshot = try presentationSnapshot(neutralWrapperInput(), mode: .leafOnly)
        XCTAssertEqual(presentationWire(snapshot)["tree"], .object(["elements": .array([
            .object(["role": .string("AXWindow"), "children": .array([
                .object(["role": .string("AXGroup"), "enabled": .bool(true),
                    "focused": .bool(false), "selected": .bool(false), "children": .array([
                        .object(["role": .string("AXButton"), "ref": .number(1),
                            "title": .string(" Save "), "label": .string("Commit"), "value": .string("draft"),
                            "actions": .array([.string("AXPress")]), "enabled": .bool(true),
                            "focused": .bool(false), "selected": .bool(false)])
                    ])])
            ])])
        ])]))
    }

    func testPresentationByteMeasurements() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (name, root) in [("neutral-wrapper", neutralWrapperInput()), ("zero-ref-text", zeroRefTextInput())] {
            let snapshot = try presentationSnapshot(root)
            let data = presentationWire(snapshot)
            let tree = try encoder.encode(XCTUnwrap(data["tree"]))
            let reply = try encoder.encode(WireReply.success(command: .snapshot, data: data))
            let verbose = try presentationSnapshot(root, mode: .leafOnly)
            XCTAssertEqual(snapshot.evidence, verbose.evidence)
            if name == "neutral-wrapper" {
                let verboseData = presentationWire(verbose)
                XCTAssertLessThan(tree.count, try encoder.encode(XCTUnwrap(verboseData["tree"])).count)
                XCTAssertLessThan(reply.count, try encoder.encode(WireReply.success(command: .snapshot, data: verboseData)).count)
            }
            for mode in [HintMode.full, .leafOnly] {
                let noncompact = try presentationSnapshot(root, mode: mode)
                XCTAssertEqual(SnapshotPresentation(snapshot: noncompact).emittedNodes, noncompact.evidence.nodes.count)
            }
            print("PRESENTATION_METRIC \(name) treeBytes=\(tree.count) replyBytes=\(reply.count) refs=\(snapshot.evidence.refs.count)")
            print("PRESENTATION_TREE \(name) \(String(decoding: tree, as: UTF8.self))")
            print("PRESENTATION_REPLY \(name) \(String(decoding: reply, as: UTF8.self))")
        }
    }

    func testCoverageReportsOriginalRootElementCapAndZeroRefs() throws {
        let snapshot = try presentationSnapshot(truncationPolicyInput(), maxElements: 2)
        XCTAssertEqual(presentationWire(snapshot)["coverage"], .object([
            "scope": .string("selectedWindow"), "absenceIsConclusive": .bool(false),
            "observedNodes": .number(2), "emittedNodes": .number(2), "refCount": .number(0),
            "limits": .object(["maxDepth": .number(8), "maxElements": .number(2)]),
            "boundaries": .array([
                .object(["path": .array([.number(0)]), "reason": .string("maxElements"),
                    "observedChildren": .number(0), "totalChildren": .number(1)]),
                .object(["path": .array([]), "reason": .string("maxElements"),
                    "observedChildren": .number(1), "totalChildren": .number(2)])
            ]), "noRefReason": .string("traversalLimited")
        ]))
        XCTAssertTrue(snapshot.evidence.refs.isEmpty)
    }

    func testCoveragePreservesDepthAndMixedBoundaryOrderAndCounts() throws {
        let depth = try presentationSnapshot(truncationPolicyInput(), maxDepth: 1, maxElements: 20)
        let mixed = try presentationSnapshot(truncationPolicyInput(), maxDepth: 1, maxElements: 2)
        let depthBoundary: JSONValue = .object([
            "path": .array([.number(0)]), "reason": .string("maxDepth"),
            "observedChildren": .number(0), "totalChildren": .number(1)
        ])
        for (snapshot, expectedBoundaries, observed, refs) in [
            (depth, [depthBoundary], 3, 1),
            (mixed, [depthBoundary, .object([
                "path": .array([]), "reason": .string("maxElements"),
                "observedChildren": .number(1), "totalChildren": .number(2)
            ])], 2, 0)
        ] {
            let before = snapshot.evidence
            guard case let .object(coverage) = presentationWire(snapshot)["coverage"] else {
                return XCTFail("missing coverage")
            }
            XCTAssertEqual(coverage["boundaries"], .array(expectedBoundaries))
            XCTAssertEqual(coverage["observedNodes"], .number(Double(observed)))
            XCTAssertEqual(coverage["emittedNodes"], .number(Double(observed)))
            XCTAssertEqual(coverage["refCount"], .number(Double(refs)))
            XCTAssertEqual(coverage["limits"], .object([
                "maxDepth": .number(1), "maxElements": .number(Double(snapshot.treeOptions.maxElements))
            ]))
            XCTAssertEqual(coverage["noRefReason"], refs == 0 ? .string("traversalLimited") : nil)
            XCTAssertEqual(presentationWire(snapshot)["truncated"], .bool(true))
            XCTAssertEqual(snapshot.evidence, before)
        }
    }

    func testCoverageKeepsOriginalNestedPathAfterAncestorCollapse() throws {
        let root = AXTreeInputNode(role: "AXWindow", children: [
            AXTreeInputNode(role: "AXGroup", children: [
                AXTreeInputNode(role: "AXScrollArea", children: [
                    AXTreeInputNode(role: "AXButton", actions: ["AXPress"])
                ])
            ])
        ])
        let snapshot = try presentationSnapshot(root, maxDepth: 2)
        XCTAssertEqual(snapshot.evidence.truncation.map(\.path), [[0, 0]])
        XCTAssertEqual(SnapshotPresentation(snapshot: snapshot).emittedNodes, 2)
        XCTAssertEqual(presentationWire(snapshot)["tree"], .object(["elements": .array([
            .object(["role": .string("AXWindow"), "children": .array([
                .object(["role": .string("AXScrollArea")])
            ])])
        ])]))
        guard case let .object(coverage) = presentationWire(snapshot)["coverage"] else {
            return XCTFail("missing coverage")
        }
        XCTAssertEqual(coverage["observedNodes"], .number(3))
        XCTAssertEqual(coverage["emittedNodes"], .number(2))
        XCTAssertEqual(coverage["boundaries"], .array([.object([
            "path": .array([.number(0), .number(0)]), "reason": .string("maxDepth"),
            "observedChildren": .number(0), "totalChildren": .number(1)
        ])]))
        XCTAssertEqual(coverage["noRefReason"], .string("traversalLimited"))
    }

    func testCoverageCompleteCountsAndNoRefReasonAcrossHintModes() throws {
        for mode in [HintMode.full, .leafOnly, .leafCompact] {
            for root in [neutralWrapperInput(), zeroRefTextInput()] {
                let snapshot = try presentationSnapshot(root, mode: mode)
                let before = snapshot.evidence
                guard case let .object(coverage) = presentationWire(snapshot)["coverage"] else {
                    return XCTFail("missing coverage")
                }
                let observed = snapshot.evidence.nodes.count
                XCTAssertEqual(coverage["scope"], .string("selectedWindow"))
                XCTAssertEqual(coverage["absenceIsConclusive"], .bool(false))
                XCTAssertEqual(coverage["observedNodes"], .number(Double(observed)))
                let emitted = mode == .leafCompact ? 2 : observed
                XCTAssertEqual(coverage["emittedNodes"], .number(Double(emitted)))
                let refs = mode == .full ? observed : (observed == 3 ? 1 : 0)
                XCTAssertEqual(coverage["refCount"], .number(Double(refs)))
                XCTAssertEqual(coverage["boundaries"], .array([]))
                XCTAssertEqual(coverage["noRefReason"], refs == 0 ? .string("noEligibleRefs") : nil)
                XCTAssertEqual(presentationWire(snapshot)["truncated"], .bool(false))
                XCTAssertEqual(snapshot.evidence, before)
            }
        }
    }

    func testCompactSnapshotWireDataMatchesSharedActualProducerFixture() throws {
        let snapshot = try presentationSnapshot(neutralWrapperInput())
        let reply = WireReply.success(command: .snapshot, data: presentationWire(snapshot))
        let actual = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? NSDictionary
        )
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            root.appendingPathComponent("contracts/fixtures/snapshot-compact-reply.json"))) as? NSDictionary)
        XCTAssertEqual(actual, expected)
    }

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
}

private func assertCompactPresentation(
    _ root: AXTreeInputNode,
    expected: String,
    emittedNodes: Int,
    refPaths: [[Int]],
    maxDepth: Int = 8,
    maxElements: Int = 500,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let compact = try presentationSnapshot(root, maxDepth: maxDepth, maxElements: maxElements)
    let verbose = try presentationSnapshot(root, mode: .leafOnly, maxDepth: maxDepth, maxElements: maxElements)
    let before = compact.evidence
    let presentation = SnapshotPresentation(snapshot: compact)
    let expectedTree = try JSONDecoder().decode(JSONValue.self, from: Data(expected.utf8))
    XCTAssertEqual(presentation.tree, expectedTree, file: file, line: line)
    XCTAssertEqual(presentation.emittedNodes, emittedNodes, file: file, line: line)
    XCTAssertEqual(presentationWire(compact)["tree"], expectedTree, file: file, line: line)
    XCTAssertEqual(compact.evidence, before, file: file, line: line)
    XCTAssertEqual(compact.evidence, verbose.evidence, file: file, line: line)
    XCTAssertEqual(compact.evidence.refs.map(\.path), refPaths, file: file, line: line)
    XCTAssertNoThrow(try AXEvidencePolicy.validate(compact.evidence, options: compact.treeOptions), file: file, line: line)
}

private func presentationWire(_ snapshot: AXTreeSnapshot) -> [String: JSONValue] {
    let record = SnapshotRecord(
        id: "123e4567-e89b-42d3-a456-426614174000",
        createdAt: "2026-09-08T10:00:00.000Z",
        expiresAt: "2026-09-08T10:10:00.000Z",
        target: snapshot.target, treeOptions: snapshot.treeOptions,
        evidence: snapshot.evidence
    )
    return SnapshotResult(record: record, snapshot: snapshot).wireData
}

private func presentationSnapshot(
    _ root: AXTreeInputNode,
    mode: HintMode = .leafCompact,
    maxDepth: Int = 8,
    maxElements: Int = 500
) throws -> AXTreeSnapshot {
    AXTree.snapshot(target: try treeFixture("save-cancel").target,
        options: .init(maxDepth: maxDepth, maxElements: maxElements, hintMode: mode), root: root)
}

private func neutralWrapperInput() -> AXTreeInputNode {
    AXTreeInputNode(role: "AXWindow", children: [
        AXTreeInputNode(role: "AXGroup", enabled: true, focused: false, selected: false, children: [
            AXTreeInputNode(role: "AXButton", title: " Save ", label: "Commit", value: "draft",
                enabled: true, focused: false, selected: false, actions: ["AXPress"])
        ])
    ])
}

private func zeroRefTextInput() -> AXTreeInputNode {
    AXTreeInputNode(role: "AXWindow", children: [
        AXTreeInputNode(role: "AXStaticText", value: "Read only")
    ])
}

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
