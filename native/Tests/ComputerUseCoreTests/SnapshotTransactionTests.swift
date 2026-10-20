import ApplicationServices
import Darwin
import XCTest
@testable import ComputerUseCore

final class SnapshotTransactionTests: XCTestCase {
    private let wall = Date(timeIntervalSince1970: 1_788_861_900)

    func testPreparationIsBracketedByIdentityChecksBeforeObservation() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let command = context()
        var phases: [String] = []
        var lockHeld = false
        let lock = DesktopLock(rootURL: root, flock: { descriptor, operation in
            let value = flock(descriptor, operation)
            if value == 0 { lockHeld = operation != LOCK_UN }
            return SystemCallResult(value: value, error: value < 0 ? errno : 0)
        })
        let service = SnapshotService(
            lock: lock, store: StateStore(rootURL: root),
            resolve: { _, _ in phases.append("resolve"); return snapshot.target },
            observe: { _, _, _ in
                phases.append("observe")
                return AXTreeObservation(snapshot: snapshot, liveElements: [:])
            },
            prepareSnapshot: { target, context in
                XCTAssertTrue(lockHeld)
                XCTAssertEqual(target, snapshot.target)
                XCTAssertTrue(context === command)
                phases.append("prepare")
            },
            validateTarget: { identity, context in
                XCTAssertEqual(identity, snapshot.target.identity)
                XCTAssertTrue(context === command)
                phases.append("validate")
                return snapshot.target
            }
        )
        _ = try await service.snapshot(selector: .pid(42, windowId: 7),
            options: snapshot.treeOptions, context: command)
        XCTAssertEqual(phases, ["resolve", "validate", "prepare", "validate", "observe", "validate"])
        XCTAssertFalse(lockHeld)
    }

    func testPreparationRejectsChangedProcessOrWindowBeforeAndAfterHook() async throws {
        let snapshot = try transactionFixture("save-cancel")
        let changedWindowID = ResolvedTarget(
            identity: TargetIdentity(pid: snapshot.target.identity.pid,
                launchDate: snapshot.target.identity.launchDate,
                bundleId: snapshot.target.identity.bundleId,
                windowId: snapshot.target.identity.windowId + 1),
            title: snapshot.target.title, bounds: snapshot.target.bounds
        )
        let changedBounds = ResolvedTarget(identity: snapshot.target.identity,
            title: snapshot.target.title,
            bounds: WindowBounds(x: 1, y: 2, width: 300, height: 400))
        for changed in [changedLaunchTarget(snapshot.target), changedWindowID,
                        changedWindowTarget(snapshot.target), changedBounds] {
            for changedAt in [1, 2] {
                let root = transactionRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                var validations = 0
                var phases: [String] = []
                let service = SnapshotService(
                    lock: DesktopLock(rootURL: root), store: StateStore(rootURL: root),
                    resolve: { _, _ in snapshot.target },
                    observe: { _, _, _ in
                        phases.append("observe")
                        return AXTreeObservation(snapshot: snapshot, liveElements: [:])
                    },
                    prepareSnapshot: { _, _ in phases.append("prepare") },
                    validateTarget: { identity, _ in
                        XCTAssertEqual(identity, snapshot.target.identity)
                        validations += 1
                        phases.append("validate")
                        return validations == changedAt ? changed : snapshot.target
                    }
                )
                await assertTransactionFailure("STALE_SNAPSHOT") {
                    try await service.snapshot(selector: .pid(42, windowId: 7),
                        options: snapshot.treeOptions, context: self.context())
                }
                XCTAssertEqual(phases, changedAt == 1 ? ["validate"] : ["validate", "prepare", "validate"])
                let snapshots = root.appendingPathComponent("snapshots")
                XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [], [])
            }
        }
    }

    func testCancellationOrDeadlineAtEachSnapshotPhaseStopsBeforeNextPhase() async throws {
        let snapshot = try transactionFixture("save-cancel")
        let orderedPhases = ["resolve", "validate-before", "prepare", "validate-after", "observe", "validate-final"]
        for code in ["INTERRUPTED", "TIMEOUT"] {
            for stoppedAt in orderedPhases {
                let root = transactionRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let ticks = LockedUInt64(0)
                let command = context(timeoutMilliseconds: 1, monotonicNow: { ticks.value })
                var phases: [String] = []
                var validations = 0
                func phase(_ name: String) {
                    phases.append(name)
                    if name == stoppedAt {
                        if code == "INTERRUPTED" { command.cancel() }
                        else { ticks.value = command.deadline }
                    }
                }
                let service = SnapshotService(
                    lock: DesktopLock(rootURL: root), store: StateStore(rootURL: root),
                    resolve: { _, _ in phase("resolve"); return snapshot.target },
                    observe: { _, _, _ in
                        phase("observe")
                        return AXTreeObservation(snapshot: snapshot, liveElements: [:])
                    },
                    prepareSnapshot: { _, _ in phase("prepare") },
                    validateTarget: { _, _ in
                        let name = ["validate-before", "validate-after", "validate-final"][validations]
                        validations += 1
                        phase(name)
                        return snapshot.target
                    }
                )
                await assertTransactionFailure(code, message: stoppedAt) {
                    try await service.snapshot(selector: .pid(42, windowId: 7),
                        options: snapshot.treeOptions, context: command)
                }
                let stopIndex = try XCTUnwrap(orderedPhases.firstIndex(of: stoppedAt))
                XCTAssertEqual(phases, Array(orderedPhases.prefix(stopIndex + 1)), "\(code) at \(stoppedAt)")
                let snapshots = root.appendingPathComponent("snapshots")
                XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [], [])
            }
        }
    }

    func testMappedPreparationFailuresDoNotObserveOrPublish() async throws {
        let snapshot = try transactionFixture("save-cancel")
        for code in ["NATIVE_FAILURE", "PERMISSION_DENIED", "TIMEOUT", "INTERRUPTED"] {
            let root = transactionRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            var phases: [String] = []
            let expected = NativeFailure(code, "injected preparation failure", details: ["safe": .string("kept")])
            let service = SnapshotService(
                lock: DesktopLock(rootURL: root), store: StateStore(rootURL: root),
                resolve: { _, _ in snapshot.target },
                observe: { _, _, _ in
                    phases.append("observe")
                    return AXTreeObservation(snapshot: snapshot, liveElements: [:])
                },
                prepareSnapshot: { _, _ in
                    phases.append("prepare")
                    throw expected
                },
                validateTarget: { _, _ in phases.append("validate"); return snapshot.target }
            )
            let failure = await captureTransactionFailure {
                try await service.snapshot(selector: .pid(42, windowId: 7),
                    options: snapshot.treeOptions, context: self.context())
            }
            XCTAssertEqual(failure?.code, expected.code)
            XCTAssertEqual(failure?.message, expected.message)
            XCTAssertEqual(failure?.details, expected.details)
            XCTAssertEqual(phases, ["validate", "prepare"])
            let snapshots = root.appendingPathComponent("snapshots")
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? [], [])
        }
    }

    func testRawPreparationFailuresStopObservationAndPublication() async throws {
        let snapshot = try transactionFixture("save-cancel")
        let statuses: [AXError] = [.attributeUnsupported, .failure, .illegalArgument, .cannotComplete,
                                    .invalidUIElement, .apiDisabled, .notImplemented, .noValue]
        for phase in ["read-timeout", "write-timeout", "copy", "write", "throw"] {
            let phaseStatuses: [AXError]
            if phase == "copy" { phaseStatuses = statuses.filter { $0 != .attributeUnsupported && $0 != .noValue } }
            else if phase == "write" { phaseStatuses = [.cannotComplete, .invalidUIElement, .apiDisabled, .notImplemented, .noValue] }
            else if phase == "throw" { phaseStatuses = [.failure] }
            else { phaseStatuses = statuses }
            for status in phaseStatuses {
                let root = transactionRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                var lockHeld = false
                let lock = DesktopLock(rootURL: root, flock: { fd, op in
                    let result = flock(fd, op)
                    if result == 0 { lockHeld = op != LOCK_UN }
                    return SystemCallResult(value: result, error: result < 0 ? errno : 0)
                })
                var setups = 0
                var writes = 0
                var observations = 0
                var validations = 0
                let expected = phase == "throw"
                    ? NativeFailure("NATIVE_FAILURE", "raw setup threw", details: ["phase": .string(phase)])
                    : NativeFailure(status == .apiDisabled ? "PERMISSION_DENIED" : "NATIVE_FAILURE",
                        status == .apiDisabled ? "Accessibility access is unavailable" : "Accessibility data could not be read reliably",
                        details: ["ax": expectedAXDiagnostic(phase: "preparation",
                            operation: phase == "copy" ? "copyAttribute" : phase == "write" ? "setAttribute" : "setMessagingTimeout",
                            attribute: ["copy", "write"].contains(phase) ? "AXManualAccessibility" : nil,
                            status: status, name: testAXName(status))])
                let api = AXPreparationAPI(isTrusted: { true },
                    createApplication: { _ in AXUIElementCreateApplication(42) },
                    setMessagingTimeout: { _, _ in
                        if phase == "throw" { throw expected }
                        setups += 1
                        return phase == "read-timeout" || (phase == "write-timeout" && setups == 2) ? status : .success
                    }, copyAttribute: { _, _ in phase == "copy" ? (status, nil) : (.noValue, nil) },
                    setAttribute: { _, _, _ in writes += 1; return phase == "write" ? status : .success })
                let service = SnapshotService(lock: lock, store: StateStore(rootURL: root),
                    resolve: { _, _ in snapshot.target },
                    observe: { _, _, _ in
                        observations += 1
                        return AXTreeObservation(snapshot: snapshot, liveElements: [:])
                    }, prepareSnapshot: { target, context in
                        XCTAssertTrue(lockHeld)
                        try await AXSnapshotPreparation.prepare(pid: target.identity.pid, context: context,
                            driver: AXSnapshotPreparation.makeDriver(api: api))
                    }, validateTarget: { _, _ in validations += 1; return snapshot.target })
                let failure = await captureTransactionFailure {
                    try await service.snapshot(selector: .pid(42, windowId: 7), options: snapshot.treeOptions,
                                               context: self.context())
                }
                XCTAssertEqual(failure?.code, expected.code, "\(phase) \(status)")
                XCTAssertEqual(failure?.message, expected.message)
                XCTAssertEqual(failure?.details, expected.details)
                XCTAssertEqual(observations, 0)
                XCTAssertEqual(validations, 1)
                XCTAssertEqual(writes, phase == "write" ? 1 : 0)
                XCTAssertFalse(lockHeld)
                XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath:
                    root.appendingPathComponent("snapshots").path)) ?? [], [])
            }
        }
    }

    func testNativeServiceSerializesSafeRawFailuresAndNeverArbitraryErrorDescriptions() async throws {
        let fixture = try transactionFixture("save-cancel")
        let sentinels = ["PRIVATE-title-836", "PRIVATE-value-937", "https://private.invalid/738", "PRIVATE-identifier-639"]
        let request = try XCTUnwrap(WireRequest.decode([
            "schemaVersion": 1, "command": "snapshot", "target": ["pid": 42, "windowId": 7],
            "tree": ["maxDepth": 8, "maxElements": 500, "hintMode": "full"],
            "options": ["timeoutMs": 1_000, "cursor": "off"]
        ]))
        for stage in ["preparation", "observation", "generic", "first-context"] {
            let root = transactionRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let lock = DesktopLock(rootURL: root)
            let first = liveAXFailure(for: .cannotComplete, diagnostic:
                AXDiagnosticContext(phase: .resolution, operation: .setMessagingTimeout))
            let api = AXPreparationAPI(isTrusted: { true }, createApplication: { _ in AXUIElementCreateApplication(42) },
                setMessagingTimeout: { _, _ in .success }, copyAttribute: { _, _ in
                    if stage == "generic" { throw NSError(domain: sentinels[0], code: 1,
                        userInfo: [NSLocalizedDescriptionKey: sentinels.joined(separator: " ")]) }
                    if stage == "first-context" { throw first }
                    return stage == "preparation" ? (.success, ["private-object": sentinels] as CFDictionary) : (.success, kCFBooleanTrue)
                }, setAttribute: { _, _, _ in .success })
            var observations = 0
            let service = SnapshotService(lock: lock, store: StateStore(rootURL: root), resolve: { _, _ in fixture.target },
                observe: { target, options, context in
                    observations += 1
                    var status = AXError.cannotComplete
                    let values = [AXValueCreate(.axError, &status)!] + sentinels.map { $0 as CFTypeRef }
                        + Array(repeating: ["private-object": sentinels] as CFDictionary, count: 6)
                    let cache = LiveAXBatchCache(multipleRead: { _, _ in (.success, values as CFArray) },
                        singleRead: { _, _ in XCTFail("no fallback"); return (.failure, nil) })
                    let reader = liveAXTreeReader(cache: cache,
                        readChildrenAttribute: { _, _ in XCTFail("role failure stops children"); return (.noValue, nil) },
                        copyActionNames: { _ in XCTFail("role failure stops actions"); return (.noValue, nil) })
                    let read = try AXTree.readSnapshot(target: target, options: options,
                        root: AXUIElementCreateApplication(42), reader: reader,
                        checkpoint: { try context.check() }, prepare: { _ in })
                    return AXTreeObservation(snapshot: read.snapshot, liveElements: [:])
                }, prepareSnapshot: { target, context in
                    try await AXSnapshotPreparation.prepare(pid: target.identity.pid, context: context,
                        driver: AXSnapshotPreparation.makeDriver(api: api))
                }, validateTarget: { _, _ in fixture.target })
            let reply = await NativeService(snapshotService: service).execute(request, context: context())
            XCTAssertFalse(reply.ok)
            let expected: [String: JSONValue]?
            switch stage {
            case "preparation": expected = ["ax": expectedAXDiagnostic(phase: "preparation", operation: "copyAttribute",
                attribute: "AXManualAccessibility", status: .success, name: "success", reason: "unexpectedType")]
            case "observation": expected = ["ax": expectedAXDiagnostic(operation: "copyMultipleAttributes", attribute: "AXRole",
                status: .cannotComplete, name: "cannotComplete", scope: "batchEntry")]
            case "first-context": expected = first.details
            default: expected = nil
            }
            XCTAssertEqual(reply.error?.details, expected)
            XCTAssertEqual(reply.error?.message, stage == "generic" ? "Native command failed" : "Accessibility data could not be read reliably")
            let encoded = try JSONEncoder().encode(reply)
            let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            for sentinel in sentinels + ["private-object"] { XCTAssertFalse(json.contains(sentinel)) }
            let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
            guard case let .object(envelope) = decoded, case let .object(error)? = envelope["error"] else {
                return XCTFail("invalid native envelope")
            }
            XCTAssertEqual(error["details"], expected.map(JSONValue.object))
            XCTAssertEqual(observations, stage == "observation" ? 1 : 0)
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("snapshots").path)) ?? [], [])
            try await lock.withLock(context: context()) {} // all failure paths release the lock
        }
    }

    func testRawRequestedAndRejectedWriteControlsPublishWithIdentityBrackets() async throws {
        let snapshot = try transactionFixture("save-cancel")
        for status in [AXError.success, .attributeUnsupported, .failure, .illegalArgument] {
            let root = transactionRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = StateStore(rootURL: root)
            var phases: [String] = []
            var writes = 0
            let api = AXPreparationAPI(isTrusted: { true },
                createApplication: { _ in AXUIElementCreateApplication(42) },
                setMessagingTimeout: { _, _ in .success }, copyAttribute: { _, _ in (.success, kCFBooleanTrue) },
                setAttribute: { _, _, _ in writes += 1; return status })
            let service = SnapshotService(lock: DesktopLock(rootURL: root), store: store,
                resolve: { _, _ in phases.append("resolve"); return snapshot.target },
                observe: { _, _, _ in
                    phases.append("observe"); return AXTreeObservation(snapshot: snapshot, liveElements: [:])
                }, prepareSnapshot: { target, context in
                    phases.append("prepare")
                    try await AXSnapshotPreparation.prepare(pid: target.identity.pid, context: context,
                        driver: AXSnapshotPreparation.makeDriver(api: api))
                }, validateTarget: { _, _ in phases.append("validate"); return snapshot.target })
            let result = try await service.snapshot(selector: .pid(42, windowId: 7), options: snapshot.treeOptions,
                                                    context: context())
            XCTAssertEqual(try store.readSnapshot(id: result.record.id, context: context()).evidence, snapshot.evidence)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
                root.appendingPathComponent("snapshots").path).count, 1)
            XCTAssertEqual(writes, status == .success ? 1 : 2)
            XCTAssertEqual(phases, ["resolve", "validate", "prepare", "validate", "observe", "validate"])
        }
    }

    func testProductionBatchFailuresNeverPublishAndValidBatchControlDoes() async throws {
        let fixture = try transactionFixture("save-cancel")
        let valid = (["AXWindow" as CFTypeRef] + Array(repeating: kCFNull as CFTypeRef, count: 10)) as CFArray
        var outcomes: [(AXError, CFArray?)] = [(.success, valid), (.success, nil),
            (.success, ["AXWindow" as CFString] as CFArray),
            (.success, Array(repeating: "extra" as CFString, count: 12) as CFArray)]
        outcomes += [AXError.apiDisabled, .invalidUIElement, .cannotComplete, .failure, .noValue,
                     .illegalArgument, .notImplemented].map { ($0, nil) }
        for (status, values) in outcomes {
            let root = transactionRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = StateStore(rootURL: root)
            var singles = 0
            var batches = 0
            var lockHeld = false
            let lock = DesktopLock(rootURL: root, flock: { fd, op in
                let result = flock(fd, op)
                if result == 0 { lockHeld = op != LOCK_UN }
                return SystemCallResult(value: result, error: result < 0 ? errno : 0)
            })
            let cache = LiveAXBatchCache(multipleRead: { _, _ in batches += 1; return (status, values) },
                singleRead: { _, name in
                    singles += 1
                    return name == kAXRoleAttribute ? (.success, "AXWindow" as CFString) : (.noValue, nil)
                })
            let scalars = liveAXTreeReader(cache: cache)
            let reader = AXTreeReader<AXUIElement>(string: scalars.string, bool: scalars.bool,
                children: { _ in .unavailable }, actions: { _ in .unavailable }, bounds: scalars.bounds)
            let service = SnapshotService(lock: lock, store: store,
                resolve: { _, _ in fixture.target }, observe: { target, options, context in
                    let read = try AXTree.readSnapshot(target: target, options: options,
                        root: AXUIElementCreateApplication(42), reader: reader,
                        checkpoint: { try context.check() }, prepare: { _ in })
                    return AXTreeObservation(snapshot: read.snapshot, liveElements: [:])
                }, prepareSnapshot: { _, _ in }, validateTarget: { _, _ in fixture.target })
            if status == .success && values === valid {
                let result = try await service.snapshot(selector: .pid(42, windowId: 7),
                    options: fixture.treeOptions, context: context())
                XCTAssertEqual(try store.readSnapshot(id: result.record.id, context: context()).evidence,
                               result.snapshot.evidence)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
                    root.appendingPathComponent("snapshots").path).count, 1)
            } else {
                let failure = await captureTransactionFailure {
                    try await service.snapshot(selector: .pid(42, windowId: 7),
                        options: fixture.treeOptions, context: self.context())
                }
                assertAXDiagnostic(try XCTUnwrap(failure), operation: "copyMultipleAttributes",
                    status: status, name: testAXName(status), scope: "batchTopLevel",
                    reason: status != .success ? "statusFailure" : values == nil ? "missingValue" : "batchLengthMismatch")
                XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath:
                    root.appendingPathComponent("snapshots").path)) ?? [], [])
            }
            XCTAssertEqual(batches, 1)
            XCTAssertEqual(singles, 0)
            XCTAssertFalse(lockHeld)
        }
    }

    func testSnapshotRefreshesIdentityAfterObservationBeforePublishing() async throws {
        let root = transactionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try transactionFixture("save-cancel")
        let changed = changedLaunchTarget(snapshot.target)
        var observations = 0
        var validations = 0
        let store = StateStore(rootURL: root)
        let service = SnapshotService(
            lock: DesktopLock(rootURL: root),
            store: store,
            resolve: { _, _ in snapshot.target },
            observe: { _, _, _ in
                observations += 1
                return AXTreeObservation(snapshot: snapshot, liveElements: [:])
            },
            prepareSnapshot: { _, _ in },
            validateTarget: { _, _ in
                validations += 1
                return validations <= 2 ? snapshot.target : changed
            },
            prepareElement: { _, _ in }
        )
        await assertTransactionFailure("STALE_SNAPSHOT") {
            try await service.snapshot(
                selector: .pid(42, windowId: 7),
                options: snapshot.treeOptions,
                context: self.context()
            )
        }
        XCTAssertEqual(observations, 1)
        XCTAssertEqual(validations, 3)
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
            prepareSnapshot: { _, _ in XCTFail("action must not prepare AX") },
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
            prepareSnapshot: { _, _ in },
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
            prepareSnapshot: { _, _ in },
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
                prepareSnapshot: { _, _ in },
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
            prepareSnapshot: { _, _ in },
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
            prepareSnapshot: { _, _ in },
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
            prepareSnapshot: { _, _ in },
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
